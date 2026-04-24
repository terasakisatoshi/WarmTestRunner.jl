# TestRunner Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WarmTestRunner's direct `include` worker backend with a Julia 1.12+ TestRunner-style virtual execution backend that runs through `test/runtests.jl`, uses worker `Main`, and supports file/testset/line/expression selection.

**Architecture:** Keep the controller daemon, Malt worker pool, watch mode, crash retry, and `RunSummary` surface. Replace the file-level execution core with an `ExecutionPlan` layer and a `virtual_execution.jl` backend derived from `extern/TestRunner.jl`, including JuliaSyntax parsing, JuliaInterpreter include interception, dependency selection, and a Test.jl-compatible custom test set.

**Tech Stack:** Julia 1.12+, Malt, TestEnv, Revise, JuliaSyntax, JuliaInterpreter, LoweredCodeUtils, Compiler, MacroTools, Test.

---

## File Map

- Modify `Project.toml`: raise Julia compat to 1.12 and add virtual execution dependencies.
- Modify `src/WarmTestRunner.jl`: include new execution source files and pass new API selectors through `run`.
- Modify `src/types.jl`: add `TestDiagnostic`, `TestSelection`, `ExecutionPlan`, update `TestJob`, and add diagnostics to `TestResult`.
- Create `src/execution.jl`: planning helpers, path normalization, selected-file reachability errors, and conversion from API selectors to `ExecutionPlan`s.
- Create `src/virtual_execution.jl`: TestRunner-derived interpreter, include hook, custom test set, and `execute_plan`.
- Modify `src/worker.jl`: remove `Base.include(context, job.path)` execution and call `execute_plan`.
- Modify `src/controller.jl`: replace `build_jobs` with plan-building, schedule `ExecutionPlan` jobs, and preserve crash retry and quickfail behavior.
- Modify `src/discovery.jl`: stop excluding `runtests.jl` as a conceptual entry point; add static include discovery helpers.
- Modify `src/results.jl`: include diagnostics in JSON schema v2.
- Modify `test/runtests.jl`: include new virtual execution and planning tests.
- Create `test/virtual_execution.jl`: backend tests without daemon/Malt.
- Create `test/execution_planning.jl`: selection and reachability tests.
- Modify `test/worker_single.jl`, `test/controller_daemon.jl`, `test/crash_recovery.jl`, `test/watch.jl`: update expectations from file-direct jobs to plans.
- Modify `test/packages/FixturePkg/test/runtests.jl`: make FixturePkg use an entry file for integrated tests.
- Create `test/packages/VirtualExecutionFixture/`: deterministic fixture for include selection, ambiguous names, setup errors, quickfail, and warm `Main` reset.
- Modify `README.md`, `SPEC.md`, `STATUS.md`: document the new execution model.

## Task 1: Dependencies And Source Wiring

**Files:**
- Modify: `Project.toml`
- Modify: `src/WarmTestRunner.jl`
- Create: `src/execution.jl`
- Create: `src/virtual_execution.jl`

- [ ] **Step 1: Update dependencies**

Edit `Project.toml` so `[deps]` includes:

```toml
Compiler = "807dbc54-b67e-4c79-8afb-eafe4df6f2e1"
JuliaInterpreter = "aa1ae85d-cabe-5617-a682-6adf51b2e16a"
JuliaSyntax = "70703baa-626e-46a2-a12c-08ffd08c73b4"
LoweredCodeUtils = "6f1432cf-f94c-5a45-995e-cdbf5db27b0b"
MacroTools = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
```

Edit `[compat]` to add:

```toml
Compiler = "0.1"
JuliaInterpreter = "0.10.3"
JuliaSyntax = "1, 2"
LoweredCodeUtils = "3.3.1"
MacroTools = "0.5.16"
julia = "1.12"
```

- [ ] **Step 2: Instantiate**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.instantiate()'
```

Expected: command exits 0 and `Manifest.toml` changes to include the new dependencies.

- [ ] **Step 3: Add empty execution files**

Create `src/execution.jl`:

```julia
# Execution planning and backend-independent execution data live here.
```

Create `src/virtual_execution.jl`:

```julia
# TestRunner-style virtual execution backend.
```

- [ ] **Step 4: Wire source includes**

Modify `src/WarmTestRunner.jl` so execution files load after `discovery.jl` and before `results.jl`:

```julia
include("types.jl")
include("config.jl")
include("discovery.jl")
include("execution.jl")
include("virtual_execution.jl")
include("results.jl")
```

- [ ] **Step 5: Verify load fails only on missing implementation if any**

Run:

```bash
julia --project=. --startup-file=no -e 'using WarmTestRunner; println("loaded")'
```

Expected: prints `loaded`.

- [ ] **Step 6: Commit**

```bash
git add Project.toml Manifest.toml src/WarmTestRunner.jl src/execution.jl src/virtual_execution.jl
git commit -m "feat: add virtual execution dependencies"
```

## Task 2: Execution Data Model

**Files:**
- Modify: `src/types.jl`
- Modify: `src/results.jl`
- Test: `test/results.jl`

- [ ] **Step 1: Add failing result diagnostics test**

Append to `test/results.jl`:

```julia
@testset "JSON includes diagnostics schema v2" begin
    diagnostic = WarmTestRunner.TestDiagnostic(
        file = "test/foo.jl",
        line = 42,
        kind = :fail,
        message = "expected true",
        related = WarmTestRunner.TestDiagnosticRelated[],
    )
    result = WarmTestRunner.TestResult(
        path = "test/foo.jl",
        status = :failed,
        elapsed = 0.1,
        diagnostics = [diagnostic],
    )
    summary = WarmTestRunner.summarize_results([result])
    json = WarmTestRunner.summary_to_json(summary)
    @test occursin("\"schema_version\":2", json)
    @test occursin("\"diagnostics\"", json)
    @test occursin("\"kind\":\"fail\"", json)
    @test occursin("\"line\":42", json)
