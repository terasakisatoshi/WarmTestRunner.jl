# `retry_crashed` Public Run Option Design

Date: 2026-04-23
Issue: `#4` Expose `retry_crashed` as a public `run()` option

## Goal

Add `run(retry_crashed = ...)` so callers can choose whether a crashed test file is retried once on a recreated worker or finalized immediately as `:crashed`.

## Chosen Scope

`retry_crashed` becomes a per-run option on the public `run()` API.

- `retry_crashed = true` preserves the current behavior
- `retry_crashed = false` disables retrying the crashed job itself
- the option applies only to crash recovery during job execution

It does not:

- become part of `serve()` or daemon-level persistent configuration
- change the existing worker recreation path needed for later jobs
- affect failure, error, or quickfail semantics outside crash handling

## Why This Scope

Crash retry is a run-time scheduling choice, not daemon configuration. Keeping it on `run()` matches the existing spec shape, avoids reuse-configuration churn, and lets callers decide case by case whether they want a second attempt after a worker transport crash.

## Public API Behavior

`run` grows one supported keyword:

```julia
run(; retry_crashed::Bool = true, ...)
```

Behavior:

- `run(retry_crashed = true)` retries a crashed job once after recreating the worker
- `run(retry_crashed = false)` records the first `:crashed` result without rerunning that job
- later jobs may still run on a recreated replacement worker when recovery is possible
- `retry_crashed` composes normally with `tests`, `quickfail`, `changed_only`, `rerun_failed`, and `fresh`

## Scheduler Semantics

The scheduler keeps its current crash detection and worker recreation flow, but makes the retry step conditional.

Sequence when a job crashes:

1. record the initial `:crashed` result from the dead worker
2. if `retry_crashed = false`, finalize that result for the crashed job
3. if `retry_crashed = true`, recreate the worker and rerun the same job once
4. if the retry also crashes, finalize the second `:crashed` result
5. when execution should continue, ensure a healthy worker exists for later jobs

This preserves two existing invariants:

- a crashed worker does not keep processing jobs
- later jobs can continue when `quickfail = false`

## Quickfail Semantics

`quickfail` continues to react to the finalized result for the current job.

- with `retry_crashed = true`, quickfail waits for the single retry result before deciding whether to stop dispatch
- with `retry_crashed = false`, quickfail stops dispatch immediately after the first `:crashed` result is finalized

## Testing Plan

Add focused regression coverage for:

1. `run(...; retry_crashed = false)` finalizes a crashed file without rerunning it and still allows later jobs when `quickfail = false`
2. `run(...; quickfail = true, retry_crashed = false)` preserves skipped ordering after the finalized crash
3. existing crash-recovery behavior remains intact when `retry_crashed = true`
4. direct scheduler coverage still proves that later jobs run on a recreated worker after a no-retry crash path

Tests should extend the existing crash-recovery coverage in `test/crash_recovery.jl`.

## Documentation Updates

Update `STATUS.md` to reflect:

- `run(...; retry_crashed = true, ...)` is now supported
- the default remains one retry after a crash on a recreated worker
- `retry_crashed = false` finalizes the first crash result for that job while still allowing later jobs to use recovered workers when appropriate
