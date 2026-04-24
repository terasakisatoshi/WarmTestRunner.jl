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

function make_no_entry_planning_fixture(root::AbstractString; files::Dict{String,String})
    write_file(joinpath(root, "Project.toml"), """
    name = "PlanningFixture"
    uuid = "11111111-1111-1111-1111-111111111111"
    version = "0.1.0"
    """)
    write_file(joinpath(root, "src", "PlanningFixture.jl"), "module PlanningFixture\nend\n")
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

@testset "missing statically included file errors when selected" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("missing.jl")
            """,
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["missing.jl"])
    end
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
            message = "include(\\"string_literal.jl\\")"
            include( "selection.jl" )
            """,
            files = Dict("selection.jl" => "@test true\n"),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["selection.jl"])
        selection = only(only(plans).selections)
        @test endswith(selection.file, joinpath("test", "selection.jl"))
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["ghost.jl"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["string_literal.jl"])
    end
end

@testset "static include discovery handles module include forms" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            module Sub
            end
            include(Sub, "inside.jl")
            Base.include(Sub, "base_inside.jl")
            """,
            files = Dict(
                "inside.jl" => "@test true\n",
                "base_inside.jl" => "@test true\n",
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["inside.jl"])
        selection = only(only(plans).selections)
        @test endswith(selection.file, joinpath("test", "inside.jl"))

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["base_inside.jl"])
        selection = only(only(plans).selections)
        @test endswith(selection.file, joinpath("test", "base_inside.jl"))
    end
end

@testset "static include discovery ignores uncalled function bodies" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test

            function latent_tests()
                include("ghost.jl")
            end

            @test true
            """,
            files = Dict("ghost.jl" => "@test false\n"),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)

        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["ghost.jl"])
    end
end

@testset "static include discovery follows top-level executable containers" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test

            begin
                include("grouped.jl")
            end

            @testset "root wrapper" begin
                include("wrapped.jl")
            end

            if false
                include("conditional_ghost.jl")
            end

            f() = include("short_function_ghost.jl")
            typed_f()::Any = include("typed_short_function_ghost.jl")
            """,
            files = Dict(
                "grouped.jl" => """
                using Test
                @testset "grouped selected" begin
                    @test true
                end

                module Inner
                using Test
                @testset "inside module selected" begin
                    @test false
                end
                end
                """,
                "wrapped.jl" => """
                using Test
                @testset "wrapped selected" begin
                    @test false

                    function latent()
                        @testset "latent hidden" begin
                            @test false
                        end
                    end

                    typed_latent()::Any = @testset "typed latent hidden" begin
                        @test false
                    end

                    if false
                        @testset "conditional latent hidden" begin
                            @test false
                        end
                    end
                end
                """,
                "short_function_ghost.jl" => "@test false\n",
                "typed_short_function_ghost.jl" => "@test false\n",
                "conditional_ghost.jl" => "@test false\n",
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["grouped.jl"])
        @test endswith(only(only(plans).selections).file, joinpath("test", "grouped.jl"))

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["wrapped.jl"])
        @test endswith(only(only(plans).selections).file, joinpath("test", "wrapped.jl"))
        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningWrappedInclude))
        @test result.status == :failed

        plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["wrapped selected"])
        @test endswith(only(only(plans).selections).file, joinpath("test", "wrapped.jl"))
        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningWrappedNameInclude))
        @test result.status == :failed

        plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["inside module selected"])
        @test endswith(only(only(plans).selections).file, joinpath("test", "grouped.jl"))
        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningModuleName))
        @test result.status == :failed

        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = ["latent hidden"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = ["typed latent hidden"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = ["conditional latent hidden"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["short_function_ghost.jl"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["typed_short_function_ghost.jl"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["conditional_ghost.jl"])
    end
end

@testset "selected include inside wrapper does not run sibling tests" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test

            @testset "root wrapper" begin
                include("wrapper_setup.jl")
                @test false
                include("target.jl")
            end
            """,
            files = Dict(
                "wrapper_setup.jl" => """
                const WRAPPED_SETUP_VALUE = 41
                """,
                "target.jl" => """
                using Test

                @testset "target selected" begin
                    @test WRAPPED_SETUP_VALUE + 1 == 42
                end
                """,
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        plan = only(WarmTestRunner.build_execution_plans(cfg; tests = ["target.jl"]))
        result = WarmTestRunner.execute_plan(plan; topmodule = Module(:ExecutionPlanningWrapperSibling))
        @test result.status == :passed
        @test occursin("target selected", result.stdout)
        @test !any(d -> d.file == joinpath(root, "test", "runtests.jl"), result.diagnostics)
    end
end

@testset "multiple entry selections keep all patterns" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["selected testset", "other testset"])
    selection = only(only(plans).selections)
    @test endswith(selection.file, joinpath("test", "selection.jl"))
    @test selection.patterns == Any["selected testset", "other testset"]

    added_load_path = !(PLANNING_FIXTURE_ROOT in LOAD_PATH)
    added_load_path && pushfirst!(LOAD_PATH, PLANNING_FIXTURE_ROOT)
    try
        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningNameSelections))
        @test result.status == :passed
        @test occursin("selected testset", result.stdout)
        @test occursin("other testset", result.stdout)
    finally
        added_load_path && filter!(path -> path != PLANNING_FIXTURE_ROOT, LOAD_PATH)
    end
end

@testset "unknown testset selection errors" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = ["not a testset"])
end

