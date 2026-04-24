# Portions of this file are adapted from TestRunner.jl.
# TestRunner.jl copyright (c) 2025 Shuhei Kadowaki, MIT licensed.

using Core.IR
using Compiler: Compiler as CC
using JuliaInterpreter: JuliaInterpreter as JI
using LoweredCodeUtils: LoweredCodeUtils as LCU
using JuliaSyntax: JuliaSyntax as JS
using MacroTools: MacroTools

const BacktraceElm = Union{Ptr{Nothing},Base.InterpreterIP}
const ExceptionFrame = @NamedTuple{exception::Any,backtrace::Vector{BacktraceElm}}

const warmtest_errors_and_fails = IdDict{Any, Vector{Any}}()
const last_warmtest_testset_result = Ref{Union{Nothing,Test.DefaultTestSet}}(nothing)
const current_execution_diagnostics = Ref{Union{Nothing,Vector{TestDiagnostic}}}(nothing)

struct WarmTestInterpreter <: JI.Interpreter
    patterns::Dict{String,Vector{Any}}
    filter_lines::Dict{String,Set{Int}}
    run_all_files::Set{String}
    filename::String
    context::Module
    current_exceptions::Vector{ExceptionFrame}
end

function WarmTestInterpreter(
    interp::WarmTestInterpreter;
    patterns::Dict{String,Vector{Any}} = interp.patterns,
    filter_lines::Dict{String,Set{Int}} = interp.filter_lines,
    run_all_files::Set{String} = interp.run_all_files,
    filename::String = interp.filename,
    context::Module = interp.context,
    current_exceptions::Vector{ExceptionFrame} = interp.current_exceptions,
)
    return WarmTestInterpreter(patterns, filter_lines, run_all_files, filename, context, current_exceptions)
end

const current_warmtest_interpreter = Ref{Union{Nothing,WarmTestInterpreter}}(nothing)

struct WarmTestTestSet <: Test.AbstractTestSet
    dts::Test.DefaultTestSet
    function WarmTestTestSet(args...; options...)
        return new(Test.DefaultTestSet(args...; options...))
    end
end

struct WrappedString
    value::String
end
Base.show(io::IO, ws::WrappedString) = print(io, ws.value)

function Test.record(ts::WarmTestTestSet, @nospecialize res)
    interp = current_warmtest_interpreter[]
    if interp !== nothing && res isa Test.Threw
        (; exception, source) = res
        excs = copy(interp.current_exceptions)
        res = Test.Threw(exception, excs, source)
        warmtest_errors_and_fails[res] = excs
        empty!(interp.current_exceptions)
    elseif interp !== nothing && res isa Test.Error
        (; test_type, orig_expr, value, source) = res
        excs = copy(interp.current_exceptions)
        res = Test.Error(test_type, orig_expr, WrappedString(value), Base.ExceptionStack(excs), source)
        warmtest_errors_and_fails[res] = excs
        empty!(interp.current_exceptions)
    elseif res isa Test.Fail || res isa Test.Error
        warmtest_errors_and_fails[res] = Any[]
    end
    Test.record(ts.dts, res)
    return res
end

function Test.finish(ts::WarmTestTestSet)
    last_warmtest_testset_result[] = ts.dts
    if Test.get_testset_depth() != 0
        Test.record(Test.get_testset(), ts.dts)
    else
        Test.finish(ts.dts)
    end
    return ts.dts
end

const JULIAINTERPRETER_INTERPRET_FILE = let
    jlfile = pathof(JI)::String
    Symbol(normpath(jlfile, "..", "interpret.jl"))
end

function JI.handle_err(interp::WarmTestInterpreter, frame::JI.Frame, @nospecialize(err))
    excs = map(current_exceptions()) do exc
        ExceptionFrame((exc.exception, exc.backtrace))
    end
    append!(interp.current_exceptions, scrub_exc_stack(excs))
    return @invoke JI.handle_err(interp::JI.Interpreter, frame::JI.Frame, err::Any)
end

