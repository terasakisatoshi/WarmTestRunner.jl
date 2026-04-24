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

@testset "multiple entry selections keep all patterns" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["selected testset", "other testset"])
    selection = only(only(plans).selections)
    @test endswith(selection.file, joinpath("test", "runtests.jl"))
    @test selection.patterns == Any["selected testset", "other testset"]
end
