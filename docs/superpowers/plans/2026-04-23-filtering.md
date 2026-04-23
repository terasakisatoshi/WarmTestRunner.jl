# Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add path substring and warmtest tag filtering to `WarmTestRunner.run`.

**Architecture:** Candidate jobs are still selected first by explicit `tests`, `changed_only`, `rerun_failed`, or full discovery. A shared filtering helper then narrows `Vector{TestJob}` by path substring and tags. The public API forwards filter options through the controller request, guarded by a new protocol version so older daemons restart before filtered runs.

**Tech Stack:** Julia 1.10, standard `Test`, existing `Malt` controller daemon, TOML registry protocol versioning.

---

## File Structure

- Modify `src/discovery.jl`: add pure helpers for path/tag matching and `filter_test_jobs`.
- Modify `src/controller.jl`: extend `build_jobs` and `handle_request!` to apply filter options.
- Modify `src/WarmTestRunner.jl`: add public `run` keywords, validate/filter argument conversion, and add filtered-run protocol gate.
- Modify `src/server_registry.jl`: bump protocol constants and add `FILTERING_PROTOCOL_VERSION`.
- Modify `test/discovery.jl`: add unit tests for the pure filtering helper.
- Modify `test/controller_daemon.jl`: add public daemon-backed `run(filter=...)` and `run(include_tags=...)` coverage.
- Modify `test/api_smoke.jl`: add validation smoke tests.
- Modify `README.md` and `STATUS.md`: document the new API and update implemented/deferred lists.

---

### Task 1: Pure Filtering Helper

**Files:**
- Modify: `src/discovery.jl`
- Test: `test/discovery.jl`

- [ ] **Step 1: Write failing unit tests**

Add this testset after the existing tag parsing tests in `test/discovery.jl`:

```julia
@testset "filter_test_jobs narrows by path and tags" begin
    pkgroot = mktempdir()
    mkpath(joinpath(pkgroot, "test", "unit"))

    jobs = [
        TestJob(path = joinpath(pkgroot, "test", "alpha.jl"), name = "alpha.jl", tags = ["slow"]),
        TestJob(path = joinpath(pkgroot, "test", "unit", "beta.jl"), name = "beta.jl", tags = ["network", "slow"]),
        TestJob(path = joinpath(pkgroot, "test", "gamma.jl"), name = "gamma.jl", tags = String[]),
    ]

    by_basename = WarmTestRunner.filter_test_jobs(jobs, pkgroot; filter = "alpha")
    @test [job.name for job in by_basename] == ["alpha.jl"]

    by_relpath = WarmTestRunner.filter_test_jobs(jobs, pkgroot; filter = joinpath("unit", "beta"))
    @test [job.name for job in by_relpath] == ["beta.jl"]

    by_include = WarmTestRunner.filter_test_jobs(jobs, pkgroot; include_tags = ["slow"])
    @test [job.name for job in by_include] == ["alpha.jl", "beta.jl"]

    by_exclude = WarmTestRunner.filter_test_jobs(jobs, pkgroot; exclude_tags = ["network"])
    @test [job.name for job in by_exclude] == ["alpha.jl", "gamma.jl"]

    composed = WarmTestRunner.filter_test_jobs(
        jobs,
        pkgroot;
        include_tags = ["slow"],
        exclude_tags = ["network"],
    )
    @test [job.name for job in composed] == ["alpha.jl"]

    empty_filter = WarmTestRunner.filter_test_jobs(jobs, pkgroot; filter = "")
    @test [job.name for job in empty_filter] == ["alpha.jl", "beta.jl", "gamma.jl"]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/discovery.jl")'
```

Expected: FAIL with `UndefVarError: filter_test_jobs not defined`.

- [ ] **Step 3: Implement minimal helper**

In `src/discovery.jl`, after `discover_changed_tests`, add:

