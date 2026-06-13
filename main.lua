io.stdout:setvbuf("no")
package.path = "./lua/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local structs = require("structs")
local net = require("network")
local cfg = require("config_engine")
local FSM = require("fsm_core")
local State = require("sim_world")

ffi.cdef[[
    void Sleep(uint32_t dwMilliseconds);
    int usleep(uint32_t usec);
    int QueryPerformanceCounter(int64_t *lpPerformanceCount);
    int QueryPerformanceFrequency(int64_t *lpFrequency);
    typedef struct { long tv_sec; long tv_nsec; } timespec;
    int clock_gettime(int clk_id, timespec *tp);
]]

-- ============================================================================
-- PHASE 1: HTTP & IP HELPERS
-- ============================================================================
local function sys_sleep(ms)
    if jit.os == "Windows" then
        ffi.C.Sleep(ms)
    else
        ffi.C.usleep(ms * 1000)
    end
end

local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(1, ts) -- CLOCK_MONOTONIC
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

local function http_post(url, json_payload)
    local payload_path = "matchmaker_payload.json"
    local f = assert(io.open(payload_path, "w"), "Failed to open temp file")
    f:write(json_payload)
    f:close()
    local cmd = string.format('curl -s -X POST -H "Content-Type: application/json" -d "@%s" %s', payload_path, url)
    local pf = io.popen(cmd)
    local res = pf:read("*a")
    pf:close()
    os.remove(payload_path)
    return res
end

local function http_get(url)
    local cmd = string.format('curl -s "%s"', url)
    local f = io.popen(cmd)
    if not f then return "" end
    local res = f:read("*a")
    f:close()
    return res
end

local function get_local_ip()
    local cmd = ""
    if jit.os == "Windows" then
        cmd = 'powershell -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike \'127.*\' -and $_.IPAddress -notlike \'169.254.*\' } | Select-Object -First 1).IPAddress"'
    else
        cmd = "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
    end
    local f = io.popen(cmd)
    if not f then return "127.0.0.1" end
    local res = f:read("*a")
    f:close()
    res = res:gsub("%s+", "")
    if not res:match("^%d+%.%d+%.%d+%.%d+$") then return "127.0.0.1" end
    return res
end

local json = require("json_util") -- [JSON UTILS INJECTED]

print("========================================")
print(" WEAVER ENGINE: 8-NODE WAN MATCHMAKING  ")
print("========================================")

-- ============================================================================
-- PHASE 2: BLOCKING SETUP & MATCHMAKING
-- ============================================================================
local MATCHMAKER_URL = "http://138.199.152.240:8000"

print("Enter local port to bind (e.g., 50000): ")
io.write("> ")
local local_port = tonumber(io.read("*l")) or 50000

assert(net.Host(local_port), "FATAL: Failed to bind port " .. local_port)
local my_local_ip = get_local_ip()

print(string.format("[SYSTEM] Local socket bound to %s:%d. Punching STUN...", my_local_ip, local_port))
local my_pub_ip = net.StunPunch() or my_local_ip
print(string.format("[SYSTEM] External Identity acquired: %s", my_pub_ip))

print("Enter 'H' to Host a new lobby, or paste a Lobby ID to Join:")
io.write("> ")
local user_input = io.read("*l")

local lobby_id = ""
local session_token = 0

-- Pydantic Schema matches 'PlayerEndpoint'
local payload_tbl = {
    public_ip = my_pub_ip,
    public_port = local_port, -- Relay shotgun routing makes this best-effort
    local_ip = my_local_ip,
    local_port = local_port
}
local initial_payload = json.encode(payload_tbl)

if user_input:upper() == "H" then
    print("[MATCHMAKER] Requesting new lobby...")
    local response = http_post(MATCHMAKER_URL .. "/host", initial_payload)
    local res_data = json.decode(response)
    
    lobby_id = res_data.lobby_id
    session_token = res_data.session_token -- Cached from initial creation
    print("[MATCHMAKER] Hosted Lobby: " .. lobby_id)
else
    lobby_id = user_input
    print("[MATCHMAKER] Joining Lobby: " .. lobby_id)
    local response = http_post(MATCHMAKER_URL .. "/join/" .. lobby_id, initial_payload)
    local res_data = json.decode(response)
    
    session_token = res_data.session_token -- Cached from join sequence
end

print("[MATCHMAKER] Polling quorum status. Waiting for 'locked'...")
local status_data = nil

while true do
    local raw_res = http_get(MATCHMAKER_URL .. "/status/" .. lobby_id)
    if raw_res and raw_res ~= "" then
        status_data = json.decode(raw_res)
        if status_data.status == "locked" then
            print("[MATCHMAKER] Quorum reached. Lobby is LOCKED.")
            break
        end
    end
    sys_sleep(500)
end

-- Derive local_id based on array position
local local_id = 0
for i, p in ipairs(status_data.players) do
    if p.ip == my_pub_ip and p.local_ip == my_local_ip and p.local_port == local_port then
        local_id = i - 1 -- Lua 1-index to Engine 0-index translation
        break
    end
