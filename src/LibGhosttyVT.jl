# Minimal bindings to the libghostty-vt C API (https://lib.ghostty.org).
module LibGhosttyVT

const libghostty_vt = Ref("libghostty-vt")

function __init__()
    libghostty_vt[] = get(ENV, "LIBGHOSTTY_VT", "libghostty-vt")
end

const SUCCESS = Cint(0)
const DATA_COLS = Cint(1)
const DATA_ROWS = Cint(2)
const DATA_CURSOR_X = Cint(3)
const DATA_CURSOR_Y = Cint(4)
const DATA_TOTAL_ROWS = Cint(14)
const OPT_SCROLLBACK_MAX_BYTES = Cint(28)
const POINT_TAG_SCREEN = Cint(2)
const CELL_DATA_WIDE = Cint(3)
const CELL_DATA_HAS_TEXT = Cint(4)
const CELL_WIDE_SPACER_TAIL = Cint(2)
const CELL_WIDE_SPACER_HEAD = Cint(3)

struct GridRef
    node::Ptr{Cvoid}
    x::UInt16
    y::UInt16
end

# `GhosttyPoint`: an `int` tag followed by an 8-byte aligned union whose
# coordinate variant is `{uint16_t x; uint32_t y}`.
struct Point
    tag::Cint
    _pad::Cint
    x::UInt16
    y::UInt32
    _rest::UInt64
end

# `GhosttyStyle`: fg, bg and underline colors (`{uint8_t tag; uint8_t value[3]}`),
# then `uint16_t flags` and `uint16_t reserved`.
const Style = NTuple{16, UInt8}
const DEFAULT_STYLE = ntuple(_ -> 0x00, 16)

check(r, f) = r == SUCCESS || error("libghostty-vt: $f failed with result $r")

mutable struct Terminal
    ptr::Ptr{Cvoid}
end

function Terminal(cols::Integer = 80, rows::Integer = 24)
    out = Ref{Ptr{Cvoid}}(C_NULL)
    check(ccall((:ghostty_terminal_new, libghostty_vt[]), Cint,
                (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, UInt16, UInt16), C_NULL, out, cols, rows),
          :ghostty_terminal_new)
    t = Terminal(out[])
    finalizer(t) do t
        ccall((:ghostty_terminal_free, libghostty_vt[]), Cvoid, (Ptr{Cvoid},), t)
    end
    unlimited = Ref{Csize_t}(typemax(Csize_t))
    check(ccall((:ghostty_terminal_set, libghostty_vt[]), Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}),
                t, OPT_SCROLLBACK_MAX_BYTES, unlimited), :ghostty_terminal_set)
    t
end
Base.unsafe_convert(::Type{Ptr{Cvoid}}, t::Terminal) = t.ptr

function Base.write(t::Terminal, data::Vector{UInt8})
    ccall((:ghostty_terminal_vt_write, libghostty_vt[]), Cvoid, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
          t, data, length(data))
    length(data)
end
Base.write(t::Terminal, s::String) = write(t, Vector{UInt8}(s))

function terminal_get(t::Terminal, key, ::Type{T}) where {T}
    out = Ref{T}()
    check(ccall((:ghostty_terminal_get, libghostty_vt[]), Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}),
                t, key, out), :ghostty_terminal_get)
    out[]
end

"""
    cursor(t::Terminal) -> (row, column)

1-based cursor position within the active screen.
"""
cursor(t::Terminal) = (Int(terminal_get(t, DATA_CURSOR_Y, UInt16)) + 1, Int(terminal_get(t, DATA_CURSOR_X, UInt16)) + 1)

total_rows(t::Terminal) = Int(terminal_get(t, DATA_TOTAL_ROWS, Csize_t))
active_rows(t::Terminal) = Int(terminal_get(t, DATA_ROWS, UInt16))
cols(t::Terminal) = Int(terminal_get(t, DATA_COLS, UInt16))

function gridref(t::Terminal, row, col)
    ref = Ref(GridRef(C_NULL, 0, 0))
    check(ccall((:ghostty_terminal_grid_ref, libghostty_vt[]), Cint, (Ptr{Cvoid}, Point, Ptr{GridRef}),
                t, Point(POINT_TAG_SCREEN, 0, col, row, 0), ref), :ghostty_terminal_grid_ref)
    ref
end

function cellget(cell::UInt64, key, ::Type{T}) where {T}
    out = Ref{T}()
    check(ccall((:ghostty_cell_get, libghostty_vt[]), Cint, (UInt64, Cint, Ptr{Cvoid}), cell, key, out),
          :ghostty_cell_get)
    out[]
end

function graphemes(ref::Ref{GridRef})
    buf = Vector{UInt32}(undef, 8)
    n = Ref{Csize_t}(0)
    while true
        r = ccall((:ghostty_grid_ref_graphemes, libghostty_vt[]), Cint,
                  (Ptr{GridRef}, Ptr{UInt32}, Csize_t, Ptr{Csize_t}), ref, buf, length(buf), n)
        r == SUCCESS && return String(map(Char, view(buf, 1:n[])))
        r == Cint(-3) || check(r, :ghostty_grid_ref_graphemes)  # GHOSTTY_OUT_OF_SPACE
        resize!(buf, n[])
    end
end

function style(ref::Ref{GridRef})
    s = Ref{Style}(DEFAULT_STYLE)
    check(ccall((:ghostty_grid_ref_style, libghostty_vt[]), Cint, (Ptr{GridRef}, Ptr{Style}), ref, s),
          :ghostty_grid_ref_style)
    s[]
end

"""
    cells(t::Terminal, row) -> Vector{Tuple{String, Style}}

The cells of `row` (1-based, counting from the top of the scrollback) as
`(text, style)` pairs. Empty cells hold `" "`; the trailing halves of wide
characters are skipped.
"""
function cells(t::Terminal, row::Integer)
    line = Tuple{String, Style}[]
    for col in 0:cols(t)-1
        ref = gridref(t, row - 1, col)
        cell = Ref{UInt64}(0)
        check(ccall((:ghostty_grid_ref_cell, libghostty_vt[]), Cint, (Ptr{GridRef}, Ptr{UInt64}), ref, cell),
              :ghostty_grid_ref_cell)
        wide = cellget(cell[], CELL_DATA_WIDE, Cint)
        (wide == CELL_WIDE_SPACER_TAIL || wide == CELL_WIDE_SPACER_HEAD) && continue
        text = cellget(cell[], CELL_DATA_HAS_TEXT, Bool) ? graphemes(ref) : " "
        push!(line, (text, style(ref)))
    end
    line
end

end
