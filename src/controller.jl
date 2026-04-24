using Sockets
using Serialization
using UUIDs
using Base: @kwdef

Base.@kwdef mutable struct ControllerState
    cfg::RunnerConfig
    handle::ServerHandle
    status::ServerStatus
    workers::Vector{WorkerHandle}
    lock::ReentrantLock = ReentrantLock()
    run_active::Bool = false
    stop_requested::Bool = false
end

function build_jobs(
    cfg::RunnerConfig;
    tests::AbstractVector{<:AbstractString} = String[],
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    last_failed::AbstractVector{<:AbstractString} = String[],
)
    !isempty(tests) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))

    explicit_jobs = [
        TestJob(
            path = job_path_from_test_name(cfg, name),
            name = basename(name),
        )
        for name in tests
    ]

    if rerun_failed
        isempty(last_failed) && return TestJob[]
        if isempty(tests)
            return [
                TestJob(path = job_path_from_recorded_result(cfg, path), name = basename(path))
                for path in last_failed
            ]
        end
        failed_paths = Set(job_path_from_recorded_result(cfg, path) for path in last_failed)
        return [job for job in explicit_jobs if abspath(job.path) in failed_paths]
    end

    changed_only && return discover_changed_tests(cfg.pkgroot)
    isempty(tests) && return discover_tests(cfg.pkgroot)
    return explicit_jobs
end

function plans_to_jobs(cfg::RunnerConfig, plans::AbstractVector{<:ExecutionPlan})
    return [
        TestJob(
            path = plan.entryfile,
            name = basename(plan.entryfile),
            plan = plan,
        )
        for plan in plans
    ]
end

function build_plan_jobs(
    cfg::RunnerConfig;
    tests = nothing,
    testsets = nothing,
    line_patterns = nothing,
    expression_patterns = nothing,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    last_failed::AbstractVector{<:AbstractString} = String[],
)
    plans = build_execution_plans(
        cfg;
        tests,
        testsets,
        line_patterns,
        expression_patterns,
        changed_only,
        rerun_failed,
        last_failed,
    )
    return plans_to_jobs(cfg, plans)
end

function absolute_diagnostic_path(cfg::RunnerConfig, path::AbstractString)
    isempty(path) && return ""
    return normpath(isabspath(path) ? String(path) : joinpath(cfg.pkgroot, path))
end

function failed_selection_paths_from_diagnostics(
    cfg::RunnerConfig,
    selections::AbstractVector{<:TestSelection},
    diagnostics::AbstractVector{<:TestDiagnostic},
)
    failed_files = Set{String}()
    for diagnostic in diagnostics
        path = absolute_diagnostic_path(cfg, diagnostic.file)
        isempty(path) || push!(failed_files, path)
    end
    isempty(failed_files) && return String[]

    paths = String[]
    for selection in selections
        selection_path = normpath(abspath(selection.file))
        selection_path in failed_files || continue
        push!(paths, result_path(cfg, selection.file))
    end
    return unique!(paths)
end

function failed_paths_for_job(cfg::RunnerConfig, job::TestJob, result::TestResult)
    result.status in (:failed, :errored, :crashed) || return String[]
    plan = job.plan
    plan === nothing && return String[result.path]
    if plan.run_all || isempty(plan.selections)
        return String[plan.label]
    end

    diagnostic_paths = failed_selection_paths_from_diagnostics(cfg, plan.selections, result.diagnostics)
    isempty(diagnostic_paths) || return diagnostic_paths

    paths = String[]
    for selection in plan.selections
        push!(paths, result_path(cfg, selection.file))
    end
    return unique!(paths)
end

function start_worker_pool(cfg::RunnerConfig)
    workers = [start_worker(cfg; id = i) for i in 1:cfg.jobs]
    try
        @sync for worker in workers
            @async bootstrap_worker!(worker, cfg)
        end
        return workers
    catch
        stop_worker_pool!(workers)
        rethrow()
    end
end

function stop_worker_pool!(workers::AbstractVector{<:WorkerHandle})
    for worker in workers
        try
            stop_worker!(worker)
        catch
            worker.state = :crashed
        end
    end
    return nothing
end

function recreate_worker!(state::ControllerState, index::Int)
    old_worker = state.workers[index]
    try
        stop_worker!(old_worker)
    catch
    end

    worker = start_worker(state.cfg; id = old_worker.id)
    try
        bootstrap_worker!(worker, state.cfg)
        state.workers[index] = worker
        return worker
    catch
        try
            stop_worker!(worker)
        catch
        end
        rethrow()
    end
end

