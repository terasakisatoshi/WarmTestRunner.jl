Base.@kwdef struct RunnerConfig
    pkgroot::String = pwd()
    tool_project::String = abspath(joinpath(@__DIR__, ".."))
    jobs::Int = 1
    threads_per_worker::Int = 1
    use_testenv::Bool = true
    use_revise::Bool = false
    preload_package::Bool = true
    startup_file::Bool = false
    color::Bool = true
    worker_timeout::Float64 = 60.0
    log_level::Symbol = :info
end

function make_config(; kwargs...)
    cfg = RunnerConfig(; kwargs...)
    cfg.jobs > 0 || throw(ArgumentError("jobs must be positive"))
    cfg.threads_per_worker > 0 || throw(ArgumentError("threads_per_worker must be positive"))
    cfg.color || throw(ArgumentError("color=false is not implemented yet"))
    cfg.worker_timeout == 60.0 || throw(ArgumentError("worker_timeout is not implemented yet"))
    cfg.log_level == :info || throw(ArgumentError("log_level=$(cfg.log_level) is not implemented yet"))
    return cfg
end
