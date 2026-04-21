using Test
using WarmTestRunner
using Sockets
using Serialization

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")
const PASS_JOB = TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl")
const FAIL_JOB = TestJob(path = joinpath(FIXTURE_ROOT, "test", "fail.jl"), name = "fail.jl")

function write_temp_test(dir::AbstractString, name::AbstractString, body::AbstractString)
    path = joinpath(dir, name)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, body)
    end
    return path
end

function wait_for_server_record(pkgroot::AbstractString; timeout_s::Real = 10.0)
    deadline = time() + timeout_s
    while time() < deadline
        record = WarmTestRunner.load_server_record(pkgroot)
        record !== nothing && return record
        sleep(0.05)
    end
    error("timed out waiting for server record")
end

function send_request(port::Integer, request)
    socket = connect(ip"127.0.0.1", port)
    try
        serialize(socket, request)
        return deserialize(socket)
    finally
        close(socket)
    end
end

@testset "inline scheduler runs pass and fail files" begin
    cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 2)
    jobs = [PASS_JOB, FAIL_JOB]

    summary = WarmTestRunner.run_jobs_inline(cfg, jobs)

    @test length(summary.results) == 2
    @test summary.passed == 1
    @test summary.failed == 1
end

@testset "inline scheduler quickfail skips undispatched jobs" begin
    mktempdir() do tmp
        slow_pass_path = write_temp_test(
            tmp,
            "slow_pass.jl",
            """
            using Test
            sleep(2.0)
            @test true
            """,
        )
        skipped_path = write_temp_test(
            tmp,
            "skipped.jl",
            """
            using Test
            @test true
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 2)
        jobs = [
            FAIL_JOB,
            TestJob(path = slow_pass_path, name = "slow_pass.jl"),
            TestJob(path = skipped_path, name = "skipped.jl"),
        ]

        summary = WarmTestRunner.run_jobs_inline(cfg, jobs; quickfail = true)
        statuses = getfield.(summary.results, :status)

        @test summary.failed == 1
        @test summary.crashed == 0
        @test :skipped in statuses
        @test count(==(:skipped), statuses) == 1
    end
end

@testset "inline scheduler preserves original result order" begin
    mktempdir() do tmp
        slow_path = write_temp_test(
            tmp,
            "slow.jl",
            """
            using Test
            sleep(0.5)
            @test true
            """,
        )
        fast_path = write_temp_test(
            tmp,
            "fast.jl",
            """
            using Test
            @test true
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 2)
        jobs = [
            TestJob(path = slow_path, name = "slow.jl"),
            TestJob(path = fast_path, name = "fast.jl"),
        ]

        summary = WarmTestRunner.run_jobs_inline(cfg, jobs)

        @test [result.path for result in summary.results] == [slow_path, fast_path]
        @test [result.status for result in summary.results] == [:passed, :passed]
    end
end