function refresh_worker_pool!(state::ControllerState)
    new_workers = start_worker_pool(state.cfg)
    old_workers = lock(state.lock) do
        old_workers = state.workers
        state.workers = new_workers
        return old_workers
    end

    try
        stop_worker_pool!(old_workers)
        return new_workers
    catch
        try
            stop_worker_pool!(new_workers)
        catch
        end
        lock(state.lock) do
            state.workers = old_workers
        end
        rethrow()
    end
end

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
    if isempty(jobs)
        return summarize_results(TestResult[])
    end

    results = Vector{Union{Nothing, TestResult}}(undef, length(jobs))
    fill!(results, nothing)
    next_job = Ref(1)
    stop_dispatch = Ref(false)
    pool_lock = ReentrantLock()

    function take_job_index()
        lock(pool_lock) do
            if stop_dispatch[] || should_stop!() || next_job[] > length(jobs)
                return nothing
            end
            idx = next_job[]
            next_job[] += 1
            return idx
        end
    end

    function mark_quickfail!(result::TestResult)
        quickfail || return
        if result.status in (:failed, :errored, :crashed)
            lock(pool_lock) do
                stop_dispatch[] = true
            end
        end
    end

    @sync for worker_index in eachindex(workers)
        @async begin
            worker = workers[worker_index]
            while true
                idx = take_job_index()
                idx === nothing && break
                on_job_start!(worker_index, idx, jobs[idx])
                try
                    result = run_test_in_worker!(worker, jobs[idx], cfg)
                    final_result = result
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
                            should_stop!() && break
                            worker = recover_worker!(worker_index)
                            quickfail && break
                        end
                    else
                        results[idx] = final_result
                        mark_quickfail!(final_result)
                    end
                finally
                    on_job_finish!(worker_index, idx, jobs[idx])
                end
            end
        end
    end

    ordered_results = Vector{TestResult}(undef, length(jobs))
    for (idx, maybe_result) in pairs(results)
        if maybe_result === nothing
            job = jobs[idx]
            ordered_results[idx] = TestResult(
                path = job.plan === nothing ? result_path(cfg, job.path) : job.plan.label,
                status = :skipped,
                elapsed = 0.0,
                worker_id = nothing,
            )
        else
            ordered_results[idx] = maybe_result
        end
    end

    return summarize_results(ordered_results)
end

function run_jobs_inline(cfg::RunnerConfig, jobs::AbstractVector{<:TestJob}; quickfail::Bool = false)
    workers = start_worker_pool(cfg)
    try
        return schedule_jobs!(workers, jobs, cfg; quickfail = quickfail)
    finally
        stop_worker_pool!(workers)
    end
end

function controller_status(handle::ServerHandle, pkgroot::AbstractString; state::Symbol, running_jobs::Int, last_failed::Vector{String}, last_success_at::Union{Nothing, Float64})
    return ServerStatus(
        server_id = handle.server_id,
        pid = handle.pid,
        pkgroot = pkgroot,
        started_at = handle.started_at,
        jobs = handle.jobs,
        running_jobs = running_jobs,
        last_failed = last_failed,
        last_success_at = last_success_at,
        state = state,
    )
end

function persist_status!(state::ControllerState)
    status = lock(state.lock) do
        state.status
    end
    record = load_server_record(state.cfg.pkgroot)
    record === nothing && return nothing
    write_server_record!(state.handle, status; port = record.port)
    return nothing
end

function controller_status_snapshot(state::ControllerState)
    return lock(state.lock) do
        state.status
    end
end

function controller_stop_requested(state::ControllerState)
    return lock(state.lock) do
        state.stop_requested
    end
end

function adjust_running_jobs!(state::ControllerState, delta::Int)
    lock(state.lock) do
        current = state.status
        state.status = controller_status(
            state.handle,
            state.cfg.pkgroot;
            state = current.state,
            running_jobs = max(0, current.running_jobs + delta),
            last_failed = current.last_failed,
            last_success_at = current.last_success_at,
        )
    end
    persist_status!(state)
    return nothing
end

request_command(request) = request isa NamedTuple ? getproperty(request, :cmd) : request[:cmd]

function request_payload(request, key::Symbol, default)
    if request isa NamedTuple
        return hasproperty(request, key) ? getproperty(request, key) : default
    end
    return get(request, key, default)
end

function controller_log_paths()
    warm_home = get(ENV, "WARMTESTRUNNER_HOME", joinpath(homedir(), ".julia", "warmtestrunner"))
    logs_dir = joinpath(warm_home, "logs")
    mkpath(logs_dir)
    token = string(uuid4())
    return (
        stdout = joinpath(logs_dir, "controller-$(token).out.log"),
        stderr = joinpath(logs_dir, "controller-$(token).err.log"),
    )
