module TerminalRegressionTests
    using DeepDiffs
    import REPL

    include("LibGhosttyVT.jl")
    using .LibGhosttyVT: LibGhosttyVT, cells, cursor

    @static if VERSION >= v"1.12-"
        const EmulatedCondition = Threads.Condition

        function wait_condition(condition)
            lock(condition)
            try
                return wait(condition)
            finally
                unlock(condition)
            end
        end

        function notify_condition(condition)
            lock(condition)
            try
                return notify(condition)
            finally
                unlock(condition)
            end
        end
    else
        const EmulatedCondition = Condition
        wait_condition(condition) = wait(condition)
        notify_condition(condition) = notify(condition)
    end

    function load_outputs(file)
        outputs = String[]
        decorators = String[]
        is_output = true
        is_continuation = false
        nlines = 0
        for line in readlines(file)
            if line[1] == '+'
                is_continuation = line[2] != '+'
                if is_continuation
                  until = findfirst(c -> c == '+', line[2:end])+1
                  nlines = parse(Int, line[2:until - 1])
                  push!(outputs,
                    join(split(outputs[end],'\n')[1:end-nlines],'\n'))
                else
                  push!(outputs,"")
                end
                is_output = true
                continue
            elseif line[1] == '-'
                if is_continuation
                  push!(decorators,
                    join(split(decorators[end],'\n')[1:end-nlines],'\n'))
                else
                  push!(decorators,"")
                end
                is_output = false
                continue
            elseif line[1] == '|'
                array = is_output ? outputs : decorators
                array[end] = string(array[end],isempty(array[end]) ? "" : "\n",line[2:end])
            else
                error("Unrecognized first character \"$(line[1])\"")
            end
        end
        outputs, decorators
    end

    mutable struct PTY
        master::Base.TTY
        slave::RawFD
    end
    Base.close(pty::PTY) = close(pty.master)

    function PTY()
        Sys.isunix() || error("TerminalRegressionTests requires a Unix PTY")
        flags = Base.Filesystem.JL_O_RDWR | Base.Filesystem.JL_O_NOCTTY
        fdm = ccall(:posix_openpt, Cint, (Cint,), flags)
        fdm == -1 && error("Failed to open PTY master")
        ccall(:grantpt, Cint, (Cint,), fdm) == 0 || error("grantpt failed")
        ccall(:unlockpt, Cint, (Cint,), fdm) == 0 || error("unlockpt failed")
        fds = ccall(:open, Cint, (Ptr{UInt8}, Cint), ccall(:ptsname, Ptr{UInt8}, (Cint,), fdm), flags)
        fds == -1 && error("Failed to open PTY slave")
        pty = PTY(Base.TTY(RawFD(fdm)), RawFD(fds))
        finalizer(close, pty)
    end

    mutable struct EmulatedTerminal <: REPL.Terminals.UnixTerminal
        input_buffer::IOBuffer
        out_stream::Base.TTY
        pty::PTY
        terminal::LibGhosttyVT.Terminal
        waiting::Bool
        step::EmulatedCondition
        filled::EmulatedCondition
        # Yield after every write, e.g. to test for flickering issues
        aggressive_yield::Bool
    end

    function EmulatedTerminal(cols::Integer = 80, rows::Integer = 24)
        pty = PTY()
        EmulatedTerminal(
            IOBuffer(UInt8[]; read = true, write = true, append = true, truncate = true, maxsize = typemax(Int)),
            Base.TTY(pty.slave), pty, LibGhosttyVT.Terminal(cols, rows),
            false, EmulatedCondition(), EmulatedCondition(), false)
    end
    if isdefined(REPL.LineEdit, :hascolor)
        @eval REPL.LineEdit.hascolor(::EmulatedTerminal) = true
    end
    function Base.wait(term::EmulatedTerminal)
        if !term.waiting || bytesavailable(term.input_buffer) != 0
            wait_condition(term.step)
        end
    end
    for T in (Vector{UInt8}, Array, AbstractArray, String, Symbol, Any, Char, UInt8)
        function Base.write(term::EmulatedTerminal,a::T)
            b = write(term.out_stream, a)
            if term.aggressive_yield
                notify_condition(term.step)
            end
            return b
        end
    end
    Base.eof(term::EmulatedTerminal) = false
    function Base.peek(term::EmulatedTerminal, ::Type{T}=UInt8) where {T}
        if bytesavailable(term.input_buffer) == 0
            term.waiting = true
            notify_condition(term.step)
            wait_condition(term.filled)
        end
        term.waiting = false
        peek(term.input_buffer, T)
    end
    function Base.read(term::EmulatedTerminal, ::Type{Char})
        if bytesavailable(term.input_buffer) == 0
            term.waiting = true
            notify_condition(term.step)
            wait_condition(term.filled)
        end
        term.waiting = false
        read(term.input_buffer, Char)
    end
    function Base.readuntil(term::EmulatedTerminal, delim::UInt8; kwargs...)
        if bytesavailable(term.input_buffer) == 0
            term.waiting = true
            notify_condition(term.step)
            wait_condition(term.filled)
        end
        term.waiting = false
        readuntil(term.input_buffer, delim; kwargs...)
    end
    function Base.readline(term::EmulatedTerminal; keep::Bool=false)
        line = readuntil(term, 0x0a, keep=true)::Vector{UInt8}
        i = length(line)
        if keep || i == 0 || line[i] != 0x0a
            return String(line)
        elseif i < 2 || line[i-1] != 0x0d
            return String(resize!(line,i-1))
        else
            return String(resize!(line,i-2))
        end
    end
    REPL.Terminals.raw!(t::EmulatedTerminal, raw::Bool) =
        ccall(:jl_tty_set_mode,
                 Int32, (Ptr{Cvoid},Int32),
                 t.out_stream.handle, raw) != -1
    REPL.Terminals.pipe_reader(t::EmulatedTerminal) = t.input_buffer
    REPL.Terminals.pipe_writer(t::EmulatedTerminal) = t.out_stream

    function _compare(output, outbuf)
        outstring = String(output)
        bufstring = String(outbuf)
        result = outstring == bufstring
        if !result
            println("Test failed. Expected result written to expected.out,
                actual result written to failed.out")
            open("failed.out","w") do f
                write(f,bufstring)
            end
            open("expected.out","w") do f
                write(f,outstring)
            end
            println(stdout, deepdiff(outstring, bufstring))
            error()
        end
        return result
    end

    const default_decorators = ['A':'Z'; 'a':'z'; '0':'9']

    # A blank cell whose style is invisible (no background, not inverse).
    isblank((text, style)) = text == " " && style[5] == 0x00 && style[13] & 0x10 == 0

    """
        dump(contents::IO, decorator::IO, em::LibGhosttyVT.Terminal)

    Write the screen of `em`, including scrollback, as plain text to `contents`
    and as one decorator character per cell to `decorator`, where each distinct
    cell style gets its own character. Trailing blank cells and rows are dropped,
    except that the cursor's row is kept up to the cursor.
    """
    function dump(contents::IO, decorator::IO, em::LibGhosttyVT.Terminal)
        crow, ccol = cursor(em)
        crow += LibGhosttyVT.total_rows(em) - LibGhosttyVT.active_rows(em)
        rows = [cells(em, row) for row in 1:LibGhosttyVT.total_rows(em)]
        for (i, row) in enumerate(rows)
            n = something(findlast(!isblank, row), 0)
            i == crow && (n = max(n, min(ccol - 1, length(row))))
            resize!(row, n)
        end
        nrows = max(crow, something(findlast(!isempty, rows), 0))
        styles = Dict{LibGhosttyVT.Style, Char}()
        available = copy(default_decorators)
        for (i, row) in enumerate(view(rows, 1:nrows))
            if i > 1
                println(contents)
                println(decorator)
            end
            for (text, style) in row
                print(contents, text)
                print(decorator, get!(() -> popfirst!(available), styles, style))
            end
        end
    end

    function compare(em, output, decorator = nothing)
        buf = IOBuffer()
        decoratorbuf = IOBuffer()
        dump(buf, decoratorbuf, em)
        outbuf = take!(buf)
        decoratorbuf = take!(decoratorbuf)
        _compare(Vector{UInt8}(codeunits(output)), outbuf) || return false
        decorator === nothing && return true
        _compare(Vector{UInt8}(codeunits(decorator)), decoratorbuf)
    end

    process_events_compat() = @static VERSION >= v"1.2.0-DEV.566" ? Base.process_events() : Base.process_events(false)
    function process_all_buffered(emuterm)
        # Since writes to the tty are asynchronous, there's an
        # inherent race condition between them being sent to the
        # kernel and being available to epoll. We write a sentinel value
        # here and wait for it to be read back.
        sentinel = Ref{UInt32}(0xffffffff)
        ccall(:write, Cvoid, (Cint, Ptr{UInt32}, Csize_t), emuterm.pty.slave, sentinel, sizeof(UInt32))
        process_events_compat()
        # Read until we get our sentinel
        while bytesavailable(emuterm.pty.master) < sizeof(UInt32) ||
            reinterpret(UInt32, emuterm.pty.master.buffer.data[(emuterm.pty.master.buffer.size-3):emuterm.pty.master.buffer.size])[] != sentinel[]
            emuterm.aggressive_yield || yield()
            process_events_compat()
            sleep(0.01)
        end
        write(emuterm.terminal, readavailable(emuterm.pty.master)[1:(end-4)])
    end

    function automated_test(f, cmp, outputpath, inputs; aggressive_yield = false)
        emuterm = EmulatedTerminal()
        emuterm.aggressive_yield = aggressive_yield
        outputs, decorators = load_outputs(outputpath)
        c = Condition()
        @async Base.wait_readnb(emuterm.pty.master, typemax(Int64))
        yield()
        t1 = @async try
            f(emuterm)
            Base.notify(c)
        catch err
            Base.showerror(stderr, err, catch_backtrace())
            Base.notify_error(c, err)
        end
        t2 = @async try
            for input in inputs
                wait(emuterm);
                emuterm.aggressive_yield || @assert emuterm.waiting
                output = popfirst!(outputs)
                decorator = isempty(decorators) ? nothing : popfirst!(decorators)
                @assert !eof(emuterm.pty.master)
                process_all_buffered(emuterm)
                cmp(emuterm.terminal, output, decorator)
                print(emuterm.input_buffer, input); notify_condition(emuterm.filled)
            end
            Base.notify(c)
        catch err
            Base.showerror(stderr, err, catch_backtrace())
            Base.notify_error(c, err)
        end
        while !istaskdone(t1) || !istaskdone(t2)
            wait(c)
        end
    end
    automated_test(f, outputpath, inputs; kwargs...) = automated_test(f, compare, outputpath, inputs; kwargs...)

    function create_automated_test(f, outputpath, inputs; aggressive_yield=false)
        emuterm = EmulatedTerminal()
        emuterm.aggressive_yield = aggressive_yield
        c = Condition()
        @async Base.wait_readnb(emuterm.pty.master, typemax(Int64))
        yield()
        t1 = @async try
            f(emuterm)
            Base.notify(c)
        catch err
            Base.showerror(stderr, err, catch_backtrace())
            Base.notify_error(c, err)
        end
        t2 = @async try
            outs = map(inputs) do input
                wait(emuterm);
                emuterm.aggressive_yield || @assert emuterm.waiting
                process_all_buffered(emuterm)
                out = IOBuffer()
                decorator = IOBuffer()
                dump(out, decorator, emuterm.terminal)
                print(emuterm.input_buffer, input); notify_condition(emuterm.filled)
                out, decorator
            end
            open(outputpath, "w") do io
                print(io,"+"^50,"\n",
                    join(map(outs) do x
                        sprint() do io
                            out, dec = x
                            print(io, "|", replace(String(take!(out)),"\n" => "\n|"))
                            println(io, "\n", "-"^50)
                            print(io, "|", replace(String(take!(dec)),"\n" => "\n|"))
                        end
                    end, string('\n',"+"^50,'\n')))
            end
            Base.notify(c)
        catch err
            Base.showerror(stderr, err, catch_backtrace())
            Base.notify_error(c, err)
        end
        while !istaskdone(t1) || !istaskdone(t2)
            wait(c)
        end
    end
end
