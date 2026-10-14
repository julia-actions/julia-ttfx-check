using Test

include(joinpath(@__DIR__, "..", "src", "ttfx.jl"))

const M = (key = "load", name = "load (cold)", threshold = 0.10, suite = 0.02, floor = 0.10)

function with_env(f, pairs...)
    old = Dict(k => get(ENV, k, nothing) for (k, _) in pairs)
    try
        for (k, v) in pairs
            ENV[k] = v
        end
        f()
    finally
        for (k, v) in old
            v === nothing ? delete!(ENV, k) : (ENV[k] = v)
        end
    end
end

# A package whose `__init__` sleeps for `delay` seconds, so its load time is known.
function fixture(dir, delay)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), """
        name = "TTFXFixture"
        uuid = "3c2a7c6e-5a51-4f43-9a8b-2a0c3d1c5e01"
        version = "0.1.0"
        """)
    write(joinpath(dir, "src", "TTFXFixture.jl"), """
        module TTFXFixture
        f(x) = x + 1
        $(delay > 0 ? "__init__() = sleep($delay)" : "")
        end
        """)
    return dir
end

@testset "judge" begin
    # every block beyond the threshold, no overlap, medians apart by more than the floor
    @test judge([1.0, 1.0], [1.5, 1.6], M) == "regression"
    @test judge([1.5, 1.6], [1.0, 1.0], M) == "improvement"
    # one block within the threshold
    @test judge([1.0, 1.0], [1.5, 1.05], M) == "same"
    # beyond the threshold in every block, but the samples overlap
    @test judge([1.0, 1.5], [1.45, 1.7], M) == "same"
    # beyond the threshold and apart, but under the floor
    @test judge([0.10, 0.11], [0.15, 0.16], M) == "same"
    @test judge([0.10, 0.11], [0.25, 0.26], M) == "regression"
end

@testset "config" begin
    dir = fixture(mktempdir(), 0)
    write(joinpath(dir, "workload.jl"), "TTFXFixture.f(1)")
    work = mktempdir()
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_WORK" => work, "TTFX_WORKLOAD" => "workload.jl",
             "TTFX_DEPENDENTS" => "A, B C\nD: D.run(x::Int = 1)\nE: workload.jl\nTTFXFixture\nA",
             "TTFX_THRESHOLD_LOAD" => "25", "TTFX_FLOOR_RUN" => "0.5", "TTFX_BLOCKS" => "6") do
        cfg, head_dir = config()
        @test head_dir == dir
        @test cfg.pkg == "TTFXFixture"
        @test cfg.blocks == 6
        # the package itself first; duplicates and the package itself dropped from dependents
        @test [t.pkg for t in cfg.tasks] == ["TTFXFixture", "A", "B", "C", "D", "E"]
        @test [t.dependent for t in cfg.tasks] == [false, true, true, true, true, true]
        # a path in the repository is used as it is, code goes to a file
        @test cfg.tasks[1].workload == joinpath(dir, "workload.jl")
        @test cfg.tasks[6].workload == joinpath(dir, "workload.jl")
        @test read(cfg.tasks[5].workload, String) == "D.run(x::Int = 1)"
        @test cfg.tasks[2].workload == ""
        m = Dict(m.key => m for m in cfg.metrics)
        @test m["load"].threshold == 0.25
        @test m["run"].floor == 0.5
        @test m["precompile"].threshold == 0.08
        # run is only measured with a workload
        @test [x.key for x in metrics_of(cfg, cfg.tasks[2])] == ["precompile", "load", "warm"]
        @test length(metrics_of(cfg, cfg.tasks[1])) == 4
    end
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_WORK" => work, "TTFX_NAME" => "a b") do
        @test_throws ErrorException config()
    end
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_WORK" => work, "TTFX_DEPENDENTS" => "Not-A-Name") do
        @test_throws ErrorException config()
    end
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_WORK" => work, "TTFX_BLOCKS" => "1") do
        @test_throws ErrorException config()
    end
    # workloads are relative to the repository root, which can differ from the package's directory
    repo = mktempdir()
    mkdir(joinpath(repo, "ttfx"))
    write(joinpath(repo, "ttfx", "w.jl"), "1")
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_REPO_DIR" => repo, "TTFX_WORK" => work, "TTFX_WORKLOAD" => "ttfx/w.jl") do
        @test config()[1].tasks[1].workload == joinpath(repo, "ttfx", "w.jl")
    end
    # a missing workload file is an error, not code
    with_env("TTFX_HEAD_DIR" => dir, "TTFX_WORK" => work, "TTFX_WORKLOAD" => "test/missing.jl") do
        @test_throws ErrorException config()
    end