end

function wait_for_record(pkgroot::AbstractString; timeout_s::Real = 10.0, log_paths = nothing)
    deadline = time() + timeout_s
    while time() < deadline
        record = try
            load_server_record(pkgroot)
        catch
            nothing
        end
        record !== nothing && return record
        sleep(0.05)
    end
    if log_paths === nothing
        error("timed out waiting for server record for $(abspath(pkgroot))")
    end
    error("timed out waiting for server record for $(abspath(pkgroot)); check controller logs at stdout=$(log_paths.stdout) stderr=$(log_paths.stderr)")
end

function wait_for_record_gone(pkgroot::AbstractString; timeout_s::Real = 10.0)
    deadline = time() + timeout_s
    while time() < deadline
        record = try
            load_server_record(pkgroot)
        catch
            nothing
        end
        record === nothing && return nothing
        sleep(0.05)
    end
    error("timed out waiting for server record to disappear for $(abspath(pkgroot))")
end

function validate_reuse_configuration(record, kwargs)
    extras = [key for key in keys(kwargs) if key ∉ (:pkgroot, :jobs)]
    isempty(extras) || throw(ArgumentError("cannot reuse an existing controller with config kwargs: $(join(string.(extras), ", "))"))
    requested_jobs = get(kwargs, :jobs, nothing)
    if requested_jobs !== nothing && requested_jobs != record.handle.jobs
        throw(ArgumentError("existing controller jobs=$(record.handle.jobs) does not match requested jobs=$(requested_jobs)"))
    end
    return nothing
end

function client_request(pkgroot::AbstractString, request)
    record = load_server_record(pkgroot)
    record === nothing && throw(ArgumentError("no server record for $(abspath(pkgroot))"))

    socket = connect(ip"127.0.0.1", record.port)
    try
        serialize(socket, request)
        response = deserialize(socket)
        if response isa NamedTuple && get(response, :status, nothing) == :error
            throw(ErrorException(String(get(response, :error, "controller request failed"))))
        end
        return response
    finally
        close(socket)
    end
end

function launch_controller(cfg::RunnerConfig)
    logs = controller_log_paths()
    stdout_io = open(logs.stdout, "w")
    stderr_io = open(logs.stderr, "w")
    controller_env = copy(ENV)
    controller_env["JULIA_PROJECT"] = cfg.tool_project
    controller_env["WARMTESTRUNNER_HOME"] = get(ENV, "WARMTESTRUNNER_HOME", joinpath(homedir(), ".julia", "warmtestrunner"))
    request = """
        using WarmTestRunner
        cfg = WarmTestRunner.make_config(;
            pkgroot = $(repr(cfg.pkgroot)),
            jobs = $(repr(cfg.jobs)),
            threads_per_worker = $(repr(cfg.threads_per_worker)),
            use_testenv = $(repr(cfg.use_testenv)),
            use_revise = $(repr(cfg.use_revise)),
            preload_package = $(repr(cfg.preload_package)),
            startup_file = $(repr(cfg.startup_file)),
            color = $(repr(cfg.color)),
            worker_timeout = $(repr(cfg.worker_timeout)),
            log_level = $(repr(cfg.log_level)),
        )
        WarmTestRunner.serve_forever(cfg)
        """

    cmd = pipeline(
        setenv(
            `$(Base.julia_cmd()) --startup-file=no -e $request`,
            controller_env,
        ),
        stdin = devnull,
        stdout = stdout_io,
        stderr = stderr_io,
    )
    try
        Base.run(cmd; wait = false)
        return wait_for_record(cfg.pkgroot; log_paths = logs).handle
    finally
        close(stdout_io)
        close(stderr_io)
    end
end

function run_jobs_on_pool!(state::ControllerState, jobs::AbstractVector{<:TestJob}; quickfail::Bool, retry_crashed::Bool = true)
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
    catch
        lock(state.lock) do
            state.run_active = false
            state.status = controller_status(
                state.handle,
                state.cfg.pkgroot;
                state = state.stop_requested ? :stopping : :idle,
                running_jobs = 0,
                last_failed = state.status.last_failed,
                last_success_at = state.status.last_success_at,
            )
        end
        persist_status!(state)
        rethrow()
    end

    successful_run = !isempty(summary.results) && all(result.status == :passed for result in summary.results)

    lock(state.lock) do
        state.run_active = false
        state.status = controller_status(
            state.handle,
            state.cfg.pkgroot;
            state = state.stop_requested ? :stopping : :idle,
            running_jobs = 0,
            last_failed = reduce(
                append!,
                (
                    failed_paths_for_job(state.cfg, job, result)
                    for (job, result) in zip(jobs, summary.results)
                );
                init = String[],
            ),
            last_success_at = successful_run ? time() : state.status.last_success_at,
        )
    end
    persist_status!(state)
    return summary
