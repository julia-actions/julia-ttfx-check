# Measure a package's time to first X at two commits, and that of packages depending on
# it, and judge the difference.
#
#   julia --startup-file=no ttfx.jl
#
# Configured through environment variables (see action.yml, which sets them from its
# inputs): TTFX_BASE_DIR and TTFX_HEAD_DIR are checkouts of the package at the two commits,
# TTFX_WORK a scratch directory and TTFX_OUT the directory for the report.
#
# The measurement and the verdicts follow the TTFX job of JuliaLang/julia's CI. The two
# arms are measured in ABBA blocks, each sample in fresh processes from a cold cache. A
# difference in a task's metric is robust when every block, each pairing a head sample
# with the base sample taken next to it in time, clears the threshold; the samples of the
# two arms do not overlap; and the medians differ by at least the floor. With several
# tasks, each metric's geometric mean over them is also judged per block, against a
# tighter threshold, which is where a small regression spread over the dependents shows.

using TOML

const METRICS = [
    (key = "precompile", name = "precompile",      threshold = 8,  suite = 2, floor = 0.25),
    (key = "load",       name = "load (cold)",     threshold = 10, suite = 2, floor = 0.10),
    (key = "run",        name = "run (cold)",      threshold = 15, suite = 3, floor = 0.05),
    (key = "warm",       name = "load+run (warm)", threshold = 15, suite = 3, floor = 0.05),
]

const MARKER = "__TTFX__:"

env(key, default) = (v = strip(get(ENV, key, "")); isempty(v) ? default : String(v))
envint(key, default) = parse(Int, env(key, string(default)))
envfloat(key, default) = parse(Float64, env(key, string(default)))

struct Arm
    label::String  # "base" or "head"
    src::String    # the package checkout
    root::String   # this arm's directory under the work directory
end
depot(a::Arm) = joinpath(a.root, "depot")

# A task is a package to load, and optionally a workload to run after loading it: the
# package under test, or one of its dependents.
struct PkgTask
    pkg::String
    workload::String    # path of the workload script, or "" for none
    dependent::Bool
end
project(a::Arm, t::PkgTask) = joinpath(a.root, "env-" * t.pkg)
script(a::Arm, t::PkgTask) = joinpath(a.root, "task-" * t.pkg * ".jl")
precompile_script(a::Arm, t::PkgTask) = joinpath(a.root, "precompile-" * t.pkg * ".jl")
metrics_of(cfg, t::PkgTask) = filter(m -> m.key != "run" || !isempty(t.workload), cfg.metrics)

struct Config
    julia::Cmd
    work::String
    out::String
    shared_depot::String
    name::String           # keys the comment marker
    pkg::String
    tasks::Vector{PkgTask}
    blocks::Int
    repeats::Int
    timeout::Float64
    precompile_all::Bool
    metrics::Vector{Any}   # METRICS with the configured thresholds and floors
end

function config()
    work = abspath(env("TTFX_WORK", joinpath(tempdir(), "julia-ttfx")))
    head_dir = abspath(env("TTFX_HEAD_DIR", pwd()))
    repo_dir = abspath(env("TTFX_REPO_DIR", head_dir))
    proj = TOML.parsefile(joinpath(head_dir, "Project.toml"))
    haskey(proj, "name") || error("$(joinpath(head_dir, "Project.toml")) has no package name")
    pkg = proj["name"]
    # A workload is the path of a file relative to the repository root, or inline code.
    function workload_file(w, name)
        isempty(w) && return ""
        f = normpath(joinpath(repo_dir, w))
        isfile(f) && return f
        occursin(r"^[^\n]*\.jl$", w) && error("workload file `$w` not found in $repo_dir")
        mkpath(work)
        f = joinpath(work, "workload-$name.jl")
        write(f, w)
        return f
    end
    tasks = [PkgTask(pkg, workload_file(env("TTFX_WORKLOAD", ""), pkg), false)]
    # One dependent per line as `Name: workload`, or bare names separated by spaces or commas
    function add_dependent(d, w = "")
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", d) || error("not a package name in `dependents`: `$d`")
        d == pkg || any(t -> t.pkg == d, tasks) || push!(tasks, PkgTask(d, workload_file(w, d), true))
    end
    for line in split(env("TTFX_DEPENDENTS", ""), '\n')
        m = match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$", line)
        if m !== nothing
            add_dependent(m.captures[1], String(strip(m.captures[2])))
        else
            foreach(add_dependent, split(line, r"[\s,]+"; keepempty = false))
        end
    end
    metrics = map(METRICS) do m
        k = uppercase(m.key)
        (key = m.key, name = m.name,
         threshold = envfloat("TTFX_THRESHOLD_$k", m.threshold) / 100,
         suite = envfloat("TTFX_SUITE_THRESHOLD_$k", m.suite) / 100,
         floor = envfloat("TTFX_FLOOR_$k", m.floor))
    end
    name = env("TTFX_NAME", "default")
    occursin(r"^[A-Za-z0-9._-]+$", name) || error("name may only contain letters, digits, `.`, `_` and `-`, got `$name`")
    scope = env("TTFX_PRECOMPILE_SCOPE", "package")
    scope in ("package", "all") || error("precompile_scope must be `package` or `all`, got `$scope`")
    blocks = envint("TTFX_BLOCKS", 4)
    blocks >= 2 || error("blocks must be at least 2")
    repeats = envint("TTFX_REPEATS", 3)
    repeats >= 2 || error("repeats must be at least 2: the warm metric uses the repeats after the first")
    return Config(`$(Base.julia_cmd()[1]) --startup-file=no`, work,
                  abspath(env("TTFX_OUT", joinpath(work, "report"))), joinpath(work, "depot"),
                  name, pkg, tasks, blocks, repeats, envfloat("TTFX_TIMEOUT", 1800),
                  scope == "all", metrics), head_dir
