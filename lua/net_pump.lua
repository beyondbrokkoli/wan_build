local ffi = require("ffi")
local bit = require("bit")
local cfg = require("config_engine")
local net = require("network")

local CHAOS_PACKET_LOSS = 0.0
local Pump = {}
local peer_ack_of_me = ffi.new("uint32_t[8]")

function Pump.send_dynamic_history(ctx)
    local current_tick = ctx.sim_tick_count
    local conf_tick = ctx.rollback_arena.confirmed_tick

    for p = 0, 7 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            local pkt = ffi.new("LockstepPacket")
            ffi.fill(pkt, ffi.sizeof("LockstepPacket"), 0) -- [SCALE UP] MANDATORY: Wipe 128-slot array garbage
            
            pkt.session_token = ctx.session_token
            pkt.player_id = ctx.net_identity
            pkt.frame_tick = current_tick
            pkt.ack_tick = ctx.peer_highest_tick[p]

            if conf_tick > 0 then
                local conf_idx = bit.band(conf_tick, 255) -- [SCALE UP]
                pkt.state_checksum = ctx.rollback_arena.frames[conf_idx].state_checksum
                pkt.checksum_tick = conf_tick
            end

            local needed_base = peer_ack_of_me[p] + 1
            if needed_base == 1 then
                needed_base = math.max(1, current_tick - 127) -- [SCALE UP]
            end

            local history_len = current_tick - needed_base + 1
            if history_len > 128 then -- [SCALE UP]
                history_len = 128 -- [SCALE UP]
                needed_base = current_tick - 127 -- [SCALE UP]
            elseif history_len <= 0 then
                history_len = 1
                needed_base = current_tick
            end

            pkt.base_tick = needed_base
            pkt.history_count = history_len

            for i = 0, history_len - 1 do
                local h_tick = needed_base + i
                local h_idx = bit.band(h_tick, 255) -- [SCALE UP]
                local frame = ctx.rollback_arena.frames[h_idx]
                pkt.inputs[i] = frame.player_input[ctx.net_identity]
                pkt.clicks[i] = frame.click_grid_idx[ctx.net_identity]
            end
            net.SendTo(pkt, p)
        end
    end
end



-- [CRITICAL FIX]: Allocate the burst buffer ONCE at the top of the file
local MAX_BURST_PACKETS = 256
local global_in_buffer = ffi.new("LockstepPacket[?]", MAX_BURST_PACKETS)

function Pump.intercept_network(ctx, current_tick)
    -- Drain the OS buffer directly into persistent memory
    local count = net.RecvAll(global_in_buffer, MAX_BURST_PACKETS)

    for i = 0, count - 1 do
        local pkt = global_in_buffer[i]
        local pid = pkt.player_id
        
        -- [QUICK REJECT]: If the packet is older than our confirmed tick, drop it immediately 
        -- to save CPU cycles from iterating 128 history frames of dead data.
        if pkt.frame_tick < ctx.rollback_arena.confirmed_tick then
            goto continue_inbox
        end

        if pid < 8 and pkt.frame_tick >= 0 and ctx.peer_active[pid] then -- [SCALE UP] MANDATORY: Block unauthorized peers
            if pkt.ack_tick > peer_ack_of_me[pid] then
                peer_ack_of_me[pid] = pkt.ack_tick
            end
            
            local window_start = math.max(0, current_tick - 255) -- [SCALE UP]
            local window_end = math.min(current_tick + 255, ctx.rollback_arena.confirmed_tick + 255) -- [SCALE UP]

            for h = 0, pkt.history_count - 1 do
                local h_tick = pkt.base_tick + h
                if h_tick > ctx.rollback_arena.confirmed_tick and h_tick >= window_start and h_tick <= window_end then
                    local h_idx = bit.band(h_tick, 255) -- [SCALE UP]
                    local h_frame = ctx.rollback_arena.frames[h_idx]
                    
                    if h_frame.tick ~= h_tick then
                        h_frame.tick = h_tick
                        h_frame.state = cfg.net_state.empty
                        for p_scan = 0, 7 do
                            h_frame.player_input[p_scan] = 0
                            h_frame.click_grid_idx[p_scan] = 65535
                        end
                        h_frame.state_checksum = 0
                        h_frame.remote_checksum = 0
                    end
                    
                    local inc_input = pkt.inputs[h]
                    local inc_click = pkt.clicks[h]
                    
                    if h_frame.player_input[pid] ~= inc_input or h_frame.click_grid_idx[pid] ~= inc_click then
                        if h_tick < current_tick then
                            if ctx.rollback_arena.is_rollback_active == 0 or h_tick < ctx.rollback_arena.rollback_target then
                                ctx.rollback_arena.is_rollback_active = 1
                                ctx.rollback_arena.rollback_target = h_tick
                            end
                        end
                        h_frame.player_input[pid] = inc_input
                        h_frame.click_grid_idx[pid] = inc_click
                    end
                end
            end

            if pkt.frame_tick > ctx.peer_highest_tick[pid] then
                ctx.peer_highest_tick[pid] = pkt.frame_tick
            end

            if pkt.checksum_tick > 0 and pkt.checksum_tick >= math.max(0, ctx.rollback_arena.confirmed_tick - 60) and pkt.checksum_tick <= current_tick then
                local c_idx = bit.band(pkt.checksum_tick, 255) -- [SCALE UP]
                local c_frame = ctx.rollback_arena.frames[c_idx]
                if c_frame.tick == pkt.checksum_tick then
                    c_frame.remote_checksum = pkt.state_checksum
                end
            end
        end
        ::continue_inbox::
    end

    local true_consensus = 0xFFFFFFFF
    for p = 0, 7 do
        if p ~= ctx.net_identity and ctx.peer_active[p] then
            if ctx.peer_highest_tick[p] < true_consensus then
                true_consensus = ctx.peer_highest_tick[p]
            end
        end
    end

    local local_max_valid_tick = math.max(0, current_tick - 1)
    if true_consensus > local_max_valid_tick then
        true_consensus = local_max_valid_tick
    end

    if true_consensus ~= 0xFFFFFFFF and true_consensus > ctx.rollback_arena.confirmed_tick then
        ctx.rollback_arena.confirmed_tick = true_consensus
    end
end

return Pump
