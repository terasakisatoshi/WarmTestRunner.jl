using Test
using WarmTestRunner

@testset "watch path resolution" begin
    mktempdir() do tmp
        srcdir = joinpath(tmp, "src")
        testdir = joinpath(tmp, "test")
        mkpath(srcdir)
        mkpath(testdir)

        paths = WarmTestRunner.resolve_watch_paths(tmp, ["src", testdir, "missing"])

        @test paths == sort([abspath(srcdir), abspath(testdir)])

        nested = joinpath(srcdir, "nested")
        mkpath(nested)

        recursive_paths = WarmTestRunner.resolve_watch_paths(tmp, ["src"])
        @test recursive_paths == sort([abspath(srcdir), abspath(nested)])
    end
end

@testset "one-shot watch" begin
    @test_throws ArgumentError WarmTestRunner._watch_once(String[]; debounce_seconds = 0)

    mktempdir() do tmp
        watched = joinpath(tmp, "watched.txt")
        write(watched, "before")

        task = @async WarmTestRunner._watch_once([watched]; debounce_seconds = 0.05)
        sleep(0.2)
        write(watched, "after")

        changed = fetch(task)
        @test changed == abspath(watched)
    end
end

@testset "watch argument validation" begin
    mktempdir() do tmp
        err = try
            WarmTestRunner.watch(pkgroot = tmp, debounce_seconds = 0)
            nothing
        catch caught
            caught
        end
        @test err isa ArgumentError
        @test occursin("debounce_seconds", sprint(showerror, err))
    end
end
