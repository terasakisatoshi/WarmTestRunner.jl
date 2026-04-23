function summarize_results(results::AbstractVector{<:TestResult})
    collected = collect(results)
    statuses = getfield.(collected, :status)
    return RunSummary(
        results = collected,
        passed = count(==(:passed), statuses),
        failed = count(==(:failed), statuses),
        errored = count(==(:errored), statuses),
        crashed = count(==(:crashed), statuses),
        skipped = count(==(:skipped), statuses),
        elapsed_total = sum(result.elapsed for result in collected; init = 0.0),
    )
end

function result_to_json_data(result::TestResult)
    return (
        path = result.path,
        status = String(result.status),
        elapsed = result.elapsed,
        stdout = result.stdout,
        stderr = result.stderr,
        exception_summary = result.exception_summary,
        stacktrace = result.stacktrace,
        worker_id = result.worker_id,
    )
end

function summary_to_json_data(summary::RunSummary)
    return (
        schema_version = 1,
        passed = summary.passed,
        failed = summary.failed,
        errored = summary.errored,
        crashed = summary.crashed,
        skipped = summary.skipped,
        elapsed_total = summary.elapsed_total,
        results = [result_to_json_data(result) for result in summary.results],
    )
end

function json_escape(text::AbstractString)
    io = IOBuffer()
    for char in text
        if char == '"'
            print(io, "\\\"")
        elseif char == '\\'
            print(io, "\\\\")
        elseif char == '\n'
            print(io, "\\n")
        elseif char == '\r'
            print(io, "\\r")
        elseif char == '\t'
            print(io, "\\t")
        elseif Int(char) < 0x20
            print(io, "\\u", lpad(string(Int(char), base = 16), 4, '0'))
        else
            print(io, char)
        end
    end
    return String(take!(io))
end

json_value(value::Nothing) = "null"
json_value(value::Bool) = value ? "true" : "false"
json_value(value::Symbol) = json_value(String(value))
json_value(value::AbstractString) = "\"" * json_escape(value) * "\""
json_value(value::Integer) = string(value)
json_value(value::AbstractFloat) = isfinite(value) ? string(value) : "null"

function json_value(value::AbstractVector)
    return "[" * join((json_value(item) for item in value), ",") * "]"
end

function json_value(value::NamedTuple)
    fields = String[]
    for name in keys(value)
        push!(fields, json_value(String(name)) * ":" * json_value(getfield(value, name)))
    end
    return "{" * join(fields, ",") * "}"
end

function summary_to_json(summary::RunSummary)
    return json_value(summary_to_json_data(summary))
end
