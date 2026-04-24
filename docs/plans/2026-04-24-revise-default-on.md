# Revise Default On Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable `Revise.jl` integration by default while preserving `use_revise = false` as an explicit opt-out.

**Architecture:** `RunnerConfig` remains the single source of truth for runtime defaults. Worker bootstrap already branches on `cfg.use_revise`, so the behavior change is isolated to the configuration default plus tests and documentation.

**Tech Stack:** Julia, WarmTestRunner.jl, Revise.jl, Test standard library.

---

### Task 1: Update Configuration Tests

**Files:**
- Modify: `test/api_smoke.jl`

**Step 1: Write the failing assertions**

Add assertions that the default config enables Revise and explicit false disables it:

```julia
@test cfg.use_revise === true
@test WarmTestRunner.make_config(; use_revise = false).use_revise === false
```

**Step 2: Run the focused test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl")'
```

Expected: FAIL until the default is changed.

### Task 2: Update Worker Revise Tests

**Files:**
- Modify: `test/worker_single.jl`

**Step 1: Convert the positive Revise test to use the default**

Change the worker load test to omit `use_revise = true` and assert Revise loads by default.

**Step 2: Add an explicit opt-out test**

Create a worker with `use_revise = false`, bootstrap it, and assert:

```julia
@test Malt.remote_eval_fetch(worker.proc, :(isdefined(Main, :Revise))) === false
@test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_REVISE_LOADED)) === false
```

**Step 3: Run the focused worker test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: FAIL until the default is changed, then PASS.

### Task 3: Change Runtime Default

**Files:**
- Modify: `src/config.jl`

**Step 1: Implement the minimal change**

Change:

```julia
use_revise::Bool = false
```

to:

```julia
use_revise::Bool = true
```

**Step 2: Run focused tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl")'
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: PASS.

### Task 4: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `STATUS.md`

**Step 1: Replace the old default description**

Document that `use_revise` defaults to `true`, and `use_revise = false` disables worker Revise bootstrap. Update the README user-facing Revise section and configuration example in addition to SPEC/STATUS.

**Step 2: Run documentation-relevant regression tests**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected: PASS.

### Task 5: Final Verification

**Files:**
- No edits.

**Step 1: Confirm clean-room package test passed**

Use the Task 4 `Pkg.test()` result as the final verification. Re-run only if code changed after Task 4:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected: PASS.