@testset "vector line selections execute selected tests" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("selection.jl")
            """,
            files = Dict(
                "selection.jl" => """
                using Test

                @testset "first selected" begin
                    @test true
                end

                @testset "unselected" begin
                    @test false
                end

                @testset "second selected" begin
                    @test true
                end
                """,
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        plans = WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => [4, 12]])
        selection = only(only(plans).selections)
        @test selection.patterns == Any[4, 12]
        @test selection.filter_lines == Set([4, 12])

        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningVectorLines))

        @test result.status == :passed
        @test occursin("first selected", result.stdout)
        @test occursin("second selected", result.stdout)
        @test !occursin("unselected", result.stdout)
    end
end

@testset "line filters do not hide expression selections in same file" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("selection.jl")
            """,
            files = Dict(
                "selection.jl" => """
                using Test

                @testset "line selected" begin
                    @test true
                end

                @testset "expression selected" begin
                    @test false
                end
                """,
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)
        plans = WarmTestRunner.build_execution_plans(
            cfg;
            line_patterns = ["selection.jl" => 4],
            expression_patterns = ["selection.jl" => "expression selected"],
        )

        results = [
            WarmTestRunner.execute_plan(plan; topmodule = Module(Symbol(:ExecutionPlanningMixedSelections, index)))
            for (index, plan) in pairs(plans)
        ]

        @test any(result -> result.status == :failed, results)
    end
end

@testset "invalid line selections are rejected" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => Int[]])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => 1.5])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = Any["selection.jl"])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = Any[123 => 1])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => 0])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => -1])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => -1:1])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["selection.jl" => [3, 0]])
end

@testset "invalid expression selectors are rejected" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; expression_patterns = Any["selection.jl"])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; expression_patterns = Any[123 => "selected testset"])
end

@testset "explicit empty selectors are rejected" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = String[])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = Any[123])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = 123)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = Any[])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = 123)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = Pair{String,Any}[])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = 123)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; expression_patterns = Pair{String,Any}[])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; expression_patterns = 123)
end

@testset "empty changed and rerun selectors still validate explicit selectors" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; rerun_failed = true, last_failed = String[], testsets = ["not a testset"])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; rerun_failed = true, last_failed = String[], line_patterns = ["selection.jl" => 0])
    @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; rerun_failed = true, last_failed = String[], expression_patterns = ["missing.jl" => "x"])

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
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; changed_only = true, testsets = ["not a testset"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; changed_only = true, line_patterns = ["alpha.jl" => 0])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; changed_only = true, expression_patterns = ["missing.jl" => "x"])
    end
end

@testset "changed_only ignores unreachable implicit changes" begin
    mktempdir() do root
        make_planning_fixture(
            root;
            runtests = """
            using Test
            include("alpha.jl")
            """,
            files = Dict(
                "alpha.jl" => "@test true\n",
                "beta.jl" => "@test false\n",
            ),
        )
        Base.run(`git -C $root init --quiet`)
        Base.run(`git -C $root add .`)
        Base.run(`git -C $root commit --quiet -m initial`)
        write_file(joinpath(root, "test", "beta.jl"), "@test true\n")

        cfg = WarmTestRunner.make_config(pkgroot = root)
        @test isempty(WarmTestRunner.build_execution_plans(cfg; changed_only = true))
    end
end

@testset "rerun_failed ignores unreachable implicit failures" begin
    cfg = WarmTestRunner.make_config(pkgroot = PLANNING_FIXTURE_ROOT)
    @test isempty(WarmTestRunner.build_execution_plans(cfg; rerun_failed = true, last_failed = ["missing.jl"]))
end

@testset "planning without runtests validates and applies selectors" begin
    mktempdir() do root
        make_no_entry_planning_fixture(
            root;
            files = Dict(
                "alpha.jl" => """
                using Test

                @testset "alpha selected" begin
                    @test true
                end

                @testset "alpha unselected" begin
                    @test false
                end
                """,
                "beta.jl" => """
                using Test

                @testset "beta selected" begin
                    @test true
                end
                """,
            ),
        )
        cfg = WarmTestRunner.make_config(pkgroot = root)

        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; tests = ["missing.jl"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; testsets = ["missing testset"])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; line_patterns = ["missing.jl" => 1])
        @test_throws ArgumentError WarmTestRunner.build_execution_plans(cfg; expression_patterns = ["missing.jl" => "alpha selected"])

        plans = WarmTestRunner.build_execution_plans(cfg; tests = ["alpha.jl"])
        @test length(plans) == 1
        @test endswith(only(plans).entryfile, joinpath("test", "alpha.jl"))
        @test only(only(plans).selections).run_all

        plans = WarmTestRunner.build_execution_plans(cfg; testsets = ["alpha selected"])
        @test length(plans) == 1
        @test endswith(only(plans).entryfile, joinpath("test", "alpha.jl"))
        result = WarmTestRunner.execute_plan(only(plans); topmodule = Module(:ExecutionPlanningNoEntryName))
        @test result.status == :passed
        @test occursin("alpha selected", result.stdout)
        @test !occursin("alpha unselected", result.stdout)

        plans = WarmTestRunner.build_execution_plans(cfg; line_patterns = ["alpha.jl" => 4])
        @test length(plans) == 1
        @test only(only(plans).selections).filter_lines == Set([4])

        plans = WarmTestRunner.build_execution_plans(cfg; expression_patterns = ["alpha.jl" => "alpha selected"])
        @test length(plans) == 1
        @test only(only(plans).selections).patterns == Any["alpha selected"]
    end
end
