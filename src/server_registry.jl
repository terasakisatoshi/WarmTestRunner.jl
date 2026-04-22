using UUIDs

const REGISTRY_NAMESPACE = UUID("e9f6f42a-70d3-49ec-bdbd-e7d5bf5a3ca9")
const SERVER_PROTOCOL_VERSION = 2
const CHANGED_ONLY_PROTOCOL_VERSION = 2

registry_root() = joinpath(get(ENV, "WARMTESTRUNNER_HOME", joinpath(homedir(), ".julia", "warmtestrunner")), "servers")

server_record_path(pkgroot::AbstractString) = joinpath(
    registry_root(),
    string(uuid5(REGISTRY_NAMESPACE, abspath(pkgroot))) * ".toml",
)

function write_server_record!(handle::ServerHandle, status::ServerStatus; port::Integer)
    mkpath(registry_root())
    data = Dict{String, Any}(
        "protocol_version" => SERVER_PROTOCOL_VERSION,
        "server_id" => handle.server_id,
        "pid" => handle.pid,
        "pkgroot" => handle.pkgroot,
        "started_at" => handle.started_at,
        "jobs" => handle.jobs,
        "running_jobs" => status.running_jobs,
        "last_failed" => status.last_failed,
        "last_success_at" => something(status.last_success_at, 0.0),
        "state" => String(status.state),
        "port" => Int(port),
    )
    open(server_record_path(handle.pkgroot), "w") do io
        TOML.print(io, data)
    end
    return nothing
end

function load_server_record(pkgroot::AbstractString)
    path = server_record_path(pkgroot)
    isfile(path) || return nothing
    data = TOML.parsefile(path)
    protocol_version = Int(get(data, "protocol_version", 1))
    last_success_at = data["last_success_at"] == 0.0 ? nothing : Float64(data["last_success_at"])
    return (
        protocol_version = protocol_version,
        handle = ServerHandle(
            pkgroot = String(data["pkgroot"]),
            server_id = String(data["server_id"]),
            pid = Int(data["pid"]),
            started_at = Float64(data["started_at"]),
            jobs = Int(data["jobs"]),
        ),
        status = ServerStatus(
            server_id = String(data["server_id"]),
            pid = Int(data["pid"]),
            pkgroot = String(data["pkgroot"]),
            started_at = Float64(data["started_at"]),
            jobs = Int(data["jobs"]),
            running_jobs = Int(data["running_jobs"]),
            last_failed = String.(data["last_failed"]),
            last_success_at = last_success_at,
            state = Symbol(data["state"]),
        ),
        port = Int(data["port"]),
    )
end

function delete_server_record!(pkgroot::AbstractString)
    path = server_record_path(pkgroot)
    isfile(path) && rm(path)
    return nothing
end