end

net.SetPlayerId(local_id)
net.SetSession(session_token)

-- ============================================================================
-- PHASE 3: 3-TIER ABSOLUTE MESH ROUTING
-- ============================================================================
print(string.format("[SYSTEM] Assigning Identity: Node %d. Meshing topology...", local_id))

for i, p in ipairs(status_data.players) do
    local peer_id = i - 1
    
    if peer_id ~= local_id then
        if p.ip == my_pub_ip and p.local_ip == my_local_ip then
            -- Tier 1: Same Machine (Loopback)
            print(string.format("[ROUTE] Node %d -> Loopback (127.0.0.1:%d)", peer_id, p.local_port))
            net.Connect(peer_id, "127.0.0.1", p.local_port)
            
        elseif p.ip == my_pub_ip and p.local_ip ~= my_local_ip then
            -- Tier 2: Same Network (LAN Hairpin)
            print(string.format("[ROUTE] Node %d -> LAN Hairpin (%s:%d)", peer_id, p.local_ip, p.local_port))
            net.Connect(peer_id, p.local_ip, p.local_port)
            
        else
            -- Tier 3: Guaranteed WAN (Hetzner UDP Relay)
            print(string.format("[ROUTE] Node %d -> Hetzner UDP Relay (138.199.152.240:49152)", peer_id))
            net.Connect(peer_id, "138.199.152.240", 49152)
        end
    end
end

-- ============================================================================
-- PHASE 4: CLOCK SYNCHRONIZATION & PURE LOOP
-- ============================================================================
-- Perfect sync: server_time and start_time arrive in the exact same HTTP response
local real_time_remaining = status_data.start_time - status_data.server_time

if real_time_remaining > 0 then
    print(string.format("[SYSTEM] Topology Locked. Sleeping %.2f seconds for global sync...", real_time_remaining))
    sys_sleep(real_time_remaining * 1000)
end

-- Engine Data Setup
local total_tiles = cfg.world.map_width * cfg.world.map_height
local bytes_terrain = 8 * total_tiles * ffi.sizeof("uint16_t")
local bytes_elevation = 8 * total_tiles * ffi.sizeof("float")

local ctx = {
    session_token = session_token,
    net_identity = local_id,
    sim_tick_count = 1,
    accumulator = 0.0,
    pending_click = -1,
    total_tiles = total_tiles,
    last_bot_tick = 0,
    peer_active = ffi.new("bool[8]"),
    peer_highest_tick = ffi.new("uint32_t[8]"),
    rts_grid = State.init_grid(total_tiles),
    rollback_arena = ffi.new("RollbackBuffer"),
    snapshot_ring = {
        terrain = ffi.new(string.format("uint16_t[256][8][%d]", total_tiles)), -- [SCALE UP PRESERVED]
        elevation = ffi.new(string.format("float[256][8][%d]", total_tiles))  -- [SCALE UP PRESERVED]
    }
}

local f0 = ctx.rollback_arena.frames[0]
f0.tick = 0
for p = 0, 7 do
    f0.click_grid_idx[p] = 65535
    f0.player_input[p] = 0
end

ctx.rollback_arena.head_tick = 0
ctx.rollback_arena.confirmed_tick = 0

for p = 0, 7 do
    if p ~= local_id then
        ctx.peer_active[p] = true
    end
end

ffi.copy(ctx.snapshot_ring.terrain[0], ctx.rts_grid.terrain, bytes_terrain)
ffi.copy(ctx.snapshot_ring.elevation[0], ctx.rts_grid.elevation, bytes_elevation)

local h0_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
f0.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h0_terrain)

local TICK_RATE = 60
local FIXED_DT = 1.0 / TICK_RATE
local last_time = get_time_hires()
local next_debug_print = last_time + 1.0

print("[SYSTEM] Drop-in complete. Entering pristine FSM loop.")

-- THE SACRED LOOP: Zero network polling, zero HTTP. Just math.
while true do
    current_time = get_time_hires()
    local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
    last_time = current_time

    ctx.accumulator = ctx.accumulator + frame_time
    FSM.tick_playing_state(ctx, FIXED_DT, bytes_terrain, bytes_elevation)

    if current_time >= next_debug_print then
        local display_idx = bit.band(ctx.sim_tick_count - 1, 255) -- [SCALE UP PRESERVED]
        local display_checksum = ctx.rollback_arena.frames[display_idx].state_checksum or 0
        local missing_frames = ctx.sim_tick_count - ctx.rollback_arena.confirmed_tick

        print(string.format("[HEARTBEAT] SimTick: %d | NetHead: %d | Confirmed: %d | Missing: %d | StateHash: 0x%08X",
            ctx.sim_tick_count,
            ctx.rollback_arena.head_tick,
            ctx.rollback_arena.confirmed_tick,
            missing_frames,
            display_checksum
        ))
        next_debug_print = current_time + 1.0
    end
    sys_sleep(1)
end