function scrub_backtrace(bt::Vector{BacktraceElm})
    runtest_idx = @something let
        findfirst(ip::BacktraceElm ->
            Test.ip_has_file_and_func(ip, @__FILE__, (:execute_plan,)), bt)
    end return bt
    internal_idx = @something let
        findfirst(ip::BacktraceElm ->
            Test.ip_has_file_and_func(ip, @__FILE__, (:evaluate_call!,)), bt)
    end let
        findfirst(ip::BacktraceElm ->
            Test.ip_has_file_and_func(ip, JULIAINTERPRETER_INTERPRET_FILE, (:step_expr!, :eval_rhs,)), bt)
    end return bt
    internal_idx < runtest_idx || return bt
    return append!(bt[1:internal_idx-1], bt[runtest_idx:end])
end

function scrub_exc_stack(excs::Vector{ExceptionFrame})
    return ExceptionFrame[ExceptionFrame((exc, scrub_backtrace(bt))) for (exc, bt) in excs]
end

function record_execution_diagnostic!(file::AbstractString, line::Integer, kind::Symbol, @nospecialize(err))
    diagnostics = current_execution_diagnostics[]
    diagnostics === nothing && return nothing
    push!(
        diagnostics,
        TestDiagnostic(
            file = String(file),
            line = Int(line),
            kind = kind,
            message = sprint(showerror, err),
        ),
    )
    return nothing
end

function traverse(f, node::JS.SyntaxNode)
    stack = JS.SyntaxNode[node]
    while !isempty(stack)
        current = pop!(stack)
        f(current)
        for i = JS.numchildren(current):-1:1
            push!(stack, current[i])
        end
    end
end

function matched_lines!(
    lines::Set{Int},
    sn::JS.SyntaxNode,
    patterns::Vector{Any},
    filter_lines::Union{Nothing,Set{Int}} = nothing,
)
    # First, handle line number patterns (Int and UnitRange{Int})
    for pattern in patterns
        if pattern isa Integer
            push!(lines, pattern)
        elseif pattern isa UnitRange{<:Integer}
            for line in pattern
                push!(lines, line)
            end
        end
    end

    # Then, handle other patterns
    traverse(sn) do node::JS.SyntaxNode
        expr = Expr(node)
        if matches_pattern(expr, patterns)
            sourcefile = JS.sourcefile(node)
            first_line = JS.source_line(sourcefile, JS.first_byte(node))
            last_line = JS.source_line(sourcefile, JS.last_byte(node))

            # If filter_lines is provided, only include matches that overlap with specified lines
            if filter_lines === nothing
                push!(lines, (first_line:last_line)...)
            else
                for line in first_line:last_line
                    if line in filter_lines
                        push!(lines, (first_line:last_line)...)
                        break
                    end
                end
            end
        end
    end
    return lines
end

function matches_pattern(@nospecialize(expr), patterns::Vector{Any})
    for pattern in patterns
        if pattern isa Integer || pattern isa UnitRange{<:Integer}
            # Skip line number patterns - they are handled separately
            continue
        elseif pattern isa AbstractString || pattern isa Regex
            # Match @testset names
            if matches_named_testset_call(pattern, expr)
                return true
            end
        elseif MacroTools.@capture(expr, $pattern)
            return true
        end
    end
    return false
end

function matches_named_testset_call(pat::Union{AbstractString,Regex}, @nospecialize ex)
    MacroTools.@capture(ex, @testset String_ xs__) || return false
    return pat isa Regex ? occursin(pat, String) : pat == String
end

function is_testset_or_test(@nospecialize expr)
    # Check if expression is a test-related macro call
    return MacroTools.@capture(expr, @inferred(xs__)) ||
           MacroTools.@capture(expr, @test(xs__)) ||
           MacroTools.@capture(expr, @test_broken(xs__)) ||
           MacroTools.@capture(expr, @test_deprecated(xs__)) ||
           MacroTools.@capture(expr, @test_logs(xs__)) ||
           MacroTools.@capture(expr, @test_warn(xs__)) ||
           MacroTools.@capture(expr, @test_skip(xs__)) ||
           MacroTools.@capture(expr, @test_throws(xs__)) ||
           MacroTools.@capture(expr, @testset(xs__))
end

function selected_target_files(interp::WarmTestInterpreter)
    targets = Set{String}()
    union!(targets, keys(interp.patterns))
    union!(targets, interp.run_all_files)
    return targets
end

function includes_selected_target(interp::WarmTestInterpreter, node::JS.SyntaxNode)
    targets = selected_target_files(interp)
    isempty(targets) && return false
    paths = String[]
    collect_static_include_paths!(paths, node)
    for path in paths
        child = normpath(joinpath(dirname(interp.filename), path))
        for included_file in static_included_files(child)
            abspath(included_file) in targets && return true
        end
    end
    return false