end
```

- [ ] **Step 2: Run failing test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/results.jl")'
```

Expected: FAIL with `UndefVarError: TestDiagnostic not defined` or `MethodError` for `diagnostics`.

- [ ] **Step 3: Add diagnostic and execution structs**

In `src/types.jl`, after `TestJob`, add:

```julia
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
```

Update `TestJob`:

```julia
Base.@kwdef struct TestJob
    path::String
    name::String = ""
    tags::Vector{String} = String[]
    est_seconds::Float64 = 0.0
    plan::Union{Nothing, ExecutionPlan} = nothing
end
```

Update `TestResult`:

```julia
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
```

- [ ] **Step 4: Update JSON serialization**

In `src/results.jl`, add:

```julia
function diagnostic_related_to_json_data(related::TestDiagnosticRelated)
    return (
        file = related.file,
        line = related.line,
        message = related.message,
    )
end

function diagnostic_to_json_data(diagnostic::TestDiagnostic)
    return (
        file = diagnostic.file,
        line = diagnostic.line,
        kind = String(diagnostic.kind),
        message = diagnostic.message,
        related = [diagnostic_related_to_json_data(item) for item in diagnostic.related],
    )
end
```

Update `result_to_json_data` to include:

```julia
diagnostics = [diagnostic_to_json_data(diagnostic) for diagnostic in result.diagnostics],
```

Update `summary_to_json_data`:

```julia
schema_version = 2,
```

- [ ] **Step 5: Run result tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/results.jl")'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/types.jl src/results.jl test/results.jl
git commit -m "feat: add execution result diagnostics"
```

## Task 3: Virtual Execution Fixture

**Files:**
- Create: `test/packages/VirtualExecutionFixture/Project.toml`
- Create: `test/packages/VirtualExecutionFixture/src/VirtualExecutionFixture.jl`
- Create: `test/packages/VirtualExecutionFixture/test/runtests.jl`
- Create: `test/packages/VirtualExecutionFixture/test/setup.jl`
- Create: `test/packages/VirtualExecutionFixture/test/names.jl`
- Create: `test/packages/VirtualExecutionFixture/test/selection.jl`
- Create: `test/packages/VirtualExecutionFixture/test/errors.jl`
- Modify: `test/runtests.jl`
- Create: `test/virtual_execution.jl`

- [ ] **Step 1: Create fixture package**

Create `test/packages/VirtualExecutionFixture/Project.toml`:

```toml
name = "VirtualExecutionFixture"
uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
version = "0.1.0"

[deps]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
```

Create `test/packages/VirtualExecutionFixture/src/VirtualExecutionFixture.jl`:

```julia
module VirtualExecutionFixture

module UpstreamName
export token
token() = :upstream
end

module Wrapper
export UpstreamName
module UpstreamName
export token
token() = :wrapped
end
end

add1(x) = x + 1

end
```

Create `test/packages/VirtualExecutionFixture/test/runtests.jl`:

```julia
using Test
using VirtualExecutionFixture

include("setup.jl")
include("names.jl")
include("selection.jl")
include("errors.jl")
```

Create `test/packages/VirtualExecutionFixture/test/setup.jl`:

```julia
using Test

fixture_setup_value = VirtualExecutionFixture.add1(40)

@testset "setup file" begin
    @test fixture_setup_value == 41
end
```

Create `test/packages/VirtualExecutionFixture/test/names.jl`:

```julia
using Test
using VirtualExecutionFixture.Wrapper
using VirtualExecutionFixture.UpstreamName

@testset "ambiguous exported module names" begin
    @test VirtualExecutionFixture.Wrapper.UpstreamName.token() == :wrapped
    @test VirtualExecutionFixture.UpstreamName.token() == :upstream
end
```

Create `test/packages/VirtualExecutionFixture/test/selection.jl`:

```julia
using Test

@testset "selected testset" begin
    @test fixture_setup_value == 41
    @test VirtualExecutionFixture.add1(1) == 2
end

@testset "other testset" begin
    @test VirtualExecutionFixture.add1(2) == 3
end

@test VirtualExecutionFixture.add1(3) == 4
```

Create `test/packages/VirtualExecutionFixture/test/errors.jl`:

```julia
using Test

function fixture_domain_error()
    error("fixture domain error")
end

@testset "failure testset" begin
    @test VirtualExecutionFixture.add1(1) == 99
end

@testset "error testset" begin
    @test fixture_domain_error() == nothing
end
```

- [ ] **Step 2: Add failing virtual execution tests**

Create `test/virtual_execution.jl`:

```julia
using Test
using WarmTestRunner

