# TestRunner Backend Design

## Goal

Make WarmTestRunner a warm, daemon-backed frontend for a TestRunner-style virtual test
execution engine.

The target design is not a compatibility patch over the current isolated-module runner.
It replaces the execution model with one that more closely matches ordinary Julia test
suites while adding first-class selective execution.

## Motivation

The current worker backend evaluates each discovered test file with `Base.include` inside
a worker-local test context module. That design is simple, but it creates artificial name
resolution behavior. For example, a test file containing both:

```julia
using Tensor4all
using QuanticsGrids
```

can fail in the synthetic module because `Tensor4all` exports a nested `QuanticsGrids`
module while the upstream `QuanticsGrids` package also provides the same binding. The same
file passes when evaluated in the normal `Main` context.

This is a symptom of a broader issue: WarmTestRunner should not invent a per-file module
model that differs from how package tests usually run. The warm worker process should be
the isolation boundary. Inside that worker, the execution engine should preserve ordinary
Julia test-suite structure, including `test/runtests.jl`, `include(...)`, top-level setup,
and `Test.jl` behavior.

## Decision

Adopt a TestRunner.jl-style virtual execution backend as the canonical worker execution
engine.

This means:

- require Julia 1.12 or newer
- stop excluding `test/runtests.jl` from the normal execution model
- treat `test/runtests.jl` as the preferred suite entry point
- use `Main` as the default worker execution top module
- parse test source with JuliaSyntax
- execute non-test top-level code as dependency/setup code
- selectively execute matching `@test` and `@testset` expressions
- intercept `include(...)` so included files are processed by the same backend
- capture Test.jl results through a TestRunner-style custom test set

The current `Base.include(context, file)` backend should be removed rather than kept as a
legacy mode.

## Non-Goals

- Preserve the old per-file isolated module semantics.
- Preserve Julia 1.10 or 1.11 support.
- Add a separate compatibility execution mode.
- Recreate TestRunner.jl's CLI app packaging.
- Use TestRunner.jl's JSON output structures as WarmTestRunner's public result format.

WarmTestRunner keeps its daemon, worker pool, scheduling, retry, watch, and result-summary
identity. TestRunner.jl supplies the execution model, not the whole application shape.

## Architecture

### Layers

WarmTestRunner should have three clear runtime layers:

1. Controller layer
   - daemon lifecycle
   - registry management
   - test planning
   - worker scheduling
   - crash recovery
   - result aggregation

2. Worker transport layer
   - Malt worker creation
   - package/test environment activation
   - Revise loading
   - package preload
   - bootstrap hook execution
   - stdout/stderr capture
   - transport crash classification

3. Virtual execution layer
   - source parsing
   - include interception
   - top-level dependency execution
   - selective `@test` / `@testset` execution
   - Test.jl result capture
   - failure/error diagnostic extraction

The execution layer should not know about daemon sockets or scheduling. The controller
should not know about JuliaSyntax, JuliaInterpreter, or LoweredCodeUtils internals.

### Source Files

Expected source layout:

```text
src/execution.jl
src/virtual_execution.jl
src/worker.jl
src/controller.jl
src/results.jl
```

`execution.jl` owns the interface and data model:

```julia
struct TestSelection
    file::String
    patterns::Vector{Any}
    filter_lines::Union{Nothing,Set{Int}}
    run_all::Bool
end

struct ExecutionPlan
    entryfile::String
    selections::Vector{TestSelection}
    run_all::Bool
end

struct ExecutionResult
    status::Symbol
    stdout::String
    stderr::String
    exception_summary::Union{Nothing,String}
    stacktrace::Union{Nothing,String}
    diagnostics::Vector{TestDiagnostic}
end
```

`virtual_execution.jl` owns the TestRunner-derived engine:

