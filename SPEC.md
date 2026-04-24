# WarmTestRunner.jl Specification

Status: draft, repository-local source of truth

This document is the canonical specification for `WarmTestRunner.jl` in this repository.
It inherits the design discussion captured in the shared ChatGPT conversation below and
recasts that discussion as a maintainable product spec:

- Source discussion: <https://chatgpt.com/share/69e71606-2a60-83e8-8c66-1234bf9684d9>

The shared conversation is historical context. This `SPEC.md` is the working copy that
should be updated as the design evolves in this repository.

## 1. Overview

`WarmTestRunner.jl` is a development-time test runner for Julia package authors. Its
purpose is to make repeated local test runs faster by combining:

- `TestEnv.jl` for activating test dependencies in an interactive or long-lived process
- `TestRunner.jl`-style virtual test execution through `test/runtests.jl`
- worker-pool parallelism over execution plans
- `DaemonMode.jl`-style warm process reuse
- `Malt.jl` as the worker-process substrate

The core idea is to keep a pool of warm worker processes alive across runs and execute
`ExecutionPlan`s inside worker `Main`. When `test/runtests.jl` exists, it is the
authoritative suite entry. Targeted file runs are still evaluated through that entry so
top-level setup and include structure match the ordinary Julia test suite.

## 2. Goals And Non-goals

### 2.1 Goals

`WarmTestRunner.jl` is intended to provide the following:

- Activation of the package's test dependencies inside reusable worker processes
- Execution of ordinary Julia test suites through `test/runtests.jl`
- Targeted file, testset, line, and expression selection without bypassing suite setup
- Parallel execution of independent execution plans across multiple worker processes
- Reuse of workers across runs so that package loading, compilation, and JIT work can be
  amortized
- Structured result-unit output, including output capture and failure diagnostics
- Reasonable crash recovery when an individual worker dies
- A development-oriented API that supports whole-suite runs and targeted reruns

### 2.2 Non-goals

The following are explicitly out of scope:

- Full behavioral compatibility with `Pkg.test()`
- Replacing `Pkg.test()` as the final CI or release-validation command
- Guaranteeing that every existing Julia test suite can run unchanged under this runner
- Eliminating all process contamination or global side effects
- Perfect impact analysis or exact minimal test selection in early versions

## 3. Product Positioning

### 3.1 Relationship To `Pkg.test()`

`WarmTestRunner.jl` is a development aid, not a drop-in replacement for `Pkg.test()`.
The intended workflow is:

- Day-to-day local iteration: `WarmTestRunner.run()`
- Final verification before merge or release: `Pkg.test()`

This distinction is fundamental. `Pkg.test()` assumes a new Julia process and a
temporary test environment. `WarmTestRunner.jl` deliberately trades some of that
isolation for lower latency on repeated runs.

### 3.2 Primary Use Case

A package author is iterating locally and repeatedly performs this loop:

- edit code
- run all or some tests
- inspect failures
- edit again
- rerun quickly

### 3.3 Secondary Use Cases

- combine with `Revise.jl` for rapid development feedback
- watch source and test files and rerun automatically
- shard selected execution plans across workers
- rerun only files that failed previously

## 4. System Model

`WarmTestRunner.jl` is organized around four conceptual layers.

### 4.1 Controller

The controller runs in the client or coordinating process and is responsible for:

- discovering or parsing the suite entry
- applying file, testset, line, expression, and later tag filters
- creating execution plans
- creating or connecting to a worker pool
- scheduling jobs onto available workers
- aggregating results
- handling retries and worker replacement

### 4.2 Persistent Worker Pool

The worker pool is a set of long-lived `Malt.Worker` processes. Each worker is an
independent Julia process. Workers are retained across runs so that loaded packages,
compiled methods, and other warm state can be reused.

### 4.3 Worker Bootstrap

Each worker runs a one-time bootstrap sequence when it is created. Bootstrap prepares
the worker to execute the target package's tests by:

- selecting the package root
- configuring the process environment
- activating the test environment
- optionally loading `Revise`
- optionally preloading the target package
- optionally running a user hook

