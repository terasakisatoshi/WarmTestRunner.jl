module WarmTestRunner

using TOML
using Test

include("types.jl")
include("config.jl")
include("discovery.jl")
include("results.jl")
include("sandbox.jl")
include("worker.jl")
include("server_registry.jl")
include("controller.jl")

export RunnerConfig, RunSummary, ServerHandle, ServerStatus, TestJob, TestResult, WorkerHandle
export bootstrap_worker!, capture_test_output, discover_tests, parse_warmtest_tags
export build_jobs, run_jobs_inline, run_test_file_in_module, run_test_in_worker!, schedule_jobs!, start_worker, start_worker_pool, status, stop, stop_worker!, stop_worker_pool!, summarize_results
export delete_server_record!, load_server_record, registry_root, serve_forever, write_server_record!
export serve, run

function live_record_or_nothing(pkgroot::AbstractString)
    record = load_server_record(pkgroot)
    record === nothing && return nothing

    try
        client_request(pkgroot, (cmd = :status,))
        return record
    catch
        delete_server_record!(pkgroot)
        return nothing
    end
end

function serve(; kwargs...)
    cfg = make_config(; kwargs...)
    record = live_record_or_nothing(cfg.pkgroot)
    record !== nothing && validate_reuse_configuration(record, kwargs)
    record !== nothing && return record.handle
    return launch_controller(cfg)
end

function run(; tests = String[], quickfail::Bool = false, changed_only::Bool = false, kwargs...)
    !isempty(tests) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    cfg = make_config(; kwargs...)
    serve(; kwargs...)
    return client_request(
        cfg.pkgroot,
        (
            cmd = :run,
            tests = String.(tests),
            quickfail = quickfail,
            changed_only = changed_only,
        ),
    )
end

function stop(; pkgroot::AbstractString = pwd())
    record = load_server_record(pkgroot)
    record === nothing && return :ok

    try
        return client_request(pkgroot, (cmd = :stop,))
    catch
        delete_server_record!(pkgroot)
        return :ok
    end
end

function status(; pkgroot::AbstractString = pwd())
    record = live_record_or_nothing(pkgroot)
    record === nothing && return ServerStatus(pkgroot = abspath(pkgroot), state = :stopped)
    return client_request(pkgroot, (cmd = :status,))
end

end # module WarmTestRunner
