using Test
using WarmTestRunner

@testset "public api smoke" begin
    @test isdefined(WarmTestRunner, :serve)
    @test isdefined(WarmTestRunner, :run)
    @test isdefined(WarmTestRunner, :stop)
    @test isdefined(WarmTestRunner, :status)

    cfg = WarmTestRunner.RunnerConfig(pkgroot = pwd(), jobs = 2)
    @test cfg.jobs == 2
    @test cfg.threads_per_worker == 1
    @test cfg.tool_project == abspath(joinpath(@__DIR__, ".."))

    @test WarmTestRunner.make_config(; jobs = 3, threads_per_worker = 2).jobs == 3
    @test_throws ArgumentError WarmTestRunner.make_config(; jobs = 0)
    @test_throws ArgumentError WarmTestRunner.make_config(; threads_per_worker = 0)
    @test_throws ArgumentError WarmTestRunner.make_config(; use_revise = true)
    @test_throws ArgumentError WarmTestRunner.make_config(; color = false)
    @test_throws ArgumentError WarmTestRunner.make_config(; worker_timeout = 1.0)
    @test_throws ArgumentError WarmTestRunner.make_config(; log_level = :debug)

    summary = WarmTestRunner.RunSummary(
        results = WarmTestRunner.TestResult[],
        passed = 0,
        failed = 0,
        errored = 0,
        crashed = 0,
        skipped = 0,
        elapsed_total = 0.0,
    )
    @test summary.passed == 0

    mktempdir() do tmp
        status = WarmTestRunner.status(pkgroot = tmp)
        @test status.state == :stopped
        @test status.server_id === nothing
        @test status.pkgroot == abspath(tmp)
    end
end