const VIRTUAL_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
const VIRTUAL_FIXTURE_ENTRY = joinpath(VIRTUAL_FIXTURE_ROOT, "test", "runtests.jl")

@testset "virtual execution run all" begin
    plan = WarmTestRunner.ExecutionPlan(entryfile = VIRTUAL_FIXTURE_ENTRY, run_all = true)
    result = WarmTestRunner.execute_plan(plan; topmodule = Module(:VirtualExecutionRunAll))
    @test result.status == :failed
    @test occursin("ambiguous exported module names", result.stdout)
    @test occursin("failure testset", result.stdout)
    @test !isempty(result.diagnostics)
end

@testset "virtual execution testset selection" begin
    selection = WarmTestRunner.TestSelection(
        file = joinpath(VIRTUAL_FIXTURE_ROOT, "test", "selection.jl"),
        patterns = Any["selected testset"],
    )
    plan = WarmTestRunner.ExecutionPlan(
        entryfile = VIRTUAL_FIXTURE_ENTRY,
        selections = [selection],
    )
    result = WarmTestRunner.execute_plan(plan; topmodule = Module(:VirtualExecutionSelected))
    @test result.status == :passed
    @test occursin("selected testset", result.stdout)
    @test !occursin("other testset", result.stdout)
end

@testset "virtual execution file selection runs all tests in file" begin
    selection = WarmTestRunner.TestSelection(
        file = joinpath(VIRTUAL_FIXTURE_ROOT, "test", "selection.jl"),
        run_all = true,
    )
    plan = WarmTestRunner.ExecutionPlan(
        entryfile = VIRTUAL_FIXTURE_ENTRY,
        selections = [selection],
    )
    result = WarmTestRunner.execute_plan(plan; topmodule = Module(:VirtualExecutionFileSelected))
    @test result.status == :passed
    @test occursin("selected testset", result.stdout)
    @test occursin("other testset", result.stdout)
end
```

Add to `test/runtests.jl`:

```julia
include("virtual_execution.jl")
```

- [ ] **Step 3: Run failing test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/virtual_execution.jl")'
```

Expected: FAIL with `UndefVarError: execute_plan not defined`.

- [ ] **Step 4: Commit fixture and failing tests**

```bash
git add test/packages/VirtualExecutionFixture test/virtual_execution.jl test/runtests.jl
git commit -m "test: add virtual execution fixtures"
```

## Task 4: Port TestRunner Core Backend

**Files:**
- Modify: `src/virtual_execution.jl`
- Test: `test/virtual_execution.jl`

- [ ] **Step 1: Add imports and attribution header**

Replace `src/virtual_execution.jl` with:

```julia
# Portions of this file are adapted from TestRunner.jl.
# TestRunner.jl copyright (c) 2025 Shuhei Kadowaki, MIT licensed.

using Core.IR
using Compiler: Compiler as CC
using JuliaInterpreter: JuliaInterpreter as JI
using LoweredCodeUtils: LoweredCodeUtils as LCU
using JuliaSyntax: JuliaSyntax as JS
using MacroTools: MacroTools
```

- [ ] **Step 2: Port interpreter type and pattern matching**

Append to `src/virtual_execution.jl`:

```julia
const BacktraceElm = Union{Ptr{Nothing}, Base.InterpreterIP}
const ExceptionFrame = @NamedTuple{exception::Any, backtrace::Vector{BacktraceElm}}

struct WarmTestInterpreter <: JI.Interpreter
    patterns::Dict{String, Vector{Any}}
    filter_lines::Dict{String, Set{Int}}
    run_all_files::Set{String}
    filename::String
    context::Module
    current_exceptions::Vector{ExceptionFrame}
end

function WarmTestInterpreter(interp::WarmTestInterpreter;
    patterns::Dict{String, Vector{Any}} = interp.patterns,
    filter_lines::Dict{String, Set{Int}} = interp.filter_lines,
    run_all_files::Set{String} = interp.run_all_files,
    filename::String = interp.filename,
    context::Module = interp.context,
    current_exceptions::Vector{ExceptionFrame} = interp.current_exceptions,
)
    return WarmTestInterpreter(patterns, filter_lines, run_all_files, filename, context, current_exceptions)
end

const current_warmtest_interpreter = Ref{Union{Nothing, WarmTestInterpreter}}(nothing)

function is_testset_or_test(@nospecialize expr)
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

function matches_named_testset_call(pat::Union{AbstractString, Regex}, @nospecialize ex)
    MacroTools.@capture(ex, @testset String_ xs__) || return false
    return pat isa Regex ? occursin(pat, String) : pat == String
end

function matches_pattern(@nospecialize(expr), patterns::Vector{Any})
    for pattern in patterns
        if pattern isa Integer || pattern isa UnitRange{<:Integer}
            continue
        elseif pattern isa AbstractString || pattern isa Regex
            matches_named_testset_call(pattern, expr) && return true
        elseif MacroTools.@capture(expr, $pattern)
            return true
        end
    end
    return false
end
```

- [ ] **Step 3: Port syntax traversal and selection**

Append the traversal and selection functions from `extern/TestRunner.jl/src/TestRunner.jl`:

```julia
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

function matched_lines!(lines::Set{Int}, sn::JS.SyntaxNode, patterns::Vector{Any},
                        filter_lines::Union{Nothing, Set{Int}} = nothing)
    for pattern in patterns
        if pattern isa Integer
            push!(lines, pattern)
        elseif pattern isa UnitRange{<:Integer}
            push!(lines, pattern...)
        end
    end

    traverse(sn) do node::JS.SyntaxNode
        expr = Expr(node)
        if matches_pattern(expr, patterns)
            sourcefile = JS.sourcefile(node)
            first_line = JS.source_line(sourcefile, JS.first_byte(node))
            last_line = JS.source_line(sourcefile, JS.last_byte(node))
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
```

Then copy these functions from `extern/TestRunner.jl/src/TestRunner.jl` with names unchanged:

```text
select_statements!
select_dependencies!
add_ssas_uses!
add_slot_deps!
```

Copy exactly from the upstream file, then run formatting manually if needed. These
functions are backend internals and should stay close to upstream TestRunner.jl until
WarmTestRunner has its own full coverage.

- [ ] **Step 4: Port include interception**

Append:

```julia
function JI.evaluate_call!(interp::WarmTestInterpreter, frame::JI.Frame, call_expr::Expr, enter_generated::Bool = false)
    pc = frame.pc
    ret = JI.bypass_builtins(interp, frame, call_expr, pc)
    isa(ret, Some{Any}) && return ret.value
    ret = @invokelatest JI.maybe_evaluate_builtin(interp, frame, call_expr, false)
    isa(ret, Some{Any}) && return ret.value
    fargs = JI.collect_args(interp, frame, call_expr)
    return JI.evaluate_call!(interp, frame, fargs, enter_generated)
end

function JI.evaluate_call!(interp::WarmTestInterpreter, ::JI.Frame, fargs::Vector{Any}, ::Bool)
    f = popfirst!(fargs)
    isinclude(f) && return handle_include(interp, f, fargs)
    return @invokelatest f(fargs...)
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
            @invokelatest include_func(args...)
            throw(ErrorException("unreachable include dispatch"))
        end
    else
        @invokelatest include_func(args...)
        throw(ErrorException("unreachable include dispatch"))
    end
    isa(fname, String) || (@invokelatest include_func(args...); throw(ErrorException("unreachable include filename")))
    included_file = normpath(joinpath(dirname(interp.filename), fname))
    newinterp = WarmTestInterpreter(interp; filename = included_file, context = include_context)
    return _virtual_run(newinterp)
end
```

- [ ] **Step 5: Add virtual run loop**

Append:

```julia
function _virtual_run(interp::WarmTestInterpreter)
    filename = interp.filename
    isfile(filename) || throw(SystemError(lazy"opening file \"$filename\"", 2, nothing))
    toptext = read(filename, String)
    stream = JS.ParseStream(toptext)
    JS.parse!(stream; rule = :all)
    isempty(stream.diagnostics) || throw(JS.ParseError(stream))
    sntop = JS.build_tree(JS.SyntaxNode, stream; filename)
    return _virtual_run(interp, sntop)
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

        expr = Expr(node)
        is_test_expr = is_testset_or_test(expr)
        file_patterns = get(interp.patterns, interp.filename, nothing)
        run_all_file = interp.filename in interp.run_all_files

        if is_test_expr && (run_all_file || file_patterns !== nothing)
            expr = Expr(:block, expr, lnn)
            lwr = Meta.lower(context, expr)
            if !Meta.isexpr(lwr, :thunk)
                Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo
            concretized = falses(length(src.code))
            if run_all_file
                fill!(concretized, true)
            else
                lines = Set{Int}()
                matched_lines!(lines, node, file_patterns, get(interp.filter_lines, interp.filename, nothing))
                select_statements!(interp, concretized, src, context, lines)
            end
            frame = JI.Frame(context, src)
            LCU.selective_eval_fromstart!(interp, frame, concretized, true)
        elseif !is_test_expr
            lwr = Meta.lower(context, Expr(:block, expr, lnn))
            if !Meta.isexpr(lwr, :thunk)
                Core.eval(context, lwr)
                continue
            end
            src = only(lwr.args)::CodeInfo
            frame = JI.Frame(context, src)
            JI.finish!(interp, frame, true)
        end
    end
    return nothing
end
```

- [ ] **Step 6: Add `execute_plan` minimal capture**

Append:

```julia
function selection_maps(plan::ExecutionPlan)
    patterns = Dict{String, Vector{Any}}()
    filter_lines = Dict{String, Set{Int}}()
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

function execute_plan(plan::ExecutionPlan; topmodule::Module = Main)
    started = time()
    captured = capture_test_output() do
        Core.eval(topmodule, :(using Test))
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
        _virtual_run(interp)
        return nothing
    end
    if captured.error === nothing
        return TestResult(
            path = plan.label,
            status = :passed,
            elapsed = time() - started,
            stdout = captured.stdout,
            stderr = captured.stderr,
        )
    end
    status, summary, stacktrace = classify_exception(captured.error, captured.backtrace)
    return TestResult(
        path = plan.label,
        status = status,
        elapsed = time() - started,
        stdout = captured.stdout,
        stderr = captured.stderr,
        exception_summary = summary,
        stacktrace = stacktrace,
    )
end
```

