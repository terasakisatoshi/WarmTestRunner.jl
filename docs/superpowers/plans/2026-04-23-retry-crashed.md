# Retry Crashed Public Option Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `run(...; retry_crashed::Bool = true)` so callers can disable rerunning a crashed job while keeping worker recovery for later jobs.

**Architecture:** Keep `retry_crashed` as a per-run scheduling flag rather than daemon configuration. Thread it from the public `run()` API through the controller request into `schedule_jobs!`, make the crash retry conditional, and add protocol gating only for the behavior-changing `retry_crashed = false` path so older daemons cannot silently ignore it.

**Tech Stack:** Julia 1.10+, existing daemon/controller/worker runtime, `Test`, `Malt.Worker`, local socket protocol

---

## File Map

- Modify: `src/WarmTestRunner.jl`
  - expose `retry_crashed` on `run()`
  - restart older daemons when `retry_crashed = false` requires new protocol support
- Modify: `src/controller.jl`
  - add a `retry_crashed` keyword to `schedule_jobs!`
  - thread the request flag into daemon-backed scheduling
- Modify: `src/server_registry.jl`
  - bump protocol constants for the new no-retry behavior gate
- Modify: `test/crash_recovery.jl`
  - add crash-recovery tests for `retry_crashed = false`
- Modify: `STATUS.md`
  - move `retry_crashed` from deferred to implemented and document result semantics

### Task 1: Add failing crash-recovery tests for no-retry behavior

**Files:**
- Modify: `test/crash_recovery.jl`

- [ ] **Step 1: Write the failing public no-retry continuation test**

Add this testset after `"daemon continues later jobs after a permanent crash when quickfail=false"` in `test/crash_recovery.jl`:

```julia
@testset "public retry_crashed=false finalizes the first crash and continues later jobs" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(
                        tests = ["crash.jl", "pass.jl"],
                        quickfail = false,
                        retry_crashed = false,
                    )
                    @test getfield.(summary.results, :status) == [:crashed, :passed]
                    @test summary.crashed == 1
                    @test summary.passed == 1
                finally
                    WarmTestRunner.stop()
                end
            end
        end
    end
end
```

- [ ] **Step 2: Write the failing public quickfail no-retry test**

Add this testset after `"public quickfail keeps skipped ordering after a retried crash"`:

```julia
@testset "public quickfail stops immediately when retry_crashed=false finalizes a crash" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(
                        tests = ["crash.jl", "pass.jl"],
                        quickfail = true,
                        retry_crashed = false,
                    )
                    @test getfield.(summary.results, :status) == [:crashed, :skipped]
                    @test summary.crashed == 1
                    @test summary.skipped == 1
                finally
                    WarmTestRunner.stop()
                end
            end
        end
    end
end
```

- [ ] **Step 3: Write the failing direct scheduler no-retry recovery test**

Add this testset before `"quickfail waits for recovered crash result"`:

```julia
@testset "schedule_jobs! recreates a worker for later jobs even when retry_crashed=false" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
    workers = WarmTestRunner.start_worker_pool(cfg)
    try
        WarmTestRunner.stop_worker!(workers[1])
        jobs = [
            TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl"),
            TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl"),
        ]
        state = WarmTestRunner.ControllerState(
            cfg = cfg,
            handle = WarmTestRunner.ServerHandle(
                pkgroot = FIXTURE_ROOT,
                server_id = "test-server",
                pid = getpid(),
                started_at = time(),
                jobs = 1,
            ),
            status = WarmTestRunner.ServerStatus(pkgroot = FIXTURE_ROOT),
            workers = workers,
        )

        summary = WarmTestRunner.schedule_jobs!(
            workers,
            jobs,
            cfg;
            quickfail = false,
            retry_crashed = false,
            recover_worker! = index -> WarmTestRunner.recreate_worker!(state, index),
        )

        @test getfield.(summary.results, :status) == [:crashed, :passed]
        @test summary.crashed == 1
        @test summary.passed == 1
    finally
        WarmTestRunner.stop_worker_pool!(workers)
    end
end
```

- [ ] **Step 4: Run the focused crash-recovery file to verify the new tests fail**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/crash_recovery.jl")'
```

Expected:

- the new public tests fail because `run(...; retry_crashed = false)` is not accepted yet
- the direct scheduler test fails because `schedule_jobs!` does not accept `retry_crashed`

- [ ] **Step 5: Commit the red tests**

```bash
git add test/crash_recovery.jl
git commit -m "test: add retry_crashed coverage"
```

### Task 2: Implement conditional crash retry in the runtime

**Files:**
- Modify: `src/WarmTestRunner.jl`
- Modify: `src/controller.jl`
- Modify: `src/server_registry.jl`
- Test: `test/crash_recovery.jl`

- [ ] **Step 1: Add the public API and protocol gate**

In `src/server_registry.jl`, add a new minimum protocol constant and bump the current protocol:

```julia
const SERVER_PROTOCOL_VERSION = 5
const CHANGED_ONLY_PROTOCOL_VERSION = 2
const RERUN_FAILED_PROTOCOL_VERSION = 3
const FRESH_RUN_PROTOCOL_VERSION = 4
const RETRY_CRASHED_PROTOCOL_VERSION = 5
```

In `src/WarmTestRunner.jl`, add the gate helper next to the other protocol helpers:

```julia
function ensure_retry_crashed_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, RETRY_CRASHED_PROTOCOL_VERSION)
end
```

Then update `run` to accept the keyword and gate only the no-retry path:

```julia
function run(;
    tests = String[],
    quickfail::Bool = false,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    fresh::Bool = false,
    retry_crashed::Bool = true,
    kwargs...
)
    !isempty(tests) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))
    cfg = make_config(; kwargs...)
    changed_only && ensure_changed_only_controller!(cfg.pkgroot)
    rerun_failed && ensure_rerun_failed_controller!(cfg.pkgroot)
    fresh && ensure_fresh_controller!(cfg.pkgroot)
    !retry_crashed && ensure_retry_crashed_controller!(cfg.pkgroot)
    serve(; kwargs...)
    return client_request(
        cfg.pkgroot,
        (
            cmd = :run,
            tests = String.(tests),
            quickfail = quickfail,
            changed_only = changed_only,
            rerun_failed = rerun_failed,
            fresh = fresh,
            retry_crashed = retry_crashed,
        ),
    )
