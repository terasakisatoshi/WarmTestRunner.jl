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

function _status_label(status::Symbol)
    if status == :passed
        return "pass"
    elseif status == :failed
        return "fail"
    elseif status == :errored
        return "error"
    elseif status == :crashed
        return "crash"
    elseif status == :skipped
        return "skip"
    else
        return string(status)
    end
end

function _truncate_middle(str::AbstractString, maxchars::Int)
    chars = collect(String(str))
    length(chars) <= maxchars && return String(chars)
    left = div(maxchars - 1, 2)
    right = maxchars - left - 1
    return String(vcat(chars[1:left], ['…'], chars[(end - right + 1):end]))
end

function Base.show(io::IO, r::TestResult)
    print(io, "TestResult(", r.status, ", ")
    show(io, r.path)
    print(io, ", ", r.elapsed, "s)")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", r::TestResult)
    path_width = get(io, :warmtest_path_width, 72)
    print(io, "TestResult: ", _status_label(r.status), " — ")
    print(io, _truncate_middle(r.path, path_width))
    print(io, " (", round(r.elapsed; digits = 3), "s)")
    if r.worker_id !== nothing
        print(io, " [worker ", r.worker_id, "]")
    end
    verbose = get(io, :show_warmtest_full, false)
    if r.status != :passed && r.exception_summary !== nothing
        print(io, "\n  ", r.exception_summary)
    end
    if verbose && !isempty(r.stdout)
        print(io, "\n--- stdout ---\n", r.stdout)
    end
    if verbose && !isempty(r.stderr)
        print(io, "\n--- stderr ---\n", r.stderr)
    end
    if verbose && r.stacktrace !== nothing && !isempty(r.stacktrace)
        print(io, "\n--- stacktrace ---\n", r.stacktrace)
    end
    return nothing
end

function Base.show(io::IO, s::RunSummary)
    n = length(s.results)
    print(io, "RunSummary(", n, " file", n == 1 ? "" : "s", ": ")
    print(io, s.passed, " pass, ", s.failed, " fail, ", s.errored, " error, ", s.crashed, " crash")
    s.skipped > 0 && print(io, ", ", s.skipped, " skip")
    print(io, ")")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", s::RunSummary)
    print(io, "RunSummary: ")
    print(io, s.passed, " passed, ", s.failed, " failed, ", s.errored, " errored, ", s.crashed, " crashed")
    s.skipped > 0 && print(io, ", ", s.skipped, " skipped")
    print(io, " — ", round(s.elapsed_total; digits = 2), "s total\n")
    path_width = get(io, :warmtest_path_width, 72)
    for r in s.results
        label = _status_label(r.status)
        path_disp = _truncate_middle(r.path, path_width)
        print(io, "  ", rpad(label, 6), " ", lpad(string(round(r.elapsed; digits = 2)), 7), "s  ", path_disp)
        if r.worker_id !== nothing
            print(io, "  [w", r.worker_id, "]")
        end
        println(io)
        if r.status != :passed && r.exception_summary !== nothing
            exc = _truncate_middle(r.exception_summary, path_width + 13)
            println(io, "         ", exc)
        end
    end
    return nothing
end
