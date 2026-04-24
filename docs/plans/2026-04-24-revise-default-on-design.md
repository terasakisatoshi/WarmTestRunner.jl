# Revise Default On Design

## Goal

Make `Revise.jl` integration enabled by default so local iteration gets warm-worker code reloading without requiring `use_revise = true`.

## Decision

Set `RunnerConfig.use_revise` to `true` by default. Preserve the explicit opt-out path: callers that pass `use_revise = false` must continue to bootstrap workers without loading `Revise`.

## Alternatives Considered

1. Change the `RunnerConfig` field default to `true`.

   This is the selected approach. It keeps direct `RunnerConfig(...)` construction and `make_config(...)` behavior consistent.

2. Rewrite only `make_config(...)` to default missing `use_revise` to `true`.

   This leaves direct `RunnerConfig()` construction with the old behavior, which makes the public configuration type inconsistent.

3. Add environment-variable or auto-detection behavior.

   This is unnecessary for the requested behavior and would add another configuration surface.

## Scope

- Update `src/config.jl` so `use_revise` defaults to `true`.
- Update tests to assert the new default and the explicit `false` opt-out.
- Keep worker bootstrap ordering unchanged: Revise loads after environment activation and before package preload/bootstrap hook.
- Update README/SPEC/STATUS entries that currently state or imply `use_revise` defaults to `false`.

## Testing

Run focused tests while developing, then run the clean-room package test before completion:

```bash
julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'
```