end

# The arm's own depot goes first, so compiled code stays per arm, then the depot shared
# for registries, packages and artifacts, then Julia's bundled stdlib depots. ~/.julia is
# left out: earlier steps of the job may have put compiled code there.
function depot_path(cfg::Config, a::Union{Arm,Nothing})
    root = dirname(Sys.BINDIR)
    entries = [cfg.shared_depot, joinpath(root, "local", "share", "julia"), joinpath(root, "share", "julia")]
    a === nothing || pushfirst!(entries, depot(a))
    return join(entries, Sys.iswindows() ? ';' : ':')
end

# Run a subprocess under `timeout` seconds. Returns (stdout, stderr, succeeded, timed_out).
# SIGINT first so a precompile driver can stop its workers, SIGTERM 30 s later.
function run_timed(cmd::Cmd, timeout::Float64)
    err = IOBuffer()
    proc = open(pipeline(cmd; stderr = err), "r")
    timed_out = Ref(false)
    interrupt = Timer(timeout) do _
        timed_out[] = true
        process_running(proc) && kill(proc, Base.SIGINT)
    end
    terminate = Timer(timeout + 30) do _
        process_running(proc) && kill(proc)
    end
    out = try
        read(proc, String)
    finally
        close(interrupt); close(terminate)
    end
    wait(proc)
    return out, String(take!(err)), success(proc) && !timed_out[], timed_out[]
end

function log_output(cfg::Config, name, out, err)
    dir = joinpath(cfg.out, "logs")
    mkpath(dir)
    write(joinpath(dir, name * ".log"), "--- stdout\n", out, "\n--- stderr\n", err)
end

lastlines(s, n = 15) = join(last(split(rstrip(s), '\n'), n), '\n')
errmsg(e) = e isa ErrorException ? e.msg : sprint(showerror, e)