- `TRInterpreter` equivalent
- JuliaSyntax parsing
- LoweredCodeUtils dependency selection
- JuliaInterpreter call evaluation override
- `include(...)` handling
- custom Test.jl test set
- diagnostic extraction

`worker.jl` should call one execution-layer function, conceptually:

```julia
execute_plan(plan::ExecutionPlan; topmodule::Module = Main)
```

The worker should not directly `include` test files anymore.

## Execution Semantics

### Suite Entry

When `test/runtests.jl` exists, it is the suite entry point for normal runs.

```julia
WarmTestRunner.runtests()
```

means:

```text
entryfile = test/runtests.jl
run all tests reachable through that entry file
```

When `test/runtests.jl` does not exist, WarmTestRunner may synthesize an entry plan from
discovered test files. That fallback exists for small packages, but it should not be the
primary model.

### Top Module

The default execution top module is the worker's `Main`.

This intentionally mirrors normal Julia usage:

```bash
julia --project=. test/runtests.jl
```

or:

```julia
include("test/runtests.jl")
```

The worker process is the isolation boundary. Warm state accumulates in `Main` until the
worker is recreated. `fresh=true`, crashed-worker replacement, and `stop(); serve()` are
the reset mechanisms.

### Top-Level Code

The execution backend should classify top-level expressions as either test expressions or
setup/dependency expressions.

Test expressions include:

- `@test`
- `@testset`
- `@test_throws`
- `@test_broken`
- `@test_skip`
- `@test_warn`
- `@test_logs`
- `@test_deprecated`
- `@inferred`

Non-test top-level expressions are executed as setup. This includes imports, constants,
type definitions, function definitions, data setup, and `include(...)`.

This is deliberately conservative. Top-level setup may have side effects, but ordinary
Julia test suites rely on those side effects.

### Include Handling

`include(...)` must be intercepted by the virtual execution backend.

When interpreted top-level code calls:

```julia
include("foo.jl")
include(SomeModule, "foo.jl")
```

the backend resolves the path relative to the including file and recursively processes the
included file under the same execution plan.

This is the core reason `test/runtests.jl` can be restored as the primary entry point.
File-level selection can still target included files without directly bypassing the suite
entry file.

### Selection Model

All public selectors should normalize into one `ExecutionPlan`.

Supported selectors:

- run all tests
- target files
- testset names
- regular expressions for testset names
- line numbers or line ranges
- expression patterns
- changed-only file selection
- rerun-failed file selection

The internal representation should be file-specific:

```julia
Dict{String,Vector{Any}}      # file => patterns
Dict{String,Set{Int}}         # file => filter lines
```

This follows TestRunner.jl's `runtests(entryfile, patterns_for_files)` model.

WarmTestRunner also needs an internal run-all sentinel for file selection. Selecting
`tests = ["api/foo.jl"]` means "run every test expression in this file when it is reached
through the suite entry", not "run only non-test setup in this file". This should be
represented explicitly in `TestSelection.run_all`, not encoded as an empty pattern vector.

### Public API Shape

The ideal public API is:

```julia
runtests(;
    tests = String[],
    testsets = String[],
    line_patterns = Pair{String,Any}[],
    expression_patterns = Pair{String,Any}[],
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    fresh::Bool = false,
    quickfail::Bool = false,
    retry_crashed::Bool = true,
    output_format::Symbol = :text,
    kwargs...
)
```

`tests` means selected test files, not direct file execution. If `test/runtests.jl`
includes `test/api/foo.jl`, selecting `tests = ["api/foo.jl"]` should run through
`test/runtests.jl` and execute matching tests in that included file.

If a selected file is not reachable from `test/runtests.jl`, the planner should fail with
a clear `ArgumentError`. The ideal model treats the suite entry as authoritative. Hidden
direct execution would make selected runs diverge from whole-suite behavior and reintroduce
the same class of surprises this design is removing.

### Result Model

WarmTestRunner should keep `RunSummary` and `TestResult` as its public result surface.

