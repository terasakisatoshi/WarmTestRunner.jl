using Test
using WarmTestRunner
using Sockets
using Serialization
using TOML

const FIXTURE_ROOT = joinpath(@__DIR__, "packages", "FixturePkg")
const VIRTUAL_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
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

function init_shared_context_fixture(tmp::AbstractString)
    pkgroot = joinpath(tmp, "SharedContextFixture")
    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "SharedContextFixture"
        uuid = "11111111-2222-3333-4444-555555555555"
        version = "0.1.0"
        """,
    )
    write(
        joinpath(pkgroot, "src", "SharedContextFixture.jl"),
        """
        module SharedContextFixture

        add1(x) = x + 1

        end
        """,
    )
    write(
        joinpath(pkgroot, "test", "define_shared.jl"),
        """
        using Test
        using SharedContextFixture
        shared_ctx_value = SharedContextFixture.add1(40)
        @test shared_ctx_value == 41
        """,
    )
    write(
        joinpath(pkgroot, "test", "read_shared.jl"),
        """
        using Test
        shared_ctx_value == 41 || error("shared_ctx_value mismatch")
        @test true
        """,
    )
    write(joinpath(pkgroot, "test", "crash.jl"), "exit(1)\n")
    return pkgroot
end

function init_split_testset_parallel_fixture(tmp::AbstractString)
    pkgroot = joinpath(tmp, "SplitTestsetParallelFixture")
    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "SplitTestsetParallelFixture"
        uuid = "99999999-aaaa-bbbb-cccc-dddddddddddd"
        version = "0.1.0"
        """,
    )
    write(joinpath(pkgroot, "src", "SplitTestsetParallelFixture.jl"), "module SplitTestsetParallelFixture\nend\n")
    write(
        joinpath(pkgroot, "test", "runtests.jl"),
        """
        using Test
        include("split.jl")
        """,
    )
    write(
        joinpath(pkgroot, "test", "split.jl"),
        """
        using Test

        @testset "parallel one" begin
            sleep(0.5)
            @test true
        end

        @testset "parallel two" begin
            sleep(0.5)
            @test true
        end

        @testset "parallel three" begin
            sleep(0.5)
            @test true
        end

        @testset "parallel four" begin
            sleep(0.5)
            @test true
        end
        """,
    )
    return pkgroot
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

