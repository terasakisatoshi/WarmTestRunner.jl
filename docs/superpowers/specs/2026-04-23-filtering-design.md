# WarmTestRunner Filtering Design

## Goal

Add a small first slice of richer test selection to the Julia API. Users should be able
to narrow candidate test files by path substring and by warmtest tags without changing
the daemon lifecycle or introducing a CLI-specific selector language.

## Public API

Extend `WarmTestRunner.run` with these keyword arguments:

```julia
filter::Union{Nothing, AbstractString} = nothing
include_tags::Vector{String} = String[]
exclude_tags::Vector{String} = String[]
```

Examples:

```julia
WarmTestRunner.run(filter = "worker")
WarmTestRunner.run(include_tags = ["slow"])
WarmTestRunner.run(exclude_tags = ["network"])
```

`filter` is a plain substring match against both `relpath(job.path, pkgroot)` and
`basename(job.path)`. It is intentionally not a regular expression in this first slice.

`include_tags` keeps files that have at least one requested tag. `exclude_tags` removes
files that have at least one excluded tag. If both are provided, include filtering runs
first and exclude filtering runs second.

## Data Flow

The existing candidate selection remains the first step:

- explicit `tests`
- `changed_only`
- `rerun_failed`
- full discovery when no selector is provided

After candidates are built, one shared filtering function narrows the `Vector{TestJob}`.
This keeps filtering independent from discovery and makes daemon-backed runs and direct
`build_jobs` tests exercise the same behavior.

The controller request carries `filter`, `include_tags`, and `exclude_tags` from the
client process to the daemon. Add a new protocol version and restart older controllers
before filtered runs so old daemons do not silently ignore the new request fields.

## Edge Cases

An empty result set returns the existing empty `RunSummary`.

`filter = nothing` means no path filtering. `filter = ""` is treated as no-op path
filtering because every path contains the empty string.

Empty `include_tags` and `exclude_tags` are no-ops.

Filtering applies after `rerun_failed`, so `run(rerun_failed = true, filter = "foo")`
means "previously failed files whose path matches foo".

Filtering applies after explicit `tests`, so users can further narrow an explicit list.

## Testing

Add unit tests around `build_jobs` for:

- path substring matching
- include tag matching
- exclude tag matching
- include and exclude composition
- filtering after explicit tests

Add daemon-level coverage for at least one public `run(filter = ...)` case and one
public tag-filter case to verify request serialization and controller handling.
