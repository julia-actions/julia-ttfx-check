# julia-ttfx-check

A GitHub Action that compares a Julia package's time to first X between a pull request and
its base, and that of packages depending on it, and reports changes that are robust to
runner noise.

For each of the two commits it measures:

| metric | what is timed |
|---|---|
| precompile | `Base.compilecache` of the package and its installed extensions, with every other cache valid |
| load (cold) | `using Package` in a fresh process, right after precompiling |
| run (cold) | the first run of your workload, in the same process |
| load+run (warm) | load and run again in new processes, the best of the later repeats |

Load and run are also measured with the garbage collector off, so that a change hidden by
when GC pauses happen to fall is still seen. A change found either way counts.

## Usage

```yaml
name: TTFX

on:
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write

jobs:
  ttfx:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v2
        with:
          version: '1'
      - uses: julia-actions/julia-ttfx-check@v1
        with:
          workload: 'MyPackage.solve(MyPackage.example_problem())'
          dependents: |
            SomeDownstreamPackage
            AnotherOne: test/ttfx/anotherone.jl
            ThirdOne: ThirdOne.run_example()
```

The check runs on any runner, GitHub-hosted or your own, with whichever Julia is on the
`PATH`. Julia 1.10 or later is required. It is tested on Linux and macOS runners; on
Windows only its Julia code is tested so far.

It installs everything into its own depots under `RUNNER_TEMP`, so caching `~/.julia` does
not speed it up, and nothing from earlier steps leaks into the measurement.

Requirements and limits:

- The repository must be checked out at the workspace root (`actions/checkout` without
  `path:`); the action runs git there.
- Commenting needs `gh` and `jq`, which GitHub-hosted runners have.
- A package that is part of Julia's system image cannot be measured: `using` it returns
  the built-in copy.
- The package's own environment has only the package, so its extensions are measured only
  through a dependent that installs their trigger packages.

A robust regression fails the step (`fail_on_regression`), so the pull request shows a red
check, and so does a run where nothing could be measured (the package fails to load on
both commits, say). Set `fail_on_regression: false` to only report.

### Run time

Each of the two commits gets `blocks + 1` samples (one is a discarded warm-up) for the
package and for each dependent. A sample precompiles the package and runs `repeats + 1`
fresh Julia processes. For a package that precompiles in 10 s and loads in 1 s, the default
4 blocks take about 2 × 5 × 15 s, under 3 minutes, plus installing.

### Inputs

| input | default | |
|---|---|---|
| `workload` | none | Code to run after `using Package`, or the path of a `.jl` file with it, relative to the repository root. Without it, run (cold) is not measured. |
| `dependents` | none | Registered packages that depend on this one. Each is installed against both commits, and its precompile and load are compared too. A line `Name: workload` gives a dependent a workload (a file path or code). |
| `comment` | `changes` | When to comment on the pull request: `always`, `changes`, `regressions`, `improvements` or `never`. |
| `fail_on_regression` | `true` | Fail the step on a robust regression. |
| `threshold_precompile`, `threshold_load`, `threshold_run`, `threshold_warm` | `8`, `10`, `15`, `15` | Change in percent that every block must exceed. |
| `floor_precompile`, `floor_load`, `floor_run`, `floor_warm` | `0.25`, `0.10`, `0.05`, `0.05` | Smallest change in seconds of the medians that counts. |
| `suite_threshold_precompile`, `_load`, `_run`, `_warm` | `2`, `2`, `3`, `3` | With dependents: change in percent that the geometric mean over all packages must exceed in every block. |
| `blocks` | `4` | ABBA blocks; each gives one sample of each commit. |
| `repeats` | `3` | Fresh processes per sample for the workload: the first is cold, the best of the rest is warm. |
| `precompile_scope` | `package` | `package` times compiling just the package (or dependent) and its installed extensions; `all` times `Pkg.precompile()` after deleting every compiled cache, which is much slower. |
| `base` | the pull request's base | Commit to compare against. On a pull request, the base branch it would merge into; on a push, the branch as it was before the push. |
| `path` | `.` | Directory of the package in the repository. |
| `name` | `default` | Tells several checks in one repository apart; each has its own comment and artifact. Must be unique per job, including across a matrix (`name: ${{ matrix.os }}`). |
| `timeout` | `1800` | Seconds allowed for each Julia process. |
| `upload_artifact` | `true` | Upload the report and logs as `julia-ttfx-check-<name>`. |
| `github_token` | `github.token` | Token for the comment. |

