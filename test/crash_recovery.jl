using Test
using WarmTestRunner

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")

@testset "daemon recovers a crashed worker and retries later jobs" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                handle = WarmTestRunner.serve(jobs = 1)
                try
                    crashed = WarmTestRunner.run(tests = ["crash.jl"])
                    @test crashed.crashed == 1
                    @test getfield.(crashed.results, :status) == [:crashed]

                    recovered = WarmTestRunner.run(tests = ["pass.jl"])
                    @test recovered.passed == 1
                    @test getfield.(recovered.results, :status) == [:passed]
                finally
                    WarmTestRunner.stop()
                end
            end
        end
    end
end

@testset "daemon continues later jobs after a permanent crash when quickfail=false" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(tests = ["crash.jl", "pass.jl"], quickfail = false)
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

@testset "public retry_crashed=false finalizes the first crash and continues later jobs" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(tests = ["crash.jl", "pass.jl"], quickfail = false, retry_crashed = false)
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

@testset "recreate_worker! preserves the old worker on bootstrap failure" begin
    mktempdir() do tmp
        bad_root = joinpath(tmp, "BadFixture")
        mkpath(joinpath(bad_root, "test"))
        open(joinpath(bad_root, "Project.toml"), "w") do io
            write(io, """
            name = "BadFixture"
            uuid = "12345678-1234-1234-1234-123456789abc"
            version = "0.1.0"
            """)
        end
        open(joinpath(bad_root, "test", "warmtest_bootstrap.jl"), "w") do io
            write(io, "error(\"bootstrap failed\")\n")
        end

        good_cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
        workers = WarmTestRunner.start_worker_pool(good_cfg)
        bad_cfg = WarmTestRunner.make_config(pkgroot = bad_root, jobs = 1)
        state = WarmTestRunner.ControllerState(
            cfg = bad_cfg,
            handle = WarmTestRunner.ServerHandle(
                pkgroot = bad_root,
                server_id = "test-server",
                pid = getpid(),
                started_at = time(),
                jobs = 1,
            ),
            status = WarmTestRunner.ServerStatus(pkgroot = bad_root),
            workers = workers,
        )
        original_worker = workers[1]

        try
            @test_throws Exception WarmTestRunner.recreate_worker!(state, 1)
            @test state.workers[1] === original_worker
            @test original_worker.state == :stopped
        finally
            WarmTestRunner.stop_worker_pool!(workers)
        end
    end
end

@testset "refresh_worker_pool! preserves the old pool on bootstrap failure" begin
    mktempdir() do tmp
        bad_root = joinpath(tmp, "BadRefreshFixture")
        mkpath(joinpath(bad_root, "test"))
        open(joinpath(bad_root, "Project.toml"), "w") do io
            write(io, """
            name = "BadRefreshFixture"
            uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            version = "0.1.0"
            """)
        end
        open(joinpath(bad_root, "test", "warmtest_bootstrap.jl"), "w") do io
            write(io, "error(\"refresh bootstrap failed\")\n")
        end

        good_cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
        workers = WarmTestRunner.start_worker_pool(good_cfg)
        bad_cfg = WarmTestRunner.make_config(pkgroot = bad_root, jobs = 1)
        state = WarmTestRunner.ControllerState(
            cfg = bad_cfg,
            handle = WarmTestRunner.ServerHandle(
                pkgroot = bad_root,
                server_id = "test-server",
                pid = getpid(),
                started_at = time(),
                jobs = 1,
            ),
            status = WarmTestRunner.ServerStatus(pkgroot = bad_root),
            workers = workers,
        )

        @test isdefined(WarmTestRunner, :refresh_worker_pool!)
        try
            err = nothing
            try
                WarmTestRunner.refresh_worker_pool!(state)
                @test false
            catch caught
                err = caught
            end
            @test err !== nothing
            @test state.workers === workers
            @test all(worker.state == :idle for worker in workers)
        finally
            WarmTestRunner.stop_worker_pool!(workers)
        end
    end
end

@testset "inline scheduler quickfail preserves skipped ordering" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
    jobs = [
        TestJob(path = joinpath(FIXTURE_ROOT, "test", "fail.jl"), name = "fail.jl"),
        TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl"),
    ]

    summary = WarmTestRunner.run_jobs_inline(cfg, jobs; quickfail = true)

    @test getfield.(summary.results, :status) == [:failed, :skipped]
    @test summary.failed == 1
    @test summary.skipped == 1
end

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

@testset "quickfail waits for recovered crash result" begin
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
            quickfail = true,
            recover_worker! = index -> WarmTestRunner.recreate_worker!(state, index),
        )

        @test getfield.(summary.results, :status) == [:passed, :passed]
        @test summary.passed == 2
        @test summary.skipped == 0
    finally
        WarmTestRunner.stop_worker_pool!(workers)
    end
end

@testset "public quickfail keeps skipped ordering after a retried crash" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(tests = ["crash.jl", "pass.jl"], quickfail = true)
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

@testset "public quickfail stops immediately when retry_crashed=false finalizes a crash" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    summary = WarmTestRunner.run(tests = ["crash.jl", "pass.jl"], quickfail = true, retry_crashed = false)
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
