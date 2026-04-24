Base.@kwdef struct RunnerConfig
    pkgroot::String = pwd()
    tool_project::String = abspath(joinpath(@__DIR__, ".."))
    jobs::Int = 1
    threads_per_worker::Int = 1
    use_testenv::Bool = true
    use_revise::Bool = true
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

function job_path_from_test_name(cfg::RunnerConfig, name::AbstractString)
    return normpath(isabspath(name) ? String(name) : joinpath(cfg.pkgroot, "test", name))
end

function job_path_from_recorded_result(cfg::RunnerConfig, path::AbstractString)
    isabspath(path) && return normpath(path)

    pkgroot_relative = normpath(joinpath(cfg.pkgroot, path))
    isfile(pkgroot_relative) && return pkgroot_relative

    return normpath(joinpath(cfg.pkgroot, "test", path))
end

function result_path(cfg::RunnerConfig, path::AbstractString)
    absolute_path = normpath(isabspath(path) ? String(path) : joinpath(cfg.pkgroot, path))
    relative_path = relpath(absolute_path, cfg.pkgroot)
    parts = splitpath(relative_path)
    return !isempty(parts) && first(parts) == ".." ? absolute_path : relative_path
end
