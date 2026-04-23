using Test
using WarmTestRunner
using Sockets
using Serialization
using TOML

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")
const PASS_JOB = WarmTestRunner.TestJob(path = joinpath(FIXTURE_ROOT, "test", "pass.jl"), name = "pass.jl")
const FAIL_JOB = WarmTestRunner.TestJob(path = joinpath(FIXTURE_ROOT, "test", "fail.jl"), name = "fail.jl")

function write_temp_test(dir::AbstractString, name::AbstractString, body::AbstractString)
    path = joinpath(dir, name)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, body)
    end
    return path
end

function status_identity(status)
    return (status.server_id, status.pid, status.jobs)
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

function init_changed_only_public_fixture()
    pkgroot = mktempdir()
    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "ChangedOnlyPublicFixture"
        uuid = "66666666-7777-8888-9999-aaaaaaaaaaaa"
        version = "0.1.0"
        """,
    )
    write(joinpath(pkgroot, "src", "ChangedOnlyPublicFixture.jl"), "module ChangedOnlyPublicFixture\nend\n")
    write(joinpath(pkgroot, "test", "alpha.jl"), "using Test\nprintln(\"alpha\")\n@test true\n")
    write(joinpath(pkgroot, "test", "beta.jl"), "using Test\nprintln(\"beta\")\n@test true\n")

    Base.run(`git -C $pkgroot init`)
    Base.run(`git -C $pkgroot config user.email warmtestrunner@example.com`)
    Base.run(`git -C $pkgroot config user.name WarmTestRunner`)
    Base.run(`git -C $pkgroot add .`)
    Base.run(`git -C $pkgroot commit -m initial`)
    return pkgroot
end

function init_bootstrap_counter_fixture(tmp::AbstractString)
    pkgroot = joinpath(tmp, "BootstrapCounterFixture")
    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))

    counter_path = joinpath(pkgroot, "bootstrap-counter.txt")
    counter_literal = repr(counter_path)

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "BootstrapCounterFixture"
        uuid = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        version = "0.1.0"
        """,
    )
    write(joinpath(pkgroot, "src", "BootstrapCounterFixture.jl"), "module BootstrapCounterFixture\nend\n")
    write(
        joinpath(pkgroot, "test", "warmtest_bootstrap.jl"),
        """
        counter_path = $counter_literal
        count = isfile(counter_path) ? parse(Int, strip(read(counter_path, String))) : 0
        open(counter_path, "w") do io
            write(io, string(count + 1))
        end
        """,
    )
    write(
        joinpath(pkgroot, "test", "bootstrap_counter.jl"),
        """
        using Test
        counter_path = $counter_literal
        counter = parse(Int, strip(read(counter_path, String)))
        @test counter >= 1
        """,
    )
    return pkgroot, counter_path
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
            WarmTestRunner.TestJob(path = slow_pass_path, name = "slow_pass.jl"),
            WarmTestRunner.TestJob(path = skipped_path, name = "skipped.jl"),
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
            WarmTestRunner.TestJob(path = slow_path, name = "slow.jl"),
            WarmTestRunner.TestJob(path = fast_path, name = "fast.jl"),
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
                WarmTestRunner.TestJob(path = pass1_path, name = "pass1.jl"),
                WarmTestRunner.TestJob(path = pass2_path, name = "pass2.jl"),
                WarmTestRunner.TestJob(path = pass3_path, name = "pass3.jl"),
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

@testset "malformed registry records are treated as absent" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                record_path = WarmTestRunner.server_record_path(FIXTURE_ROOT)
                mkpath(dirname(record_path))
                open(record_path, "w") do io
                    TOML.print(io, Dict(
                        "protocol_version" => 4,
                        "server_id" => "partial-record",
                        "pid" => getpid(),
                        "pkgroot" => FIXTURE_ROOT,
                    ))
                end

                @test WarmTestRunner.status(pkgroot = FIXTURE_ROOT).state == :stopped

                handle = WarmTestRunner.serve(jobs = 1)
                try
                    current = WarmTestRunner.status()
                    @test current.state == :idle
                    @test current.pid == handle.pid
                    @test current.server_id == handle.server_id
                finally
                    WarmTestRunner.stop()
                    WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                end
            end
        end
    end
end

@testset "public run fresh=true refreshes workers without replacing the daemon" begin
    mktempdir() do tmp
        pkgroot, counter_path = init_bootstrap_counter_fixture(tmp)
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(pkgroot) do
                WarmTestRunner.serve(jobs = 1)
                stop_err = nothing
                try
                    before = WarmTestRunner.status()
                    first = WarmTestRunner.run(tests = ["bootstrap_counter.jl"])
                    counter_before = parse(Int, strip(read(counter_path, String)))
                    refreshed = WarmTestRunner.run(tests = ["bootstrap_counter.jl"], fresh = true)
                    counter_after = parse(Int, strip(read(counter_path, String)))
                    after = WarmTestRunner.status()
                    followup = WarmTestRunner.run(tests = ["bootstrap_counter.jl"])

                    @test first.passed == 1
                    @test refreshed.passed == 1
                    @test followup.passed == 1
                    @test counter_after > counter_before
                    @test counter_after == counter_before + 1
                    @test status_identity(after) == status_identity(before)
                    @test after.state == :idle
                finally
                    try
                        WarmTestRunner.stop()
                    catch err
                        stop_err = err
                    end
                    WarmTestRunner.wait_for_record_gone(pkgroot)
                    stop_err === nothing || rethrow(stop_err)
                end
            end
        end
    end
