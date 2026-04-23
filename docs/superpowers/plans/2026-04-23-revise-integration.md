# Revise Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `use_revise = true` so warm workers load `Revise.jl` during bootstrap and fail startup when `Revise` cannot be loaded.

**Architecture:** Keep Revise as a worker bootstrap option controlled by the existing `RunnerConfig.use_revise` field. The bootstrap order is activation, optional `using Revise`, optional package preload, optional `test/warmtest_bootstrap.jl`, matching `SPEC.md` section 6.5 while preserving the existing controller and worker lifecycle.

**Tech Stack:** Julia 1.10, Revise.jl, Malt workers, TestEnv/Pkg activation, existing `Test` suite, daemon registry protocol.

---

## File Map

- Modify: `Project.toml`
  - add `Revise` to `[deps]`
  - add a conservative `Revise` entry to `[compat]`
- Modify: `src/config.jl`
  - stop rejecting `use_revise = true`
  - keep the existing validation for unsupported options
- Modify: `src/worker.jl`
  - add a small Revise bootstrap expression
  - insert it after environment activation and before package preload
  - let `using Revise` errors propagate so bootstrap fails
- Modify: `test/api_smoke.jl`
  - replace the rejection assertion with an acceptance assertion
- Modify: `test/worker_single.jl`
  - add single-worker bootstrap coverage showing `Revise` was loaded
- Modify: `test/controller_daemon.jl`
  - add daemon reuse/restart coverage for `use_revise`
- Modify: `README.md`
  - list `use_revise` as an available configuration option
  - document caveats and `fresh=true` as the escape hatch
- Modify: `STATUS.md`
  - move Revise integration out of deferred work
  - document the implemented scope and caveats

## Caveats To Preserve In User-Facing Docs

- Each worker has its own independent `Revise` state.
- Revise improves the edit-run cycle but does not guarantee perfect tracking for every code change.
- Macro expansion, generated functions, method invalidation surprises, and constant redefinition may still require `run(fresh = true)` or a restarted daemon.
- Bootstrap should fail loudly when `Revise` cannot load; it should not silently continue without Revise when `use_revise = true`.

### Task 1: Add Revise Dependency Metadata

**Files:**
- Modify: `Project.toml`
- Modify: `Manifest.toml`

- [ ] **Step 1: Add Revise through Julia package tooling**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.add("Revise")'
```

Expected: `Project.toml` gains a `Revise` entry under `[deps]`, and `Manifest.toml` is updated consistently.

- [ ] **Step 2: Add explicit compat**

In `Project.toml`, add this line under `[compat]`:

```toml
Revise = "3"
```

Expected: the `[compat]` section includes `Malt`, `Revise`, `TestEnv`, and `julia`.

- [ ] **Step 3: Verify dependency resolution**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.instantiate(); Pkg.status(["Revise"])'
```

Expected: PASS-like command success, with `Revise` shown as a direct dependency.

### Task 2: Accept `use_revise = true` In Configuration

**Files:**
- Modify: `test/api_smoke.jl`
- Modify: `src/config.jl`

- [ ] **Step 1: Write the failing config acceptance test**

In `test/api_smoke.jl`, replace:

```julia
@test_throws ArgumentError WarmTestRunner.make_config(; use_revise = true)
```

with:

```julia
@test WarmTestRunner.make_config(; use_revise = true).use_revise === true
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl")'
```

Expected: FAIL with `ArgumentError("use_revise is not implemented yet")`.

- [ ] **Step 3: Implement the minimal config change**

In `src/config.jl`, remove only this validation line:

```julia
cfg.use_revise && throw(ArgumentError("use_revise is not implemented yet"))
```

Keep these existing unsupported-option guards unchanged:

```julia
cfg.color || throw(ArgumentError("color=false is not implemented yet"))
cfg.worker_timeout == 60.0 || throw(ArgumentError("worker_timeout is not implemented yet"))
cfg.log_level == :info || throw(ArgumentError("log_level=$(cfg.log_level) is not implemented yet"))
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl")'
```

Expected: PASS.

### Task 3: Load Revise During Worker Bootstrap

**Files:**
- Modify: `test/worker_single.jl`
- Modify: `src/worker.jl`

- [ ] **Step 1: Write the failing worker bootstrap test**

Append this testset to `test/worker_single.jl`:

