# `fresh` Run Reset Design

Date: 2026-04-23
Issue: `#2` Implement `run(fresh = true)` worker-pool reset

## Goal

Add `run(fresh = true)` so callers can discard warm worker state and execute the next run on a newly bootstrapped worker pool without restarting the daemon process itself.

## Chosen Scope

`fresh = true` means:

- keep the current daemon process, socket listener, registry record path, and server identity
- stop all existing workers owned by that daemon
- start a replacement worker pool using the existing `RunnerConfig`
- execute the requested run on the replacement pool

`fresh = true` does not mean:

- stopping and relaunching the controller daemon
- changing daemon configuration such as `jobs`
- altering default reuse behavior when `fresh = false`

## Why This Scope

This is the smallest change that matches the issue wording "worker-pool reset" and preserves the existing daemon-backed workflow. It avoids extra registry churn, keeps `status()` semantics simple, and provides the intended escape hatch for suspect warm state.

## Public API Behavior

`run` grows a new keyword:

```julia
run(; fresh::Bool = false, ...)
```

Behavior:

- `run(fresh = false)` keeps the current behavior
- `run(fresh = true)` recreates the worker pool immediately before job selection and scheduling
- `fresh = true` can be combined with explicit `tests`, `quickfail`, `changed_only`, and `rerun_failed`
- if there is no live daemon, `run(fresh = true)` still provisions one through the existing `serve` path, then runs against freshly bootstrapped workers

## Controller Behavior

The controller handles `fresh = true` as an in-process refresh operation.

Sequence:

1. reject the request if a run is already active
2. mark controller state as `:running` as today
3. if `fresh = true`, stop the current worker pool
4. start a replacement pool with the current `RunnerConfig`
5. swap `state.workers` to the new pool
6. continue with normal job selection and scheduling

The refresh happens before job selection so that all selection modes share the same execution context.

## Failure Handling

Refresh failure should be explicit and conservative.

- If replacement worker bootstrap fails, the `run` request fails
- The controller should avoid leaving `state.workers` pointing at a half-initialized pool
- The preferred implementation is to keep the old pool reference until the new pool is fully bootstrapped, then swap on success
- Any partially created replacement workers should be stopped before returning the error

This keeps failure behavior consistent with the rest of the runtime: failed bootstrap is surfaced immediately instead of silently degrading.

## Status Semantics

`status()` should remain coherent across refreshes.

- `pid` stays the same
- `server_id` stays the same
- `jobs` stays the same
- `state` still transitions through the existing `:running` and `:idle` states
- `last_failed` and `last_success_at` continue to reflect run outcomes, not the refresh operation itself

## Testing Plan

Add focused regression coverage for:

1. `run(fresh = true)` replaces the worker pool and still completes the requested run successfully
2. the daemon identity reported by `status()` is unchanged across the refresh
3. a follow-up run after `fresh = true` still works on the refreshed pool
4. refresh failure on bootstrap leaves the controller in a safe state and surfaces an error

The tests should reuse the existing daemon/controller integration style under `test/controller_daemon.jl` and the bootstrap-failure patterns already used in `test/crash_recovery.jl`.
