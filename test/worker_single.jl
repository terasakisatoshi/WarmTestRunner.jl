using Test
using Malt
using WarmTestRunner

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")
const VIRTUAL_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
const PASS_JOB = WarmTestRunner.TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl")
const FAIL_JOB = WarmTestRunner.TestJob(path = joinpath(FIXTURE_ROOT, "test", "fail.jl"), name = "fail.jl")

@testset "single malt worker runs fixture tests" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
    worker = WarmTestRunner.start_worker(cfg; id = 1)

    try
        @test worker.state == :booting
        @test worker.booted_at == 0.0
        @test worker.runs_completed == 0

        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test worker.state == :idle
        @test worker.booted_at > 0
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :testenv

        result = WarmTestRunner.run_test_in_worker!(
            worker,
            PASS_JOB,
            cfg,
        )
        @test result.status == :passed
        @test result.worker_id == 1
        @test occursin("bootstrap hook loaded: true", result.stdout)
        @test worker.state == :idle
        @test worker.runs_completed == 1

        failed = WarmTestRunner.run_test_in_worker!(worker, FAIL_JOB, cfg)
        @test failed.status == :failed
        @test failed.worker_id == 1
        @test failed.exception_summary !== nothing
        @test worker.state == :idle
        @test worker.runs_completed == 2
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

@testset "single malt worker executes virtual plans through runtests" begin
    cfg = WarmTestRunner.make_config(pkgroot = VIRTUAL_FIXTURE_ROOT, jobs = 1, use_revise = false)
    worker = WarmTestRunner.start_worker(cfg; id = 9)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        plan = only(WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl"]))
        result = WarmTestRunner.run_test_in_worker!(
            worker,
            WarmTestRunner.TestJob(
                path = plan.entryfile,
                name = "test/runtests.jl",
                plan = plan,
            ),
            cfg,
        )
        @test result.status == :passed
        @test result.path == "test/runtests.jl"
        @test occursin("selected testset", result.stdout)
        @test occursin("other testset", result.stdout)
        @test !occursin("failure testset", result.stdout)
        @test worker.runs_completed == 1
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

@testset "single malt worker respects use_testenv=false" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1, use_testenv = false)
    worker = WarmTestRunner.start_worker(cfg; id = 2)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :pkg_activate
        result = WarmTestRunner.run_test_in_worker!(worker, PASS_JOB, cfg)
        @test result.status == :passed
        @test worker.runs_completed == 1
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

@testset "single malt worker activates test target extras for local packages" begin
    mktempdir() do tmp
        pkgroot = joinpath(tmp, "ExtraTargetFixture")
        mkpath(joinpath(pkgroot, "src"))
        mkpath(joinpath(pkgroot, "test"))

        write(
            joinpath(pkgroot, "Project.toml"),
            """
            name = "ExtraTargetFixture"
            uuid = "33333333-4444-5555-6666-777777777777"
            version = "0.1.0"

            [extras]
            Malt = "36869731-bdee-424d-aa32-cab38c994e3b"
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

            [targets]
            test = ["Malt", "Test"]
            """,
        )
        write(
            joinpath(pkgroot, "src", "ExtraTargetFixture.jl"),
            """
            module ExtraTargetFixture
            end
            """,
        )
        testfile = joinpath(pkgroot, "test", "extra_target.jl")
        write(
            testfile,
            """
            using Test

            @testset "extra target visibility" begin
                @test Base.find_package("Malt") !== nothing
            end
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = pkgroot, jobs = 1)
        worker = WarmTestRunner.start_worker(cfg; id = 8)

        try
            WarmTestRunner.bootstrap_worker!(worker, cfg)
            result = WarmTestRunner.run_test_in_worker!(
                worker,
                WarmTestRunner.TestJob(path = testfile, name = "extra_target.jl"),
                cfg,
            )
            @test result.status == :passed
            @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :testenv
        finally
            WarmTestRunner.stop_worker!(worker)
        end
    end
end

@testset "single malt worker respects threads_per_worker" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1, threads_per_worker = 2)
    worker = WarmTestRunner.start_worker(cfg; id = 4)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test Malt.remote_eval_fetch(worker.proc, :(Threads.nthreads())) == 2
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

@testset "single malt worker loads Revise by default" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
    worker = WarmTestRunner.start_worker(cfg; id = 5)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test worker.state == :idle
        @test Malt.remote_eval_fetch(worker.proc, :(isdefined(Main, :Revise))) === true
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_REVISE_LOADED)) === true
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :testenv
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

@testset "single malt worker skips Revise when explicitly disabled" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1, use_revise = false)
    worker = WarmTestRunner.start_worker(cfg; id = 6)

    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        @test worker.state == :idle
        @test Malt.remote_eval_fetch(worker.proc, :(isdefined(Main, :Revise))) === false
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_REVISE_LOADED)) === false
    finally
        WarmTestRunner.stop_worker!(worker)
        @test worker.state == :stopped
    end
end

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
            __precompile__(false)
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

        cfg = WarmTestRunner.make_config(pkgroot = pkgroot, jobs = 1, use_testenv = false)
        worker = WarmTestRunner.start_worker(cfg; id = 7)

        try
            WarmTestRunner.bootstrap_worker!(worker, cfg)
            @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_PRELOAD_SAW_REVISE)) === true
            @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_BOOTSTRAP_SAW_REVISE)) === true
        finally
            WarmTestRunner.stop_worker!(worker)
        end
    end
end

@testset "single malt worker reports crashed transport after stop" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
    worker = WarmTestRunner.start_worker(cfg; id = 3)

    WarmTestRunner.bootstrap_worker!(worker, cfg)
    WarmTestRunner.stop_worker!(worker)
    @test worker.state == :stopped

    crashed = WarmTestRunner.run_test_in_worker!(worker, PASS_JOB, cfg)
    @test crashed.status == :crashed
    @test crashed.worker_id == 3
    @test crashed.exception_summary !== nothing
    @test worker.state == :crashed
end