end
```

- [ ] **Step 2: Make scheduler retry conditional**

In `src/controller.jl`, update the signature:

```julia
function schedule_jobs!(
    workers::AbstractVector{<:WorkerHandle},
    jobs::AbstractVector{<:TestJob},
    cfg::RunnerConfig;
    quickfail::Bool = false,
    retry_crashed::Bool = true,
    recover_worker! = nothing,
    should_stop! = () -> false,
    on_job_start! = (_worker_index, _job_index, _job) -> nothing,
    on_job_finish! = (_worker_index, _job_index, _job) -> nothing,
)
```

Then replace the crash branch inside the worker loop with:

```julia
                    if result.status == :crashed
                        if recover_worker! === nothing || should_stop!()
                            results[idx] = final_result
                            mark_quickfail!(final_result)
                            break
                        end
                        if retry_crashed
                            worker = recover_worker!(worker_index)
                            final_result = run_test_in_worker!(worker, jobs[idx], cfg)
                            results[idx] = final_result
                            mark_quickfail!(final_result)
                            if final_result.status == :crashed
                                (quickfail || should_stop!()) && break
                                worker = recover_worker!(worker_index)
                            end
                        else
                            results[idx] = final_result
                            mark_quickfail!(final_result)
                            (quickfail || should_stop!()) && break
                            worker = recover_worker!(worker_index)
                        end
                    else
```

This preserves later-job recovery while skipping rerun of the crashed job itself.

- [ ] **Step 3: Thread the flag through daemon-backed runs**

In `src/controller.jl`, update `run_jobs_on_pool!` to accept and pass the keyword:

```julia
function run_jobs_on_pool!(state::ControllerState, jobs::AbstractVector{<:TestJob}; quickfail::Bool, retry_crashed::Bool)
    summary = try
        schedule_jobs!(
            state.workers,
            jobs,
            state.cfg;
            quickfail = quickfail,
            retry_crashed = retry_crashed,
            recover_worker! = worker_index -> recreate_worker!(state, worker_index),
            should_stop! = () -> controller_stop_requested(state),
            on_job_start! = (worker_index, job_index, job) -> adjust_running_jobs!(state, +1),
            on_job_finish! = (worker_index, job_index, job) -> adjust_running_jobs!(state, -1),
        )
```

Then update the `:run` branch in `handle_request!`:

```julia
        quickfail = request_payload(request, :quickfail, false)
        retry_crashed = request_payload(request, :retry_crashed, true)
        return run_jobs_on_pool!(state, jobs; quickfail = quickfail, retry_crashed = retry_crashed)
```

- [ ] **Step 4: Run the focused crash-recovery file to verify it passes**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/crash_recovery.jl")'
```

Expected:

- all crash recovery tests pass

- [ ] **Step 5: Commit the runtime change**

```bash
git add src/WarmTestRunner.jl src/controller.jl src/server_registry.jl test/crash_recovery.jl
git commit -m "feat: add retry_crashed support"
```

### Task 3: Update status docs and run full verification

**Files:**
- Modify: `STATUS.md`
- Test: `test/runtests.jl`

- [ ] **Step 1: Update `STATUS.md` to describe implemented support**

In `STATUS.md`, make these edits:

- update the public API signature bullet to `run(; tests = String[], quickfail = false, changed_only = false, rerun_failed = false, fresh = false, retry_crashed = true, kwargs...)`
- add a current-behavior bullet: ``run(...; retry_crashed = true)`` retries a crashed file once on a recreated worker before finalizing the result
- add a current-behavior bullet: ``run(...; retry_crashed = false)`` finalizes the first `:crashed` result for that file but still allows later jobs to use recovered workers when scheduling continues
- add `public \`retry_crashed\` crash-recovery control` under verified behavior
- remove `retry_crashed as a public option` from deferred work

- [ ] **Step 2: Run the documented verification commands**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/runtests.jl")'
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected:

- both commands pass

- [ ] **Step 3: Commit docs and verification-backed finish**

```bash
git add STATUS.md
git commit -m "docs: update retry_crashed status"
```
