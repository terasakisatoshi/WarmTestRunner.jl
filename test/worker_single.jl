using Test
using Malt
using WarmTestRunner

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")
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
        @test Malt.remote_eval_fetch(worker.proc, :(Main.WARMTEST_ACTIVATION_STRATEGY)) == :pkg_activate_fallback

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