### 4.4 Virtual Test Execution

Each scheduled plan is executed by a virtual execution backend inside the worker's
`Main`. This gives the system warm, worker-local context with explicit reset points:

- the worker process persists across runs
- `Main` persists across runs
- `test/runtests.jl` and its `include(...)` tree are preserved when present
- selected included files run through the same suite entry instead of direct include
- `fresh=true` or worker recreation discards that worker `Main` state and starts over

## 5. Public API

This section defines the intended public Julia API for the full product. The MVP is a
subset of this surface area.

### 5.1 `serve`

Start or provision a persistent worker pool for a package root.

```julia
serve(;
    pkgroot::AbstractString = pwd(),
    jobs::Int = Sys.CPU_THREADS,
    threads_per_worker::Int = 1,
    use_testenv::Bool = true,
    use_revise::Bool = true,
    preload_package::Bool = true,
    startup_file::Bool = false,
    check_bounds::Union{Bool, Nothing} = nothing,
    color::Bool = true,
    worker_timeout::Real = 60,
    log_level = :info,
)
```

Responsibilities:

- create worker processes
- run worker bootstrap
- record controller connection metadata in a local registry

Return value:

- `ServerHandle`

### 5.2 `run`

Connect to an existing server or create an ephemeral session, then run tests.

```julia
run(;
    tests = nothing,
    testsets = nothing,
    line_patterns = nothing,
    expression_patterns = nothing,
    jobs::Union{Int, Nothing} = nothing,
    quickfail::Bool = false,
    verbose::Bool = false,
    rerun_failed::Bool = false,
    changed_only::Bool = false,
    fresh::Bool = false,
    retry_crashed::Bool = true,
    seed::Union{Int, Nothing} = nothing,
    output_format::Symbol = :text,
)
```

Behavior:

- if no selector is supplied, run the whole suite
- if `tests == []`, treat it as no public file selector
- if `tests` selects included files, execute them through `test/runtests.jl` when that
  entry exists
- if `testsets`, `line_patterns`, or `expression_patterns` are supplied, build focused
  virtual execution plans
- if `changed_only == true`, select a subset based on local changes
- if `fresh == true`, recreate all workers before scheduling jobs
- if `rerun_failed == true`, reuse the last recorded failing file set for the same server
- if `output_format == :json`, return data suitable for editor or CI tooling in addition
  to the normal structured result object

Return value:

- `RunSummary`

### 5.3 `stop`

Stop the persistent worker pool associated with the current package root or explicit
handle.

```julia
stop()
```

### 5.4 `status`

Report current server and worker state.

```julia
status() -> ServerStatus
```

### 5.5 `watch`

Watch files and rerun tests on changes.

```julia
watch(;
    paths = ["src", "test"],
    debounce_seconds = 0.5,
    changed_only = true,
)
```

`watch` is part of the full specification but is not part of the initial MVP.

### 5.6 CLI Shape

The Julia API is the primary surface. CLI usage is expected to be a thin wrapper around
that API:

```bash
julia --project -e 'using WarmTestRunner; WarmTestRunner.serve()'
julia --project -e 'using WarmTestRunner; WarmTestRunner.run()'
julia --project -e 'using WarmTestRunner; WarmTestRunner.run(jobs=4)'
julia --project -e 'using WarmTestRunner; WarmTestRunner.run(tests=["array.jl", "io.jl"])'
julia --project -e 'using WarmTestRunner; WarmTestRunner.run(fresh=true)'
julia --project -e 'using WarmTestRunner; WarmTestRunner.stop()'
```

## 6. Execution Semantics

### 6.1 Test Discovery

Default planning rules:

- prefer `test/runtests.jl` as the suite entry when it exists
- discover statically reachable `include(...)` targets from the suite entry
- select files only if they are reachable from that entry
- fall back to recursive `*.jl` file-entry discovery under `test/` only when no
  `test/runtests.jl` exists
