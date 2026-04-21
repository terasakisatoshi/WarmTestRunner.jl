using Test
using WarmTestRunner

@testset "sandbox classifies pass fail and error" begin
    tmp = mktempdir()

    pass_file = joinpath(tmp, "pass.jl")
    fail_file = joinpath(tmp, "fail.jl")
    error_file = joinpath(tmp, "error.jl")
    helper_file = joinpath(tmp, "helper.jl")
    helper_test_file = joinpath(tmp, "helper_test.jl")
    big_output_file = joinpath(tmp, "big_output.jl")

    write(pass_file, """
    using Test
    @testset "pass" begin
        println("hello from pass")
        @test 1 + 1 == 2
    end
    """)

    write(fail_file, """
    using Test
    @testset "fail" begin
        println("hello from fail")
        @test 1 + 1 == 3
    end
    """)

    write(error_file, """
    using Test
    println(stderr, "hello from error")
    error("boom")
    """)

    write(helper_file, """
    helper_message() = println("hello from helper")
    """)

    write(helper_test_file, """
    using Test
    helper_message()
    @test 2 + 2 == 4
    """)

    write(big_output_file, """
    using Test
    @testset "big output" begin
        for _ in 1:4000
            println("stdout payload " * repeat("x", 32))
            println(stderr, "stderr payload " * repeat("y", 32))
        end
        @test true
    end
    """)

    pass_result = WarmTestRunner.run_test_file_in_module(pass_file)
    fail_result = WarmTestRunner.run_test_file_in_module(fail_file)
    error_result = WarmTestRunner.run_test_file_in_module(error_file)
    helper_result = WarmTestRunner.run_test_file_in_module(helper_test_file; helper = helper_file)
    big_output_result = WarmTestRunner.run_test_file_in_module(big_output_file)

    @test pass_result.status == :passed
    @test occursin("hello from pass", pass_result.stdout)
    @test fail_result.status == :failed
    @test occursin("hello from fail", fail_result.stdout)
    @test !isnothing(fail_result.exception_summary)
    @test occursin("Some tests did not pass", fail_result.exception_summary)
    @test !isnothing(fail_result.stacktrace)
    @test occursin("fail.jl", fail_result.stacktrace)
    @test error_result.status == :errored
    @test occursin("hello from error", error_result.stderr)
    @test !isnothing(error_result.exception_summary)
    @test occursin("boom", error_result.exception_summary)
    @test !isnothing(error_result.stacktrace)
    @test occursin("error.jl", error_result.stacktrace)
    @test helper_result.status == :passed
    @test occursin("hello from helper", helper_result.stdout)
    @test big_output_result.status == :passed
    @test occursin("stdout payload", big_output_result.stdout)
    @test occursin("stderr payload", big_output_result.stderr)

    summary = WarmTestRunner.summarize_results(view([pass_result, fail_result, error_result, helper_result, big_output_result], :))
    @test summary.passed == 3
    @test summary.failed == 1
    @test summary.errored == 1
    @test summary.elapsed_total > 0
end
