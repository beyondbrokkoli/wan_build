local ffi = require("ffi")
local bit = require("bit")

local RNG = {}

-- A 1-element C-array forces LuaJIT into exact 32-bit hardware math, 
-- safely overflowing identically on both MSVC and GCC without float drift.
local state = ffi.new("uint32_t[1]")

-- Pass your uint64_t session_token here during initialization
function RNG.seed(session_token)
    -- Cast the 64-bit token to a pointer of two 32-bit integers
    local ptr = ffi.cast("uint32_t*", ffi.new("uint64_t[1]", session_token))
    
    -- XOR the high and low 32 bits to compress the token into the 32-bit seed
    state[0] = bit.bxor(ptr[0], ptr[1])
    
    -- Prevent a pure zero seed (LCG kryptonite)
    if state[0] == 0 then 
        state[0] = 0x811C9DC5 
    end
end

function RNG.next()
    -- Standard glibc constants. 
    -- FFI automatically applies modulo 2^32 via integer overflow.
    state[0] = state[0] * 1103515245 + 12345
    return state[0]
end

function RNG.range(min, max)
    -- tonumber() brings it back to Lua space for the modulo arithmetic
    return min + (tonumber(RNG.next()) % (max - min + 1))
end

return RNG
