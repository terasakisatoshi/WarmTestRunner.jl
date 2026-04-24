using Test

fixture_setup_value = VirtualExecutionFixture.add1(40)

@testset "setup file" begin
    @test fixture_setup_value == 41
end
