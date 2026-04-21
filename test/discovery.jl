using Test
using WarmTestRunner

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