end

function include_reaches_selected_target(interp::WarmTestInterpreter, included_path::AbstractString)
    targets = selected_target_files(interp)
    isempty(targets) && return false
    for included_file in static_included_files(included_path)
        abspath(included_file) in targets && return true
    end
    return false
end

function evaluate_test_expr!(interp::WarmTestInterpreter, context::Module, expr, lnn::LineNumberNode)
    expr = Expr(:block, expr, lnn)
    lwr = Meta.lower(context, expr)

    if !Meta.isexpr(lwr, :thunk)
        Core.eval(context, lwr)
        return nothing
    end
    src = only(lwr.args)::CodeInfo

    frame = JI.Frame(context, src)
    JI.finish!(interp, frame, #=istoplevel=#true)
    return nothing
end

function evaluate_setup_expr!(interp::WarmTestInterpreter, context::Module, expr, lnn::LineNumberNode)
    try
        lwr = Meta.lower(context, expr)

        if !Meta.isexpr(lwr, :thunk)
            Core.eval(context, lwr)
            return nothing
        end
        src = only(lwr.args)::CodeInfo

        frame = JI.Frame(context, src)
        JI.finish!(interp, frame, #=istoplevel=#true)
    catch err
        record_execution_diagnostic!(interp.filename, lnn.line, :setup_error, err)
        rethrow()
    end
    return nothing
end

function execute_selected_includes!(interp::WarmTestInterpreter, context::Module, node::JS.SyntaxNode)
    expr = try
        Expr(node)
    catch
        return nothing
    end
    if is_static_include_call(expr)
        included_file = normpath(joinpath(dirname(interp.filename), last(expr.args)))
        if include_reaches_selected_target(interp, included_file)
            lnn = LineNumberNode(JS.source_line(node), interp.filename)
            evaluate_setup_expr!(interp, context, expr, lnn)
        end
        return nothing
    end
    expr isa Expr || return nothing
    is_static_executable_container(expr) || return nothing
    for index in 1:JS.numchildren(node)
        execute_selected_includes!(interp, context, node[index])
    end
    return nothing
end

function select_statements!(
    interp::WarmTestInterpreter,
    concretized::BitVector,
    src::CodeInfo,
    mod::Module,
    lines::Set{Int},
)
    cl = LCU.CodeLinks(mod, src)
    edges = LCU.CodeEdges(src, cl)

    for idx in 1:length(src.code)
        # If the line containing this statement is requested by pattern match,
        # this statement needs to be executed.
        lins = Base.IRShow.buildLineInfoNode(src.debuginfo, nothing, idx)
        for lin in lins
            if String(lin.file) == interp.filename && lin.line in lines
                concretized[idx] = true
            end
        end
    end

    select_dependencies!(concretized, src, edges, cl)

    # Debug: uncomment to see which statements are selected
    # LCU.print_with_code(stdout, src, concretized)

    nothing
end

function select_dependencies!(concretized::BitVector, src::CodeInfo, edges, cl)
    typedefs = LCU.find_typedefs(src)
    cfg = CC.compute_basic_blocks(src.code)
    postdomtree = CC.construct_postdomtree(cfg.blocks)
    ssavalue_uses = CC.find_ssavalue_uses(src.code, length(src.code))

    changed = true
    while changed
        changed = false
        changed |= LCU.add_ssa_preds!(concretized, src, edges, ())
        changed |= add_ssas_uses!(concretized, ssavalue_uses)
        changed |= add_slot_deps!(concretized, cl)
        changed |= LCU.add_typedefs!(concretized, src, edges, typedefs, ())
        changed |= LCU.add_control_flow!(concretized, src, cfg, postdomtree)
    end

    LCU.add_active_gotos!(concretized, src, cfg, postdomtree)
end

# Add statements that use SSA values produced by already selected statements
function add_ssas_uses!(concretized::BitVector, ssavalue_uses)
    changed = false
    for idx = 1:length(concretized)
        if concretized[idx]
            for use_idx in ssavalue_uses[idx]
                if !concretized[use_idx]
                    concretized[use_idx] = true
                    changed = true
                end
            end
        end
    end
    return changed
end

function add_slot_deps!(concretized::BitVector, cl::LCU.CodeLinks)
    changed = false

    # For each slot, check if any selected statement uses it
    for slot_id = 1:length(cl.slotsuccs)
        slot_succs = cl.slotsuccs[slot_id]
        slot_preds = cl.slotpreds[slot_id]
        slot_assigns = cl.slotassigns[slot_id]

        # Check if any successor (user) of this slot is selected
        is_selected = false
        for succ_idx in slot_succs.ssas
            if concretized[succ_idx]
                is_selected = true
                break
            end
        end

        is_selected || continue

        # If this slot is selected, we need to select:
        # 1. All predecessors (statements that the slot depends on)
        # 2. All assignments to the slot
        # 3. All prior uses of the slot (to ensure their dependencies are tracked)

        # Select predecessors
        for pred_idx in slot_preds.ssas
            if !concretized[pred_idx]
                concretized[pred_idx] = true
                changed = true
            end
        end

        for assign_idx in slot_assigns
            if !concretized[assign_idx]
                concretized[assign_idx] = true
                changed = true
            end
        end

        # Select all prior uses of the slot (to ensure their effects are included)
        for succ_idx in slot_succs.ssas
            if !concretized[succ_idx]
                # Only select uses that come before the latest selected use
                # This helps avoid selecting unrelated later uses
                latest_selected = 0
                for idx in slot_succs.ssas
                    if concretized[idx]
                        latest_selected = max(latest_selected, idx)
                    end
                end
                if succ_idx < latest_selected
                    concretized[succ_idx] = true
                    changed = true
                end
            end
        end
    end

    return changed
end

# This overload has exactly the same implementation as `JI.evaluate_call!(::JI.NonRecursiveInterpreter, ...)`,
# but since the default `JI.evaluate_call!(::Interpreter, ...)` is for the recursive interpretation,
# we need to provide this implementation for `WarmTestInterpreter`.
function JI.evaluate_call!(
    interp::WarmTestInterpreter,
    frame::JI.Frame,
    call_expr::Expr,
    enter_generated::Bool = false,
)
    # @assert !enter_generated
    pc = frame.pc
    ret = JI.bypass_builtins(interp, frame, call_expr, pc)
    isa(ret, Some{Any}) && return ret.value
    # NOTE `JI.maybe_evaluate_builtin` may call `Core._apply_iterate`, which may result in world age error otherwise
    ret = @invokelatest JI.maybe_evaluate_builtin(interp, frame, call_expr, false)
    isa(ret, Some{Any}) && return ret.value
    fargs = JI.collect_args(interp, frame, call_expr)
    return JI.evaluate_call!(interp, frame, fargs, enter_generated)
end

# This overload performs almost the same work as
# `JI.evaluate_call!(::JI.NonRecursiveInterpreter, ...)`
# but includes a few important adjustments specific to WarmTestRunner's virtual process:
# - Special handling for `include` calls: recursively apply the virtual process to included files.
function JI.evaluate_call!(interp::WarmTestInterpreter, ::JI.Frame, fargs::Vector{Any}, ::Bool)
    f = popfirst!(fargs)
    args = fargs # now it's really args
    isinclude(f) && return handle_include(interp, f, args)
    return @invokelatest f(args...)
end

isinclude(@nospecialize f) = f isa Base.IncludeInto || (isa(f, Function) && nameof(f) === :include)

function handle_include(interp::WarmTestInterpreter, @nospecialize(include_func), args::Vector{Any})
    nargs = length(args)
    include_context = interp.context
    if nargs == 1
        fname = only(args)
    elseif nargs == 2
        x, fname = args
        if isa(x, Module)
            include_context = x
        elseif isa(x, Function)
            throw(ArgumentError("include(mapexpr, file) is not supported by WarmTestRunner virtual execution"))
        else
            @invokelatest include_func(args...) # make it throw throw
            @assert false "unreachable"
        end
    else
        @invokelatest include_func(args...) # make it throw throw
        throw(ErrorException("unreachable"))
    end
    if !isa(fname, String)
        @invokelatest include_func(args...) # make it throw throw
        @assert false "unreachable"
    end
    included_file = normpath(dirname(interp.filename), fname)
    if interp.filename in interp.run_all_files
        push!(interp.run_all_files, included_file)
    end
    newinterp = WarmTestInterpreter(interp; filename = included_file, context = include_context)
    _virtual_run(newinterp)
end

function _virtual_run(interp::WarmTestInterpreter)
    filename = interp.filename
    isfile(filename) || throw(SystemError(lazy"opening file \"$filename\"", 2, nothing))
    toptext = read(filename, String)
    stream = JS.ParseStream(toptext)
    JS.parse!(stream; rule = :all)
    if !isempty(stream.diagnostics)
        err = JS.ParseError(stream)
        line = 0
        try
            sourcefile = JS.SourceFile(stream; filename = filename)
            line = JS.source_line(sourcefile, first(stream.diagnostics).first_byte)
        catch
            line = 0
        end
        record_execution_diagnostic!(filename, line, :parse_error, err)
        throw(err)
    end
    sntop = JS.build_tree(JS.SyntaxNode, stream; filename)
    _virtual_run(interp, sntop)
end

function _virtual_run(interp::WarmTestInterpreter, sntop::JS.SyntaxNode)
    vnodes = JS.SyntaxNode[]
    if JS.kind(sntop) == JS.K"toplevel"
        for i = JS.numchildren(sntop):-1:1
            push!(vnodes, sntop[i])
        end
    else
        push!(vnodes, sntop)
    end

    context = interp.context
    while !isempty(vnodes)
        node = pop!(vnodes)
        lnn = LineNumberNode(JS.source_line(node), interp.filename)

        if JS.kind(node) == JS.K"module"
            @assert JS.numchildren(node) == 2 "malformed `module` AST"
            ModuleName, newsntop = JS.children(node)
            isbare = JS.has_flags(node, JS.BARE_MODULE_FLAG)
            newcontext = Core.eval(context, Expr(:module, !isbare, Expr(ModuleName), Expr(:block, lnn)))
            newinterp = WarmTestInterpreter(interp; context = newcontext)
            children = JS.children(newsntop)
            children === nothing && continue
            for newsn in children
                _virtual_run(newinterp, newsn)
            end
            continue
        end

        # Check if this is a top-level @testset or @test
        expr = Expr(node)
        is_test_expr = is_testset_or_test(expr)
        run_all_file = interp.filename in interp.run_all_files
        patterns = get(interp.patterns, interp.filename, nothing)

        if is_test_expr && run_all_file
            evaluate_test_expr!(interp, context, expr, lnn)
        elseif is_test_expr && includes_selected_target(interp, node)
            execute_selected_includes!(interp, context, node)
        elseif is_test_expr && !isnothing(patterns)
            # For @testset and @test, use pattern matching
            lines = Set{Int}()
            matched_lines!(lines, node, patterns, get(interp.filter_lines, interp.filename, nothing))
            isempty(lines) && continue

            expr = Expr(:block, expr, lnn)
            lwr = Meta.lower(context, expr)

            if !Meta.isexpr(lwr, :thunk)
                Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo

            concretized = falses(length(src.code))
            select_statements!(interp, concretized, src, context, lines)

            frame = JI.Frame(context, src)
            LCU.selective_eval_fromstart!(interp, frame, concretized, #=istoplevel=#true)
        elseif is_test_expr
            # Test expressions in unselected files are intentionally skipped.
            continue
        else
            # Unconditionally execute non-test top-level code.
            # Note: We use `JI.finish!` here instead of `Core.eval`
            # to ensure proper handling of `include` statements through our
            # custom `evaluate_call!` implementation.
            evaluate_setup_expr!(interp, context, expr, lnn)
        end
    end
end

function selection_maps(plan::ExecutionPlan)
    patterns = Dict{String,Vector{Any}}()
    filter_lines = Dict{String,Set{Int}}()
    run_all_files = Set{String}()
    for selection in plan.selections
        file = abspath(selection.file)
        if selection.run_all
            push!(run_all_files, file)
        else
            patterns[file] = Any[pattern for pattern in selection.patterns]
        end
        selection.filter_lines === nothing || (filter_lines[file] = selection.filter_lines)
    end
    return patterns, filter_lines, run_all_files
end

function diagnostic_source(source)
    source === nothing && return ("", 0)
    file = String(getfield(source, :file))
    line = Int(getfield(source, :line))
    return file, line
end

function diagnostics_from_result(@nospecialize result)
    diagnostics = TestDiagnostic[]
    if result isa Test.DefaultTestSet
        for child in result.results
            append!(diagnostics, diagnostics_from_result(child))
        end
    elseif result isa Test.Fail
        file, line = diagnostic_source(result.source)
        push!(diagnostics, TestDiagnostic(file = file, line = line, kind = :fail, message = sprint(show, result)))
    elseif result isa Test.Error
        file, line = diagnostic_source(result.source)
        push!(diagnostics, TestDiagnostic(file = file, line = line, kind = :error, message = sprint(show, result)))
    elseif result isa Test.Threw
        file, line = diagnostic_source(result.source)
        push!(diagnostics, TestDiagnostic(file = file, line = line, kind = :error, message = sprint(show, result)))
    end
    return diagnostics
end

is_execution_error_diagnostic(diagnostic::TestDiagnostic) = diagnostic.kind in (:setup_error, :parse_error)

function is_internal_virtual_diagnostic(diagnostic::TestDiagnostic)
    isempty(diagnostic.file) && return false
    return normpath(diagnostic.file) == normpath(@__FILE__)
end

function combined_diagnostics(@nospecialize(testset_result), execution_diagnostics::Vector{TestDiagnostic})
    diagnostics = diagnostics_from_result(testset_result)
    if !isempty(execution_diagnostics)
        filter!(diagnostic -> !is_internal_virtual_diagnostic(diagnostic), diagnostics)
    end
    append!(diagnostics, execution_diagnostics)
    return diagnostics
end

function virtual_status(default_status::Symbol, diagnostics::Vector{TestDiagnostic})
    any(is_execution_error_diagnostic, diagnostics) && return :errored
    return default_status
end

function execute_plan(plan::ExecutionPlan; topmodule::Module = Main)
    started = time()
    old_interp = current_warmtest_interpreter[]
    old_testset_result = last_warmtest_testset_result[]
    old_execution_diagnostics = current_execution_diagnostics[]
    execution_diagnostics = TestDiagnostic[]
    empty!(warmtest_errors_and_fails)
    last_warmtest_testset_result[] = nothing
    current_execution_diagnostics[] = execution_diagnostics
    outcome = try
        run_in_fresh_task() do
            capture_test_output() do
                Core.eval(topmodule, :(using Test))
                if !isdefined(topmodule, :include)
                    Core.eval(topmodule, :(include(path) = Base.include($topmodule, path)))
                end
                patterns, filter_lines, run_all_files = selection_maps(plan)
                if plan.run_all
                    push!(run_all_files, abspath(plan.entryfile))
                end
                interp = WarmTestInterpreter(
                    patterns,
                    filter_lines,
                    run_all_files,
                    abspath(plan.entryfile),
                    topmodule,
                    ExceptionFrame[],
                )
                current_warmtest_interpreter[] = interp
                try
                    return Test.@testset WarmTestTestSet verbose = true "$(plan.label)" begin
                        _virtual_run(interp)
                    end
                finally
                    current_warmtest_interpreter[] = old_interp
                end
            end
        end
    finally
        current_execution_diagnostics[] = old_execution_diagnostics
    end
    testset_result = last_warmtest_testset_result[]
    last_warmtest_testset_result[] = old_testset_result
    if outcome[1] == :err
        _, err, bt = outcome
        status, summary, stacktrace = classify_exception(err, bt)
        diagnostics = combined_diagnostics(testset_result, execution_diagnostics)
        return TestResult(
            path = plan.label,
            status = virtual_status(status, diagnostics),
            elapsed = time() - started,
            stdout = "",
            stderr = "",
            exception_summary = summary,
            stacktrace = stacktrace,
            diagnostics = diagnostics,
        )
    end
    captured = outcome[2]
    testset_result = testset_result === nothing ? captured.value : testset_result
    diagnostics = combined_diagnostics(testset_result, execution_diagnostics)
    if captured.error === nothing
        status = isempty(diagnostics) ? :passed : :failed
        return TestResult(
            path = plan.label,
            status = virtual_status(status, diagnostics),
            elapsed = time() - started,
            stdout = captured.stdout,
            stderr = captured.stderr,
            diagnostics = diagnostics,
        )
    end
    status, summary, stacktrace = classify_exception(captured.error, captured.backtrace)
    return TestResult(
        path = plan.label,
        status = virtual_status(status, diagnostics),
        elapsed = time() - started,
        stdout = captured.stdout,
        stderr = captured.stderr,
        exception_summary = summary,
        stacktrace = stacktrace,
        diagnostics = diagnostics,
    )
end