end

function handle_request!(state::ControllerState, request)
    cmd = request_command(request)
    if cmd == :status
        return controller_status_snapshot(state)
    elseif cmd == :run
        lock(state.lock) do
            state.run_active && throw(ArgumentError("controller is already running tests"))
            state.stop_requested && throw(ArgumentError("controller is stopping"))
            state.run_active = true
            state.stop_requested = false
            state.status = controller_status(
                state.handle,
                state.cfg.pkgroot;
                state = :running,
                running_jobs = 0,
                last_failed = state.status.last_failed,
                last_success_at = state.status.last_success_at,
            )
        end
        persist_status!(state)

        jobs = try
            request_payload(request, :fresh, false) && refresh_worker_pool!(state)
            previous_failed = lock(state.lock) do
                copy(state.status.last_failed)
            end
            build_plan_jobs(
                state.cfg;
                tests = request_payload(request, :tests, nothing),
                testsets = request_payload(request, :testsets, nothing),
                line_patterns = request_payload(request, :line_patterns, nothing),
                expression_patterns = request_payload(request, :expression_patterns, nothing),
                changed_only = request_payload(request, :changed_only, false),
                rerun_failed = request_payload(request, :rerun_failed, false),
                last_failed = previous_failed,
            )
        catch
            lock(state.lock) do
                state.run_active = false
                state.status = controller_status(
                    state.handle,
                    state.cfg.pkgroot;
                    state = state.stop_requested ? :stopping : :idle,
                    running_jobs = 0,
                    last_failed = state.status.last_failed,
                    last_success_at = state.status.last_success_at,
                )
            end
            persist_status!(state)
            rethrow()
        end
        quickfail = request_payload(request, :quickfail, false)
        retry_crashed = request_payload(request, :retry_crashed, true)
        return run_jobs_on_pool!(state, jobs; quickfail = quickfail, retry_crashed = retry_crashed)
    elseif cmd == :stop
        should_interrupt, workers_to_stop = lock(state.lock) do
            state.stop_requested = true
            state.status = controller_status(
                state.handle,
                state.cfg.pkgroot;
                state = :stopping,
                running_jobs = state.run_active ? state.status.running_jobs : 0,
                last_failed = state.status.last_failed,
                last_success_at = state.status.last_success_at,
            )
            return (state.run_active, state.workers)
        end
        persist_status!(state)
        should_interrupt && stop_worker_pool!(workers_to_stop)
        return :ok
    else
        throw(ArgumentError("unknown controller request: $(cmd)"))
    end
end

function serve_forever(cfg::RunnerConfig)
    server = listen(ip"127.0.0.1", 0)
    port = Int(getsockname(server)[2])
    handle = ServerHandle(pkgroot = cfg.pkgroot, server_id = string(uuid4()), pid = getpid(), started_at = time(), jobs = cfg.jobs)
    status = controller_status(handle, cfg.pkgroot; state = :idle, running_jobs = 0, last_failed = String[], last_success_at = nothing)
    workers = WorkerHandle[]
    state = ControllerState(cfg = cfg, handle = handle, status = status, workers = workers)

    try
        workers = start_worker_pool(cfg)
        state.workers = workers
        write_server_record!(handle, status; port = port)

        request_tasks = Task[]
        while true
            socket = try
                accept(server)
            catch
                controller_stop_requested(state) && break
                rethrow()
            end

            task = @async begin
                try
                    request = nothing
                    response = nothing
                    should_stop = false
                    try
                        request = deserialize(socket)
                        response = handle_request!(state, request)
                        should_stop = request_command(request) == :stop
                    catch err
                        response = (status = :error, error = sprint(showerror, err))
                    end

                    try
                        serialize(socket, response)
                    catch
                    end

                    if should_stop
                        try
                            close(server)
                        catch
                        end
                    end
                finally
                    close(socket)
                end
            end
            push!(request_tasks, task)
        end
        wait.(request_tasks)
    finally
        try
            stop_worker_pool!(state.workers)
        catch
        end
        try
            delete_server_record!(cfg.pkgroot)
        catch
        end
        try
            close(server)
        catch
        end
    end

    return handle
end
