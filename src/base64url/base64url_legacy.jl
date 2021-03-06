# This file is a part of Julia. License is MIT: https://julialang.org/license

module Base64URL
import Base: read, write, close, eof, empty!
#export Base64EncodePipe, Base64DecodePipe, base64encode, base64decode

# Base64EncodePipe is a pipe-like IO object, which converts into base64 data sent
# to a stream. (You must close the pipe to complete the encode, separate from
# closing the target stream).  We also have a function base64encode(f,
# args...) which works like sprint except that it produces
# base64-encoded data, along with base64encode(args...)  which is equivalent
# to base64encode(write, args...), to return base64 strings.
# A Base64DecodePipe object can be used to decode base64-encoded data read from a stream
# , while function base64decode is useful for decoding strings
#############################################################################

mutable struct Base64EncodePipe <: IO
    io::IO
    # writing works in groups of 3, so we need to cache last two bytes written
    b0::UInt8
    b1::UInt8
    nb::UInt8 # number of bytes in cache: 0, 1, or 2

    function Base64EncodePipe(io::IO)
        b = new(io,0,0,0)
        finalizer(b, close)
        return b
    end
end

#############################################################################

# Based on code by Stefan Karpinski from https://github.com/hackerschool/WebSockets.jl (distributed under the same MIT license as Julia)

# '-' and '_' instead of '+' and '/'
const b64chars = ['A':'Z';'a':'z';'0':'9';'-';'_']

const base64_pad = UInt8('=')

function b64(x::UInt8, y::UInt8, z::UInt8)
    n = Int(x)<<16 | Int(y)<<8 | Int(z)
    b64chars[(n >> 18) + 1],
    b64chars[(n >> 12) & 0b111111 + 1],
    b64chars[(n >> 6) & 0b111111 + 1],
    b64chars[(n ) & 0b111111 + 1]
end

function b64(x::UInt8, y::UInt8)
    a, b, c = b64(x, y, 0x0)
    a, b, c, base64_pad
end

function b64(x::UInt8)
    a, b = b64(x, 0x0, 0x0)
    a, b, base64_pad, base64_pad
end

const sentinel = typemax(UInt8)
const revb64chars = fill(sentinel, 256)
# Fill revb64chars
for (val, ch) in enumerate(b64chars)
    revb64chars[UInt8(ch)] = UInt8(val - 1)
end

# Decode a block of at least 2 and at most 4 bytes, received in encvec
# Returns the first decoded byte and stores up to two more in cache
function b64decode!(encvec::Vector{UInt8}, cache::Vector{UInt8})
    if length(encvec) < 2
        throw(ArgumentError("incorrect base64 format, block must be at least 2 and at most 4 bytes"))
    end
    @inbounds u = revb64chars[encvec[1]]
    @inbounds v = revb64chars[encvec[2]]
    empty!(cache)
    res = (u << 2) | (v >> 4)
    if length(encvec) > 2
        @inbounds w = revb64chars[encvec[3]]
        push!(cache, (v << 4) | (w >> 2))
    end
    if length(encvec) > 3
        @inbounds z = revb64chars[encvec[4]]
        push!(cache, (w << 6) | z)
    end
    res
end

function write(b::Base64EncodePipe, x::UInt8)
    if b.nb == 0
        b.b0 = x
        b.nb = 1
    elseif b.nb == 1
        b.b1 = x
        b.nb = 2
    else
        write(b.io, b64(b.b0,b.b1,x)...)
        b.nb = 0
    end
    1
end

function close(b::Base64EncodePipe)
    if b.nb > 0
        # write leftover bytes + padding
        if b.nb == 1
            write(b.io, b64(b.b0)...)
        else # b.nb == 2
            write(b.io, b64(b.b0, b.b1)...)
        end
        b.nb = 0
    end
    nothing
end

# like sprint, but returns base64 string
function base64urlencode(f::Function, args...)
    s = IOBuffer()
    b = Base64EncodePipe(s)
    f(b, args...)
    close(b)
    String(take!(s))
end
base64urlencode(x...) = base64urlencode(write, x...)

#############################################################################
mutable struct Base64DecodePipe <: IO
    io::IO
    # reading works in blocks of 4 characters that are decoded into 3 bytes and 2 of them cached
    cache::Vector{UInt8}
    encvec::Vector{UInt8}

    function Base64DecodePipe(io::IO)
        b = new(io,[],[])
        finalizer(b, close)
        return b
    end
end

function read(b::Base64DecodePipe, t::Type{UInt8})
    if !isempty(b.cache)
        return shift!(b.cache)
    else
        empty!(b.encvec)
        while !eof(b.io) && length(b.encvec) < 4
            c::UInt8 = read(b.io, t)
            @inbounds if revb64chars[c] != sentinel
                push!(b.encvec, c)
            end
        end
        return b64decode!(b.encvec,b.cache)
    end
end

eof(b::Base64DecodePipe) = isempty(b.cache) && eof(b.io)
close(b::Base64DecodePipe) = nothing

# Decodes a base64-encoded string
function base64urldecode(s)
    b = IOBuffer(s)
    try
        return read(Base64DecodePipe(b))
    finally
        close(b)
    end
end

end # module