@testset "inline scheduler preserves imported package bindings across files" begin
    mktempdir() do tmp
        importer_path = write_temp_test(
            tmp,
            "importer.jl",
            """
            using Test
            using FixturePkg
            @test FixturePkg.add1(1) == 2
            """,
        )
        consumer_path = write_temp_test(
            tmp,
            "consumer.jl",
            """
            using Test
            @test FixturePkg.add1(2) == 3
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
        jobs = [
            WarmTestRunner.TestJob(path = importer_path, name = "importer.jl"),
            WarmTestRunner.TestJob(path = consumer_path, name = "consumer.jl"),
        ]

        summary = WarmTestRunner.run_jobs_inline(cfg, jobs)

        @test getfield.(summary.results, :status) == [:passed, :passed]
        @test summary.passed == 2
    end
end

@testset "inline scheduler preserves helper definitions across files" begin
    mktempdir() do tmp
        helper_def_path = write_temp_test(
            tmp,
            "helper_def.jl",
            """
            using Test
            using FixturePkg
            shared_fixture_helper(x) = FixturePkg.add1(x)
            @test shared_fixture_helper(1) == 2
            """,
        )
        helper_use_path = write_temp_test(
            tmp,
            "helper_use.jl",
            """
            using Test
            @test shared_fixture_helper(2) == 3
            """,
        )

        cfg = WarmTestRunner.make_config(pkgroot = FIXTURE_ROOT, jobs = 1)
        jobs = [
            WarmTestRunner.TestJob(path = helper_def_path, name = "helper_def.jl"),
            WarmTestRunner.TestJob(path = helper_use_path, name = "helper_use.jl"),
        ]

        summary = WarmTestRunner.run_jobs_inline(cfg, jobs)

        @test getfield.(summary.results, :status) == [:passed, :passed]
        @test summary.passed == 2
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
                first = WarmTestRunner.runtests(tests = ["pass.jl"])
                second = WarmTestRunner.status()

                @test reused.pid == handle.pid
                @test first.passed == 1
                @test second.state == :idle
                @test second.pid == handle.pid
                @test_throws ArgumentError WarmTestRunner.serve(jobs = 2)
                @test_throws ArgumentError WarmTestRunner.runtests(jobs = 2, tests = ["pass.jl"])
                @test_throws ErrorException WarmTestRunner.client_request(FIXTURE_ROOT, (cmd = :bogus,))

                WarmTestRunner.stop()
                WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                @test WarmTestRunner.load_server_record(FIXTURE_ROOT) === nothing
                @test WarmTestRunner.status().state == :stopped
            end
        end
    end
end

@testset "daemon outlives launcher process" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            project_root = dirname(@__DIR__)
            script = """
                using WarmTestRunner
                cd(ARGS[1]) do
                    handle = WarmTestRunner.serve(jobs = 1)
                    status = WarmTestRunner.status()
                    println("launched_pid=", handle.pid)
                    println("launcher_pgid=", ccall(:getpgrp, Cint, ()))
                    println("launched_state=", status.state)
                end
            """
            output = read(
                pipeline(
                    setenv(
                        `$(Base.julia_cmd()) --startup-file=no --project=$project_root -e $script $FIXTURE_ROOT`,
                        "WARMTESTRUNNER_HOME" => tmp,
                    ),
                    stderr = stderr,
                ),
                String,
            )
            @test occursin("launched_state=idle", output)

            launched_pid = parse(Int, match(r"launched_pid=(\d+)", output).captures[1])
            if !Sys.iswindows()
                launcher_pgid = parse(Int, match(r"launcher_pgid=(\d+)", output).captures[1])
                controller_pgid = parse(Int, strip(read(`ps -o pgid= -p $launched_pid`, String)))
                @test controller_pgid != launcher_pgid
            end

            observed = nothing
            deadline = time() + 5
            while time() < deadline
                observed = WarmTestRunner.status(pkgroot = FIXTURE_ROOT)
                observed.state == :idle && observed.jobs == 1 && break
                sleep(0.1)
            end

            @test observed !== nothing
            @test observed.state == :idle
            @test observed.jobs == 1

            WarmTestRunner.stop(pkgroot = FIXTURE_ROOT)
            WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
        end
    end
end

@testset "runtests prints text summary by default" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    output_path = joinpath(tmp, "summary.out")
                    summary = open(output_path, "w") do output
                        redirect_stdout(output) do
                            WarmTestRunner.runtests(tests = ["pass.jl"])
                        end
                    end

                    text = read(output_path, String)
                    @test summary isa WarmTestRunner.RunSummary
                    @test summary.passed == 1
                    @test occursin("RunSummary:", text)
                    @test occursin("pass.jl", text)

                    quiet_path = joinpath(tmp, "quiet.out")
                    quiet_summary = open(quiet_path, "w") do output
                        redirect_stdout(output) do
                            WarmTestRunner.runtests(tests = ["pass.jl"], print_summary = false)
                        end
                    end
                    @test quiet_summary isa WarmTestRunner.RunSummary
                    @test isempty(read(quiet_path, String))
                finally
                    WarmTestRunner.stop()
                    WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
                end
            end
        end
    end
end

@testset "daemon with default use_revise can be reused by matching calls" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                handle = WarmTestRunner.serve(jobs = 1)
                stop_err = nothing
                try
                    reused = WarmTestRunner.serve(jobs = 1)
                    summary = WarmTestRunner.runtests(tests = ["pass.jl"])
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

@testset "explicit use_revise=false mismatch is rejected for default daemon reuse" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
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

@testset "public runtests fresh=true refreshes workers without replacing the daemon" begin
    mktempdir() do tmp
        pkgroot, counter_path = init_bootstrap_counter_fixture(tmp)
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(pkgroot) do
                WarmTestRunner.serve(jobs = 1)
                stop_err = nothing
                try
                    before = WarmTestRunner.status()
                    first = WarmTestRunner.runtests(tests = ["bootstrap_counter.jl"])
                    counter_before = parse(Int, strip(read(counter_path, String)))
                    refreshed = WarmTestRunner.runtests(tests = ["bootstrap_counter.jl"], fresh = true)
                    counter_after = parse(Int, strip(read(counter_path, String)))
                    after = WarmTestRunner.status()
                    followup = WarmTestRunner.runtests(tests = ["bootstrap_counter.jl"])

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

@testset "public runtests fresh=true clears shared worker context" begin
    mktempdir() do tmp
        pkgroot = init_shared_context_fixture(tmp)
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(pkgroot) do
                WarmTestRunner.serve(jobs = 1)
                stop_err = nothing
                try
                    seeded = WarmTestRunner.runtests(tests = ["define_shared.jl"])
                    visible = WarmTestRunner.runtests(tests = ["read_shared.jl"])
                    reset = WarmTestRunner.runtests(tests = ["read_shared.jl"], fresh = true)

                    @test getfield.(seeded.results, :status) == [:passed]
                    @test getfield.(visible.results, :status) == [:passed]
                    @test getfield.(reset.results, :status) == [:errored]
                    @test any(
                        diagnostic -> occursin("UndefVarError", diagnostic.message),
                        only(reset.results).diagnostics,
                    )
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
                    summary = WarmTestRunner.runtests(tests = ["pass.jl"], fresh = true)
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

@testset "public runtests reruns only previous failing files" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    empty_before = WarmTestRunner.runtests(rerun_failed = true)
                    @test isempty(empty_before.results)

                    first = WarmTestRunner.runtests(tests = ["fail.jl", "pass.jl"])
                    @test [result.path for result in first.results] == ["test/fail.jl", "test/pass.jl"]
                    @test getfield.(first.results, :status) == [:failed, :passed]

                    status_after_first = WarmTestRunner.status()
                    @test status_after_first.last_failed == ["test/fail.jl"]

                    rerun = WarmTestRunner.runtests(rerun_failed = true)
                    @test [result.path for result in rerun.results] == ["test/fail.jl"]
                    @test getfield.(rerun.results, :status) == [:failed]

                    filtered = WarmTestRunner.runtests(tests = ["pass.jl", "fail.jl"], rerun_failed = true)
                    @test [result.path for result in filtered.results] == ["test/fail.jl"]
                    @test getfield.(filtered.results, :status) == [:failed]

                    cleared = WarmTestRunner.runtests(tests = ["pass.jl"])
                    @test getfield.(cleared.results, :status) == [:passed]
                    @test isempty(WarmTestRunner.status().last_failed)

                    empty_after = WarmTestRunner.runtests(rerun_failed = true)
                    @test isempty(empty_after.results)
                finally
                    WarmTestRunner.stop()
                end
            end
        end
    end
end

@testset "public runtests treats empty tests selector as run all" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            summary = try
                WarmTestRunner.runtests(
                    pkgroot = FIXTURE_ROOT,
                    tests = String[],
                    jobs = 1,
                    use_revise = false,
                    fresh = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test length(summary.results) == 4
                @test Set(basename(result.path) for result in summary.results) ==
                    Set(["crash.jl", "crash_once.jl", "fail.jl", "pass.jl"])
            end

            try
                WarmTestRunner.stop(pkgroot = FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(FIXTURE_ROOT)
            catch
            end
        end
    end
end

@testset "rerun_failed preserves selected included file granularity" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            first = try
                WarmTestRunner.runtests(
                    pkgroot = VIRTUAL_FIXTURE_ROOT,
                    tests = ["errors.jl", "selection.jl"],
                    jobs = 1,
                    use_revise = false,
                    fresh = true,
                )
            catch err
                err
            end

            @test first isa WarmTestRunner.RunSummary
            if first isa WarmTestRunner.RunSummary
                results_by_path = Dict(result.path => result for result in first.results)
                @test Set(keys(results_by_path)) == Set(["test/errors.jl", "test/selection.jl"])
                @test results_by_path["test/errors.jl"].status == :failed
                @test results_by_path["test/selection.jl"].status == :passed
                @test WarmTestRunner.status(pkgroot = VIRTUAL_FIXTURE_ROOT).last_failed == ["test/errors.jl"]
                @test occursin("selected testset", results_by_path["test/selection.jl"].stdout)
            end

            rerun = try
                WarmTestRunner.runtests(
                    pkgroot = VIRTUAL_FIXTURE_ROOT,
                    rerun_failed = true,
                )
            catch err
                err
            end

            @test rerun isa WarmTestRunner.RunSummary
            if rerun isa WarmTestRunner.RunSummary
                @test getfield.(rerun.results, :status) == [:failed]
                @test occursin("failure testset", only(rerun.results).stdout)
                @test occursin("error testset", only(rerun.results).stdout)
                @test !occursin("selected testset", only(rerun.results).stdout)
            end

            try
                WarmTestRunner.stop(pkgroot = VIRTUAL_FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(VIRTUAL_FIXTURE_ROOT)
            catch
            end
        end
    end
end

@testset "public runtests executes selected included files through runtests" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            summary = try
                WarmTestRunner.runtests(
                    pkgroot = VIRTUAL_FIXTURE_ROOT,
                    tests = ["selection.jl"],
                    jobs = 1,
                    use_revise = false,
                    fresh = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test getfield.(summary.results, :status) == [:passed]
                @test only(summary.results).path == "test/selection.jl"
                @test occursin("selected testset", only(summary.results).stdout)
                @test occursin("other testset", only(summary.results).stdout)
                @test !occursin("failure testset", only(summary.results).stdout)
            end

            try
                WarmTestRunner.stop(pkgroot = VIRTUAL_FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(VIRTUAL_FIXTURE_ROOT)
            catch
            end
        end
    end
end

@testset "public runtests accepts named testset selectors" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            summary = try
                WarmTestRunner.runtests(
                    pkgroot = VIRTUAL_FIXTURE_ROOT,
                    testsets = ["selected testset"],
                    jobs = 1,
                    use_revise = false,
                    fresh = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test getfield.(summary.results, :status) == [:passed]
                @test occursin("selected testset", only(summary.results).stdout)
                @test !occursin("other testset", only(summary.results).stdout)
                @test isempty(only(summary.results).diagnostics)
            end

            try
                WarmTestRunner.stop(pkgroot = VIRTUAL_FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(VIRTUAL_FIXTURE_ROOT)
            catch
            end
        end
    end
end

@testset "public split_testsets uses existing multi-worker daemon" begin
    mktempdir() do tmp
        pkgroot = init_split_testset_parallel_fixture(tmp)
        warm_home = joinpath(tmp, "warm-home")
        withenv("WARMTESTRUNNER_HOME" => warm_home) do
            handle = try
                WarmTestRunner.serve(
                    pkgroot = pkgroot,
                    jobs = 4,
                    use_testenv = false,
                    use_revise = false,
                    preload_package = false,
                )
            catch err
                err
            end

            @test handle isa WarmTestRunner.ServerHandle
            if handle isa WarmTestRunner.ServerHandle
                @test handle.jobs == 4
            end

            summary = try
                WarmTestRunner.runtests(
                    pkgroot = pkgroot,
                    jobs = 4,
                    split_testsets = true,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test length(summary.results) == 4
                @test summary.passed == 4
                @test all(result -> startswith(result.path, "test/split.jl:"), summary.results)
                @test length(Set(result.worker_id for result in summary.results)) > 1
                @test WarmTestRunner.status(pkgroot = pkgroot).jobs == 4
            end

            try
                WarmTestRunner.stop(pkgroot = pkgroot)
                WarmTestRunner.wait_for_record_gone(pkgroot)
            catch
            end
        end
    end
end

@testset "selector run restarts when live registry record is from an older protocol" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            initial_handle = WarmTestRunner.serve(
                pkgroot = VIRTUAL_FIXTURE_ROOT,
                jobs = 1,
                use_revise = false,
            )

            record_path = WarmTestRunner.server_record_path(VIRTUAL_FIXTURE_ROOT)
            record_data = TOML.parsefile(record_path)
            record_data["protocol_version"] = WarmTestRunner.EXECUTION_PLANS_PROTOCOL_VERSION - 1
            open(record_path, "w") do io
                TOML.print(io, record_data)
            end

            summary = try
                WarmTestRunner.runtests(
                    pkgroot = VIRTUAL_FIXTURE_ROOT,
                    testsets = ["selected testset"],
                    jobs = 1,
                    use_revise = false,
                )
            catch err
                err
            end

            @test summary isa WarmTestRunner.RunSummary
            if summary isa WarmTestRunner.RunSummary
                @test summary.passed == 1
            end

            current_status = WarmTestRunner.status(pkgroot = VIRTUAL_FIXTURE_ROOT)
            @test current_status.server_id != initial_handle.server_id

            try
                WarmTestRunner.stop(pkgroot = VIRTUAL_FIXTURE_ROOT)
                WarmTestRunner.wait_for_record_gone(VIRTUAL_FIXTURE_ROOT)
            catch
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
                sleep(6.0)
                @test true
                """,
            )

            cd(FIXTURE_ROOT) do
                WarmTestRunner.serve(jobs = 1)
                try
                    run_task = @async WarmTestRunner.runtests(tests = [slow_path])
                    sleep(0.3)

                    deadline = time() + 5.0
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
                run_task = @async WarmTestRunner.runtests(tests = [slow_path])
                deadline = time() + 1.5
                while time() < deadline
                    current = WarmTestRunner.status()
                    current.state == :running && current.running_jobs == 1 && break
                    sleep(0.05)
                end

                stop_elapsed = @elapsed stop_result = WarmTestRunner.stop()
                summary = fetch(run_task)

                @test stop_elapsed < 2.5
                @test stop_result == :ok
                @test summary.crashed == 1
                @test getfield.(summary.results, :status) == [:crashed]
                @test WarmTestRunner.status().state == :stopped
            end
        end
    end
end

@testset "public runtests selects only changed tests when changed_only=true" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            pkgroot = init_changed_only_public_fixture()
            write(joinpath(pkgroot, "test", "beta.jl"), "using Test\nprintln(\"beta changed\")\n@test true\n")

            summary = try
                WarmTestRunner.runtests(
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

@testset "public runtests returns JSON when output_format=json" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            output_path = joinpath(tmp, "json.out")
            json = try
                open(output_path, "w") do output
                    redirect_stdout(output) do
                        WarmTestRunner.runtests(
                            pkgroot = FIXTURE_ROOT,
                            tests = ["pass.jl"],
                            jobs = 1,
                            output_format = :json,
                        )
                    end
                end
            catch err
                err
            end

            @test json isa String
            if json isa String
                @test occursin("\"schema_version\":2", json)
                @test occursin("\"passed\":1", json)
                @test occursin("\"status\":\"passed\"", json)
                @test occursin("\"diagnostics\":[]", json)
                @test occursin("\"path\":", json)
            end
            @test isempty(read(output_path, String))

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
                WarmTestRunner.runtests(
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