The execution backend should provide richer internal diagnostics, but those diagnostics
should be adapted into the existing summary shape:

- `:passed`
- `:failed`
- `:errored`
- `:crashed`
- `:skipped`

For selected runs through a single `test/runtests.jl` entry, result grouping needs a clear
unit. The ideal unit is the selected file when file selection is present, otherwise the
entry file. Testset-level diagnostics can appear inside `stdout`, `exception_summary`,
`stacktrace`, and structured JSON diagnostics.

## Dependencies

Update `Project.toml`:

```toml
[deps]
Compiler = "807dbc54-b67e-4c79-8afb-eafe4df6f2e1"
JuliaInterpreter = "aa1ae85d-cabe-5617-a682-6adf51b2e16a"
JuliaSyntax = "70703baa-626e-46a2-a12c-08ffd08c73b4"
LoweredCodeUtils = "6f1432cf-f94c-5a45-995e-cdbf5db27b0b"
MacroTools = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"

[compat]
julia = "1.12"
```

Use TestRunner.jl's compat bounds as the starting point:

```toml
Compiler = "0.1"
JuliaInterpreter = "0.10.3"
JuliaSyntax = "1, 2"
LoweredCodeUtils = "3.3.1"
MacroTools = "0.5.16"
```

Do not add TestRunner.jl as a runtime dependency if the goal is to own the integrated
backend. Vendor the design, not the package boundary.

## Error Handling

The backend must distinguish these cases:

- Test failures inside `@test`
- Exceptions inside `@test`
- Exceptions inside selected `@testset` bodies but outside a specific `@test`
- Syntax parse errors
- Include path errors
- Top-level setup errors
- Worker transport crashes

TestRunner.jl's custom test set and exception-stack scrubbing should be adapted so that
diagnostics point at user test files instead of interpreter internals.

Transport crashes remain the responsibility of `worker.jl` and `controller.jl`.

## Scheduling

The old scheduler maps one file to one `TestJob`. The new planner should map one
`ExecutionPlan` to one worker execution.

For whole-suite runs, there are two possible scheduling modes:

1. Single-entry mode
   - one worker runs `test/runtests.jl`
   - most faithful to ordinary suite behavior
   - least parallel

2. Partitioned selection mode
   - controller partitions selected files across workers
   - each worker uses `test/runtests.jl` as entry with file-specific selections
   - preserves include semantics while enabling parallelism
   - may duplicate top-level setup across workers

The ideal default is:

- whole-suite run with `jobs > 1`: statically discover included files from `test/runtests.jl`
  and partition reachable test files across workers
- whole-suite run with dynamic or unresolvable include structure: use single-entry mode and
  emit an informational note in verbose output
- direct `runtests(testsets=...)` or line/expression selection: run a focused plan on one worker
- `jobs=1`: run a single faithful plan

Partitioned plans still use `test/runtests.jl` as their entry. The selection map differs
per worker. Files assigned to that worker get `run_all = true` or their requested patterns.
Files not assigned to that worker execute only non-test top-level setup.

It is acceptable for top-level setup to be duplicated across workers. Worker processes are
already separate isolation boundaries, and this matches the current product tradeoff of
speed over strict single-process suite fidelity.

The planner should never bypass `test/runtests.jl` just to preserve file-level
parallelism.

## Freshness And Warm State

Warm state is part of the product.

The new contract:

- workers keep `Main` state between runs
- Revise updates package code where possible
- `fresh=true` recreates workers and discards `Main` state
- changing execution-affecting config requires daemon restart
- setup code may be re-executed across warm runs and must be treated as normal Julia test
  behavior

Because `Main` is reused, repeated `include` of the same test file can hit constant or
module redefinition issues. The design should not hide this with synthetic modules. Users
should use `fresh=true` when warm `Main` state becomes invalid.

## Testing Strategy

Regression tests should be written before implementation for these behaviors:

