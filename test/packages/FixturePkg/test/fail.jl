using Test
using FixturePkg

@testset "fixture fail" begin
    @test add1(1) == 3
end
