#!/usr/bin/env julia

using Pkg
using WarmTestRunner

repo_root = normpath(joinpath(@__DIR__, ".."))

mktempdir(prefix = "warmtestrunner-smoke-") do tmp
    pkgroot = joinpath(tmp, "SmokeTarget")
    warm_home = joinpath(tmp, "warm-home")

    mkpath(joinpath(pkgroot, "src"))
    mkpath(joinpath(pkgroot, "test"))
    mkpath(warm_home)

    write(
        joinpath(pkgroot, "Project.toml"),
        """
        name = "SmokeTarget"
        uuid = "33333333-3333-3333-3333-333333333333"
        version = "0.1.0"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """,
    )

    write(
        joinpath(pkgroot, "src", "SmokeTarget.jl"),
        """
        module SmokeTarget

        export addone

        addone(x) = x + 1

        end
        """,
    )

    write(
        joinpath(pkgroot, "test", "runtests.jl"),
        """
        using Test
        using SmokeTarget

        include("basic.jl")
        """,
    )

    write(
        joinpath(pkgroot, "test", "basic.jl"),
        """
        @test addone(1) == 2
        """,
    )

    println("Smoke target: ", pkgroot)

    Pkg.activate(pkgroot)
    Pkg.develop(path = repo_root)

    ENV["WARMTESTRUNNER_HOME"] = warm_home

    cd(pkgroot) do
        WarmTestRunner.serve(pkgroot = pkgroot, jobs = 1)
        try
            summary = WarmTestRunner.run(pkgroot = pkgroot)
            @show summary.passed
            @show summary.failed
            @show summary.errored
            @show summary.crashed
            @show summary.skipped

            if summary.passed != 1 ||
               summary.failed != 0 ||
               summary.errored != 0 ||
               summary.crashed != 0 ||
               summary.skipped != 0
                error("WarmTestRunner smoke test failed")
            end
        finally
            WarmTestRunner.stop(pkgroot = pkgroot)
        end
    end
end