```julia
@testset "single malt worker loads Revise when requested" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1, use_revise = true)
    worker = WarmTestRunner.start_worker(cfg; id = 5)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test worker.state == :idle
        @test Malt.remote_eval_fetch(worker.proc, :(isdefined(Main, :Revise))) === true
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_REVISE_LOADED)) === true
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :pkg_activate_fallback
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: FAIL because `Main.Revise` and `Main.WARMTEST_REVISE_LOADED` are not defined in the worker.

- [ ] **Step 3: Add a Revise bootstrap expression**

In `src/worker.jl`, add this helper after `activation_expr`:

```julia
function revise_expr(cfg::RunnerConfig)
    cfg.use_revise || return quote
        Core.eval(Main, :(WARMTEST_REVISE_LOADED = false))
    end

    return quote
        using Revise
        Core.eval(Main, :(WARMTEST_REVISE_LOADED = true))
    end
end
```

- [ ] **Step 4: Insert Revise after activation and before preload**

In `bootstrap_worker!`, update the remote bootstrap expression to this order:

```julia
expr = quote
    cd($(cfg.pkgroot))
    $(activation_expr(cfg))
    $(revise_expr(cfg))
    if $(cfg.preload_package) && $(using_expr !== nothing)
        Base.eval(Main, $using_expr)
    end
    if $(bootstrap !== nothing)
        Base.include(Main, $bootstrap)
    end
    nothing
