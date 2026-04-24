const WARMTEST_TAG_SCAN_LINES = 5
const WARMTEST_DIRECTIVE_PREFIX = "# warmtest:"
const WARMTEST_EXCLUDED_TEST_FILES = Set(["runtests.jl", "warmtest_bootstrap.jl"])

function parse_warmtest_tag_line(line::AbstractString)
    startswith(line, WARMTEST_DIRECTIVE_PREFIX) || return String[]
    matchobj = match(r"tags\s*=\s*(.*)$", line)
    matchobj === nothing && return String[]
    return [strip(tag) for tag in split(matchobj.captures[1], ",") if !isempty(strip(tag))]
end

function parse_warmtest_tags(path::AbstractString)
    isfile(path) || return String[]
    return open(path, "r") do io
        # Only the first few lines are scanned so the directive stays a small header comment.
        for _ in 1:WARMTEST_TAG_SCAN_LINES
            eof(io) && break
            line = strip(readline(io))
            tags = parse_warmtest_tag_line(line)
            isempty(tags) || return tags
        end
        return String[]
    end
end

function discover_tests(pkgroot::AbstractString)
    testdir = joinpath(pkgroot, "test")
    isdir(testdir) || return TestJob[]

    paths = String[]
    for (root, _, files) in walkdir(testdir)
        for file in files
            endswith(file, ".jl") || continue
            path = joinpath(root, file)
            basename(path) in WARMTEST_EXCLUDED_TEST_FILES && continue
            push!(paths, path)
        end
    end

    sort!(paths)
    return [
        TestJob(path = path, name = basename(path), tags = parse_warmtest_tags(path))
        for path in paths
    ]
end

function git_output_lines(cmd::Cmd)
    try
        text = readchomp(pipeline(cmd, stderr = devnull))
        isempty(text) && return String[]
        return split(text, '\n')
    catch
        return nothing
    end
end

function path_starts_with_component(path::AbstractString, component::AbstractString)
    parts = splitpath(normpath(path))
    return !isempty(parts) && first(parts) == component
end

function git_changed_paths(pkgroot::AbstractString)
    tracked = git_output_lines(`git -C $pkgroot diff --name-only HEAD --`)
    tracked === nothing && return nothing

    untracked = git_output_lines(`git -C $pkgroot ls-files --others --exclude-standard`)
    untracked === nothing && return nothing

    paths = Set{String}()
    for path in Iterators.flatten((tracked, untracked))
        isempty(path) && continue
        push!(paths, normpath(path))
    end
    return sort!(collect(paths))
end

function discover_changed_tests(pkgroot::AbstractString)
    discovered = discover_tests(pkgroot)
    changed = git_changed_paths(pkgroot)
    changed === nothing && return discovered
    any(path_starts_with_component(path, "src") for path in changed) && return discovered

    changed_tests = Set(
        path for path in changed
        if path_starts_with_component(path, "test") && endswith(path, ".jl")
    )

    return [
        job for job in discovered
        if normpath(relpath(job.path, pkgroot)) in changed_tests
    ]
end

function static_included_files(entryfile::AbstractString)
    entry = abspath(entryfile)
    seen = Set{String}()
    ordered = String[]

    function visit(path::String)
        path in seen && return
        push!(seen, path)
        push!(ordered, path)
        isfile(path) || return
        text = read(path, String)
        for matchobj in eachmatch(r"include\(\"([^\"]+)\"\)", text)
            child = normpath(joinpath(dirname(path), matchobj.captures[1]))
            visit(child)
        end
    end

    visit(entry)
    return ordered
end
