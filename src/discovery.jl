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