- Tensor4all-style ambiguous exported module names work under `Main`.
- `test/runtests.jl` is used as the entry point.
- `include(...)` is intercepted and selected included files run.
- File selection runs through the entry file rather than direct include.
- Testset name selection works.
- Regex testset selection works.
- Line selection works.
- Expression selection works.
- Non-test top-level setup runs before selected tests.
- Errors in setup code become `:errored`.
- Test failures become `:failed`.
- Exceptions inside `@test` retain user stack traces.
- `fresh=true` clears worker `Main` state.
- Crashed workers are still retried or finalized according to `retry_crashed`.
- JSON output includes useful diagnostics for selected tests.

Tensor4all should be kept as an external validation target, not as the only regression.
The WarmTestRunner test suite should include small fixture packages that reproduce the
same name-resolution and include-selection patterns deterministically.

## Documentation Updates

Update:

- `README.md`
- `SPEC.md`
- `STATUS.md`
- examples under `examples/`

Remove language that says:

- `test/runtests.jl` is excluded by default
- each test file runs as an independent file-level job
- a shared worker-local test module is the execution context

Replace it with:

- `test/runtests.jl` is the preferred suite entry
- the worker process is the isolation boundary
- worker `Main` is the warm execution context
- the virtual backend supports file/testset/line/expression selection
- `fresh=true` resets accumulated worker state

## Resolved Policy Choices

### Unreachable Selected Files

File selectors must refer to files reachable from `test/runtests.jl`. If a selected file
is not reachable, planning fails with an `ArgumentError` that names the file and the entry
point. This keeps selected runs faithful to the suite.

Packages without `test/runtests.jl` are the only exception. For those packages,
WarmTestRunner synthesizes an entry plan from discovered test files.

### Parallelism

For `jobs > 1`, the controller partitions statically reachable included test files across
workers. Every worker still starts from `test/runtests.jl`; the difference is the
file-specific selection map.

If include discovery is dynamic or incomplete, the controller falls back to a single
faithful plan instead of directly including files.

### Quickfail

`quickfail = true` has two effects:

- inside one execution plan, the custom test set throws an internal sentinel after the
  first failure or error is recorded
- at the controller level, no new plans are scheduled after the first failed or errored
  result is received

Already-running worker plans may finish or be interrupted only if the transport layer can
do that safely. The required semantic guarantee is that no additional pending work is
started after the first observed failure.

### JSON Diagnostics

The JSON output should move to schema version 2 when this backend lands. Keep the existing
summary fields, and add per-result diagnostics:

```julia
diagnostics = [
    (
        file = "test/foo.jl",
        line = 42,
        kind = "fail" | "error" | "parse_error" | "setup_error",
        message = "...",
        related = [
            (file = "src/foo.jl", line = 10, message = "...")
        ],
    )
]
```

The text display can stay concise, but JSON should expose enough structure for editors and
watch-mode UIs.

## Recommended Implementation Order

1. Add dependencies and raise Julia compat to 1.12.
2. Add execution data types and backend interface.
3. Port the TestRunner-style interpreter into `virtual_execution.jl`.
4. Add local fixture tests for virtual execution independent of Malt.
5. Integrate the backend into `worker.jl`.
6. Replace file-direct scheduling with execution planning.
7. Restore `test/runtests.jl` as the default entry point.
8. Add public selectors.
9. Update result adaptation and JSON diagnostics.
10. Update docs and external Tensor4all validation.

## Success Criteria

The design is successful when:

- Tensor4all's `test/api/skeleton_alignment.jl` passes without editing Tensor4all.
- WarmTestRunner can run a package through `test/runtests.jl`.
- WarmTestRunner can select tests by file, testset, line, and expression.
- Included files are handled through the same execution plan.
- Failure diagnostics point at user test files.
- `fresh=true` reliably resets worker state.
- The old per-file isolated-module execution path is gone.