@testset "inline scheduler keeps healthy workers running after a crash" begin
    mktempdir() do tmp
        pass1_path = write_temp_test(
            tmp,
            "pass1.jl",
            """
            using Test
            @test true
            """,
        )
        pass2_path = write_temp_test(
            tmp,
            "pass2.jl",
            """
            using Test
            @test true
            """,
        )
        pass3_path = write_temp_test(
            tmp,
            "pass3.jl",
            """
            using Test
            @test true
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 2)
        workers = WarmTestRunner.start_worker_pool(cfg)
        try
            WarmTestRunner.stop_worker!(workers[1])
            jobs = [
                TestJob(path = pass1_path, name = "pass1.jl"),
                TestJob(path = pass2_path, name = "pass2.jl"),
                TestJob(path = pass3_path, name = "pass3.jl"),
            ]

            summary = WarmTestRunner.schedule_jobs!(workers, jobs, cfg)
            statuses = getfield.(summary.results, :status)

            @test summary.crashed == 1
            @test summary.passed == 2
            @test count(==(:crashed), statuses) == 1
            @test count(==(:passed), statuses) == 2
        finally
            WarmTestRunner.stop_worker_pool!(workers)
        end
    end
end

@testset "daemon internals survive request errors" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
            task = @async WarmTestRunner.serve_forever(cfg)
            record = wait_for_server_record(FIXTURE_ROOT)
            stopped = false

            try
                status = send_request(record.port, (cmd = :status,))
                @test status.state == :idle
                @test status.pid == record.handle.pid

                summary = send_request(record.port, (cmd = :run, tests = ["pass.jl"], quickfail = false))
                @test summary.passed == 1

                after_run = send_request(record.port, (cmd = :status,))
                @test after_run.state == :idle
                @test after_run.last_success_at !== nothing

                bad = send_request(record.port, (cmd = :bogus,))
                @test bad.status == :error

                still_alive = send_request(record.port, (cmd = :status,))
                @test still_alive.state == :idle

                @test send_request(record.port, (cmd = :stop,)) == :ok
                stopped = true
            finally
                if !stopped
                    try
                        send_request(record.port, (cmd = :stop,))
                    catch
                    end
                end
                wait(task)
            end
        end
    end
end

@testset "daemon registry roundtrip" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                handle = WarmTestRunner.serve(jobs = 1)
                reused = WarmTestRunner.serve(jobs = 1)
                first = WarmTestRunner.run(tests = ["pass.jl"])
                second = WarmTestRunner.status()

                @test reused.pid == handle.pid
                @test first.passed == 1
                @test second.state == :idle
                @test second.pid == handle.pid
                @test_throws ArgumentError WarmTestRunner.serve(jobs = 2)
                @test_throws ArgumentError WarmTestRunner.run(jobs = 2, tests = ["pass.jl"])
                @test_throws ErrorException WarmTestRunner.client_request(FIXTURE_ROOT, (cmd = :bogus,))

                WarmTestRunner.stop()
                WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                @test WarmTestRunner.load_server_record(FIXTURE_ROOT) === nothing
                @test WarmTestRunner.status().state == :stopped
            end
        end
    end
end

@testset "serve replaces stale registry records" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            fake_handle = WarmTestRunner.ServerHandle(
                pkgroot = FIXTURE_ROOT,
                server_id = "stale-server",
                pid = 999999,
                started_at = time(),
                jobs = 1,
            )
            fake_status = WarmTestRunner.ServerStatus(
                server_id = fake_handle.server_id,
                pid = fake_handle.pid,
                pkgroot = fake_handle.pkgroot,
                started_at = fake_handle.started_at,
                jobs = fake_handle.jobs,
                state = :idle,
            )
            WarmTestRunner.write_server_record!(fake_handle, fake_status; port = 1)

            cd(FIXTURE_ROOT) do
                handle = WarmTestRunner.serve(jobs = 1)
                try
                    @test handle.pid != fake_handle.pid
                    @test WarmTestRunner.status().state == :idle
                finally
                    WarmTestRunner.stop()
                end
            end
        end
    end
end

@testset "status reports running during an active run" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            slow_path = write_temp_test(
                tmp,
                "slow_status.jl",
                """
                using Test
                sleep(3.0)
                @test true
                """,
            )

            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    run_task = @async WarmTestRunner.run(tests = [slow_path])
                    sleep(0.3)

                    deadline = time() + 1.5
                    max_elapsed = 0.0
                    seen_running = false
                    while time() < deadline
                        elapsed = @elapsed current = WarmTestRunner.status()
                        max_elapsed = max(max_elapsed, elapsed)
                        if current.state == :running && current.running_jobs == 1
                            seen_running = true
                            break
                        end
                        sleep(0.05)
                    end

                    @test max_elapsed < 1.5
                    @test seen_running

                    summary = fetch(run_task)
                    @test summary.passed == 1
                finally
                    try
                        WarmTestRunner.stop()
                    catch
                    end
                end
            end
        end
    end
end

@testset "stop interrupts an active run promptly" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            slow_path = write_temp_test(
                tmp,
                "slow_stop.jl",
                """
                using Test
                sleep(3.0)
                @test true
                """,
            )

            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                run_task = @async WarmTestRunner.run(tests = [slow_path])
                deadline = time() + 1.5
                while time() < deadline
                    current = WarmTestRunner.status()
                    current.state == :running && current.running_jobs == 1 && break
                    sleep(0.05)
                end

                stop_elapsed = @elapsed stop_result = WarmTestRunner.stop()
                summary = fetch(run_task)

                @test stop_elapsed < 1.5
                @test stop_result == :ok
                @test summary.crashed == 1
                @test getfield.(summary.results, :status) == [:crashed]
                @test WarmTestRunner.status().state == :stopped
            end
        end
    end
end
