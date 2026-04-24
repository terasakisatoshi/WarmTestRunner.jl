# Shared Topmodule Design

## Goal

Reduce avoidable `UndefVarError` failures during warm runs by replacing the per-file fresh
module execution model with a shared per-worker execution context.

## Problem

The current runner creates a new anonymous module for each test file and evaluates only
`using Test` before `include(testfile)`. This keeps file execution soft-isolated, but it
breaks test suites that rely on package imports, helper definitions, constants, and
included setup code being available in a shared test context.

Typical failures look like:

- one file assumes `using MyPkg` already happened elsewhere
- helpers loaded through `include(...)` are not visible to another file
- top-level setup code that mutates globals is not preserved across file boundaries

This is consistent with the current spec, but it is not the desired product direction.

## Decision

Adopt a shared `topmodule` model per worker and treat it as the canonical warm execution
context for the lifetime of that worker.

This changes the runtime contract:

- each worker owns one long-lived test context module
- bootstrap and preload work still happen once per worker
- test files execute inside that worker-owned module instead of a fresh anonymous module
- `fresh=true` remains the escape hatch for throwing away accumulated state
- parallel scheduling remains file-level; only the execution context changes

## Recommended Rollout

Implement the new model in two stages.

### Stage 1

Switch from "fresh module per file" to "shared module per worker" while keeping file-level
selection and scheduling unchanged.

This stage should:

- eliminate many avoidable `UndefVarError` cases
- preserve the current `runtests()` surface area
- minimize scheduler and result-format churn

This stage does not attempt selective `@testset` execution.

### Stage 2

Optionally add `TestRunner`-style selective execution later:

- parse source syntax
- always execute non-test top-level setup
- selectively execute matching `@test` / `@testset`
- recursively process `include(...)` in the same shared module

That is a separate feature and should not be coupled to the first rollout.

## Architecture

### Worker Context

`WorkerHandle` should own a durable module reference created during bootstrap, for example
`WarmTestContext`.

Bootstrap should continue to:

1. `cd(pkgroot)`
2. activate the package/test environment
3. load `Revise` when requested
4. preload the package when requested
5. run `test/warmtest_bootstrap.jl` when present

After that, the worker should create and retain its shared test module. Test files will be
evaluated in that module for subsequent runs.

### File Execution

`run_test_in_worker!` should no longer create a new module per file. Instead, it should:

1. ensure the shared module has `using Test`
2. include the target file inside that shared module
3. capture stdout/stderr and classify pass/fail/error/crash as today

### Refresh and Crash Recovery

The new model increases warm-state coupling, so worker recreation matters more:

- `fresh=true` should replace the entire worker pool, as it does now
- crashed workers should still be recreated before reuse
- manual `stop()` plus `serve()` remains the hard reset path

## Tradeoffs

### Benefits

- avoids many cross-file `UndefVarError` failures
- better matches how many Julia test suites are actually structured
- simpler than full `TestRunner`-style AST selection

### Costs

- drops the current "fresh namespace per file" isolation guarantee
- increases susceptibility to state leakage between files
- may expose order dependence that was previously masked by per-file isolation

This trade is acceptable because backward compatibility with the current isolation model is
not a priority for this change.

## Testing Strategy

Add regression tests first for:

- a file that uses `MyPkg.symbol` without local `using MyPkg`, after another file imports it
- a file that depends on helpers loaded by another test file or shared include path
- `fresh=true` clearing the shared context
- worker crash recovery restoring a fresh shared context

Retain existing coverage for:

- file-level scheduling
- output capture
- quickfail
- retry-crashed behavior

Update any tests that currently assert fresh-module-per-file behavior.

## Files Expected To Change

- `src/types.jl`
- `src/worker.jl`
- `src/controller.jl`
- `src/sandbox.jl` if helper execution helpers are reused
- `test/controller_daemon.jl`
- `test/sandbox.jl`
- `STATUS.md`
- `SPEC.md`