# Install the task's environment for the arm: the package checkout developed into a fresh
# project, plus the dependent from the registry. Packages and the registry go into the
# shared depot; the untimed first precompile fills the arm's own depot.
function setup!(cfg::Config, a::Arm, t::PkgTask)
    p = project(a, t)
    mkpath(p); mkpath(depot(a))
    code = """
        using Pkg
        Pkg.develop(path = $(repr(a.src)))
        $(t.dependent ? "Pkg.add($(repr(t.pkg)))" : "")
        Pkg.instantiate()
        """
    cmd = addenv(`$(cfg.julia) --project=$p -e $code`,
                 "JULIA_DEPOT_PATH" => depot_path(cfg, nothing), "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    out, err, ok, _ = run_timed(cmd, cfg.timeout)
    log_output(cfg, "setup-$(a.label)-$(t.pkg)", out, err)
    ok || error("installing failed:\n", lastlines(err))
    cmd = addenv(`$(cfg.julia) --project=$p -e "using Pkg; Pkg.precompile()"`,
                 "JULIA_DEPOT_PATH" => depot_path(cfg, a))
    out, err, ok, _ = run_timed(cmd, cfg.timeout)
    log_output(cfg, "precompile-$(a.label)-$(t.pkg)", out, err)
    ok || error("precompiling failed:\n", lastlines(err))
    write(script(a, t), task_script(t))
    write(precompile_script(a, t), precompile_code(precompile_targets(cfg, p, t)))
end

function manifest_deps(p::String)
    for f in ("JuliaManifest.toml", "Manifest.toml")
        path = joinpath(p, f)
        isfile(path) || continue
        m = TOML.parsefile(path)
        return get(m, "deps", m)
    end
    error("no manifest in $p")
end

# What a sample precompiles, in order: the task's package, then the extensions that are
# installed in its environment (all their trigger packages are), of the task's package
# and, for a dependent, of the package under test. As (name, uuid) pairs.
function precompile_targets(cfg::Config, p::String, t::PkgTask)
    deps = manifest_deps(p)
    entry(name) = deps[name][1]
    targets = [(t.pkg, entry(t.pkg)["uuid"])]
    for parent in unique([t.pkg, cfg.pkg])
        haskey(deps, parent) || continue
        e = entry(parent)
        for (ext, trig) in sort!(collect(get(e, "extensions", Dict{String,Any}())); by = first)
            triggers = trig isa String ? [trig] : trig
            all(x -> haskey(deps, x), triggers) || continue
            push!(targets, (ext, string(Base.uuid5(Base.UUID(e["uuid"]), ext))))
        end
    end
    return targets
end

# The script that times precompiling the targets. Every other package keeps the valid
# cache from setup, so this times exactly the targets, one `Base.compilecache` each, without
# Pkg's own overhead or its parallelism. Only the targets' own cache files in the arm's depot
# are deleted first: another package's extension of the same name keeps its cache.
function precompile_code(targets)
    ids = join(("Base.PkgId(Base.UUID($(repr(u))), $(repr(n)))" for (n, u) in targets), ", ")
    return """
        ids = [$ids]
        depot = DEPOT_PATH[1]
        for id in ids, f in Base.find_all_in_cache_path(id)
            startswith(f, depot) || continue
            stem = splitext(f)[1]
            for ext in (".ji", ".so", ".dylib", ".dll")
                rm(stem * ext; force = true)
            end
        end
        times = [@elapsed(Base.compilecache(id)) for id in ids]
        println(stdout, $(repr(MARKER)), sum(times), " ", join((id.name * "=" * string(t) for (id, t) in zip(ids, times)), " "))
        """
end

# The script run for each sample. Load is the `using`, run the workload. `time_ns` because
# `time` on Windows is too coarse for a fast `using`. With TTFX_GC=off
# the GC stays off throughout, apart from one full collection after load, which is left
# out of both phases.
function task_script(t::PkgTask)
    workload = isempty(t.workload) ? "" : "include($(repr(t.workload)))"
    return """
        const __ttfx_gc_off = get(ENV, "TTFX_GC", "") == "off"
        __ttfx_gc_off && GC.enable(false)
        __t1 = time_ns()
        using $(t.pkg)
        __t2 = time_ns()
        if __ttfx_gc_off
            GC.enable(true); GC.gc(); GC.enable(false)
        end
        __t2b = time_ns()
        $workload
        __t3 = time_ns()
        __ttfx_gc_off && GC.enable(true)
        println(stdout, $(repr(MARKER)), (__t2 - __t1) / 1e9, " ", (__t3 - __t2b) / 1e9)
        """
end

# Resolved versions of every package in an environment, to tell whether the two arms
# measured the same dependencies.
function resolved(p::String)
    for f in ("Manifest.toml", "JuliaManifest.toml")
        path = joinpath(p, f)
        isfile(path) || continue
        m = TOML.parsefile(path)
        deps = get(m, "deps", m)
        v = Dict{String,String}()
        for (name, entries) in deps
            entries isa Vector || continue
            e = entries[1]
            v[name] = string(get(e, "version", ""), " ", get(e, "git-tree-sha1", get(e, "path", "")))
        end
        return v
    end
    return Dict{String,String}()
end

# The JIT object cache always goes. With `precompile_scope: all`, all compiled code too;
# otherwise the precompile script deletes just what it times.
function clear!(cfg::Config, a::Arm; compiled::Bool)
    rm(joinpath(depot(a), "cache"); recursive = true, force = true)
    compiled && cfg.precompile_all && rm(joinpath(depot(a), "compiled"); recursive = true, force = true)
end

function run_task(cfg::Config, a::Arm, t::PkgTask, logname; gc_off = false)
    cmd = addenv(`$(cfg.julia) --project=$(project(a, t)) $(script(a, t))`,
                 "JULIA_DEPOT_PATH" => depot_path(cfg, a), "TTFX_GC" => gc_off ? "off" : "on")
    out, err, ok, timed_out = run_timed(cmd, cfg.timeout)
    if !ok
        log_output(cfg, logname, out, err)
        error(timed_out ? "timed out after $(cfg.timeout) s" : "failed:\n" * lastlines(err))
    end
    lines = split(out, '\n')
    i = findlast(startswith(MARKER), lines)
    i === nothing && error("printed no timings")
    load, run = parse.(Float64, split(lines[i][length(MARKER)+1:end]))
    return load, run
end

# One sample: precompile from a cold cache, then the task `repeats` times in fresh
# processes, the first of them cold, then once more with the GC off.
function measure(cfg::Config, a::Arm, t::PkgTask, block::Int)
    logname = "$(a.label)-$(t.pkg)-block$block"
    try
        clear!(cfg, a; compiled = true)
        cmd = if cfg.precompile_all
            code = "using Pkg; t = @elapsed Pkg.precompile(); print(stdout, $(repr(MARKER)), t)"
            `$(cfg.julia) --project=$(project(a, t)) -e $code`
        else
            `$(cfg.julia) --project=$(project(a, t)) $(precompile_script(a, t))`
        end
        out, err, ok, timed_out = run_timed(addenv(cmd, "JULIA_DEPOT_PATH" => depot_path(cfg, a)), cfg.timeout)
        if !ok
            log_output(cfg, logname * "-precompile", out, err)
            error("precompile ", timed_out ? "timed out" : "failed:\n" * lastlines(err))
        end
        line = split(split(out, MARKER)[end], '\n')[1]
        precompile = parse(Float64, split(line)[1])
        clear!(cfg, a; compiled = false)
        loads, runs = Float64[], Float64[]
        for r in 1:cfg.repeats
            l, rr = run_task(cfg, a, t, "$logname-run$r")
            push!(loads, l); push!(runs, rr)
        end
        s = Dict{String,Any}("status" => "ok", "precompile" => precompile,
            "load" => loads[1], "run" => runs[1], "warm" => minimum((loads .+ runs)[2:end]),
            "loads" => loads, "runs" => runs)
        # Without the GC a workload can run out of memory. That loses only the GC-off
        # verdicts, not the sample.
        clear!(cfg, a; compiled = false)
        try
            s["load_gcoff"], s["run_gcoff"] = run_task(cfg, a, t, "$logname-gcoff"; gc_off = true)
        catch e
            s["error_gcoff"] = errmsg(e)
        end
        return s
    catch e
        @warn "$(t.pkg) failed on the $(a.label) arm in block $block" msg = errmsg(e)
        return Dict{String,Any}("status" => "error", "error" => errmsg(e))
    end
end

median(x) = (s = sort(x); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)
geomean(x) = exp(sum(log, x) / length(x))

function judge(bv, hv, m)
    ratios = hv ./ bv
    if all(>(1 + m.threshold), ratios) && minimum(hv) > maximum(bv) && median(hv) - median(bv) >= m.floor
        "regression"
    elseif all(<(1 - m.threshold), ratios) && maximum(hv) < minimum(bv) && median(bv) - median(hv) >= m.floor
        "improvement"
    else
        "same"
    end
end

either(v, vg) = "regression" in (v, vg) ? "regression" : "improvement" in (v, vg) ? "improvement" : "same"

# Per metric of a task: the per-block values and verdicts. Load and run are also judged
# with the GC off, and either verdict counts, a regression first.
function compare_task(cfg::Config, t::PkgTask, samples)
    results = []
    for m in metrics_of(cfg, t)
        bv = [s["base"][m.key] for s in samples]
        hv = [s["head"][m.key] for s in samples]
        v = judge(bv, hv, m)
        r = Dict{String,Any}("metric" => m, "base" => bv, "head" => hv, "ratios" => hv ./ bv,
                             "verdict" => v, "verdict_plain" => v)
        if m.key in ("load", "run") && all(s -> haskey(s["base"], "load_gcoff") && haskey(s["head"], "load_gcoff"), samples)
            bg = [s["base"][m.key*"_gcoff"] for s in samples]
            hg = [s["head"][m.key*"_gcoff"] for s in samples]
            vg = judge(bg, hg, m)
            r["ratios_gcoff"] = hg ./ bg
            r["verdict_gcoff"] = vg
            r["verdict"] = either(v, vg)
        end
        push!(results, r)
    end
    return results
end

# Per metric, the geometric mean over the tasks of each block's ratio; a verdict when every
# block clears the suite threshold.
function compare_suite(cfg::Config, measured)
    suite = []
    for m in cfg.metrics
        # A value below the floor is mostly noise in relative terms, so it stays out.
        rs = [r for (_, results) in measured for r in results
              if r["metric"].key == m.key && median(r["base"]) >= m.floor]
        length(rs) >= 2 || continue
        verdict_of(gs) = all(>(1 + m.suite), gs) ? "regression" : all(<(1 - m.suite), gs) ? "improvement" : "same"
        gs = [geomean([r["ratios"][k] for r in rs]) for k in 1:cfg.blocks]
        s = Dict{String,Any}("metric" => m, "ratios" => gs, "verdict_plain" => verdict_of(gs), "n" => length(rs))
        rg = filter(r -> haskey(r, "ratios_gcoff"), rs)
        if m.key in ("load", "run") && length(rg) >= 2
            gg = [geomean([r["ratios_gcoff"][k] for r in rg]) for k in 1:cfg.blocks]
            s["ratios_gcoff"] = gg
            s["verdict_gcoff"] = verdict_of(gg)
            s["verdict"] = either(s["verdict_plain"], s["verdict_gcoff"])
        else
            s["verdict"] = s["verdict_plain"]
        end
        push!(suite, s)
    end
    return suite
end

fmt(x) = x >= 100 ? string(round(Int, x)) : x >= 10 ? string(round(x; digits = 1)) : x >= 1 ? string(round(x; digits = 2)) : string(round(x; digits = 3))
change(x) = (x >= 1 ? "+" : "") * string(round(100 * (x - 1); digits = 1)) * "%"
code(s) = "`" * s * "`"
mark(s, verdict) = verdict == "same" ? s : "**$s**"
changes(r, key, vkey) = haskey(r, key) ? mark(join(change.(r[key]), ", "), r[vkey]) : "–"
label(name, verdict) = mark(name, verdict) * (verdict == "same" ? "" : " ($verdict)")
plural(n, s) = "$n $s" * (n == 1 ? "" : "s")

function header(cfg::Config)
    head = env("TTFX_HEAD_LABEL", "head")
    base = env("TTFX_BASE_LABEL", "base")
    url = env("TTFX_RUN_URL", "")
    runner = env("RUNNER_OS", string(Sys.KERNEL)) * " " * env("RUNNER_ARCH", string(Sys.ARCH))
    s = "$(code(cfg.pkg)) $head vs $base · Julia $VERSION · $runner · $(cfg.blocks) blocks (ABBA)"
    return isempty(url) ? s : s * " · [run]($url)"
end

marker(cfg::Config) = "<!-- julia-ttfx-check:$(cfg.name) -->"
title(cfg::Config) = cfg.name == "default" ? "TTFX" : "TTFX ($(cfg.name))"

function rule_text(cfg::Config, ntasks)
    ts = join(("$(m.name) $(round(Int, 100m.threshold))%" for m in cfg.metrics), ", ")
    fs = join(("$(m.name) $(m.floor) s" for m in cfg.metrics), ", ")
    s = "A change is robust when every block clears the threshold ($ts), the samples of the two commits " *
        "do not overlap, and the medians differ by at least the floor ($fs). Load and run are also judged " *
        "with the GC off, and either counts."
    if ntasks >= 2
        ss = join(("$(m.name) $(round(Int, 100m.suite))%" for m in cfg.metrics), ", ")
        s *= " Over all packages whose base value is at least the floor, each metric's geometric mean must clear " *
             "a threshold in every block ($ss)."
    end
    return s
end

function metric_table(io, results)
    println(io, "| metric | base (s) | head (s) | change per block | with GC off |")
    println(io, "|---|---|---|---|---|")
    for r in results
        println(io, "| ", label(r["metric"].name, r["verdict"]), " | ", join(fmt.(r["base"]), ", "), " | ",
                join(fmt.(r["head"]), ", "), " | ", changes(r, "ratios", "verdict_plain"), " | ",
                changes(r, "ratios_gcoff", "verdict_gcoff"), " |")
    end
end

# A dependent's cell: the median change, bold with the verdict when there is one.
function cell(results, key)
    i = findfirst(r -> r["metric"].key == key, results)
    i === nothing && return "–"
    r = results[i]
    c = change(median(r["ratios"]))
    return r["verdict"] == "same" ? c : "**$c $(r["verdict"])**"
end

function report(cfg::Config, measured, suite, failures, notes; gcoff_errors = Dict{String,String}())
    task_results = [r for (_, results) in measured for r in results]
    nreg = count(r -> r["verdict"] == "regression", task_results) + count(s -> s["verdict"] == "regression", suite) +
           count(f -> f.verdict == "regression", failures)
    nimp = count(r -> r["verdict"] == "improvement", task_results) + count(s -> s["verdict"] == "improvement", suite) +
           count(f -> f.verdict == "improvement", failures)
    verdict = nreg > 0 && nimp > 0 ? "mixed" : nreg > 0 ? "regression" : nimp > 0 ? "improvement" :
              isempty(measured) ? "error" : "same"
    summary = verdict == "error" ? "Nothing could be measured." : nreg + nimp == 0 ? "No robust change." :
        join(filter(!isempty, [nreg > 0 ? plural(nreg, "robust regression") : "",
                               nimp > 0 ? plural(nimp, "robust improvement") : ""]), ", ") * "."
    io = IOBuffer()
    println(io, marker(cfg))
    println(io, "### ", title(cfg), ": ", summary)
    println(io)
    println(io, header(cfg))
    main = findfirst(((t, _),) -> !t.dependent, measured)
    if main !== nothing
        println(io)
        metric_table(io, measured[main][2])
    end
    deps = [(t, r) for (t, r) in measured if t.dependent]
    if !isempty(deps)
        println(io)
        println(io, "**Dependents** (median change over blocks)")
        println(io)
        println(io, "| package | precompile | load (cold) | run (cold) | load+run (warm) |")
        println(io, "|---|---|---|---|---|")
        for (t, r) in deps
            println(io, "| ", code(t.pkg), " | ", cell(r, "precompile"), " | ", cell(r, "load"), " | ",
                    cell(r, "run"), " | ", cell(r, "warm"), " |")
        end
    end
    if !isempty(suite)
        println(io)
        println(io, "| all packages (geomean) | change per block | with GC off |")
        println(io, "|---|---|---|")
        for s in suite
            println(io, "| ", label(s["metric"].name, s["verdict"]), " | ", changes(s, "ratios", "verdict_plain"),
                    " | ", changes(s, "ratios_gcoff", "verdict_gcoff"), " |")
        end
    end
    if !isempty(failures)
        println(io)
        for f in failures
            println(io, "- ", code(f.pkg), ": ", f.text)
        end
    end
    for (t, _) in measured
        e = get(gcoff_errors, t.pkg, nothing)
        e === nothing && continue
        println(io)
        println(io, "The runs of ", code(t.pkg), " with the GC off failed, so it is judged with the GC on only.\n",
                details("error", e))
    end
    for n in notes
        println(io)
        println(io, n)
    end
    if !isempty(deps)
        println(io)
        println(io, "<details><summary>Dependents per block</summary>\n")
        for (t, r) in deps
            println(io, code(t.pkg), "\n")
            metric_table(io, r)
            println(io)
        end
        println(io, "</details>")
    end
    println(io)
    println(io, "<sub>", rule_text(cfg, length(measured)), "</sub>")
    return String(take!(io)), verdict, nreg, nimp
end

details(label, e) = "<details><summary>$label</summary>\n\n```\n$e\n```\n</details>"

# A task that fails on one arm only is a regression or an improvement for the package
# itself. For a dependent it can also mean the dependent's compat does not admit the
# version of the head commit, so it is only noted.
function failure(t::PkgTask, base_err, head_err; setup = false)
    if base_err !== nothing && head_err !== nothing
        return (pkg = t.pkg, verdict = "same", text = "fails on both commits.\n" * details("head", head_err))
    elseif head_err !== nothing
        what = setup && t.dependent ? "cannot be installed or precompiled with the head commit (compat?)" :
               "fails with the head commit"
        return (pkg = t.pkg, verdict = t.dependent && setup ? "same" : "regression", text = what * ".\n" * details("head", head_err))
    else
        return (pkg = t.pkg, verdict = t.dependent && setup ? "same" : "improvement",
                text = "fails with the base commit only.\n" * details("base", base_err))
    end
end

function set_output(pairs...)
    f = get(ENV, "GITHUB_OUTPUT", "")
    isempty(f) && return
    open(f, "a") do io
        for (k, v) in pairs
            println(io, k, "=", v)
        end
    end
end

function main()
    cfg, head_dir = config()
    base_dir = abspath(env("TTFX_BASE_DIR", ""))
    isdir(base_dir) || error("TTFX_BASE_DIR is not a directory: $base_dir")
    mkpath(cfg.out)
    # Both arms live in sibling directories of equal length, so their paths sort the same
    # way relative to the shared depot.
    arms = [Arm("base", base_dir, joinpath(cfg.work, "arms", "base")),
            Arm("head", head_dir, joinpath(cfg.work, "arms", "head"))]
    measured = Tuple{PkgTask,Vector{Any}}[]
    failures = []
    notes = String[]
    differ = Set{String}()
    all_samples = Dict{String,Any}()
    gcoff_errors = Dict{String,String}()
    for t in cfg.tasks
        errs = Dict{String,Any}("base" => nothing, "head" => nothing)
        for a in arms
            @info "Setting up $(t.pkg) on the $(a.label) arm"
            try
                setup!(cfg, a, t)
            catch e
                errs[a.label] = errmsg(e)
            end
        end
        if any(!isnothing, values(errs))
            push!(failures, failure(t, errs["base"], errs["head"]; setup = true))
            continue
        end
        rb, rh = resolved(project(arms[1], t)), resolved(project(arms[2], t))
        union!(differ, k for k in union(keys(rb), keys(rh)) if k != cfg.pkg && get(rb, k, "") != get(rh, k, ""))
        # The first processes after a setup run slower (file caches, the runner settling),
        # and the first arm of block 1 would always take that hit; one discarded sample
        # per arm absorbs it.
        for a in arms
            @info "$(t.pkg), warm-up: $(a.label)"
            measure(cfg, a, t, 0)
        end
        samples = []
        for b in 1:cfg.blocks
            s = Dict{String,Any}()
            for a in (isodd(b) ? arms : reverse(arms))
                @info "$(t.pkg), block $b of $(cfg.blocks): $(a.label)"
                s[a.label] = measure(cfg, a, t, b)
                r = s[a.label]
                if r["status"] == "ok"
                    @info "$(t.pkg), block $b, $(a.label)" precompile = r["precompile"] loads = r["loads"] runs = r["runs"] load_gcoff = get(r, "load_gcoff", nothing) run_gcoff = get(r, "run_gcoff", nothing)
                    haskey(r, "error_gcoff") && (gcoff_errors[t.pkg] = r["error_gcoff"])
                end
            end
            push!(samples, s)
            any(s[l]["status"] == "error" for l in ("base", "head")) && break
        end
        all_samples[t.pkg] = samples
        errs = Dict(l => [s[l]["error"] for s in samples if s[l]["status"] == "error"] for l in ("base", "head"))
        if !isempty(errs["base"]) || !isempty(errs["head"])
            first_or_nothing(v) = isempty(v) ? nothing : first(v)
            push!(failures, failure(t, first_or_nothing(errs["base"]), first_or_nothing(errs["head"])))
        else
            push!(measured, (t, compare_task(cfg, t, samples)))
        end
    end
    if !isempty(differ)
        d = sort!(collect(differ))
        push!(notes, "The commits resolved different versions of " * join(code.(first(d, 10)), ", ") *
                     (length(d) > 10 ? " and others" : "") * ".")
    end
    text, verdict, nreg, nimp = report(cfg, measured, compare_suite(cfg, measured), failures, notes; gcoff_errors)
    open(io -> TOML.print(io, Dict("samples" => all_samples)), joinpath(cfg.out, "samples.toml"), "w")
    write(joinpath(cfg.out, "report.md"), text)
    write(joinpath(cfg.out, "verdict"), verdict)
    print(stdout, text)
    set_output("verdict" => verdict, "regressions" => nreg, "improvements" => nimp,
               "report" => joinpath(cfg.out, "report.md"))
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(io -> print(io, text), summary, "a")
end

# Run as a script, but not when the tests include this file.
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
