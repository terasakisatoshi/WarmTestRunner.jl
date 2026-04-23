using Test
using WarmTestRunner

@testset "summary JSON data preserves results" begin
    result = WarmTestRunner.TestResult(
        path = "/tmp/pkg/test/fail.jl",
        status = :failed,
        elapsed = 0.25,
        stdout = "hello\n",
        stderr = "warn",
        exception_summary = "Test failed",
        stacktrace = "stack",
        worker_id = 3,
    )
    summary = WarmTestRunner.RunSummary(
        results = [result],
        passed = 0,
        failed = 1,
        errored = 0,
        crashed = 0,
        skipped = 0,
        elapsed_total = 0.25,
    )

    data = WarmTestRunner.summary_to_json_data(summary)

    @test data.schema_version == 1
    @test data.failed == 1
    @test data.elapsed_total == 0.25
    @test length(data.results) == 1
    @test data.results[1].path == "/tmp/pkg/test/fail.jl"
    @test data.results[1].status == "failed"
    @test data.results[1].exception_summary == "Test failed"
    @test data.results[1].worker_id == 3
end

@testset "summary JSON string escapes strings" begin
    result = WarmTestRunner.TestResult(
        path = "quote\"slash\\newline\n.jl",
        status = :passed,
        elapsed = 0.1,
        stdout = "line1\nline2",
        stderr = "",
    )
    summary = WarmTestRunner.RunSummary(
        results = [result],
        passed = 1,
        failed = 0,
        errored = 0,
        crashed = 0,
        skipped = 0,
        elapsed_total = 0.1,
    )

    json = WarmTestRunner.summary_to_json(summary)

    @test json isa String
    @test occursin("\"schema_version\":1", json)
    @test occursin("\"path\":\"quote\\\"slash\\\\newline\\n.jl\"", json)
    @test occursin("\"stdout\":\"line1\\nline2\"", json)
    @test occursin("\"exception_summary\":null", json)
end