- exclude `test/warmtest_bootstrap.jl` from file-entry discovery
- preserve stable ordering unless a scheduling strategy explicitly reorders plans

### 6.2 Filtering

The system should support these selection modes:

- explicit file path
- named testset selection
- line selection within a file
- expression or testset-name selection within a file
- filename substring match
- regular-expression match
- tag include or exclude

The current Julia API implements explicit files, named testsets, line selectors, and
expression selectors. Substring, regex, and tag filters are future filtering modes.

### 6.3 Tag Format

Test files may opt into tags via a header comment.

```julia
# warmtest: tags=slow,network,gpu
```

Tags are advisory metadata used only by `WarmTestRunner.jl`.

### 6.4 Worker Environment

Each worker is configured with an explicit execution environment. The intended defaults
are:

- `JULIA_PROJECT = pkgroot`
- controlled `JULIA_LOAD_PATH`
- `JULIA_NUM_THREADS = threads_per_worker`
- `OPENBLAS_NUM_THREADS = 1`
- optional `JULIA_STARTUP_FILE=no`

The worker environment must be explicit because `Malt` workers should not be assumed to
inherit the parent process package environment or all environment variables.

### 6.5 Bootstrap Sequence

Bootstrap runs once per worker and follows this order:

1. `cd(pkgroot)`
2. `using TestEnv` if `use_testenv == true`
3. `TestEnv.activate(pkgroot)` or equivalent activation logic
4. `using Revise` if `use_revise == true` (default)
5. `using TargetPackage` if `preload_package == true`
6. execute a user preload hook if present

### 6.6 Preload Hook

Users may define an optional bootstrap hook at `test/warmtest_bootstrap.jl`.

Example:

```julia
using Random
Random.seed!(1234)
```

This hook is intended for worker-local setup that should happen once when a worker is
created, not before every individual test file.

### 6.7 Execution Unit

The scheduling unit is an `ExecutionPlan`.

Whole-suite runs usually produce one plan for `test/runtests.jl`. File-selected runs
through that entry report selected files as result units. Testset-level diagnostics can
still appear inside stdout, exception summaries, stack traces, and structured
diagnostics.

### 6.8 Virtual Execution Model

Within a worker, each plan is executed by:

- using worker `Main` as the default top module
- parsing source with `JuliaSyntax`
- evaluating non-test top-level setup code
- intercepting `include(...)` so included files are handled by the same backend
- selectively executing matching `@test` and `@testset` expressions
- collecting Test.jl output and structured diagnostics

Illustrative pseudocode:

```julia
Core.eval(Main, :(using Test))
execute_plan(plan; topmodule = Main)
```

The implementation must not reintroduce a synthetic per-file module model as the normal
execution path.

### 6.9 Isolation Model

Isolation is soft, not absolute.

- worker processes persist across runs
- each worker reuses `Main`
- `fresh=true` forces worker recreation
- a worker may be recreated automatically after a crash or contamination event

This model is central to the product. The package does not claim to reproduce the
cleanliness of a brand-new `Pkg.test()` process for every run.

### 6.10 Scheduling

Default scheduling policy:

- assign the next queued file to the next available worker

Optional enhanced policy:

- keep historical execution durations
- schedule long-running files earlier, using an LPT-like heuristic

Illustrative timing cache format:

```toml
[test_times]
"test/array.jl" = 1.23
"test/io.jl" = 4.91
```

### 6.11 `changed_only`

When the repository is under Git control, `changed_only` may use `git diff --name-only`
or equivalent information to restrict the run set.

For the initial implementation, the heuristic may be intentionally coarse:

- changes under `src/` imply all tests
- changes to a test file imply that specific file

The specification prefers correctness over aggressive narrowing.

### 6.12 Quickfail

If `quickfail == true`, the controller stops queueing new jobs after the first `failed`
or `errored` result.

Default behavior:

- do not cancel jobs already running on workers

Later versions may add best-effort interruption of in-flight jobs, but that is not a
core requirement.

### 6.13 Result Model

Each result unit returns a structured result with at least:

- `status`, one of `passed`, `failed`, `errored`, `crashed`, or `skipped`
- path label for the suite entry or selected file
- elapsed wall-clock time
- captured `stdout`
- captured `stderr`
- exception summary, if any
- stacktrace text, if any
- worker identifier, if available

### 6.14 Console Output

Default console output should provide one summary line per file:

```text
[1/12] test/array.jl .... PASS  0.84s
[2/12] test/io.jl ....... FAIL  1.92s
```

Verbose mode may stream or flush worker output in greater detail.

Failure detail should include:

- exception type
- failure message
- stacktrace
- captured output

### 6.15 Machine-readable Output

`run(output_format = :json)` must make structured output available for editor integration
or external tooling.

The exact schema may evolve, but it must preserve result status and diagnostics,
including user-file locations where available.

## 7. Reliability Model

### 7.1 Worker State Machine

Each worker tracks one of these states:

- `booting`
- `idle`
- `running`
- `failed`
- `crashed`
- `stopping`

### 7.2 Server State

The server status should expose at least:

- controller PID
- startup time
- package root
- worker count
- number of running jobs
- failing job list from the most recent run
- time of most recent successful run

### 7.3 Session Registry

Persistent server metadata is stored locally so later invocations can find the active
pool. The intended default location is:

```text
~/.julia/warmtestrunner/servers/
```

Stored metadata should include:

- PID
- package root
- socket or port information
- package version
- startup timestamp

### 7.4 Worker Crash Recovery

If a worker process exits unexpectedly:

1. mark the current file result as `crashed`
2. recreate the worker
3. if `retry_crashed == true`, retry the same file once on a recreated worker

### 7.5 Bootstrap Failure

If bootstrap fails, for example during `TestEnv.activate` or preload hook execution:

- mark that worker unusable
- fail `serve()` or the corresponding startup path
- do not continue with a partially initialized pool as if it were healthy

### 7.6 Contaminated Worker Handling

The system should support discarding workers that appear unsafe to reuse.

Potential contamination signals include:

- dangerous global runtime changes
- unexpectedly lingering tasks
- explicit dirty markers
- known classes of exceptions after file execution

The MVP may use a simplified rule:

- recreate the worker when post-run state or an exception class strongly suggests the
  process should not be trusted further

## 8. Operational Model

### 8.1 `Revise` Integration

Workers load `Revise` during bootstrap by default. Passing `use_revise = false`
disables this integration. Revise is intended to improve the local edit-run cycle, but
it does not guarantee perfect tracking of all code changes.

Known caveats:

- each worker has its own `Revise` state
- generated functions, macro expansion, and constant redefinition remain tricky
- `fresh=true` remains the escape hatch when warm state becomes suspect

### 8.2 Relationship To Test Suite Structure

`WarmTestRunner.jl` works best when suites can be rerun in a warm `Main`. Suites that
define constants or modules repeatedly may need `fresh=true` between runs, and final
verification should still use `Pkg.test()`.

### 8.3 Watch Mode

`watch()` is part of the full product shape but is deferred beyond the MVP. When
implemented, it should:

- watch source and test paths
- debounce rapid bursts of changes
- reuse the same worker pool
- typically combine with `changed_only = true`

### 8.4 Recommended User Workflow

Recommended operational pattern:

1. start a warm pool once with `serve()`
2. iterate with repeated `run()` calls
3. use `fresh=true` when state contamination is suspected
4. use `Pkg.test()` for final isolated verification

## 9. Implementation Notes

This section is non-normative but records the intended internal decomposition for this
repository.

### 9.1 Suggested Source Layout

```text
WarmTestRunner.jl/
├─ Project.toml
├─ src/
│  ├─ WarmTestRunner.jl
│  ├─ types.jl
│  ├─ config.jl
│  ├─ discovery.jl
│  ├─ controller.jl
│  ├─ worker.jl
│  ├─ bootstrap.jl
│  ├─ execution.jl
│  ├─ virtual_execution.jl
│  ├─ sandbox.jl
│  ├─ results.jl
│  ├─ server_registry.jl
│  ├─ watch.jl
│  └─ cli.jl
├─ test/
│  ├─ runtests.jl
│  ├─ integration/
│  ├─ fixtures/
│  └─ packages/
│     ├─ PkgA/
│     └─ PkgB/
└─ docs/
```