end

@testset "compare and report" begin
    dir = fixture(mktempdir(), 0)
    cfg = with_env(() -> config()[1], "TTFX_HEAD_DIR" => dir, "TTFX_WORK" => mktempdir(), "TTFX_BLOCKS" => "2",
                   "TTFX_DEPENDENTS" => "Dep", "TTFX_WORKLOAD" => "1 + 1")
    sample(precompile, load, run; gcoff = 1.0) = Dict{String,Any}("status" => "ok", "precompile" => precompile,
        "load" => load, "run" => run, "warm" => load + run, "load_gcoff" => load * gcoff, "run_gcoff" => run)
    # load regresses only with the GC off: the verdict still counts
    samples = [Dict("base" => sample(2.0, 0.30, 0.20), "head" => sample(2.0, 0.31, 0.20; gcoff = 2.0)) for _ in 1:2]
    main_task, dep = cfg.tasks
    results = compare_task(cfg, main_task, samples)
    load = only(filter(r -> r["metric"].key == "load", results))
    @test load["verdict_plain"] == "same"
    @test load["verdict_gcoff"] == "regression"
    @test load["verdict"] == "regression"
    @test all(r -> r["verdict"] == "same", filter(r -> r["metric"].key != "load", results))

    # the GC-off runs failed in one sample: judged with the GC on only
    lost = deepcopy(samples)
    for k in ("load_gcoff", "run_gcoff")
        delete!(lost[2]["head"], k)
    end
    results = compare_task(cfg, main_task, lost)
    load = only(filter(r -> r["metric"].key == "load", results))
    @test !haskey(load, "ratios_gcoff")
    @test load["verdict"] == "same"
    text, _, _, _ = report(cfg, [(main_task, results)], [], [], String[]; gcoff_errors = Dict("TTFXFixture" => "out of memory"))
    @test occursin("with the GC off failed", text) && occursin("out of memory", text)

    # a dependent with a small shared regression: no single package clears its threshold,
    # the geometric mean over both clears the suite threshold
    small = [Dict("base" => sample(10.0, 1.0, 0.0), "head" => sample(10.5, 1.0, 0.0)) for _ in 1:2]
    measured = [(main_task, compare_task(cfg, main_task, small)), (dep, compare_task(cfg, dep, small))]
    suite = compare_suite(cfg, measured)
    pre = only(filter(s -> s["metric"].key == "precompile", suite))
    @test pre["verdict"] == "regression"
    @test all(r -> r["verdict"] == "same", measured[1][2])
    # run is only in the package's own results, so it has no geometric mean
    @test !any(s -> s["metric"].key == "run", suite)
    # values below the floor stay out of the geometric mean: a 4% shift of a 10 ms run in
    # both of two packages is no robust regression
    tiny = [Dict("base" => sample(10.0, 1.0, 0.01), "head" => sample(10.0, 1.0, 0.0104)) for _ in 1:2]
    both = PkgTask("Dep", main_task.workload, true)
    measured_tiny = [(main_task, compare_task(cfg, main_task, tiny)), (both, compare_task(cfg, both, tiny))]
    @test !any(s -> s["metric"].key == "run", compare_suite(cfg, measured_tiny))

    text, verdict, nreg, nimp = report(cfg, measured, suite, [], String[])
    @test startswith(text, "<!-- julia-ttfx-check:default -->\n")
    @test verdict == "regression" && nreg == 1 && nimp == 0
    @test occursin("**Dependents**", text)
    @test occursin("geometric mean", text)

    # a dependent that cannot be installed with the head commit is noted, not counted
    f = failure(dep, nothing, "unsatisfiable requirements"; setup = true)
    text, verdict, nreg, _ = report(cfg, measured[1:1], [], [f], String[])
    @test verdict == "same" && nreg == 0
    @test occursin("cannot be installed", text)
    # a dependent that installs but then fails with the head commit is a regression
    f = failure(dep, nothing, "ERROR: boom")
    _, verdict, nreg, _ = report(cfg, measured[1:1], [], [f], String[])
    @test verdict == "regression" && nreg == 1
    # the package itself failing on head is a regression
    f = failure(main_task, nothing, "ERROR: boom")
    _, verdict, nreg, _ = report(cfg, [], [], [f], String[])
    @test verdict == "regression" && nreg == 1
    # nothing measured at all
    _, verdict, _, _ = report(cfg, [], [], [failure(main_task, "x", "y")], String[])
    @test verdict == "error"