```julia
function job_path_matches_filter(job::TestJob, pkgroot::AbstractString, filter::AbstractString)
    isempty(filter) && return true
    relative = relpath(job.path, pkgroot)
    return occursin(filter, relative) || occursin(filter, basename(job.path))
end

function job_has_any_tag(job::TestJob, tags::AbstractVector{<:AbstractString})
    isempty(tags) && return false
    job_tags = Set(job.tags)
    return any(tag -> tag in job_tags, tags)
end

function filter_test_jobs(
    jobs::AbstractVector{<:TestJob},
    pkgroot::AbstractString;
    filter::Union{Nothing, AbstractString} = nothing,
    include_tags::AbstractVector{<:AbstractString} = String[],
    exclude_tags::AbstractVector{<:AbstractString} = String[],
)
    filtered = collect(jobs)

    if filter !== nothing
        filtered = [job for job in filtered if job_path_matches_filter(job, pkgroot, filter)]
    end

    if !isempty(include_tags)
        filtered = [job for job in filtered if job_has_any_tag(job, include_tags)]
    end

    if !isempty(exclude_tags)
        filtered = [job for job in filtered if !job_has_any_tag(job, exclude_tags)]
    end

    return filtered
end
```

In `src/WarmTestRunner.jl`, add `filter_test_jobs` to the discovery export line:

```julia
export bootstrap_worker!, capture_test_output, discover_tests, filter_test_jobs, parse_warmtest_tags
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/discovery.jl")'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/discovery.jl src/WarmTestRunner.jl test/discovery.jl
git commit -m "feat: add test job filtering helper"
```

---

### Task 2: Build Jobs Filtering

**Files:**
- Modify: `src/controller.jl`
- Test: `test/discovery.jl`

- [ ] **Step 1: Write failing `build_jobs` tests**

Add this testset to `test/discovery.jl` after the `filter_test_jobs` testset:

```julia
@testset "build_jobs applies filters after candidate selection" begin
    pkgroot = mktempdir()
    mkpath(joinpath(pkgroot, "test", "unit"))

    write(joinpath(pkgroot, "test", "alpha.jl"), "# warmtest: tags=slow\nusing Test\n@test true\n")
    write(joinpath(pkgroot, "test", "unit", "beta.jl"), "# warmtest: tags=network,slow\nusing Test\n@test true\n")
    write(joinpath(pkgroot, "test", "gamma.jl"), "using Test\n@test true\n")

    cfg = WarmTestRunner.RunnerConfig(pkgroot = pkgroot)

    path_filtered = WarmTestRunner.build_jobs(cfg; filter = "unit")
    @test [job.name for job in path_filtered] == ["beta.jl"]

    tag_filtered = WarmTestRunner.build_jobs(cfg; include_tags = ["slow"], exclude_tags = ["network"])
    @test [job.name for job in tag_filtered] == ["alpha.jl"]

    explicit_filtered = WarmTestRunner.build_jobs(
        cfg;
        tests = ["alpha.jl", joinpath("unit", "beta.jl")],
        filter = "beta",
    )
    @test [job.name for job in explicit_filtered] == ["beta.jl"]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/discovery.jl")'
```

Expected: FAIL with `MethodError` because `build_jobs` does not accept `filter`, `include_tags`, or `exclude_tags`.

- [ ] **Step 3: Extend `build_jobs`**

In `src/controller.jl`, update the `build_jobs` signature:

```julia
function build_jobs(
    cfg::RunnerConfig;
    tests::AbstractVector{<:AbstractString} = String[],
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    last_failed::AbstractVector{<:AbstractString} = String[],
    filter::Union{Nothing, AbstractString} = nothing,
    include_tags::AbstractVector{<:AbstractString} = String[],
    exclude_tags::AbstractVector{<:AbstractString} = String[],
)
```

Replace the final candidate-returning block in `build_jobs` with:

```julia
    jobs = if rerun_failed
        if isempty(last_failed)
            TestJob[]
        elseif isempty(tests)
            [TestJob(path = path, name = basename(path), tags = parse_warmtest_tags(path)) for path in last_failed]
        else
            failed_paths = Set(abspath.(last_failed))
            [job for job in explicit_jobs if abspath(job.path) in failed_paths]
        end
    elseif changed_only
        discover_changed_tests(cfg.pkgroot)
    elseif isempty(tests)
        discover_tests(cfg.pkgroot)
    else
        explicit_jobs
    end

    return filter_test_jobs(
        jobs,
        cfg.pkgroot;
        filter = filter,
        include_tags = include_tags,
        exclude_tags = exclude_tags,
    )
```

