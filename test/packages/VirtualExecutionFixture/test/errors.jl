using Test

function fixture_domain_error()
    error("fixture domain error")
end

@testset "failure testset" begin
    @test VirtualExecutionFixture.add1(1) == 99
end

@testset "error testset" begin
    @test fixture_domain_error() == nothing
end
