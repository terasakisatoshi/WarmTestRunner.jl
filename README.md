# WarmTestRunner.jl

WarmTestRunner.jl provides a daemon-backed test runner for local iteration. It keeps a warm worker pool alive and reuses it across runs.

## Public API

- `serve(; pkgroot, jobs, threads_per_worker, use_testenv, preload_package, startup_file, ...)`
- `run(; tests = String[], quickfail = false, changed_only = false, kwargs...)`
- `status(; pkgroot = pwd())`
- `stop(; pkgroot = pwd())`

## Execution Model

- `serve()` starts or reuses a daemon for the package root.
- `run()` connects to the daemon, discovers tests when `tests == []`, and returns a structured `RunSummary`.
- if `changed_only = true` and any changed path is under `src/`, the full discovered test set runs
- if `changed_only = true` and Git change detection is unavailable or the package is not in a usable Git repo, the full discovered test set runs
- if `changed_only = true` and only changed `.jl` files anywhere under `test/` are present, only those files run
- if `changed_only = true` and no relevant files changed, `run()` returns an empty `RunSummary`
- `changed_only` cannot be combined with explicit `tests`
- `status()` reports daemon state and current active-job count.
- `stop()` sends a stop request and returns after the controller acknowledges it.
