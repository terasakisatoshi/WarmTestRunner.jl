using Test
using WarmTestRunner

function init_git_fixture_pkg()
    pkgroot = mktempdir()
    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "ChangedOnlyFixture"
        uuid = "11111111-2222-3333-4444-555555555555"
        version = "0.1.0"
        """,
    )
    write(joinpath(pkgroot, "src", "ChangedOnlyFixture.jl"), "module ChangedOnlyFixture\nend\n")
    write(joinpath(pkgroot, "test", "alpha.jl"), "using Test\n@test true\n")
    write(joinpath(pkgroot, "test", "beta.jl"), "using Test\n@test true\n")

    Base.run(`git -C $pkgroot init`)
    Base.run(`git -C $pkgroot config user.email warmtestrunner@example.com`)
    Base.run(`git -C $pkgroot config user.name WarmTestRunner`)
    Base.run(`git -C $pkgroot add .`)
    Base.run(`git -C $pkgroot commit -m initial`)
    return pkgroot
end

@testset "discover tests excludes runtests and parses tags" begin
    pkgroot = mktempdir()
    mkpath(joinpath(pkgroot, "test", "unit"))

    write(joinpath(pkgroot, "test", "runtests.jl"), "error(\"should not be discovered\")\n")
    write(joinpath(pkgroot, "test", "warmtest_bootstrap.jl"), "global WARMTEST_BOOTSTRAPPED = true\n")
    write(joinpath(pkgroot, "test", "alpha.jl"), "# warmtest: tags=slow,network\n")
    write(joinpath(pkgroot, "test", "unit", "beta.jl"), "println(\"beta\")\n")

    jobs = WarmTestRunner.discover_tests(pkgroot)

    @test [job.path for job in jobs] == sort([
        joinpath(pkgroot, "test", "alpha.jl"),
        joinpath(pkgroot, "test", "unit", "beta.jl"),
    ])
    @test jobs[1].tags == ["slow", "network"]
    @test jobs[2].tags == String[]
end

@testset "parse_warmtest_tags handles missing and malformed directives" begin
    pkgroot = mktempdir()

    absent = joinpath(pkgroot, "absent.jl")
    write(absent, "println(\"no directive here\")\n")

    malformed = joinpath(pkgroot, "malformed.jl")
    write(malformed, "# warmtest: nope\n")

    empty_tags = joinpath(pkgroot, "empty_tags.jl")
    write(empty_tags, "# warmtest: tags =   \n")

    @test WarmTestRunner.parse_warmtest_tags(absent) == String[]
    @test WarmTestRunner.parse_warmtest_tags(malformed) == String[]
    @test WarmTestRunner.parse_warmtest_tags(empty_tags) == String[]
end

@testset "discover_changed_tests changed_only behavior" begin
    @testset "selects all tests when src changes" begin
        pkgroot = init_git_fixture_pkg()
        write(
            joinpath(pkgroot, "src", "ChangedOnlyFixture.jl"),
            "module ChangedOnlyFixture\nconst SRC_TOUCH = :changed\nend\n",
        )

        jobs = try
            WarmTestRunner.discover_changed_tests(pkgroot)
        catch err
            err
        end

        @test jobs isa Vector{WarmTestRunner.TestJob}
        if jobs isa Vector{WarmTestRunner.TestJob}
            @test sort([job.name for job in jobs]) == ["alpha.jl", "beta.jl"]
        end
    end

    @testset "selects changed tracked and untracked test files" begin
        pkgroot = init_git_fixture_pkg()
        write(joinpath(pkgroot, "test", "alpha.jl"), "using Test\nprintln(\"alpha changed\")\n@test true\n")
        write(joinpath(pkgroot, "test", "gamma.jl"), "using Test\nprintln(\"gamma new\")\n@test true\n")

        jobs = try
            WarmTestRunner.discover_changed_tests(pkgroot)
        catch err
            err
        end

        @test jobs isa Vector{WarmTestRunner.TestJob}
        if jobs isa Vector{WarmTestRunner.TestJob}
            @test sort([job.name for job in jobs]) == ["alpha.jl", "gamma.jl"]
        end
    end

    @testset "returns no jobs for irrelevant file changes" begin
        pkgroot = init_git_fixture_pkg()
        write(joinpath(pkgroot, "notes.txt"), "docs only\n")

        jobs = try
            WarmTestRunner.discover_changed_tests(pkgroot)
        catch err
            err
        end

        @test jobs isa Vector{WarmTestRunner.TestJob}
        if jobs isa Vector{WarmTestRunner.TestJob}
            @test isempty(jobs)
        end
    end

    @testset "falls back to full discovery when git is unavailable" begin
        pkgroot = mktempdir()
        mkpath(joinpath(pkgroot, "src"))
        mkpath(joinpath(pkgroot, "test"))

        write(
            joinpath(pkgroot, "Project.toml"),
            """
            name = "ChangedOnlyFixture"
            uuid = "11111111-2222-3333-4444-555555555555"
            version = "0.1.0"
            """,
        )
        write(joinpath(pkgroot, "src", "ChangedOnlyFixture.jl"), "module ChangedOnlyFixture\nend\n")
        write(joinpath(pkgroot, "test", "alpha.jl"), "using Test\n@test true\n")
        write(joinpath(pkgroot, "test", "beta.jl"), "using Test\n@test true\n")

        discovered = WarmTestRunner.discover_tests(pkgroot)
        jobs = WarmTestRunner.discover_changed_tests(pkgroot)

        @test [job.name for job in jobs] == [job.name for job in discovered]
    end
end
