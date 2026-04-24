using Test

@testset "selected testset" begin
    @test fixture_setup_value == 41
    @test VirtualExecutionFixture.add1(1) == 2
end

@testset "other testset" begin
    @test VirtualExecutionFixture.add1(2) == 3
end

@test VirtualExecutionFixture.add1(3) == 4
