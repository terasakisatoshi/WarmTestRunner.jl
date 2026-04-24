# Execution planning and backend-independent execution data live here.

function suite_entry_file(pkgroot::AbstractString)
    entry = joinpath(pkgroot, "test", "runtests.jl")
    return isfile(entry) ? entry : nothing
end

function normalize_test_file(cfg::RunnerConfig, name::AbstractString)
    path = job_path_from_test_name(cfg, name)
    isfile(path) && return abspath(path)
    throw(ArgumentError("selected test file $(repr(name)) does not exist under $(joinpath(cfg.pkgroot, "test"))"))
end

function reachable_file_map(entryfile::AbstractString)
    files = static_included_files(entryfile)
    map = Dict{String,String}()
    for file in files
        absolute = abspath(file)
        map[absolute] = absolute
        map[basename(file)] = absolute
        rel = relpath(file, dirname(entryfile))
        map[normpath(rel)] = absolute
        map[normpath(joinpath(basename(dirname(entryfile)), rel))] = absolute
    end
    return map
end

function selected_file_from_map(map::Dict{String,String}, cfg::RunnerConfig, name::AbstractString, entryfile::AbstractString)
    candidates = String[
        String(name),
        normpath(String(name)),
        normpath(joinpath("test", String(name))),
        basename(String(name)),
    ]
    absolute = abspath(job_path_from_test_name(cfg, name))
    push!(candidates, absolute)
    for candidate in candidates
        if haskey(map, candidate)
            return map[candidate]
        end
    end
    throw(ArgumentError("selected test file $(repr(name)) is not reachable from $(relpath(entryfile, cfg.pkgroot))"))
end

function push_selection!(selections::Vector{TestSelection}, selection::TestSelection)
    file = abspath(selection.file)
    index = findfirst(existing -> abspath(existing.file) == file, selections)
    if index === nothing
        push!(selections, selection)
        return selections
    end

    existing = selections[index]
    run_all = existing.run_all || selection.run_all
    patterns = run_all ? Any[] : Any[existing.patterns...; selection.patterns...]
    filter_lines = if existing.filter_lines === nothing
        selection.filter_lines
    elseif selection.filter_lines === nothing
        existing.filter_lines
    else
        union(existing.filter_lines, selection.filter_lines)
    end
    selections[index] = TestSelection(
        file = existing.file,
        patterns = patterns,
        filter_lines = filter_lines,
        run_all = run_all,
    )
    return selections
end

function build_execution_plans(
    cfg::RunnerConfig;
    tests::AbstractVector{<:AbstractString} = String[],
    testsets::AbstractVector = Any[],
    line_patterns::AbstractVector = Pair{String,Any}[],
    expression_patterns::AbstractVector = Pair{String,Any}[],
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    last_failed::AbstractVector{<:AbstractString} = String[],
)
    !isempty(tests) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))

    entry = suite_entry_file(cfg.pkgroot)
    if entry === nothing
        jobs = build_jobs(cfg; tests, changed_only, rerun_failed, last_failed)
        return [
            ExecutionPlan(
                entryfile = job.path,
                selections = [TestSelection(file = job.path, run_all = true)],
                label = result_path(cfg, job.path),
            )
            for job in jobs
        ]
    end

    selected_tests = String.(tests)
    if rerun_failed
        selected_tests = isempty(tests) ? String.(last_failed) : [path for path in tests if path in last_failed]
    elseif changed_only
        selected_tests = [result_path(cfg, job.path) for job in discover_changed_tests(cfg.pkgroot)]
    end

    if isempty(selected_tests) && isempty(testsets) && isempty(line_patterns) && isempty(expression_patterns)
        return [ExecutionPlan(entryfile = entry, run_all = true, label = "test/runtests.jl")]
    end

    reachability = reachable_file_map(entry)
    selections = TestSelection[]
    for name in selected_tests
        file = selected_file_from_map(reachability, cfg, name, entry)
        push_selection!(selections, TestSelection(file = file, run_all = true))
    end
    for pattern in testsets
        push_selection!(selections, TestSelection(file = abspath(entry), patterns = Any[pattern]))
    end
    for pair in line_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        lines = last(pair)
        line_set = lines isa Integer ? Set([Int(lines)]) : Set(Int.(collect(lines)))
        push_selection!(selections, TestSelection(file = file, patterns = Any[lines], filter_lines = line_set))
    end
    for pair in expression_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        push_selection!(selections, TestSelection(file = file, patterns = Any[last(pair)]))
    end
    return [ExecutionPlan(entryfile = entry, selections = selections, label = "test/runtests.jl")]
end