end

@testset "resolved versions and cache clearing" begin
    p = mktempdir()
    write(joinpath(p, "Manifest.toml"), """
        julia_version = "1.10.0"
        manifest_format = "2.0"
        [[deps.A]]
        uuid = "00000000-0000-0000-0000-000000000001"
        version = "1.2.3"
        git-tree-sha1 = "abc"
        [[deps.B]]
        path = "/x"
        uuid = "00000000-0000-0000-0000-000000000002"
        """)
    v = resolved(p)
    @test v["A"] == "1.2.3 abc"
    @test v["B"] == " /x"
    @test isempty(resolved(mktempdir()))

    dir = fixture(mktempdir(), 0)
    for scope in ("package", "all")
        cfg = with_env(() -> config()[1], "TTFX_HEAD_DIR" => dir, "TTFX_WORK" => mktempdir(), "TTFX_PRECOMPILE_SCOPE" => scope)
        a = Arm("base", dir, mktempdir())
        compiled = joinpath(depot(a), "compiled", "v$(VERSION.major).$(VERSION.minor)")
        for d in (joinpath(compiled, "TTFXFixture"), joinpath(compiled, "Other"), joinpath(depot(a), "cache", "x"))
            mkpath(d)
        end
        clear!(cfg, a; compiled = false)
        @test !isdir(joinpath(depot(a), "cache")) && isdir(joinpath(compiled, "TTFXFixture"))
        clear!(cfg, a; compiled = true)
        @test !isdir(joinpath(compiled, "TTFXFixture"))
        @test isdir(joinpath(compiled, "Other")) == (scope == "package")
    end
end

@testset "task script" begin
    t = PkgTask("Printf", "", false)
    for gc in ("on", "off")
        out = read(addenv(`$(Base.julia_cmd()) --startup-file=no -e $(task_script(t))`, "TTFX_GC" => gc), String)
        line = only(filter(startswith(MARKER), split(out, '\n')))
        load, run = parse.(Float64, split(line[length(MARKER)+1:end]))
        # loading a stdlib from the system image can take no measurable time
        @test load >= 0 && run >= 0
    end
end

# The whole driver on a package whose head commit sleeps in `__init__`, against itself and
# against a base that does not.
@testset "end to end" begin
    root = mktempdir()
    base = fixture(joinpath(root, "base"), 0)
    head = fixture(joinpath(root, "head"), 0.4)
    for d in (base, head)
        write(joinpath(d, "workload.jl"), "TTFXFixture.f(1)")
    end
    function check(base_dir, head_dir)
        work = mktempdir()
        out = joinpath(work, "report")
        outputs = joinpath(work, "outputs")
        with_env("TTFX_BASE_DIR" => base_dir, "TTFX_HEAD_DIR" => head_dir, "TTFX_WORK" => work, "TTFX_OUT" => out,
                 "TTFX_BLOCKS" => "4", "TTFX_WORKLOAD" => "workload.jl", "TTFX_NAME" => "e2e",
                 "GITHUB_OUTPUT" => outputs, "GITHUB_STEP_SUMMARY" => joinpath(work, "summary.md")) do
            redirect_stdout(devnull) do
                main()
            end
        end
        o = Dict(split(l, '='; limit = 2) for l in eachline(outputs))
        return o, read(joinpath(out, "report.md"), String), read(joinpath(work, "summary.md"), String)
    end
    o, text, summary = check(base, head)
    @test o["verdict"] == "regression"
    @test parse(Int, o["regressions"]) >= 2  # load and warm
    @test occursin("**load (cold)** (regression)", text)
    @test startswith(text, "<!-- julia-ttfx-check:e2e -->")
    @test summary == text

    o, text, _ = check(head, base)
    @test o["verdict"] == "improvement"

    o, text, _ = check(head, head)
    @test o["verdict"] == "same"
    @test occursin("No robust change.", text)
end
