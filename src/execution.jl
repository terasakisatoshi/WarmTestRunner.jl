# Execution planning and backend-independent execution data live here.

function suite_entry_file(pkgroot::AbstractString)
    entry = joinpath(pkgroot, "test", "runtests.jl")
    return isfile(entry) ? entry : nothing
end

function reachable_file_map(entryfile::AbstractString)
    files = static_included_files(entryfile)
    return selectable_file_map(files, dirname(entryfile))
end

function selectable_file_map(files::AbstractVector{<:AbstractString}, base_dir::AbstractString)
    map = Dict{String,Vector{String}}()
    add_mapping!(key::AbstractString, value::AbstractString) = push!(get!(map, String(key), String[]), String(value))
    for file in files
        absolute = abspath(file)
        add_mapping!(absolute, absolute)
        add_mapping!(basename(file), absolute)
        rel = relpath(file, base_dir)
        add_mapping!(normpath(rel), absolute)
        add_mapping!(normpath(joinpath(basename(base_dir), rel)), absolute)
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

function all_reachable_files(map::Dict{String,Vector{String}})
    files = String[]
    seen = Set{String}()
    for matches in values(map)
        for file in matches
            file in seen && continue
            push!(seen, file)
            push!(files, file)
        end
    end
    sort!(files)
    return files
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

function merged_selections(selections::Vector{TestSelection})
    merged = TestSelection[]
    for selection in selections
        push_selection!(merged, selection)
    end
    return merged
end

function plan_selection_groups(selections::Vector{TestSelection})
    filtered_files = Set(abspath(selection.file) for selection in selections if selection.filter_lines !== nothing)
    unfiltered_pattern_files = Set(
        abspath(selection.file) for selection in selections
        if selection.filter_lines === nothing && !selection.run_all && !isempty(selection.patterns)
    )
    if isempty(intersect(filtered_files, unfiltered_pattern_files))
        return [merged_selections(selections)]
    end

    unfiltered = TestSelection[]
    filtered = TestSelection[]
    for selection in selections
        push!(selection.filter_lines === nothing ? unfiltered : filtered, selection)
    end

    groups = Vector{TestSelection}[]
    isempty(unfiltered) || push!(groups, merged_selections(unfiltered))
    isempty(filtered) || push!(groups, merged_selections(filtered))
    return groups
end

function push_line_pattern!(patterns::Vector{Any}, filter_lines::Set{Int}, line::Integer)
    line >= 1 || throw(ArgumentError("line selections must be positive source line numbers; got $(repr(line))"))
    normalized = Int(line)
    push!(patterns, normalized)
    push!(filter_lines, normalized)
    return nothing
end

function push_line_pattern!(patterns::Vector{Any}, filter_lines::Set{Int}, range::UnitRange{<:Integer})
    isempty(range) && throw(ArgumentError("line selection must not be empty"))
    for line in range
        line >= 1 || throw(ArgumentError("line selections must be positive source line numbers; got $(repr(line)) in $(repr(range))"))
    end
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

function assert_nonempty_selector(name::Symbol, selector)
    selector === nothing && return nothing
    isempty(selector) && throw(ArgumentError("$(name) selection must not be empty"))
    return nothing
end

function testset_macro_name(@nospecialize(expr))
    Meta.isexpr(expr, :macrocall) || return nothing
    isempty(expr.args) && return nothing
    macro_name = first(expr.args)
    macro_name == Symbol("@testset") && return macro_name
    macro_name isa GlobalRef && macro_name.name == Symbol("@testset") && return macro_name
    return nothing
end

function top_level_testset_expr(@nospecialize(expr))
    testset_macro_name(expr) !== nothing && return true
    Meta.isexpr(expr, :block) || return false
    return any(arg -> top_level_testset_expr(arg), expr.args)
end

function execution_matches_named_testset(pattern, @nospecialize(expr))
    testset_macro_name(expr) === nothing && return false
    for arg in expr.args
        arg isa AbstractString || continue
        return pattern isa Regex ? occursin(pattern, String(arg)) : pattern == arg
    end
    return false
end

function expr_contains_named_testset(pattern, @nospecialize(expr))
    execution_matches_named_testset(pattern, expr) && return true
    expr isa Expr || return false
    is_nonexecuted_static_include_container(expr) && return false
    return any(arg -> expr_contains_named_testset(pattern, arg), expr.args)
end

function file_contains_top_level_testset_pattern(file::AbstractString, pattern)
    isfile(file) || return false
    stream = JS.ParseStream(read(file, String))
    JS.parse!(stream; rule = :all)
    isempty(stream.diagnostics) || return false
    top = JS.build_tree(JS.SyntaxNode, stream; filename = file)
    for index in 1:JS.numchildren(top)
        node = top[index]
        expr = try
            Expr(node)
        catch
            continue
        end
        top_level_testset_expr(expr) || continue
        expr_contains_named_testset(pattern, expr) && return true
    end
    return false
end

function files_for_testset_pattern(files::AbstractVector{<:AbstractString}, pattern)
    matches = String[]
    for file in files
        file_contains_top_level_testset_pattern(file, pattern) || continue
        push!(matches, String(file))
    end
    isempty(matches) && throw(ArgumentError("selected testset $(repr(pattern)) is not reachable from test/runtests.jl"))
    return matches
end

