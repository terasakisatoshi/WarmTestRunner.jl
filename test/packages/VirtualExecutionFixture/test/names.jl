using Test
using VirtualExecutionFixture.Wrapper
using VirtualExecutionFixture.UpstreamName

@testset "ambiguous exported module names" begin
    @test VirtualExecutionFixture.Wrapper.UpstreamName.token() == :wrapped
    @test VirtualExecutionFixture.UpstreamName.token() == :upstream
end