Outputs: `verdict` (`regression`, `improvement`, `mixed`, `same` or `error`), `regressions`,
`improvements` and `report` (the path of the markdown report). The report also goes to the
job summary.

### Comments

Each check keeps a single comment on the pull request. The `comment` input decides when that
comment is first created; `changes` also counts a run where nothing could be measured. Once it exists, it is updated on every run, whatever the verdict,
so it always describes the latest commit. A pull request that showed a regression and then
fixed it ends with a comment saying there is no robust change. A report with no robust change
keeps its measurements in a collapsed section, so it takes little space.

## How a change is judged

This follows the TTFX job of [JuliaLang/julia's CI](https://github.com/JuliaCI/julia-buildkite/tree/main/utilities/ttfx).

- The two commits are measured in ABBA blocks: base, head, then head, base, and so on. Each
  block pairs a sample of each commit taken next to each other in time, so drift in the
  runner's speed affects both.
- Every sample starts cold: fresh processes, with the package's compiled cache and Julia's
  JIT object cache deleted.
- A metric changed robustly only if all three hold:
  - in every block, the head/base ratio is beyond the threshold;
  - the samples of the two commits do not overlap;
  - the medians differ by at least the floor.
- Load and run are judged with the GC on and with it off, and either verdict counts. If the
  runs with the GC off fail (a workload can run out of memory without the GC), the package
  is judged with the GC on only, and the report says so.

Requiring every block to agree is what keeps shared runners from producing false alarms;
more blocks make the check stricter and slower. The floors keep sub-0.1 s jitter out; lower
them for a package that loads in milliseconds.

## Dependents

A regression in load or precompile time often shows only in the packages that use yours:
an invalidation they hit, a method table they extend, a type that became harder to infer.
For each package listed in `dependents`, the check installs it into a fresh environment
for each commit, with your package developed from that commit, and measures its precompile
and load times the same way. A dependent given its own workload (`Name: path/to/file.jl` or
`Name: code`, one per line) is timed running it as well; the file is read from the pull
request's checkout for both commits.

Within one commit your package never changes, so its compiled cache, and those of the
packages between it and the dependent, are built once at setup. Each sample then times
compiling the dependent itself, with `Base.compilecache`, followed by the extensions
installed in its environment: its own and your package's. That is how long the dependent
takes to compile against your package, where invalidations, harder inference and slower
method insertion show up, without Pkg's overhead and parallelism adding noise.

Each dependent is judged on its own like the package itself. Across all the packages, each
metric's geometric mean is also judged per block, against the tighter suite threshold: a
small regression that every dependent shares shows up there even when no single package
clears its threshold. A package whose base value of a metric is below that metric's floor
stays out of its geometric mean, since a few percent of a few milliseconds is noise.

A dependent that cannot be installed against the head commit, typically because its
`[compat]` does not admit a new major version, is reported but does not count as a
regression. One that installs but then fails to precompile, load or run with the head
commit does count.

## Dependency versions

Both commits resolve their dependencies separately, at about the same time. If they end up
with different versions (because the pull request changes `[compat]`, say), the report says
so.

## Pull requests from forks

On a `pull_request` event from a fork, `GITHUB_TOKEN` cannot comment. Set `comment: never` in
the measuring workflow, and post the comment from a second workflow that runs on
`workflow_run`, using the artifact the first uploaded:

```yaml
name: TTFX comment

on:
  workflow_run:
    workflows: [TTFX]
    types: [completed]

permissions:
  actions: read
  pull-requests: write

jobs:
  comment:
    if: github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: julia-ttfx-check-default
          path: ttfx
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ github.token }}
      - uses: julia-actions/julia-ttfx-check/comment@v1
        with:
          report_dir: ttfx
          comment: changes
```

The comment action only posts to the pull request whose head is the commit that was
measured, since the fork controls what its artifact contains. When the pull request has
moved on since, it leaves the comment to the run for the newer commit.

## Development

```sh
julia --startup-file=no test/runtests.jl  # the driver, including end-to-end runs on a fixture package
bash test/scripts.sh                      # the checkout and comment scripts, with a fake `gh`
```

CI also runs the action itself on a fixture package with a known regression, a known
improvement and no change, and on a real package with a dependent.