### 9.2 Core Types

```julia
struct ServerHandle
    pkgroot::String
    server_id::String
    pid::Int
    started_at::Float64
    jobs::Int
end

struct WorkerHandle
    id::Int
    state::Symbol
    booted_at::Float64
    runs_completed::Int
    dirty::Bool
end

struct TestDiagnostic
    file::String
    line::Int
    kind::Symbol
    message::String
end

struct TestSelection
    file::String
    patterns::Vector
    filter_lines::Union{Nothing, Set{Int}}
    run_all::Bool
end

struct ExecutionPlan
    entryfile::String
    selections::Vector{TestSelection}
    run_all::Bool
    label::String
end

struct TestJob
    path::String
    name::String
    tags::Vector{String}
    est_seconds::Float64
    plan::Union{Nothing, ExecutionPlan}
end

struct TestResult
    path::String
    status::Symbol
    elapsed::Float64
    stdout::String
    stderr::String
    exception_summary::Union{Nothing, String}
    stacktrace::Union{Nothing, String}
    worker_id::Union{Nothing, Int}
    diagnostics::Vector{TestDiagnostic}
end

struct RunSummary
    results::Vector{TestResult}
    passed::Int
    failed::Int
    errored::Int
    crashed::Int
    skipped::Int
    elapsed_total::Float64
end
```

### 9.3 Internal Functions

Illustrative internal responsibilities:

```julia
discover_tests(pkgroot)::Vector{TestJob}
build_execution_plans(cfg)::Vector{ExecutionPlan}
bootstrap_worker!(worker, cfg)::Nothing
run_test_in_worker!(worker, job, cfg)::TestResult
recreate_worker!(pool, i)::Nothing
schedule_jobs!(pool, jobs, cfg)::RunSummary
execute_plan(plan; topmodule = Main)::TestResult
```

### 9.4 Phased Delivery

Phase 1:

- one `Malt.Worker`
- `TestEnv.activate(pkgroot)`
- run one execution plan in worker `Main`
- return structured results

Phase 2:

- multiple workers
- job queue and result aggregation
- worker recreation on crash

Phase 3:

- persistent server registry
- `serve()` plus `run()` reconnection
- measurable speedup on repeated runs

Phase 4:

- `Revise` integration
- `watch()`
- `changed_only`
- duration-aware scheduling

Phase 5:

- TestRunner-style virtual execution through `test/runtests.jl`
- included-file, testset, line, and expression selectors
- JSON diagnostics

## 10. Known Constraints

- Worker state can remain contaminated across runs through globals, random state,
  environment mutation, and logging configuration.
- Warm `Main` can expose repeated-definition issues; use `fresh=true` when needed.
- File-selected result units still execute through `test/runtests.jl` when that entry is
  present.
- The worker bootstrap must be explicit because process environment inheritance cannot be
  assumed.
- The package intentionally does not promise `Pkg.test()` equivalence.

## 11. Design Decision Summary

The main design choices inherited from the prior discussion and ratified in this
repository are:

- use `Malt` as the worker-process substrate
- use `TestEnv` as the test-environment activation layer
- use TestRunner-style virtual execution as the canonical test backend
- adopt warm, persistent workers inspired by `DaemonMode`
- keep isolation soft, with persistent worker `Main` and worker recreation as the hard
  reset mechanism
- treat `serve`, `run`, `stop`, and `status` as the MVP-critical API surface

## 12. Out-Of-Spec Questions

The following are intentionally left for later implementation planning rather than fixed
in this document:

- exact transport between client and persistent controller
- exact JSON schema for machine-readable output
- exact API shape for non-file selectors such as regex and tag filters
- exact heuristics for contamination detection
- whether a future top-level CLI wrapper should be added beyond `julia -e`
