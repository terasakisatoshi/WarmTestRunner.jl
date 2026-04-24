# Repository Guidelines

## Project Structure & Module Organization
`src/WarmTestRunner.jl` is the package entry point and wires together the runtime layers in `src/`: `config.jl`, `types.jl`, `discovery.jl`, `sandbox.jl`, `worker.jl`, `server_registry.jl`, `controller.jl`, and `results.jl`. Keep new code in the file that matches its responsibility instead of growing `WarmTestRunner.jl`.

`test/` mirrors those subsystems with focused files such as `controller_daemon.jl`, `crash_recovery.jl`, and `sandbox.jl`. `test/packages/FixturePkg/` is a fixture package used for worker and daemon integration coverage. `SPEC.md` describes the intended product surface; `STATUS.md` tracks the implemented MVP and its constraints.

## Build, Test, and Development Commands
`julia --project=. -e 'using Pkg; Pkg.instantiate()'` installs dependencies from `Project.toml` and `Manifest.toml`.

`julia --project=. --startup-file=no -e 'using Pkg; Pkg.test()'` runs the repository test suite in the clean test environment and is the standard verification step before merging. Running `include("test/runtests.jl")` separately is usually redundant.

`julia --project=. -e 'using WarmTestRunner; WarmTestRunner.serve(); WarmTestRunner.runtests()'` starts or reuses the daemon-backed worker pool for local iteration.

## Coding Style & Naming Conventions
Follow the existing Julia style: 4-space indentation, no tabs, concise functions, and explicit keyword arguments when configuration matters. Use `UpperCamelCase` for types like `RunnerConfig`, `snake_case` for functions like `start_worker_pool`, and all-caps names for test constants like `FIXTURE_ROOT`.

Preserve the current separation of concerns: discovery, sandbox execution, worker lifecycle, controller logic, and registry I/O should stay in distinct modules.

## Testing Guidelines
Use the standard `Test` library. Add focused regression tests under `test/` and include each new file from `test/runtests.jl`. Name test files after the subsystem they validate.

Prefer deterministic tests with `mktempdir()` and isolate daemon state with `withenv("WARMTESTRUNNER_HOME" => tmp)`. For integration scenarios, extend `test/packages/FixturePkg/` or generate temporary test files rather than depending on repository-global state.

## Commit & Pull Request Guidelines
Keep commit subjects short, imperative, and readable. The current history suggests a simple style, with optional Conventional Commit prefixes such as `feat: implement WarmTestRunner MVP`.

Pull requests should summarize the user-visible behavior change, list the verification commands you ran, and call out any API, configuration, or daemon-lifecycle implications. Link relevant issues or spec sections when the change implements or defers planned work.
