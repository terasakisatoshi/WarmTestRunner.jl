# Execution planning and backend-independent execution data live here.

function suite_entry_file(pkgroot::AbstractString)
    entry = joinpath(pkgroot, "test", "runtests.jl")
    return isfile(entry) ? entry : nothing
end

function reachable_file_map(entryfile::AbstractString)
    files = static_included_files(entryfile)
    map = Dict{String,Vector{String}}()
    add_mapping!(key::AbstractString, value::AbstractString) = push!(get!(map, String(key), String[]), String(value))
    for file in files
        absolute = abspath(file)
        add_mapping!(absolute, absolute)
        add_mapping!(basename(file), absolute)
        rel = relpath(file, dirname(entryfile))
        add_mapping!(normpath(rel), absolute)
        add_mapping!(normpath(joinpath(basename(dirname(entryfile)), rel)), absolute)
    end
    for values in values(map)
        unique!(values)
    end
    return map
end

function has_path_separator(path::AbstractString)
    return occursin("/", path) || occursin("\\", path)
end

function selected_file_from_map(map::Dict{String,Vector{String}}, cfg::RunnerConfig, name::AbstractString, entryfile::AbstractString)
    raw = String(name)
    path_qualified = isabspath(raw) || has_path_separator(raw)
    candidates = String[raw, normpath(raw)]
    path_qualified || push!(candidates, basename(raw))
    startswith(normpath(raw), "test$(Base.Filesystem.path_separator)") || push!(candidates, normpath(joinpath("test", raw)))
    absolute = abspath(job_path_from_test_name(cfg, name))
    push!(candidates, absolute)
    for candidate in unique(candidates)
        if haskey(map, candidate)
            matches = map[candidate]
            length(matches) == 1 && return only(matches)
            throw(ArgumentError("selected test file $(repr(name)) is ambiguous; use a path relative to $(joinpath("test"))"))
        end
    end
    throw(ArgumentError("selected test file $(repr(name)) is not reachable from $(relpath(entryfile, cfg.pkgroot))"))
end

function selected_files_from_names(map::Dict{String,Vector{String}}, cfg::RunnerConfig, names::AbstractVector{<:AbstractString}, entryfile::AbstractString)
    return [selected_file_from_map(map, cfg, name, entryfile) for name in names]
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

function push_line_pattern!(patterns::Vector{Any}, filter_lines::Set{Int}, line::Integer)
    normalized = Int(line)
    push!(patterns, normalized)
    push!(filter_lines, normalized)
    return nothing
end

function push_line_pattern!(patterns::Vector{Any}, filter_lines::Set{Int}, range::UnitRange{<:Integer})
    isempty(range) && throw(ArgumentError("line selection must not be empty"))
    push!(patterns, range)
    union!(filter_lines, Int.(range))
    return nothing
end

function push_line_pattern!(patterns::Vector{Any}, filter_lines::Set{Int}, @nospecialize(line))
    throw(ArgumentError("line selections must be integers, ranges, or collections of integers/ranges; got $(repr(line))"))
end

function line_patterns_for_selection(lines)
    patterns = Any[]
    filter_lines = Set{Int}()
    if lines isa Integer || lines isa UnitRange{<:Integer}
        push_line_pattern!(patterns, filter_lines, lines)
    else
        applicable(iterate, lines) || throw(ArgumentError("line selections must be integers, ranges, or collections of integers/ranges; got $(repr(lines))"))
        for line in lines
            push_line_pattern!(patterns, filter_lines, line)
        end
    end
    isempty(filter_lines) && throw(ArgumentError("line selection must not be empty"))
    return (; patterns, filter_lines)
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

    reachability = reachable_file_map(entry)
    selected_tests = String.(tests)
    if rerun_failed
        failed_files = Set(selected_files_from_names(reachability, cfg, String.(last_failed), entry))
        if isempty(tests)
            selected_tests = collect(failed_files)
        else
            explicit_files = selected_files_from_names(reachability, cfg, tests, entry)
            selected_tests = [file for file in explicit_files if file in failed_files]
        end
    elseif changed_only
        selected_tests = [result_path(cfg, job.path) for job in discover_changed_tests(cfg.pkgroot)]
    end

    if (changed_only || rerun_failed) && isempty(selected_tests)
        return ExecutionPlan[]
    end

    if isempty(selected_tests) && isempty(testsets) && isempty(line_patterns) && isempty(expression_patterns)
        return [ExecutionPlan(entryfile = entry, run_all = true, label = "test/runtests.jl")]
    end

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
        selection_patterns = line_patterns_for_selection(lines)
        push_selection!(selections, TestSelection(file = file, patterns = selection_patterns.patterns, filter_lines = selection_patterns.filter_lines))
    end
    for pair in expression_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        push_selection!(selections, TestSelection(file = file, patterns = Any[last(pair)]))
    end
    return [ExecutionPlan(entryfile = entry, selections = selections, label = "test/runtests.jl")]
end
