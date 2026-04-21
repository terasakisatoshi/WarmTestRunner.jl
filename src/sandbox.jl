function capture_test_output(f::Function)
    stdout_pipe = Pipe()
    stderr_pipe = Pipe()
    Base.link_pipe!(stdout_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(stderr_pipe; reader_supports_async=true, writer_supports_async=true)
    stdout_reader = Base.pipe_reader(stdout_pipe)
    stdout_writer = Base.pipe_writer(stdout_pipe)
    stderr_reader = Base.pipe_reader(stderr_pipe)
    stderr_writer = Base.pipe_writer(stderr_pipe)
    stdout_task = @async read(stdout_reader, String)
    stderr_task = @async read(stderr_reader, String)
    value = nothing
    err = nothing
    bt = nothing
    try
        try
            value = redirect_stdout(stdout_writer) do
                redirect_stderr(stderr_writer) do
                    f()
                end
            end
        catch caught
            err = caught
            bt = catch_backtrace()
        end
        close(stdout_writer)
        close(stderr_writer)
        return (
            value = value,
            error = err,
            backtrace = bt,
            stdout = fetch(stdout_task),
            stderr = fetch(stderr_task),
        )
    finally
        isopen(stdout_writer) && close(stdout_writer)
        isopen(stderr_writer) && close(stderr_writer)
        isopen(stdout_reader) && close(stdout_reader)
        isopen(stderr_reader) && close(stderr_reader)
    end
end

function run_in_fresh_task(f::Function)
    result = Channel{Any}(1)
    task = Task(() -> begin
        try
            put!(result, (:ok, f()))
        catch err
            put!(result, (:err, err, catch_backtrace()))
        end
    end)
    schedule(task)
    outcome = take!(result)
    wait(task)
    return outcome
end

function classify_exception(err, bt)
    if err isa LoadError
        inner = err.error
        inner isa Test.TestSetException && return (:failed, sprint(showerror, inner), sprint(showerror, err, bt))
        return (:errored, sprint(showerror, err), sprint(showerror, err, bt))
    end
    err isa Test.TestSetException && return (:failed, sprint(showerror, err), sprint(showerror, err, bt))
    return (:errored, sprint(showerror, err), sprint(showerror, err, bt))
end

function run_test_file_in_module(testfile::AbstractString; helper::Union{Nothing, AbstractString} = nothing)
    started = time()
    outcome = run_in_fresh_task() do
        capture_test_output() do
            mod = Module(gensym(:WarmTestModule))
            Core.eval(mod, :(using Test))
            helper === nothing || Base.include(mod, helper)
            Base.include(mod, testfile)
            return nothing
        end
    end
    if outcome[1] == :ok
        captured = outcome[2]
        if captured.error !== nothing
            status, summary, stacktrace = classify_exception(captured.error, captured.backtrace)
            return TestResult(
                path = String(testfile),
                status = status,
                elapsed = time() - started,
                stdout = captured.stdout,
                stderr = captured.stderr,
                exception_summary = summary,
                stacktrace = stacktrace,
            )
        end
        return TestResult(
            path = String(testfile),
            status = :passed,
            elapsed = time() - started,
            stdout = captured.stdout,
            stderr = captured.stderr,
        )
    end
    _, err, bt = outcome
    status, summary, stacktrace = classify_exception(err, bt)
    return TestResult(
        path = String(testfile),
        status = status,
        elapsed = time() - started,
        stdout = "",
        stderr = "",
        exception_summary = summary,
        stacktrace = stacktrace,
    )
end
