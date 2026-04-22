# WarmTestRunner.jl Status

Updated: 2026-04-22

This file summarizes how much of `SPEC.md` is implemented in the current repository and
what remains deferred.

## Overall

Current state:

- The daemon-backed MVP is implemented and passing the package test suite.
- The full product described in `SPEC.md` is not complete yet.
- The implemented scope matches the MVP plan in
  `docs/superpowers/plans/2026-04-21-warmtestrunner-mvp.md` plus a round of hardening
  after whole-system review.

Practical summary:

- `serve`, `run`, `status`, and `stop` work.
- A persistent controller process owns a warm `Malt` worker pool.
- Test files run in fresh modules inside reused workers.
- File-level parallel scheduling, output capture, crash recovery, and `quickfail` work.
- `changed_only` is implemented as a runtime selection flag.
- Several "full spec" features are still intentionally deferred.

## What Is Implemented

### Public API

Implemented:

- `serve(; pkgroot, jobs, threads_per_worker, use_testenv, preload_package, startup_file, ...)`
- `run(; tests = String[], quickfail = false, changed_only = false, kwargs...)`
- `status(; pkgroot = pwd())`
- `stop(; pkgroot = pwd())`

Current behavior:

- `serve()` starts or reuses a daemon for the package root.
- `run()` connects to the daemon, discovers tests when `tests == []`, and returns a
  structured `RunSummary`.
- `run(...; changed_only = true)` selects changed tests with the implemented coarse
  heuristic, including the `src/` fallback to the full discovered set.
- `status()` reports daemon state and current active-job count.
- `stop()` sends a stop request and returns after the controller acknowledges it.

Important note:

- `stop()` does not wait for registry-file disappearance before returning. Shutdown
  completion is asynchronous after the stop ACK.

### Core Runtime

Implemented:

- Controller daemon over localhost sockets
- Registry files under `WARMTESTRUNNER_HOME` / default warmtestrunner home
- Persistent warm worker pool using `Malt.Worker`
- Worker bootstrap with package/test environment activation
- Optional bootstrap hook via `test/warmtest_bootstrap.jl`
- Per-test-file execution in a fresh module
- File discovery under `test/`
- Exclusion of `test/runtests.jl` and `test/warmtest_bootstrap.jl`
- Tag parsing for `# warmtest: tags=...`
- Output capture and result classification
- Worker crash detection and replacement
- Ordered result aggregation
- `quickfail` with skipped-result preservation
- Stale registry detection and replacement
- Active-run `status()` responsiveness
- Active-run `stop()` responsiveness

### Configuration Actually Honored

Implemented and active:

- `pkgroot`
- `jobs`
- `threads_per_worker`
- `use_testenv`
- `preload_package`
- `startup_file`

Accepted but intentionally restricted:

- `use_revise = true` is rejected
- `color = false` is rejected
- `worker_timeout != 60.0` is rejected
- `log_level != :info` is rejected

This is deliberate. Those knobs exist in the spec shape, but the current MVP rejects
unsupported values instead of silently ignoring them.

## Verified Behavior

The current test suite covers:

- public API smoke checks
- test discovery and tag parsing
- changed-only selection coverage
- sandbox classification of pass/fail/error
- single-worker bootstrap and execution
- `threads_per_worker`
- worker transport crash after stop
- inline scheduler ordering
- inline and public `quickfail`
- crash recovery and worker recreation
- stale registry replacement
- daemon request error handling
- active-run `status()`
- active-run `stop()`

Latest verification command:

```bash
julia --project=. --startup-file=no -e 'include("test/runtests.jl")'
```

Latest result:

- full suite passed on 2026-04-21

## Deferred From The Full Spec

Not implemented yet:

- `watch()`
- `rerun_failed`
- `fresh`
- `retry_crashed` as a public option
- `verbose`
- `seed`
- `output_format = :json`
- `Revise.jl` integration
- full CLI wrapper layer beyond `julia -e 'using WarmTestRunner; ...'`
- richer filtering modes beyond explicit `tests`
- complete `Pkg.test()`-style compatibility

## Known Design Differences Or Constraints

Compared with the broader spec / earlier discussion:

- Reusing an existing daemon with incompatible kwargs raises `ArgumentError` instead of
  silently reusing it.
- `stop()` is optimized for prompt acknowledgment, not synchronous teardown completion.
- Soft isolation is the model: fresh module per file, persistent worker per session.
- This is a development-time runner, not a replacement for final `Pkg.test()` checks.

## Rough Completion Assessment

Full-spec status:

- Core daemon MVP: done
- Hardening of daemon lifecycle and crash handling: done
- Full product surface from `SPEC.md`: partial

If measured against the current MVP plan rather than the full spec, the repository is in
"implemented and verified" state.

## Recommended Next Work

Most sensible next steps:

1. decide whether the next milestone is `watch()`
2. implement one deferred feature set at a time behind tests
3. document the current public contract more explicitly, especially `stop()` semantics
4. keep using `Pkg.test()` separately as the final clean-room verification path
