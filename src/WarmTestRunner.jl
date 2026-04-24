module WarmTestRunner

using TOML
using Test

include("types.jl")
include("config.jl")
include("discovery.jl")
include("execution.jl")
include("virtual_execution.jl")
include("results.jl")
include("sandbox.jl")
include("worker.jl")
include("server_registry.jl")
include("controller.jl")
include("watch.jl")

export run, serve, status, stop, watch

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

function ensure_execution_plans_controller!(pkgroot::AbstractString)
    return ensure_protocol_controller!(pkgroot, EXECUTION_PLANS_PROTOCOL_VERSION)
end

function validate_output_format(output_format::Symbol)
    output_format in (:text, :json) && return output_format
    throw(ArgumentError("output_format must be :text or :json"))
end

function run(;
    tests = nothing,
    testsets = nothing,
    line_patterns = nothing,
    expression_patterns = nothing,
    quickfail::Bool = false,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    fresh::Bool = false,
    retry_crashed::Bool = true,
    output_format::Symbol = :text,
    kwargs...,
)
    validate_output_format(output_format)
    tests_provided = tests !== nothing && !isempty(tests)
    tests_provided && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))
    cfg = make_config(; kwargs...)
    ensure_execution_plans_controller!(cfg.pkgroot)
    changed_only && ensure_changed_only_controller!(cfg.pkgroot)
    rerun_failed && ensure_rerun_failed_controller!(cfg.pkgroot)
    fresh && ensure_fresh_controller!(cfg.pkgroot)
    !retry_crashed && ensure_retry_crashed_controller!(cfg.pkgroot)
    serve(; kwargs...)
    summary = client_request(
        cfg.pkgroot,
        (
            cmd = :run,
            tests = tests,
            testsets = testsets,
            line_patterns = line_patterns,
            expression_patterns = expression_patterns,
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
