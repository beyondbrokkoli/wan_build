-- lua/sequence.lua
local ffi = require("ffi")
local reg = require("registry_vk")
local manifest = require("pipeline_manifest")

local SequenceModule = {}

function SequenceModule.init(app_ctx)
    -- CACHE LUAJIT UPVALUES
    local cfg_gfx = app_ctx.cfg_gfx
    local map_grid_cells = app_ctx.cfg_sim.world.grid_cells

    local seq = {}

    seq.boot = {
        { -- 1
            name = "Vulkan Instance",
            action = function(ctx)
                local vulkan = require("vulkan_core")
                ctx.vk_runtime = vulkan.create_instance(reg.vk_reqs.instance_ext, cfg_gfx.cfg)

                -- Note: FFI CDEF should be globally defined, but if you do it locally here:
                ffi.cdef("void vx_sys_publish_instance(int window_id, void* instance);")

                -- [NEW] Pass the dynamic window ID
                ffi.C.vx_sys_publish_instance(cfg_gfx.win.id, ctx.vk_runtime.instance)
            end
        },
        { -- 2
            name = "GLFW Window Boot",
            action = function(ctx)
                print(string.format("[WEAVER] Ordering C-Core to Boot Window ID %d...", cfg_gfx.win.id))

                ffi.C.vx_sys_set_cmd(cfg_gfx.win.id, cfg_gfx.sys.boot, cfg_gfx.win.w, cfg_gfx.win.h)

                -- [NEW] Pass the ID out to the coroutine runner
                return "AWAIT_SURFACE", cfg_gfx.win.id
            end
        },
        { -- 3
            name = "Vulkan Logical Device",
            action = function(ctx)
                local vulkan = require("vulkan_core")

                -- [NEW] Get surface for specific window
                local surface_ptr = ffi.C.vx_sys_get_surface(cfg_gfx.win.id)

                vulkan.finalize_device_and_swapchain(ctx.vk_runtime, surface_ptr, reg.vk_reqs.device_ext)
            end
        },
        { -- 4
            name = "Memory Arenas Allocation",
            action = function(ctx)
                local memory = require("memory")
                print("[WEAVER] Booting DMA Engine & VRAM Allocator...")

                memory.InitTransferSubsystem(ctx.vk_runtime)

                -- 1. Master GPU Block (Dynamic Grid)
                -- Bits: Storage(32) | Vertex(128) | Indirect(256) | Transfer Src(1) | Transfer Dst(2) = 419
                local grid_bytes = map_grid_cells * 16
                local gpu_bytes = math.floor(grid_bytes * 8 * 1.1) 
                memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", gpu_bytes, 419, ctx.vk_runtime)

                -- 2. Master Index Block (6 indices per quad)
                -- Bits: Index(64) | Indirect(256) | Transfer Dst(2) = 322
                memory.CreateHostVisibleBuffer("MASTER_INDEX_BLOCK", "uint32_t", map_grid_cells * 6, 322, ctx.vk_runtime)

                -- 3. Palette Color Pipeline
                -- Bits: Transfer Src(1) = 1
                memory.CreateHostVisibleBuffer("PALETTE_STAGING", "float", 4096, 1, ctx.vk_runtime)

                -- 4. Palette Haven
                -- Bits: Storage(32) | Vertex(128) | Indirect(256) | Transfer Dst(2) = 418
                memory.CreateBufferHaven("PALETTE_HAVEN", 16384, 418, ctx.vk_runtime)

                print("[WEAVER] Strict VRAM Mapping Complete.")
            end
        },
        { -- 5
            name = "Swapchain Initialization",
            action = function(ctx)
                local swapchain = require("swapchain")
                ctx.sc_state = swapchain.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg_gfx.win.w, cfg_gfx.win.h, ctx.old_swapchain)
            end
        },
        { -- 6
            name = "Descriptors Matrix",
            action = function(ctx)
                local descriptors = require("descriptors")
                local memory = require("memory")
                local master_gpu_buffer = memory.Buffers["MASTER_GPU_BLOCK"]
                local palette_haven_buffer = memory.Buffers["PALETTE_HAVEN"]
                -- [INJECTED] Pass the gfx config to Descriptors
                ctx.desc_state = descriptors.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, master_gpu_buffer, palette_haven_buffer, cfg_gfx.cfg)
            end
        },
        { -- 7
            name = "Compute Graph Pipelines",
            action = function(ctx)
                local compute = require("compute_pipeline")
                local layout = ctx.desc_state.pipelineLayout
                ctx.comp_state = compute.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, layout, manifest.compute)
            end
        },
        { -- 8
            name = "Graphics Pipelines & Depth Buffer",
            action = function(ctx)
                local graphics = require("graphics_pipeline")
                local layout = ctx.desc_state.pipelineLayout
                local colorFormat = ctx.sc_state.format
                ctx.gfx_state = graphics.Init(
                    ctx.vk_runtime.vk, ctx.vk_runtime, cfg_gfx.win.w, cfg_gfx.win.h,
                    layout, colorFormat, manifest.graphics
                )
            end
        },
        { -- 9
            name = "Renderer Synchronization",
            action = function(ctx)
                local renderer = require("renderer")
                ctx.sync_state = renderer.InitSync(ctx.vk_runtime.vk, ctx.vk_runtime.device, cfg_gfx.cfg.frame_slots)
            end
        },
        { -- 10
            name = "Async Overlord Handoff",
            action = function(ctx)
                print("[WEAVER] Packing C-Core Mailbox and firing Render Thread...")
                local vk, dev = ctx.vk_runtime.vk, ctx.vk_runtime.device
                local sc, sync = ctx.sc_state, ctx.sync_state

                local wsi = ffi.new("RenderThreadInit")
                wsi.device = dev
                wsi.queue = ctx.vk_runtime.queue
                wsi.transfer_queue = ctx.vk_runtime.transferQueue
                wsi.swapchain = sc.handle

                for i = 0, sc.imageCount - 1 do
                    wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
                    wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
                end

                for i = 0, cfg_gfx.cfg.frame_slots - 1 do
                    wsi.image_available[i] = sync.imageAvailable[i]
                    wsi.render_finished[i] = sync.renderFinished[i]
                    wsi.in_flight[i]       = sync.inFlight[i]
                end

                wsi.vkWaitForFences         = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
                wsi.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
                wsi.vkResetFences           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
                wsi.vkQueueSubmit           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
                wsi.vkQueuePresentKHR       = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
                wsi.pfnBegin                = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
                wsi.pfnEnd                  = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
                wsi.pfnSetCullMode          = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
                wsi.pfnSetFrontFace         = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
                wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
                wsi.pfnSetDepthTestEnable   = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
                wsi.pfnSetDepthWriteEnable  = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
                wsi.pfnSetDepthCompareOp    = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

                ffi.cdef[[
                    void vx_stream_init(RenderThreadInit* wsi);
                    void vx_thread_start();
                    void vx_transfer_setup(uint32_t q_family_index);
                    int vx_transfer_request(uint64_t src, uint64_t dst, uint64_t size, uint64_t t_sem, uint64_t sig_val);
                ]]

                ffi.C.vx_transfer_setup(ctx.vk_runtime.tIndex)
                ffi.C.vx_stream_init(wsi)
                ffi.C.vx_thread_start()
                print("[WEAVER] Engine Initialization Complete. Async Overlord is LIVE.")
            end
        }
    }

    seq.resize = { seq.boot[5], seq.boot[8], seq.boot[9] }

    return seq
end

return SequenceModule