Also update `explicit_jobs` so tags are available for explicit test paths:

```julia
    explicit_jobs = [
        begin
            path = isabspath(name) ? name : joinpath(cfg.pkgroot, "test", name)
            TestJob(path = path, name = basename(name), tags = parse_warmtest_tags(path))
        end
        for name in tests
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/discovery.jl")'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/controller.jl test/discovery.jl
git commit -m "feat: filter built test jobs"
```

---

### Task 3: Public API And Controller Request

**Files:**
- Modify: `src/WarmTestRunner.jl`
- Modify: `src/controller.jl`
- Modify: `src/server_registry.jl`
- Test: `test/api_smoke.jl`
- Test: `test/controller_daemon.jl`

- [ ] **Step 1: Write failing API and daemon tests**

In `test/api_smoke.jl`, add these checks near the existing invalid public API checks:

```julia
    @test_throws ArgumentError WarmTestRunner.run(
        pkgroot = joinpath(@__DIR__, "packages", "FixturePkg"),
        filter = 123,
    )
```

In `test/controller_daemon.jl`, add this testset before the JSON output testset:

```julia
@testset "public run filters by path substring and tags" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            pkgroot = mktempdir()
            mkpath(joinpath(pkgroot, "src"))
            mkpath(joinpath(pkgroot, "test", "unit"))

            write(
                joinpath(pkgroot, "Project.toml"),
                """
                name = "FilteringFixture"
                uuid = "22222222-3333-4444-5555-666666666666"
                version = "0.1.0"
                """,
            )
            write(joinpath(pkgroot, "src", "FilteringFixture.jl"), "module FilteringFixture\nend\n")
            write(joinpath(pkgroot, "test", "alpha.jl"), "# warmtest: tags=slow\nusing Test\nprintln(\"alpha\")\n@test true\n")
            write(joinpath(pkgroot, "test", "unit", "beta.jl"), "# warmtest: tags=network,slow\nusing Test\nprintln(\"beta\")\n@test true\n")
            write(joinpath(pkgroot, "test", "gamma.jl"), "using Test\nprintln(\"gamma\")\n@test true\n")

            path_summary = try
                WarmTestRunner.run(
                    pkgroot = pkgroot,
                    jobs = 1,
                    use_testenv = false,
                    preload_package = false,
                    filter = "unit",
                )
            catch err
                err
            end

            @test path_summary isa WarmTestRunner.RunSummary
            if path_summary isa WarmTestRunner.RunSummary
                @test [basename(result.path) for result in path_summary.results] == ["beta.jl"]
                @test path_summary.passed == 1
            end

            tag_summary = try
                WarmTestRunner.run(
                    pkgroot = pkgroot,
                    jobs = 1,
                    use_testenv = false,
                    preload_package = false,
                    include_tags = ["slow"],
                    exclude_tags = ["network"],
                )
            catch err
                err
            end

            @test tag_summary isa WarmTestRunner.RunSummary
            if tag_summary isa WarmTestRunner.RunSummary
                @test [basename(result.path) for result in tag_summary.results] == ["alpha.jl"]
                @test tag_summary.passed == 1
            end

            try
                WarmTestRunner.stop(pkgroot = pkgroot)
                WarmTestRunner.wait_for_record_gone(pkgroot)
            catch
            end
        end
    end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl"); include("test/controller_daemon.jl")'
```

Expected: FAIL because `filter`, `include_tags`, and `exclude_tags` are not accepted by `run`.

- [ ] **Step 3: Add protocol constant**

In `src/server_registry.jl`, change the constants to:

```julia
const SERVER_PROTOCOL_VERSION = 6
const CHANGED_ONLY_PROTOCOL_VERSION = 2
const RERUN_FAILED_PROTOCOL_VERSION = 3
const FRESH_RUN_PROTOCOL_VERSION = 4
const RETRY_CRASHED_PROTOCOL_VERSION = 5
const FILTERING_PROTOCOL_VERSION = 6
```

