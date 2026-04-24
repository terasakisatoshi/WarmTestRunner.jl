# Shared Topmodule Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace per-file fresh-module execution with a shared per-worker test module so warm runs preserve test context and avoid many `UndefVarError` failures.

**Architecture:** Each worker will create and retain one shared test module during bootstrap. Test files will run inside that module, while scheduling remains file-level and `fresh=true` / crash recovery continue to recreate workers to clear warm state.

**Tech Stack:** Julia, Malt, Test, existing WarmTestRunner controller/worker runtime

---

### Task 1: Lock in regression coverage for shared context expectations

**Files:**
- Modify: `test/controller_daemon.jl`
- Test: `test/controller_daemon.jl`

**Step 1: Write the failing test**

Add focused integration tests that create temporary fixture files proving:

- one file imports the package and another file references `FixturePkg` without local `using`
- one file defines shared helpers in the worker context and a later file uses them
- `fresh=true` removes those shared definitions

**Step 2: Run test to verify it fails**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: FAIL because the current per-file fresh-module model loses the shared bindings.

**Step 3: Keep the new tests minimal**

Prefer temporary test files in `mktempdir()` over permanent fixtures unless an existing
fixture package already covers the case cleanly.

**Step 4: Run test again to confirm the same failure**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: the new regression tests still fail for the intended reason.

### Task 2: Extend worker state to track a shared test module

**Files:**
- Modify: `src/types.jl`
- Modify: `src/worker.jl`
- Test: `test/controller_daemon.jl`

**Step 1: Write the failing test**

Use the regression from Task 1 as the active red test.

**Step 2: Run test to verify it fails**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: FAIL with missing shared context behavior.

**Step 3: Write minimal implementation**

- add a field to `WorkerHandle` for the shared module identifier or durable module handle
- during `bootstrap_worker!`, create the shared module after activation/preload/bootstrap
- make the module discoverable for later remote evaluation

Do not change scheduling logic yet.

**Step 4: Run test to verify progress**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: tests still fail or move to a later failure, but bootstrap can now produce a shared context.

### Task 3: Execute test files inside the shared worker module

**Files:**
- Modify: `src/worker.jl`
- Test: `test/controller_daemon.jl`
- Test: `test/sandbox.jl` if helper behavior changes

**Step 1: Write the failing test**

Keep the Task 1 regression tests active as the red target.

**Step 2: Run test to verify it fails**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: FAIL due to fresh-module-per-file execution.

**Step 3: Write minimal implementation**

Update `run_test_in_worker!` so it:

- reuses the worker's shared module
- ensures `using Test` is available in that module
- includes the target test file in the shared module
- preserves stdout/stderr capture and current result classification

Do not broaden the public API.

**Step 4: Run test to verify it passes**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'`

Expected: shared-context regressions PASS.

### Task 4: Verify reset semantics for `fresh=true` and crash recovery

**Files:**
- Modify: `test/controller_daemon.jl`
- Modify: `test/crash_recovery.jl`
- Test: `test/controller_daemon.jl`
- Test: `test/crash_recovery.jl`

**Step 1: Write the failing test**

Add tests that prove:

- `fresh=true` removes prior shared definitions
- worker recreation after a crash starts from a clean shared module

**Step 2: Run tests to verify they fail**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl"); include("test/crash_recovery.jl")'`

Expected: FAIL because the new reset semantics are not yet fully asserted or implemented.

**Step 3: Write minimal implementation**

Adjust worker bootstrap or recreation code only if needed so fresh/recovered workers always
start with a brand-new shared module.

**Step 4: Run tests to verify they pass**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl"); include("test/crash_recovery.jl")'`

Expected: PASS.

### Task 5: Update sandbox expectations or helpers if needed

**Files:**
- Modify: `src/sandbox.jl` only if shared execution helpers are extracted
- Modify: `test/sandbox.jl`
- Test: `test/sandbox.jl`

**Step 1: Write the failing test**

If the shared-module implementation changes any assumptions in `sandbox.jl`, add the
smallest failing regression there.

**Step 2: Run test to verify it fails**

Run: `julia --project=. --startup-file=no -e 'include("test/sandbox.jl")'`

Expected: FAIL only if sandbox helper assumptions changed.

**Step 3: Write minimal implementation**

Keep sandbox helpers aligned with the worker execution contract without reintroducing
fresh-module-per-file behavior by accident.

**Step 4: Run test to verify it passes**

Run: `julia --project=. --startup-file=no -e 'include("test/sandbox.jl")'`

Expected: PASS.

### Task 6: Update product docs to match the new execution model

**Files:**
- Modify: `SPEC.md`
- Modify: `STATUS.md`
- Modify: `README.md`

**Step 1: Write the failing doc expectation**

Identify stale language that still claims:

- fresh module per file
- soft isolation via per-file namespace reset

**Step 2: Update the docs**

Document the new model clearly:

- shared test module per worker
- state persists across files within one worker
- `fresh=true` is the reset mechanism
- this is intentionally less isolated and more context-preserving

**Step 3: Review for consistency**

Check that spec, status, and README describe the same behavior.

### Task 7: Run targeted verification

**Files:**
- Test: `test/controller_daemon.jl`
- Test: `test/crash_recovery.jl`
- Test: `test/sandbox.jl`

**Step 1: Run targeted tests**

Run: `julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl"); include("test/crash_recovery.jl"); include("test/sandbox.jl")'`

Expected: PASS.

**Step 2: Run full suite**

Run: `julia --project=. --startup-file=no -e 'include("test/runtests.jl")'`

Expected: PASS.

**Step 3: Run clean-room package test**

Run: `julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'`

Expected: PASS.
