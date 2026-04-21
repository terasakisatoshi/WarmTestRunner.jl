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
        elapsed_total = sum(getfield.(collected, :elapsed)),
    )
end
