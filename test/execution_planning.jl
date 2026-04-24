using Test
using WarmTestRunner

const PLANNING_FIXTURE_ROOT = joinpath(@__DIR__, "packages", "VirtualExecutionFixture")

function write_file(path::AbstractString, text::AbstractString)
    mkpath(dirname(path))
    write(path, text)
    return path
end

function make_planning_fixture(root::AbstractString; runtests::AbstractString, files::Dict{String,String} = Dict{String,String}())
    write_file(joinpath(root, "Project.toml"), """
    name = "PlanningFixture"
    uuid = "11111111-1111-1111-1111-111111111111"
    version = "0.1.0"
    """)
    write_file(joinpath(root, "src", "PlanningFixture.jl"), "module PlanningFixture\nend\n")
    write_file(joinpath(root, "test", "runtests.jl"), runtests)
    for (path, text) in files
        write_file(joinpath(root, "test", path), text)
    end
    return root
end

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

@testset "empty changed and rerun selectors produce no plans" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test isempty(WarmTestRunner.build_execution_plans(cfg; rerun_failed = true, last_failed = String[]))

    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("alpha.jl")
            """,
            files = Dict("alpha.jl" => "@test true\n"),
        )
        Base.run(`git -C $root init --quiet`)
        Base.run(`git -C $root add .`)
        Base.run(`git -C $root commit --quiet -m initial`)

        cfg = WarmTestRunner.make_config(pkgroot = root)
        @test isempty(WarmTestRunner.build_execution_plans(cfg; changed_only = true))
    end
end

@testset "path-qualified selection does not fall back to basename" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["wrong/selection.jl"])
end

@testset "basename collisions require qualified selections" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("unit/shared.jl")
            include("integration/shared.jl")
            """,
            files = Dict(
                "unit/shared.jl" => "@test true\n",
                "integration/shared.jl" => "@test true\n",
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)

        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["shared.jl"])

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["unit/shared.jl"])
        selection = only(only(plans).selections)
        @test endswith(selection.file, joinpath("test", "unit", "shared.jl"))
        @test selection.run_all
    end
end

@testset "explicit rerun_failed tests normalize before intersection" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(
        cfg;
        tests = ["selection.jl"],
        rerun_failed = true,
        last_failed = ["test/selection.jl"],
    )
    selection = only(only(plans).selections)
    @test endswith(selection.file, joinpath("test", "selection.jl"))
    @test selection.run_all
end

@testset "static include discovery handles whitespace and comments" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            # include("ghost.jl")
            include( "selection.jl" )
            """,
            files = Dict("selection.jl" => "@test true\n"),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl"])
        selection = only(only(plans).selections)
        @test endswith(selection.file, joinpath("test", "selection.jl"))
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["ghost.jl"])
    end
end

@testset "multiple entry selections keep all patterns" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["selected testset", "other testset"])
    selection = only(only(plans).selections)
    @test endswith(selection.file, joinpath("test", "runtests.jl"))
    @test selection.patterns == Any["selected testset", "other testset"]
end
