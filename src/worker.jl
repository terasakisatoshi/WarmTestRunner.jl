using Malt

worker_context_name(id::Int) = Symbol("WarmTestContext_", id)

function bootstrap_script_path(cfg::RunnerConfig)
    path = joinpath(cfg.pkgroot, "test", "warmtest_bootstrap.jl")
    return isfile(path) ? path : nothing
end

function package_name_from_project(cfg::RunnerConfig)
    project_file = joinpath(cfg.pkgroot, "Project.toml")
    return get(TOML.parsefile(project_file), "name", nothing)
end

function activation_expr(cfg::RunnerConfig)
    if cfg.use_testenv
        return quote
            # TestEnv.activate is the intended bootstrap path when requested, but it
            # can reject an uninstalled local fixture package. Fall back to directly
            # activating the package project so Task 4 can still exercise a real
            # package checkout on a single worker.
            try
                using TestEnv
                TestEnv.activate($(cfg.pkgroot))
                Core.eval(Main, :(WARMTEST_ACTIVATION_STRATEGY = :testenv))
                Core.eval(Main, :(WARMTEST_ACTIVATION_FALLBACK_REASON = nothing))
            catch err
                using Pkg
                Pkg.activate($(cfg.pkgroot); io = devnull)
                Core.eval(Main, :(WARMTEST_ACTIVATION_STRATEGY = :pkg_activate_fallback))
                Core.eval(Main, :(WARMTEST_ACTIVATION_FALLBACK_REASON = $(sprint(showerror, err))))
            end
        end
    end

    return quote
        using Pkg
        Pkg.activate($(cfg.pkgroot); io = devnull)
        Core.eval(Main, :(WARMTEST_ACTIVATION_STRATEGY = :pkg_activate))
        Core.eval(Main, :(WARMTEST_ACTIVATION_FALLBACK_REASON = nothing))
    end
end

function revise_expr(cfg::RunnerConfig)
    cfg.use_revise || return quote
        Core.eval(Main, :(WARMTEST_REVISE_LOADED = false))
    end

    return quote
        tool_project = $(cfg.tool_project)
        added_tool_project = !(tool_project in LOAD_PATH)
        added_tool_project && pushfirst!(LOAD_PATH, tool_project)
        try
            Base.eval(Main, :(using Revise))
        finally
            added_tool_project && filter!(path -> path != tool_project, LOAD_PATH)
        end
        Core.eval(Main, :(WARMTEST_REVISE_LOADED = true))
    end
end

function start_worker(cfg::RunnerConfig; id::Int)
    exeflags = String["--project=$(cfg.tool_project)"]
    push!(exeflags, "--threads=$(cfg.threads_per_worker)")
    cfg.startup_file || push!(exeflags, "--startup-file=no")
    proc = Malt.Worker(
        exeflags = exeflags,
        monitor_stdout = false,
        monitor_stderr = false,
    )
    return WorkerHandle(id = id, proc = proc, context_module = worker_context_name(id))
end

function bootstrap_worker!(worker::WorkerHandle, cfg::RunnerConfig)
    bootstrap = bootstrap_script_path(cfg)
    package_name = package_name_from_project(cfg)
    using_expr = package_name === nothing ? nothing : Expr(:using, Expr(:., Symbol(package_name)))
    context_name = QuoteNode(worker.context_module)
    context_source = "module $(worker.context_module)\nend\n"
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
        Base.include_string(Main, $context_source)
        context = getfield(Main, $context_name)
        Base.eval(context, :(using Test))
        if $(cfg.preload_package) && $(using_expr !== nothing)
            Base.eval(context, $using_expr)
        end
        nothing
    end
    try
        Malt.remote_eval_fetch(worker.proc, expr)
        worker.state = :idle
        worker.booted_at = time()
        return nothing
    catch
        worker.state = :crashed
        rethrow()
    end
end

function run_test_in_worker!(worker::WorkerHandle, job::TestJob, ::RunnerConfig)
    worker.state = :running
    context_name = QuoteNode(worker.context_module)
    try
        payload = Malt.remote_eval_fetch(worker.proc, quote
            using Test
            let
                mod = getfield(Main, $context_name)
                stdout_pipe = Pipe()
                stderr_pipe = Pipe()
                Base.link_pipe!(stdout_pipe; reader_supports_async = true, writer_supports_async = true)
                Base.link_pipe!(stderr_pipe; reader_supports_async = true, writer_supports_async = true)
                stdout_reader = Base.pipe_reader(stdout_pipe)
                stdout_writer = Base.pipe_writer(stdout_pipe)
                stderr_reader = Base.pipe_reader(stderr_pipe)
                stderr_writer = Base.pipe_writer(stderr_pipe)
                stdout_task = @async read(stdout_reader, String)
                stderr_task = @async read(stderr_reader, String)
                started = time()
                status = :passed
                exception_summary = nothing
                stacktrace = nothing
                try
                    redirect_stdout(stdout_writer) do
                        redirect_stderr(stderr_writer) do
                            try
                                Base.eval(mod, :(using Test))
                                Base.include(mod, $(job.path))
                            catch err
                                bt = catch_backtrace()
                                if err isa LoadError
                                    inner = err.error
                                    if inner isa Test.TestSetException
                                        status = :failed
                                        exception_summary = sprint(showerror, inner)
                                        stacktrace = sprint(showerror, err, bt)
                                    else
                                        status = :errored
                                        exception_summary = sprint(showerror, err)
                                        stacktrace = sprint(showerror, err, bt)
                                    end
                                elseif err isa Test.TestSetException
                                    status = :failed
                                    exception_summary = sprint(showerror, err)
                                    stacktrace = sprint(showerror, err, bt)
                                else
                                    status = :errored
                                    exception_summary = sprint(showerror, err)
                                    stacktrace = sprint(showerror, err, bt)
                                end
                            end
                        end
                    end
                finally
                    close(stdout_writer)
                    close(stderr_writer)
                    isopen(stdout_reader) && close(stdout_reader)
                    isopen(stderr_reader) && close(stderr_reader)
                end
                (
                    status = status,
                    elapsed = time() - started,
                    stdout = fetch(stdout_task),
                    stderr = fetch(stderr_task),
                    exception_summary = exception_summary,
                    stacktrace = stacktrace,
                )
            end
        end)

        worker.state = :idle
        worker.runs_completed += 1
        return TestResult(
            path = job.path,
            status = payload.status,
            elapsed = payload.elapsed,
            stdout = payload.stdout,
            stderr = payload.stderr,
            exception_summary = payload.exception_summary,
            stacktrace = payload.stacktrace,
            worker_id = worker.id,
        )
    catch err
        worker.state = :crashed
        return TestResult(
            path = job.path,
            status = :crashed,
            elapsed = 0.0,
            exception_summary = sprint(showerror, err),
            stacktrace = sprint(showerror, err, catch_backtrace()),
            worker_id = worker.id,
        )
    end
end

function stop_worker!(worker::WorkerHandle)
    Malt.stop(worker.proc)
    worker.state = :stopped
    return nothing
end