- [ ] **Step 4: Update public `run`**

In `src/WarmTestRunner.jl`, add:

```julia
function ensure_filtering_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, FILTERING_PROTOCOL_VERSION)
end

function validate_filter(filter)
    filter === nothing && return nothing
    filter isa AbstractString && return filter
    throw(ArgumentError("filter must be nothing or an AbstractString"))
end

validate_tags(tags, name::Symbol) = String.(tags)
```

Update the `run` signature to:

```julia
function run(;
    tests = String[],
    quickfail::Bool = false,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    fresh::Bool = false,
    retry_crashed::Bool = true,
    output_format::Symbol = :text,
    filter = nothing,
    include_tags = String[],
    exclude_tags = String[],
    kwargs...,
)
```

Inside `run`, after `validate_output_format(output_format)`, add:

```julia
    filter = validate_filter(filter)
    include_tags = validate_tags(include_tags, :include_tags)
    exclude_tags = validate_tags(exclude_tags, :exclude_tags)
```

Before `serve(; kwargs...)`, add:

```julia
    (filter !== nothing || !isempty(include_tags) || !isempty(exclude_tags)) && ensure_filtering_controller!(cfg.pkgroot)
```

Add the fields to the request named tuple:

```julia
            filter = filter,
            include_tags = include_tags,
            exclude_tags = exclude_tags,
```

- [ ] **Step 5: Update controller request handling**

In `src/controller.jl`, add these keywords to the `build_jobs` call in `handle_request!`:

```julia
                filter = request_payload(request, :filter, nothing),
                include_tags = request_payload(request, :include_tags, String[]),
                exclude_tags = request_payload(request, :exclude_tags, String[]),
```

- [ ] **Step 6: Run tests to verify they pass**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/api_smoke.jl"); include("test/controller_daemon.jl")'
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/WarmTestRunner.jl src/controller.jl src/server_registry.jl test/api_smoke.jl test/controller_daemon.jl
git commit -m "feat: add public run filtering"
```

---

### Task 4: Documentation And Full Verification

**Files:**
- Modify: `README.md`
- Modify: `STATUS.md`

- [ ] **Step 1: Update README**

In `README.md`, after the "一部のテストだけ実行する" section, add:

````markdown
## ファイル名やタグで絞り込む

`filter` を指定すると、`test/` からの相対パスまたはファイル名にその文字列を含むテストだけを実行します。

```julia
WarmTestRunner.run(filter = "worker")
WarmTestRunner.run(filter = "unit/foo")
```

テストファイル先頭の `# warmtest: tags=...` を使うと、タグで実行対象を絞り込めます。

```julia
# warmtest: tags=slow,network
```

```julia
WarmTestRunner.run(include_tags = ["slow"])
WarmTestRunner.run(exclude_tags = ["network"])
WarmTestRunner.run(include_tags = ["slow"], exclude_tags = ["network"])
```

`include_tags` は指定タグのいずれかを持つファイルを残し、`exclude_tags` は指定タグのいずれかを持つファイルを除外します。
````

- [ ] **Step 2: Update STATUS**

In `STATUS.md`:

- Add `filter`, `include_tags`, and `exclude_tags` to the public API signature.
- Add bullets under "Current behavior" and "Core Runtime" describing path substring and tag filtering.
- Remove "richer filtering modes beyond explicit `tests`" from the deferred list or narrow it to "regular-expression filtering and CLI selector syntax".
- Update "Latest verification command" after full verification.

- [ ] **Step 3: Run full direct test suite**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/runtests.jl")'
```

Expected: PASS.

- [ ] **Step 4: Run final clean-room verification**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add README.md STATUS.md
git commit -m "docs: document run filtering"
```

---

## Self-Review Notes

- Spec coverage: path substring filtering, include tags, exclude tags, include-then-exclude composition, explicit-test filtering, daemon request handling, and protocol restart behavior are all covered.
- Scope kept out: regular expressions, CLI selector syntax, and exact impact analysis remain outside this implementation.
- TDD order: every production change has a preceding failing test step.
