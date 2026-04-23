marker = ENV["WARMTEST_CRASH_ONCE_MARKER"]

if !isfile(marker)
    mkpath(dirname(marker))
    write(marker, "crashed\n")
    exit(1)
end

using Test

@testset "fixture crash once" begin
    @test isfile(marker)
end