- [ ] **Step 7: Run virtual execution tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/virtual_execution.jl")'
```

Expected: the selection tests pass. Diagnostics-specific assertions are introduced in Task 5.

- [ ] **Step 8: Commit**

```bash
git add src/virtual_execution.jl
git commit -m "feat: add virtual execution backend"
```

## Task 5: Custom Test Set And Diagnostics

**Files:**
- Modify: `src/virtual_execution.jl`
- Test: `test/virtual_execution.jl`

- [ ] **Step 1: Add diagnostics assertions**

Extend `test/virtual_execution.jl`:

```julia
@testset "virtual execution diagnostics include user files" begin
    selection = WarmTestRunner.TestSelection(
        file = joinpath(VIRTUAL_FIXTURE_ROOT, "test", "errors.jl"),
        patterns = Any["error testset"],
    )
    plan = WarmTestRunner.ExecutionPlan(
        entryfile = VIRTUAL_FIXTURE_ENTRY,
        selections = [selection],
    )
    result = WarmTestRunner.execute_plan(plan; topmodule = Module(:VirtualExecutionDiagnostics))
    @test result.status == :failed
    @test any(d -> endswith(d.file, joinpath("test", "errors.jl")), result.diagnostics)
    @test any(d -> d.kind in (:error, :fail), result.diagnostics)
end
```

- [ ] **Step 2: Run failing diagnostics test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/virtual_execution.jl")'
```

Expected: FAIL because `diagnostics` is empty.

- [ ] **Step 3: Port custom test set**

In `src/virtual_execution.jl`, add:

```julia
const warmtest_errors_and_fails = IdDict{Any, Vector{Any}}()

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
    if Test.get_testset_depth() != 0
        Test.record(Test.get_testset(), ts.dts)
    else
        Test.finish(ts.dts)
    end
    return ts.dts
end
```

- [ ] **Step 4: Add exception handling hooks**

Add `JI.handle_err`, `scrub_backtrace`, and `scrub_exc_stack` using the same structure as `extern/TestRunner.jl/src/TestRunner.jl`, with `TRInterpreter` renamed to `WarmTestInterpreter`. The required public signatures in this file are:

```julia
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
```

Use this constant:

```julia
const JULIAINTERPRETER_INTERPRET_FILE = let
    jlfile = pathof(JI)::String
    Symbol(normpath(jlfile, "..", "interpret.jl"))
end
```

- [ ] **Step 5: Wrap execution in WarmTestTestSet**

Modify `execute_plan` so the virtual run happens inside:

```julia
Test.@testset WarmTestTestSet "$(plan.label)" begin
    _virtual_run(interp)
end
```

- [ ] **Step 6: Extract diagnostics**

Add:

```julia
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
        push!(diagnostics, TestDiagnostic(
            file = file,
            line = line,
            kind = :fail,
            message = sprint(show, result),
        ))
    elseif result isa Test.Error
        file, line = diagnostic_source(result.source)
        push!(diagnostics, TestDiagnostic(
            file = file,
            line = line,
            kind = :error,
            message = sprint(show, result),
        ))
    elseif result isa Test.Threw
        file, line = diagnostic_source(result.source)
        push!(diagnostics, TestDiagnostic(
            file = file,
            line = line,
            kind = :error,
            message = sprint(show, result),
        ))
    end
    return diagnostics
end
```

In `execute_plan`, capture the returned DefaultTestSet from the outer testset and set:

```julia
diagnostics = diagnostics_from_result(testset_result)
```

- [ ] **Step 7: Run diagnostics tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/virtual_execution.jl")'
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/virtual_execution.jl test/virtual_execution.jl
git commit -m "feat: capture virtual test diagnostics"
```

## Task 6: Execution Planning And Reachability

**Files:**
- Modify: `src/execution.jl`
- Modify: `src/discovery.jl`
- Create: `test/execution_planning.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add planning tests**

Create `test/execution_planning.jl`:

```julia
using Test
using WarmTestRunner

const PLANNING_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")

@testset "default entry is runtests" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(cfg)
    @test length(plans) == 1
    @test endswith(only(plans).entryfile, joinpath("test", "runtests.jl"))
    @test only(plans).run_all
end

@testset "file selection maps to reachable included file" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl"])
    @test length(plans) == 1
    selection = only(only(plans).selections)
    @test endswith(selection.file, joinpath("test", "selection.jl"))
    @test selection.run_all
end

@testset "unreachable selected file errors" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["missing.jl"])
end
```

Add to `test/runtests.jl`:

```julia
include("execution_planning.jl")
```

- [ ] **Step 2: Run failing planning tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/execution_planning.jl")'
```

Expected: FAIL with `UndefVarError: build_execution_plans not defined`.

- [ ] **Step 3: Implement static include discovery**

In `src/discovery.jl`, add:

```julia
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
        for matchobj in eachmatch(r"include\\(\"([^\"]+)\"\\)", text)
            child = normpath(joinpath(dirname(path), matchobj.captures[1]))
            visit(child)
        end
    end

    visit(entry)
    return ordered