end

@testset "fresh restarts when live registry record is from an older protocol" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                initial_handle = WarmTestRunner.serve(jobs = 1)

                record_path = WarmTestRunner.server_record_path(FIXTURE_ROOT)
                record_data = TOML.parsefile(record_path)
                record_data["protocol_version"] = 0
                open(record_path, "w") do io
                    TOML.print(io, record_data)
                end

                stop_err = nothing
                try
                    summary = WarmTestRunner.run(tests = ["pass.jl"], fresh = true)
                    current = WarmTestRunner.status()

                    @test summary.passed == 1
                    @test current.server_id != initial_handle.server_id
                    @test current.pid != initial_handle.pid
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

@testset "public run reruns only previous failing files" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    empty_before = WarmTestRunner.run(rerun_failed = true)
                    @test isempty(empty_before.results)

                    first = WarmTestRunner.run(tests = ["fail.jl", "pass.jl"])
                    @test [basename(result.path) for result in first.results] == ["fail.jl", "pass.jl"]
                    @test getfield.(first.results, :status) == [:failed, :passed]

                    status_after_first = WarmTestRunner.status()
                    @test basename.(status_after_first.last_failed) == ["fail.jl"]

                    rerun = WarmTestRunner.run(rerun_failed = true)
                    @test [basename(result.path) for result in rerun.results] == ["fail.jl"]
                    @test getfield.(rerun.results, :status) == [:failed]

                    filtered = WarmTestRunner.run(tests = ["pass.jl", "fail.jl"], rerun_failed = true)
                    @test [basename(result.path) for result in filtered.results] == ["fail.jl"]
                    @test getfield.(filtered.results, :status) == [:failed]

                    cleared = WarmTestRunner.run(tests = ["pass.jl"])
                    @test getfield.(cleared.results, :status) == [:passed]
                    @test isempty(WarmTestRunner.status().last_failed)

                    empty_after = WarmTestRunner.run(rerun_failed = true)
                    @test isempty(empty_after.results)
                finally
                    WarmTestRunner.stop()
                end
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

@testset "public run selects only changed tests when changed_only=true" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            pkgroot = init_changed_only_public_fixture()
            write(joinpath(pkgroot, "test", "beta.jl"), "using Test\nprintln(\"beta changed\")\n@test true\n")

            summary = try
                WarmTestRunner.run(
                    pkgroot = pkgroot,
                    jobs = 1,
                    use_testenv = false,
                    preload_package = false,
                    changed_only = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test [basename(result.path) for result in summary.results] == ["beta.jl"]
                @test summary.passed == 1
                @test summary.failed == 0
            end
            try
                WarmTestRunner.stop(pkgroot = pkgroot)
                WarmTestRunner.wait_for_record_gone(pkgroot)
            catch
            end
        end
    end
end

@testset "public run returns JSON when output_format=json" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            json = try
                WarmTestRunner.run(
                    pkgroot = FIXTURE_ROOT,
                    tests = ["pass.jl"],
                    jobs = 1,
                    output_format = :json,
                )
            catch err
                err
            end

            @test json isa String
            if json isa String
                @test occursin("\"schema_version\":1", json)
                @test occursin("\"passed\":1", json)
                @test occursin("\"status\":\"passed\"", json)
                @test occursin("\"path\":", json)
            end

            try
                WarmTestRunner.stop(pkgroot = FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
            catch
            end
        end
    end
end

@testset "changed_only restarts when live registry record is from an older protocol" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            pkgroot = init_changed_only_public_fixture()
            initial_handle = WarmTestRunner.serve(
                pkgroot = pkgroot,
                jobs = 1,
            )

            record_path = WarmTestRunner.server_record_path(pkgroot)
            record_data = TOML.parsefile(record_path)
            pop!(record_data, "protocol_version", nothing)
            open(record_path, "w") do io
                TOML.print(io, record_data)
            end

            write(joinpath(pkgroot, "test", "beta.jl"), "using Test\nprintln(\"beta changed\")\n@test true\n")

            summary = try
                WarmTestRunner.run(
                    pkgroot = pkgroot,
                    jobs = 1,
                    changed_only = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test [basename(result.path) for result in summary.results] == ["beta.jl"]
                @test summary.passed == 1
            end

            current_status = WarmTestRunner.status(pkgroot = pkgroot)
            @test current_status.server_id != initial_handle.server_id

            try
                WarmTestRunner.stop(pkgroot = pkgroot)
                WarmTestRunner.wait_for_record_gone(pkgroot)
            catch
            end
        end
    end
end
