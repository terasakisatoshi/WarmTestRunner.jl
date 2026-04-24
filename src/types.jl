Base.@kwdef struct ServerHandle
    pkgroot::String
    server_id::String
    pid::Int
    started_at::Float64
    jobs::Int
end

Base.@kwdef struct ServerStatus
    server_id::Union{Nothing, String} = nothing
    pid::Union{Nothing, Int} = nothing
    pkgroot::String = ""
    started_at::Union{Nothing, Float64} = nothing
    jobs::Int = 0
    running_jobs::Int = 0
    last_failed::Vector{String} = String[]
    last_success_at::Union{Nothing, Float64} = nothing
    state::Symbol = :stopped
end

Base.@kwdef struct TestDiagnosticRelated
    file::String
    line::Int
    message::String
end

Base.@kwdef struct TestDiagnostic
    file::String
    line::Int
    kind::Symbol
    message::String
    related::Vector{TestDiagnosticRelated} = TestDiagnosticRelated[]
end

Base.@kwdef struct TestSelection
    file::String
    patterns::Vector{Any} = Any[]
    filter_lines::Union{Nothing, Set{Int}} = nothing
    run_all::Bool = false
end

Base.@kwdef struct ExecutionPlan
    entryfile::String
    selections::Vector{TestSelection} = TestSelection[]
    run_all::Bool = false
    label::String = basename(entryfile)
end

Base.@kwdef struct TestJob
    path::String
    name::String = ""
    tags::Vector{String} = String[]
    est_seconds::Float64 = 0.0
    plan::Union{Nothing, ExecutionPlan} = nothing
end

Base.@kwdef struct TestResult
    path::String
    status::Symbol
    elapsed::Float64
    stdout::String = ""
    stderr::String = ""
    exception_summary::Union{Nothing, String} = nothing
    stacktrace::Union{Nothing, String} = nothing
    worker_id::Union{Nothing, Int} = nothing
    diagnostics::Vector{TestDiagnostic} = TestDiagnostic[]
end

Base.@kwdef mutable struct WorkerHandle
    id::Int
    proc::Any
    context_module::Symbol
    state::Symbol = :booting
    booted_at::Float64 = 0.0
    runs_completed::Int = 0
    dirty::Bool = false
end

Base.@kwdef struct RunSummary
    results::Vector{TestResult}
    passed::Int
    failed::Int
    errored::Int
    crashed::Int
    skipped::Int
    elapsed_total::Float64
end

function Base.show(io::IO, h::ServerHandle)
    print(io, "ServerHandle(pid=", h.pid, ", jobs=", h.jobs, ", ", h.server_id, ")")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", h::ServerHandle)
    println(io, "ServerHandle")
    println(io, "  pkgroot: ", h.pkgroot)
    println(io, "  pid:     ", h.pid)
    println(io, "  jobs:    ", h.jobs)
    print(io, "  id:      ", h.server_id)
    return nothing
end