end
```

- [ ] **Step 4: Implement planning helpers**

In `src/execution.jl`, add:

```julia
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
    map = Dict{String, String}()
    for file in files
        map[abspath(file)] = abspath(file)
        map[basename(file)] = abspath(file)
        rel = relpath(file, dirname(entryfile))
        map[normpath(rel)] = abspath(file)
    end
    return map
end

function selected_file_from_map(map::Dict{String, String}, cfg::RunnerConfig, name::AbstractString, entryfile::AbstractString)
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

function build_execution_plans(
    cfg::RunnerConfig;
    tests::AbstractVector{<:AbstractString} = String[],
    testsets::AbstractVector = Any[],
    line_patterns::AbstractVector = Pair{String, Any}[],
    expression_patterns::AbstractVector = Pair{String, Any}[],
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
        push!(selections, TestSelection(file = file, run_all = true))
    end
    for pattern in testsets
        push!(selections, TestSelection(file = abspath(entry), patterns = Any[pattern]))
    end
    for pair in line_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        lines = last(pair)
        line_set = lines isa Integer ? Set([Int(lines)]) : Set(Int.(collect(lines)))
        push!(selections, TestSelection(file = file, patterns = Any[lines], filter_lines = line_set))
    end
    for pair in expression_patterns
        file = selected_file_from_map(reachability, cfg, first(pair), entry)
        push!(selections, TestSelection(file = file, patterns = Any[last(pair)]))
    end
    return [ExecutionPlan(entryfile = entry, selections = selections, label = "test/runtests.jl")]
end
```

- [ ] **Step 5: Run planning tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/execution_planning.jl")'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/execution.jl src/discovery.jl test/execution_planning.jl test/runtests.jl
git commit -m "feat: plan virtual test executions"
```

## Task 7: Worker Integration

**Files:**
- Modify: `src/worker.jl`
- Modify: `test/worker_single.jl`

- [ ] **Step 1: Add worker test for ExecutionPlan**

Append to `test/worker_single.jl`:

```julia
@testset "worker executes virtual execution plan" begin
    pkgroot = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
    cfg = WarmTestRunner.make_config(pkgroot = pkgroot, jobs = 1, use_revise = false)
    worker = WarmTestRunner.start_worker(cfg; id = 1)
    try
        WarmTestRunner.bootstrap_worker!(worker, cfg)
        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl"])
        job = WarmTestRunner.TestJob(
            path = only(plans).entryfile,
            name = "test/runtests.jl",
            plan = only(plans),
        )
        result = WarmTestRunner.run_test_in_worker!(worker, job, cfg)
        @test result.status == :passed
        @test occursin("selected testset", result.stdout)
    finally
        WarmTestRunner.stop_worker!(worker)
    end
end
```

- [ ] **Step 2: Run failing worker test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: FAIL until `run_test_in_worker!` uses `job.plan`.

- [ ] **Step 3: Simplify bootstrap context**

In `src/worker.jl`, remove creation/evaluation of `WarmTestContext_*` from `bootstrap_worker!`. Keep activation, Revise, preload, and bootstrap hook in `Main`.

The bootstrap body should end with:

```julia
Base.eval(Main, :(using Test))
nothing
```

- [ ] **Step 4: Replace worker include execution**

Inside `run_test_in_worker!`, replace:

```julia
mod = getfield(Main, $context_name)
...
Base.eval(mod, :(using Test))
Base.include(mod, $(job.path))
```

with:

```julia
plan = $(job.plan === nothing ? ExecutionPlan(entryfile = job.path, run_all = true, label = result_path(cfg, job.path)) : job.plan)
payload_result = execute_plan(plan; topmodule = Main)
status = payload_result.status
exception_summary = payload_result.exception_summary
stacktrace = payload_result.stacktrace
diagnostics = payload_result.diagnostics
```

Return payload must include `diagnostics`.

Update final `TestResult` construction:

```julia
diagnostics = payload.diagnostics,
```

- [ ] **Step 5: Run worker tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/worker_single.jl")'
```

Expected: PASS or only failures in tests that still assume old context; update those old-context assertions to the new `Main` model.

- [ ] **Step 6: Commit**

```bash
git add src/worker.jl test/worker_single.jl
git commit -m "feat: execute plans in workers"
```

## Task 8: Controller And API Integration

**Files:**
- Modify: `src/WarmTestRunner.jl`
- Modify: `src/controller.jl`
- Modify: `test/controller_daemon.jl`

- [ ] **Step 1: Extend public run API**

In `src/WarmTestRunner.jl`, update signature:

```julia
function run(;
    tests = String[],
    testsets = Any[],
    line_patterns = Pair{String, Any}[],
    expression_patterns = Pair{String, Any}[],
    quickfail::Bool = false,
    changed_only::Bool = false,
    rerun_failed::Bool = false,
    fresh::Bool = false,
    retry_crashed::Bool = true,
    output_format::Symbol = :text,
    kwargs...
)
```

Pass new fields through `client_request`:

```julia
testsets = collect(testsets),
line_patterns = collect(line_patterns),
expression_patterns = collect(expression_patterns),
```

- [ ] **Step 2: Replace job building in controller**

In `src/controller.jl`, keep `build_jobs` temporarily for no-runtests fallback, but change `handle_request!` run planning to call:

```julia
plans = build_execution_plans(
    state.cfg;
    tests = request_payload(request, :tests, String[]),
    testsets = request_payload(request, :testsets, Any[]),
    line_patterns = request_payload(request, :line_patterns, Pair{String, Any}[]),
    expression_patterns = request_payload(request, :expression_patterns, Pair{String, Any}[]),
    changed_only = request_payload(request, :changed_only, false),
    rerun_failed = request_payload(request, :rerun_failed, false),
    last_failed = previous_failed,
)
jobs = [
    TestJob(path = plan.entryfile, name = basename(plan.entryfile), plan = plan)
    for plan in plans
]
```

- [ ] **Step 3: Add controller integration test**

Append to `test/controller_daemon.jl`:

```julia
@testset "public run uses runtests entry and file selection" begin
    mktempdir() do tmp
        withenv("WARMTESTRUNNER_HOME" => tmp) do
            pkgroot = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
            WarmTestRunner.stop(pkgroot = pkgroot)
            summary = WarmTestRunner.run(
                pkgroot = pkgroot,
                tests = ["selection.jl"],
                jobs = 1,
                use_revise = false,
                fresh = true,
            )
            try
                @test summary.failed == 0
                @test summary.errored == 0
                @test summary.passed == 1
                @test occursin("selected testset", only(summary.results).stdout)
            finally
                WarmTestRunner.stop(pkgroot = pkgroot)
            end
        end
    end
end
```

- [ ] **Step 4: Run controller test**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/controller_daemon.jl")'
```

Expected: PASS after old file-direct expectations are updated.

- [ ] **Step 5: Commit**

```bash
git add src/WarmTestRunner.jl src/controller.jl test/controller_daemon.jl
git commit -m "feat: route controller runs through execution plans"
```

## Task 9: Parallel Planning, Quickfail, And Crash Recovery

**Files:**
- Modify: `src/execution.jl`
- Modify: `src/controller.jl`
- Modify: `test/controller_daemon.jl`
- Modify: `test/crash_recovery.jl`

- [ ] **Step 1: Add partition helper test**

Append to `test/execution_planning.jl`:

```julia
@testset "partition plans keep runtests entry" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT, jobs = 2)
    plans = WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl", "names.jl"])
    partitioned = WarmTestRunner.partition_execution_plans(plans, cfg.jobs)
    @test length(partitioned) == 2
    @test all(plan -> endswith(plan.entryfile, joinpath("test", "runtests.jl")), partitioned)
    @test sum(length(plan.selections) for plan in partitioned) == 2
end
```

- [ ] **Step 2: Implement partition helper**

In `src/execution.jl`, add:

```julia
function partition_execution_plans(plans::AbstractVector{<:ExecutionPlan}, jobs::Integer)
    jobs <= 1 && return collect(plans)
    length(plans) != 1 && return collect(plans)
    plan = only(plans)
    plan.run_all && return [plan]
    isempty(plan.selections) && return [plan]

    buckets = [TestSelection[] for _ in 1:min(jobs, length(plan.selections))]
    for (idx, selection) in pairs(plan.selections)
        push!(buckets[mod1(idx, length(buckets))], selection)
    end
    return [
        ExecutionPlan(
            entryfile = plan.entryfile,
            selections = bucket,
            label = "$(plan.label)#part$(idx)",
        )
        for (idx, bucket) in pairs(buckets)
    ]
end
```

- [ ] **Step 3: Apply partitioning in controller**

After `build_execution_plans`, add:

```julia
plans = partition_execution_plans(plans, state.cfg.jobs)
```

- [ ] **Step 4: Quickfail policy**

In `src/virtual_execution.jl`, add a sentinel:

```julia
struct WarmTestQuickfail <: Exception end
```

Thread `quickfail` through `execute_plan(plan; topmodule = Main, quickfail = false)`. Add:

```julia
const current_warmtest_quickfail = Ref(false)
```

Set it at the beginning of `execute_plan`:

```julia
old_quickfail = current_warmtest_quickfail[]
current_warmtest_quickfail[] = quickfail
try
    # existing execution body
finally
    current_warmtest_quickfail[] = old_quickfail
end
```

In `Test.record(::WarmTestTestSet, res)`, after recording a `Test.Fail`, `Test.Error`, or
`Test.Threw`, throw `WarmTestQuickfail()` when `current_warmtest_quickfail[]` is true.

Classify `WarmTestQuickfail` as `:failed` when at least one diagnostic exists.

- [ ] **Step 5: Update crash recovery tests**

In `test/crash_recovery.jl`, replace direct crash file jobs with a fixture `test/runtests.jl`
that includes a file containing `exit(1)`. Ensure expected behavior remains:

```julia
@test getfield.(summary.results, :status) == [:crashed]
```

for `retry_crashed = false`, and retry path recreates the worker.

- [ ] **Step 6: Run focused tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/execution_planning.jl"); include("test/controller_daemon.jl"); include("test/crash_recovery.jl")'
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/execution.jl src/controller.jl src/virtual_execution.jl test/execution_planning.jl test/controller_daemon.jl test/crash_recovery.jl
git commit -m "feat: partition virtual execution plans"
```

## Task 10: Remove Old Sandbox Assumptions

**Files:**
- Modify: `src/sandbox.jl`
- Modify: `test/sandbox.jl`
- Modify: `test/controller_daemon.jl`

- [ ] **Step 1: Decide sandbox role**

Keep `src/sandbox.jl` only for shared output capture and exception classification:

```julia
capture_test_output
run_in_fresh_task
classify_exception
```

Delete or stop using:

```julia
run_test_file_in_module
```

- [ ] **Step 2: Update sandbox tests**

In `test/sandbox.jl`, remove tests that assert anonymous module execution. Replace with tests for:

```julia
@testset "capture_test_output captures stdout and stderr" begin
    captured = WarmTestRunner.capture_test_output() do
        println("out")
        println(stderr, "err")
        nothing
    end
    @test captured.error === nothing
    @test occursin("out", captured.stdout)
    @test occursin("err", captured.stderr)
end
```

and:

```julia
@testset "classify_exception classifies TestSetException as failed" begin
    err = try
        @testset "fails" begin
            @test false
        end
    catch caught
        caught
    end
    status, _, _ = WarmTestRunner.classify_exception(err, Base.StackTraces.StackFrame[])
    @test status == :failed
end
```

- [ ] **Step 3: Run sandbox tests**

Run:

```bash
julia --project=. --startup-file=no -e 'include("test/sandbox.jl")'
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/sandbox.jl test/sandbox.jl
git commit -m "refactor: remove isolated module sandbox runner"
```

## Task 11: Documentation And Status

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `STATUS.md`

- [ ] **Step 1: Update README execution model**

Replace text that says `test/runtests.jl` is excluded with:

```markdown
`WarmTestRunner.run()` uses `test/runtests.jl` as the preferred suite entry point.
The virtual execution backend follows `include(...)` calls from that entry file and can
select tests by file, testset name, line, or expression while still running top-level setup
code.
```

Replace shared module wording with:

```markdown
The worker process is the isolation boundary. Each worker executes tests in its warm
`Main` context, so package imports, helper definitions, and setup state persist until the
worker is recreated. Use `fresh = true` to discard accumulated worker state.
```

- [ ] **Step 2: Update SPEC**

In `SPEC.md`, update section 4.4 title from sandbox execution to virtual execution and
state:

```markdown
Each worker owns a warm `Main` execution context. Test execution is performed by a
TestRunner-style virtual backend that parses the suite entry file, runs non-test top-level
setup, intercepts `include(...)`, and selectively executes matching `@test` / `@testset`
expressions.
```

- [ ] **Step 3: Update STATUS**

In `STATUS.md`, replace MVP status claims about per-test-file execution with:

```markdown
The runner now uses a virtual execution backend derived from TestRunner.jl. `test/runtests.jl`
is the preferred entry point, and worker `Main` is the warm execution context.
```

- [ ] **Step 4: Commit docs**

```bash
git add README.md SPEC.md STATUS.md
git commit -m "docs: describe virtual execution backend"
```

## Task 12: Full Verification And External Validation

**Files:**
- No required source edits unless verification exposes bugs.

- [ ] **Step 1: Run WarmTestRunner test suite**

Run:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```

Expected: PASS.

- [ ] **Step 2: Validate Tensor4all skeleton alignment**

Run:

```bash
julia --project=. --startup-file=no -e 'using WarmTestRunner; s = WarmTestRunner.run(pkgroot="extern/Tensor4all.jl", tests=["api/skeleton_alignment.jl"], fresh=true, use_revise=false); show(stdout, MIME("text/plain"), s); println(); exit(s.failed == 0 && s.errored == 0 && s.crashed == 0 ? 0 : 1)'
```

Expected: PASS with `test/api/skeleton_alignment.jl` passing without editing Tensor4all.

- [ ] **Step 3: Validate Tensor4all full suite**

Run:

```bash
julia --project=. --startup-file=no -e 'using WarmTestRunner; s = WarmTestRunner.run(pkgroot="extern/Tensor4all.jl", fresh=true, use_revise=false); show(stdout, MIME("text/plain"), s); println(); exit(s.failed == 0 && s.errored == 0 && s.crashed == 0 ? 0 : 1)'
```

Expected: PASS or only failures unrelated to WarmTestRunner execution semantics. If failures occur, inspect `s.results[i].stdout`, `stderr`, `exception_summary`, and `stacktrace` before changing code.

- [ ] **Step 4: Commit verification fixes**

Only if Step 1-3 required fixes, commit the touched implementation, test, and documentation files:

```bash
git add Project.toml Manifest.toml src test README.md SPEC.md STATUS.md
git commit -m "fix: stabilize virtual execution backend"
```

## Self-Review Notes

- Spec coverage: the plan covers Julia 1.12 compat, TestRunner-style backend, `test/runtests.jl` entry, `Main` topmodule, include interception, file/testset/line/expression selection, diagnostics schema v2, worker integration, controller scheduling, quickfail, docs, and Tensor4all validation.
- Compatibility: the old per-file isolated-module execution path is intentionally removed.
- Risk: Task 4 and Task 5 are the highest-risk steps because they port interpreter internals. Keep those commits small and run `test/virtual_execution.jl` after every edit.
- Legal: copied TestRunner.jl-derived code must keep the MIT attribution header in `src/virtual_execution.jl`.
