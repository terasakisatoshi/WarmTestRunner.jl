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
include("watch.jl")

export RunnerConfig, RunSummary, ServerHandle, ServerStatus, TestJob, TestResult, WorkerHandle
export bootstrap_worker!, capture_test_output, discover_tests, parse_warmtest_tags
export build_jobs, run_jobs_inline, run_test_file_in_module, run_test_in_worker!, schedule_jobs!, start_worker, start_worker_pool, status, stop, stop_worker!, stop_worker_pool!, summarize_results
export summary_to_json, summary_to_json_data
export delete_server_record!, load_server_record, registry_root, serve_forever, write_server_record!
export serve, run
export watch

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

function ensure_protocol_controller!(pkgroot::AbstractString, minimum_protocol_version::Int)
    record = live_record_or_nothing(pkgroot)
    record === nothing && return nothing
    record.protocol_version >= minimum_protocol_version && return nothing
    stop(pkgroot = pkgroot)
    wait_for_record_gone(pkgroot)
    return nothing
end

function ensure_changed_only_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, CHANGED_ONLY_PROTOCOL_VERSION)
end

function ensure_rerun_failed_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, RERUN_FAILED_PROTOCOL_VERSION)
end

function ensure_fresh_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, FRESH_RUN_PROTOCOL_VERSION)
end

function ensure_retry_crashed_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, RETRY_CRASHED_PROTOCOL_VERSION)
end

function validate_output_format(output_format::Symbol)
    output_format in (:text, :json) && return output_format
    throw(ArgumentError("output_format must be :text or :json"))
end

function run(; tests = String[], quickfail::Bool = false, changed_only::Bool = false, rerun_failed::Bool = false, fresh::Bool = false, retry_crashed::Bool = true, output_format::Symbol = :text, kwargs...)
    validate_output_format(output_format)
    !isempty(tests) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))
    cfg = make_config(; kwargs...)
    changed_only && ensure_changed_only_controller!(cfg.pkgroot)
    rerun_failed && ensure_rerun_failed_controller!(cfg.pkgroot)
    fresh && ensure_fresh_controller!(cfg.pkgroot)
    !retry_crashed && ensure_retry_crashed_controller!(cfg.pkgroot)
    serve(; kwargs...)
    summary = client_request(
        cfg.pkgroot,
        (
            cmd = :run,
            tests = String.(tests),
            quickfail = quickfail,
            changed_only = changed_only,
            rerun_failed = rerun_failed,
            fresh = fresh,
            retry_crashed = retry_crashed,
        ),
    )
    output_format == :json && return summary_to_json(summary)
    return summary
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
