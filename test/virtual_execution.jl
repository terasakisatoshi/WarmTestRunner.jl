using Test
using WarmTestRunner

const VIRTUAL_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")
const VIRTUAL_FIXTURE_ENTRY = joinpath(VIRTUAL_FIXTURE_ROOT, "test", "runtests.jl")

const VIRTUAL_FIXTURE_LOAD_PATH_ADDED = !(VIRTUAL_FIXTURE_ROOT in LOAD_PATH)
VIRTUAL_FIXTURE_LOAD_PATH_ADDED && pushfirst!(LOAD_PATH, VIRTUAL_FIXTURE_ROOT)

try
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

    @testset "virtual execution top-level test failure is failed" begin
        mktempdir() do tmp
            entry = joinpath(tmp, "runtests.jl")
            write(entry, """
            using Test

            @test 1 == 2
            """)
            plan = WarmTestRunner.ExecutionPlan(entryfile = entry, run_all = true)
            result = WarmTestRunner.execute_plan(plan; topmodule = Module(:VirtualExecutionTopLevelFailure))
            @test result.status == :failed
        end
    end
finally
    VIRTUAL_FIXTURE_LOAD_PATH_ADDED && filter!(path -> path != VIRTUAL_FIXTURE_ROOT, LOAD_PATH)
end