function build_file_entry_plans(
    cfg::RunnerConfig,
    selected_test_names::Vector{String},
    selected_testsets::Vector{Any},
    selected_line_patterns,
    selected_expression_patterns;
    changed_only::Bool,
    rerun_failed::Bool,
    last_failed::AbstractVector{<:AbstractString},
)
    jobs = discover_tests(cfg.pkgroot)
    files = String[abspath(job.path) for job in jobs]
    testdir = joinpath(cfg.pkgroot, "test")
    filemap = selectable_file_map(files, testdir)

    selected_tests = selected_test_names
    if rerun_failed
        failed_files = isempty(last_failed) ? String[] : selected_files_from_names(filemap, cfg, String.(last_failed), testdir)
        if isempty(selected_test_names)
            selected_tests = collect(failed_files)
        else
            explicit_files = selected_files_from_names(filemap, cfg, selected_test_names, testdir)
            selected_tests = [file for file in explicit_files if file in failed_files]
        end
    elseif changed_only
        selected_tests = [abspath(job.path) for job in discover_changed_tests(cfg.pkgroot)]
    end

    if isempty(selected_tests) && isempty(selected_testsets) && isempty(selected_line_patterns) && isempty(selected_expression_patterns)
        (changed_only || rerun_failed) && return ExecutionPlan[]
        selected_tests = files
    end

    selections = TestSelection[]
    for name in selected_tests
        file = selected_file_from_map(filemap, cfg, name, testdir)
        push!(selections, TestSelection(file = file, run_all = true))
    end
    for pattern in selected_testsets
        for file in files_for_testset_pattern(files, pattern)
            push!(selections, TestSelection(file = file, patterns = Any[pattern]))
        end
    end
    for pair in selected_line_patterns
        file = selected_file_from_map(filemap, cfg, first(pair), testdir)
        selection_patterns = line_patterns_for_selection(last(pair))
        push!(selections, TestSelection(file = file, patterns = selection_patterns.patterns, filter_lines = selection_patterns.filter_lines))
    end
    for pair in selected_expression_patterns
        file = selected_file_from_map(filemap, cfg, first(pair), testdir)
        push!(selections, TestSelection(file = file, patterns = Any[last(pair)]))
    end
    if (changed_only || rerun_failed) && isempty(selected_tests)
        return ExecutionPlan[]
    end

    plans = ExecutionPlan[]
    for group in plan_selection_groups(selections)
        for selection in group
            push!(
                plans,
                ExecutionPlan(
                    entryfile = selection.file,
                    selections = [selection],
                    label = result_path(cfg, selection.file),
                ),
            )
        end
    end
    return plans
end

function build_execution_plans(
    cfg::RunnerConfig;
    tests::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    testsets::Union{Nothing,AbstractVector} = nothing,
    line_patterns::Union{Nothing,AbstractVector} = nothing,
    expression_patterns::Union{Nothing,AbstractVector} = nothing,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    last_failed::AbstractVector{<:AbstractString} = String[],
)
    assert_nonempty_selector(:tests, tests)
    assert_nonempty_selector(:testsets, testsets)
    assert_nonempty_selector(:line_patterns, line_patterns)
    assert_nonempty_selector(:expression_patterns, expression_patterns)

    selected_test_names = tests === nothing ? String[] : String.(tests)
    selected_testsets = testsets === nothing ? Any[] : Any[testsets...]
    selected_line_patterns = line_patterns === nothing ? Pair{String,Any}[] : line_patterns
    selected_expression_patterns = expression_patterns === nothing ? Pair{String,Any}[] : expression_patterns

    !isempty(selected_test_names) && changed_only && throw(ArgumentError("changed_only cannot be combined with explicit tests"))
    changed_only && rerun_failed && throw(ArgumentError("changed_only cannot be combined with rerun_failed"))

    entry = suite_entry_file(cfg.pkgroot)
    if entry === nothing
        return build_file_entry_plans(
            cfg,
            selected_test_names,
            selected_testsets,
            selected_line_patterns,
            selected_expression_patterns;
            changed_only,
            rerun_failed,
            last_failed,
        )
    end

    reachability = reachable_file_map(entry)
    selected_tests = selected_test_names
    if rerun_failed
        failed_files = Set(selected_files_from_names(reachability, cfg, String.(last_failed), entry))
        if isempty(selected_test_names)
            selected_tests = collect(failed_files)
        else
            explicit_files = selected_files_from_names(reachability, cfg, selected_test_names, entry)
            selected_tests = [file for file in explicit_files if file in failed_files]
        end
    elseif changed_only
        selected_tests = [result_path(cfg, job.path) for job in discover_changed_tests(cfg.pkgroot)]
    end

    if isempty(selected_tests) && isempty(selected_testsets) && isempty(selected_line_patterns) && isempty(selected_expression_patterns)
        (changed_only || rerun_failed) && return ExecutionPlan[]
        return [ExecutionPlan(entryfile = entry, run_all = true, label = "test/runtests.jl")]
    end

    selections = TestSelection[]
    for name in selected_tests
        file = selected_file_from_map(reachability, cfg, name, entry)
        push!(selections, TestSelection(file = file, run_all = true))
    end
    reachable_files = all_reachable_files(reachability)
    for pattern in selected_testsets
        for file in files_for_testset_pattern(reachable_files, pattern)
            push!(selections, TestSelection(file = file, patterns = Any[pattern]))
        end
    end
    for pair in selected_line_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        lines = last(pair)
        selection_patterns = line_patterns_for_selection(lines)
        push!(selections, TestSelection(file = file, patterns = selection_patterns.patterns, filter_lines = selection_patterns.filter_lines))
    end
    for pair in selected_expression_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        push!(selections, TestSelection(file = file, patterns = Any[last(pair)]))
    end
    if (changed_only || rerun_failed) && isempty(selected_tests)
        return ExecutionPlan[]
    end
    return [
        ExecutionPlan(entryfile = entry, selections = group, label = "test/runtests.jl")
        for group in plan_selection_groups(selections)
    ]
end
