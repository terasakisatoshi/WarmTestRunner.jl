using Test
using FixturePkg

@testset "fixture pass" begin
    @test isdefined(Main, :WARMTEST_BOOTSTRAPPED)
    println("bootstrap hook loaded: $(Main.WARMTEST_BOOTSTRAPPED)")
    @test add1(1) == 2
end
