using Malt

const WORKER_RUNTIME_MODULE = :WarmTestRunnerWorkerRuntime

function worker_runtime_setup_expr()
    runtime_name = QuoteNode(WORKER_RUNTIME_MODULE)
    runtime_source = "module $(WORKER_RUNTIME_MODULE)\nend\n"
    return quote
        if !isdefined(Main, $runtime_name)
            Base.include_string(Main, $runtime_source)
        end
        runtime = getfield(Main, $runtime_name)
        Base.eval(runtime, :(using WarmTestRunner))
        runtime
    end
end

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
        package_name = package_name_from_project(cfg)
        return quote
            try
                using Pkg
                using TestEnv
                if $(package_name === nothing)
                    Pkg.activate($(cfg.pkgroot); io = devnull)
                    TestEnv.activate()
                else
                    mktempdir() do tmp
                        Pkg.activate(tmp; io = devnull)
                        Pkg.develop(Pkg.PackageSpec(path = $(cfg.pkgroot)); io = devnull)
                        TestEnv.activate($(package_name))
                    end
                end
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
            using Revise
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
    return WorkerHandle(id = id, proc = proc, context_module = :Main)
end

function bootstrap_worker!(worker::WorkerHandle, cfg::RunnerConfig)
    bootstrap = bootstrap_script_path(cfg)
    package_name = package_name_from_project(cfg)
    using_expr = package_name === nothing ? nothing : Expr(:using, Expr(:., Symbol(package_name)))
    expr = quote
        cd($(cfg.pkgroot))
        runtime = $(worker_runtime_setup_expr())
        Core.eval(runtime, $(QuoteNode(activation_expr(cfg))))
        Core.eval(runtime, $(QuoteNode(revise_expr(cfg))))
        if $(cfg.preload_package) && $(using_expr !== nothing)
            Base.eval(Main, $using_expr)
        end
        if $(bootstrap !== nothing)
            Base.include(Main, $bootstrap)
        end
        Base.eval(Main, :(using Test))
        if $(cfg.preload_package) && $(using_expr !== nothing)
            Base.eval(Main, $using_expr)
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

function execution_plan_for_job(cfg::RunnerConfig, job::TestJob)
    job.plan !== nothing && return job.plan
    return ExecutionPlan(
        entryfile = job.path,
        run_all = true,
        label = result_path(cfg, job.path),
    )
end

function revise_runtime!(runtime::Module)
    isdefined(runtime, :Revise) || return nothing
    runtime.Revise.revise()
    return nothing
end

function execute_plan_in_runtime(plan::ExecutionPlan, runtime::Module; topmodule::Module = Main)
    started = time()
    try
        revise_runtime!(runtime)
    catch err
        status, summary, stacktrace = classify_exception(err, catch_backtrace())
        return TestResult(
            path = plan.label,
            status = status,
            elapsed = time() - started,
            stdout = "",
            stderr = "",
            exception_summary = summary,
            stacktrace = stacktrace,
        )
    end

    return execute_plan(plan; topmodule = topmodule)
end

function run_test_in_worker!(worker::WorkerHandle, job::TestJob, cfg::RunnerConfig)
    worker.state = :running
    plan = execution_plan_for_job(cfg, job)
    runtime_name = QuoteNode(WORKER_RUNTIME_MODULE)
    try
        payload = Malt.remote_eval_fetch(worker.proc, quote
            let
                runtime = getfield(Main, $runtime_name)
                result = runtime.WarmTestRunner.execute_plan_in_runtime($plan, runtime; topmodule = Main)
                (
                    path = result.path,
                    status = result.status,
                    elapsed = result.elapsed,
                    stdout = result.stdout,
                    stderr = result.stderr,
                    exception_summary = result.exception_summary,
                    stacktrace = result.stacktrace,
                    diagnostics = result.diagnostics,
                )
            end
        end)

        worker.state = :idle
        worker.runs_completed += 1
        return TestResult(
            path = payload.path,
            status = payload.status,
            elapsed = payload.elapsed,
            stdout = payload.stdout,
            stderr = payload.stderr,
            exception_summary = payload.exception_summary,
            stacktrace = payload.stacktrace,
            worker_id = worker.id,
            diagnostics = payload.diagnostics,
        )
    catch err
        worker.state = :crashed
        return TestResult(
            path = plan.label,
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
