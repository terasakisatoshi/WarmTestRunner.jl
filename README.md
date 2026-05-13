# WarmTestRunner.jl

`WarmTestRunner.jl` is a test runner that speeds up local test iteration while developing Julia packages.

Ordinary `Pkg.test()` runs tests in a fresh Julia process each time. `WarmTestRunner.jl` instead reuses a daemon process and a warm worker pool, spreading package load and compilation cost across multiple test runs.

As a rule of thumb, split usage like this:

- Day-to-day edit/test loops: `using WarmTestRunner; runtests()`
- Final checks before merge, release, or CI-equivalent runs: `Pkg.test()`

`WarmTestRunner.jl` is not a full drop-in replacement for `Pkg.test()`. Worker processes are reused, and each worker’s `Main` stays warm as an execution context. It favors iteration speed over strictly clean-room isolation.

## Requirements

- Julia 1.12 or later
- `Project.toml` for the package under test
- A `test/` directory with normal Julia test files

## Installation

Make this package available in the environment of the project you are testing. To use a local checkout as an unregistered package, add it from that project:

```bash
cd path/to/this/directory
julia -E 'using Pkg; Pkg.activate(); Pkg.develop(path = ".")'
```

## Basic usage

```bash
$ cd path/to/target/package
$ julia --project -E 'using WarmTestRunner; summary = runtests()'
```

If `test/runtests.jl` exists, `runtests()` uses it as the test suite entry point. When you pass `tests = [file.jl]` to point at `./test/file.jl`, reachable included files still go through `test/runtests.jl`, and only tests in that file are selected. Non-selected included files may still evaluate non-test expressions needed for dependencies or top-level setup, but `@test` / `@testset` in non-selected files are not run.

Pass `split_testsets = true` to split literal-name top-level `@testset` blocks in statically reachable test files into separate execution units. If you start a worker pool first with `serve(jobs = 4)`, jobs for split testsets are dispatched in parallel to existing workers.

```bash
$ julia --project -E 'using WarmTestRunner; serve(jobs = 4); runtests(split_testsets = true)'
```

The return value is a `RunSummary`:

```julia
summary.passed
summary.failed
summary.errored
summary.crashed
summary.skipped
summary.results
```

Each result is in `summary.results`; you can inspect `path`, `status`, `stdout`, `stderr`, `exception_summary`, `stacktrace`, `elapsed`, `diagnostics`, and more. For a full run, the unit of results is usually `test/runtests.jl`; when selecting files with `tests = [...]`, each selected file is a result unit. With `split_testsets = true`, top-level testset labels like `test/file.jl:line: testset name` are the result units.

The first `runtests` call starts a daemon in the background. Later `runtests` calls reuse compilation artifacts for faster runs. To stop the daemon, run:

```bash
$ cd path/to/target/package
$ julia --project -E 'using WarmTestRunner; stop()'
```

## How it works

When you call `runtests()`, a **controller** in your Julia session discovers the suite (preferring `test/runtests.jl`), applies any filters you passed, and builds **execution plans**—discrete units of work (whole suite, selected files, or split top-level `@testset`s).

Those jobs are sent to a **daemon** process that owns a pool of long-lived **worker** processes backed by **Malt.jl**. Each worker is a normal Julia process whose `Main` stays loaded across runs: package loads, compiled methods, and JIT work from earlier runs are reused, which is why iteration feels faster than starting fresh every time.

On startup, each worker runs a **bootstrap**: it activates the package’s test environment (via **TestEnv.jl**-style activation), can preload your package and **Revise.jl**, then executes plans **inside that worker’s `Main`**—similar in spirit to virtual execution through `test/runtests.jl`, so suite structure and top-level setup stay aligned with what `Pkg.test()` would see.

The controller **schedules** plans onto idle workers, **captures** stdout/stderr and failures into structured results, and can **retry** or replace workers if one crashes. If you call `serve(jobs = n)` first, the pool is sized for parallelism; with `split_testsets = true`, independent testset jobs run concurrently on different workers. Calling `stop()` shuts down the daemon and releases those processes.

## Caution

If you run `Pkg.build()` for the target package, you must stop the daemon (`stop()`) and rerun `runtests()` afterwards:

```sh
$ cd path/to/target/package
$ julia --project -e 'using Pkg; Pkg.build()'
$ julia --project -e 'using WarmTestRunner; stop()'
$ julia --project -e 'using WarmTestRunner; runtests()'
# update files in ./src or ./test/
$ julia --project -e 'using WarmTestRunner; runtests()'
# update files in ./src or ./test/ ... repeat the cycle
```