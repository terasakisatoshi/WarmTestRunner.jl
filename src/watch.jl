using FileWatching

function _validate_debounce_seconds(debounce_seconds)
    debounce_seconds > 0 || throw(ArgumentError("debounce_seconds must be positive"))
    return Float64(debounce_seconds)
end

function resolve_watch_paths(pkgroot::AbstractString, paths)
    root = abspath(pkgroot)
    resolved = String[]
    for path in paths
        candidate = isabspath(path) ? abspath(path) : abspath(joinpath(root, path))
        if isfile(candidate)
            push!(resolved, candidate)
        elseif isdir(candidate)
            for (dir, _, _) in walkdir(candidate)
                push!(resolved, dir)
            end
        end
    end
    return sort!(unique(resolved))
end

function _watch_path(path::AbstractString)
    if isdir(path)
        FileWatching.watch_folder(path)
    else
        FileWatching.watch_file(path)
    end
    return abspath(path)
end

function _watch_once(paths; debounce_seconds = 0.5)
    delay = _validate_debounce_seconds(debounce_seconds)
    isempty(paths) && throw(ArgumentError("paths must not be empty"))

    notifications = Channel{String}(max(length(paths), 1))
    tasks = Task[]
    for path in paths
        task = @async begin
            try
                put!(notifications, _watch_path(path))
            catch err
                err isa InterruptException || rethrow()
            end
        end
        push!(tasks, task)
    end

    changed = take!(notifications)
    for task in tasks
        istaskdone(task) || Base.throwto(task, InterruptException())
    end
    sleep(delay)
    return changed
end

function _run_watch_iteration(pkgroot::AbstractString; changed_only::Bool = true, kwargs...)
    return runtests(; pkgroot = pkgroot, changed_only = changed_only, kwargs...)
end

function watch(; paths = ["src", "test"], debounce_seconds = 0.5, changed_only::Bool = true, pkgroot::AbstractString = pwd(), kwargs...)
    delay = _validate_debounce_seconds(debounce_seconds)
    resolved = resolve_watch_paths(pkgroot, paths)
    isempty(resolved) && throw(ArgumentError("no existing paths to watch"))

    while true
        _watch_once(resolved; debounce_seconds = delay)
        _run_watch_iteration(pkgroot; changed_only = changed_only, kwargs...)
    end
end