end
```

Expected: if `using Revise` fails, `Malt.remote_eval_fetch` throws, `worker.state` becomes `:crashed`, and bootstrap failure propagates through existing error paths.

- [ ] **Step 5: Run the focused test to verify it passes**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: PASS.

### Task 4: Cover Bootstrap Ordering Against Package Preload

**Files:**
- Modify: `test/worker_single.jl`

- [ ] **Step 1: Write the ordering regression test**

Append this testset to `test/worker_single.jl`:

```julia
@testset "Revise loads before package preload and bootstrap hook" begin
    mktempdir() do tmp
        pkgroot = joinpath(tmp, "ReviseOrderFixture")
        mkpath(joinpath(pkgroot, "src"))
        mkpath(joinpath(pkgroot, "test"))

        write(
            joinpath(pkgroot, "Project.toml"),
            """
            name = "ReviseOrderFixture"
            uuid = "22222222-3333-4444-5555-666666666666"
            version = "0.1.0"
            """,
        )
        write(
            joinpath(pkgroot, "src", "ReviseOrderFixture.jl"),
            """
            module ReviseOrderFixture
            const REVISE_WAS_LOADED_DURING_PRELOAD = isdefined(Main, :Revise)
            end
            """,
        )
        write(
            joinpath(pkgroot, "test", "warmtest_bootstrap.jl"),
            """
            Core.eval(Main, :(WARMTEST_BOOTSTRAP_SAW_REVISE = isdefined(Main, :Revise)))
            Core.eval(Main, :(WARMTEST_PRELOAD_SAW_REVISE = ReviseOrderFixture.REVISE_WAS_LOADED_DURING_PRELOAD))
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = pkgroot, jobs = 1, use_revise = true, use_testenv = false)
        worker = WarmTestRunner.start_worker(cfg; id = 6)

        try
            WarmTestRunner.bootstrap_worker!(worker, cfg)
            @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_PRELOAD_SAW_REVISE)) === true
            @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_BOOTSTRAP_SAW_REVISE)) === true
        finally
            WarmTestRunner.stop_worker!(worker)
        end
    end
end
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: PASS after Task 3. If it fails, adjust only the bootstrap expression ordering in `src/worker.jl` so the order is activation, Revise, preload, hook.

### Task 5: Add Daemon Reuse And Restart Coverage For `use_revise`

**Files:**
- Modify: `test/controller_daemon.jl`
- Modify: `src/controller.jl`
- Modify: `src/server_registry.jl` only if the implementation needs persisted config identity

- [ ] **Step 1: Write daemon reuse coverage for matching `use_revise`**

Add this testset near the existing daemon reuse tests in `test/controller_daemon.jl`:

```julia
@testset "daemon with use_revise=true can be reused by matching calls" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                handle = WarmTestRunner.serve(jobs = 1, use_revise = true)
                stop_err = nothing
                try
                    reused = WarmTestRunner.serve(jobs = 1)
                    summary = WarmTestRunner.run(tests = ["pass.jl"])
                    current = WarmTestRunner.status()

                    @test reused.server_id == handle.server_id
                    @test summary.passed == 1
                    @test current.server_id == handle.server_id
                    @test current.state == :idle
                finally
                    try
                        WarmTestRunner.stop()
                    catch err
                        stop_err = err
                    end
                    WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                    stop_err === nothing || rethrow(stop_err)
                end
            end
        end
    end
end
```

Expected intent: once a daemon exists, default `serve(jobs = 1)` reuses it because no explicit conflicting daemon configuration was requested.

- [ ] **Step 2: Write daemon restart coverage for explicit conflicting `use_revise=false`**

Add this testset near the same daemon reuse area:

```julia
@testset "explicit use_revise mismatch is rejected for live daemon reuse" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1, use_revise = true)
                stop_err = nothing
                try
                    @test_throws ArgumentError WarmTestRunner.serve(jobs = 1, use_revise = false)
                finally
                    try
                        WarmTestRunner.stop()
                    catch err
                        stop_err = err
                    end
                    WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                    stop_err === nothing || rethrow(stop_err)
                end
            end
        end
    end
end
```

Expected intent: explicit mismatches should not silently reuse a daemon whose worker bootstrap policy differs. If existing reuse validation cannot distinguish omitted defaults from explicit keywords, implement this conservatively by rejecting any non-`:pkgroot`/`:jobs` keyword for an existing daemon, which matches the current `validate_reuse_configuration` pattern.

- [ ] **Step 3: Run the daemon test subset**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'
```

Expected before implementation: the first test may pass once Tasks 2 and 3 are complete; the second test should pass if the existing `validate_reuse_configuration` keeps rejecting extra config kwargs on reuse. If either test fails, update `validate_reuse_configuration` without changing the registry schema unless a concrete failing assertion requires persisted config identity.

- [ ] **Step 4: Keep protocol constants stable unless the request protocol changes**

Do not bump `SERVER_PROTOCOL_VERSION` for the basic Revise bootstrap path because no client request payload is changing. If the reuse implementation stores extra config metadata in registry records, bump `SERVER_PROTOCOL_VERSION` by one and add a migration-safe default in `load_server_record`.

### Task 6: Update README Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Move `use_revise` into the supported configuration example**

In the configuration example, add:

```julia
use_revise = false,
```

In the bullet list of supported options, add:

```markdown
- `use_revise`: worker 起動時に `Revise` を読み込む
```

- [ ] **Step 2: Remove `use_revise = true` from the rejected settings list**

Change the rejected settings list so it contains only:

```markdown
- `color = false`
- `worker_timeout != 60.0`
- `log_level != :info`
```

- [ ] **Step 3: Add a Revise caveats section**

Add this short section near the bootstrap/configuration documentation:

```markdown
## Revise 連携

`serve(use_revise = true)` は各 worker の bootstrap で `Revise` を読み込みます。
読み込み順は環境 activation、`Revise`、対象パッケージ preload、`test/warmtest_bootstrap.jl` です。

`Revise` の状態は worker ごとに独立しています。macro 展開、generated function、constant の再定義などは追跡しきれない場合があるため、warm state が疑わしい場合は `run(fresh = true)` で worker pool を作り直してください。
```

- [ ] **Step 4: Verify the README mentions the final behavior**

Run:

```bash
rg -n "use_revise|Revise|fresh = true" README.md
```

Expected: output shows `use_revise = false` in the supported example, no rejected `use_revise = true` bullet, and a caveat mentioning `fresh = true`.

### Task 7: Update STATUS Documentation

**Files:**
- Modify: `STATUS.md`

- [ ] **Step 1: Move Revise out of deferred status**

Replace the accepted/restricted section entry:

```markdown
- `use_revise = true` is rejected
```

with:

```markdown
- `use_revise = true`
```

- [ ] **Step 2: Add implemented scope**

In the implemented behavior section, add:

```markdown
- Optional `Revise.jl` loading during worker bootstrap when `use_revise = true`
```

- [ ] **Step 3: Keep caveats explicit**

Ensure the Revise deferred-work entry is removed or rewritten as:

```markdown
- broader Revise correctness guarantees beyond loading Revise during bootstrap
```

Add or keep this caveat text:

```markdown
Revise state is per worker, and macro expansion, generated functions, and constant redefinition may still need `run(fresh = true)`.
```

- [ ] **Step 4: Verify STATUS no longer says Revise is rejected**

Run:

```bash
rg -n "use_revise|Revise|rejected" STATUS.md
```

Expected: output does not include `use_revise = true is rejected`; output does include the implemented Revise bootstrap scope and caveats.

### Task 8: Run Full Verification

**Files:**
- No file changes.

- [ ] **Step 1: Run focused tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl")'
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'
```

Expected: all focused tests pass.

- [ ] **Step 2: Run the documented repository test command**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/runtests.jl")'
```

Expected: PASS.

- [ ] **Step 3: Run final clean-room package verification**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected: PASS.

- [ ] **Step 4: Inspect the final diff**

Run:

```bash
git diff -- Project.toml Manifest.toml src/config.jl src/worker.jl test/api_smoke.jl test/worker_single.jl test/controller_daemon.jl README.md STATUS.md
```

Expected: the diff is limited to Revise dependency metadata, `use_revise` config acceptance, worker bootstrap loading, tests, and documentation. There should be no unrelated formatting churn or production changes outside the files listed in this plan.
