//! The frame loop: command buffers, synchronisation, and the draw itself.
//!
//! The CPU and the GPU run independently. The CPU records commands and hands
//! them over; the GPU executes them whenever it gets to them. Overlapping the
//! two is what keeps both busy -- and is also what makes this the most
//! error-prone part of Vulkan, because "the GPU has not finished with that yet"
//! is invisible unless you arrange to be told.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;
const Device = @import("device.zig").Device;
const swapchain_mod = @import("swapchain.zig");
const Swapchain = swapchain_mod.Swapchain;
const max_swapchain_images = swapchain_mod.max_images;
const pipeline_mod = @import("pipeline.zig");
const PushConstants = pipeline_mod.PushConstants;
const GpuMesh = @import("mesh.zig").GpuMesh;

/// One mesh, with the texture it wears and the constants that place and light
/// it. A frame is a list of these; the scene will produce them, and the renderer
/// stays ignorant of where they came from.
pub const DrawItem = struct {
    mesh: *const GpuMesh,
    texture: c.VkDescriptorSet,
    push: PushConstants,
    shadow_push: PushConstants,
    bone_set: ?c.VkDescriptorSet = null,
};

/// The pipelines and passes one frame draws with. Bundled rather than passed
/// one by one: a second render pass would have pushed drawFrame past ten
/// parameters, where the order of four similar-looking handles is the only
/// thing keeping it correct. Context fills this in; renderer reads it.
pub const FrameResources = struct {
    render_pass: c.VkRenderPass,
    pipeline: c.VkPipeline,
    layout: c.VkPipelineLayout,
    skinned_pipeline: c.VkPipeline,
    skinned_layout: c.VkPipelineLayout,
    shadow_pass: c.VkRenderPass,
    shadow_framebuffer: c.VkFramebuffer,
    shadow_pipeline: c.VkPipeline,
    shadow_layout: c.VkPipelineLayout,
    shadow_skinned_pipeline: c.VkPipeline,
    shadow_skinned_layout: c.VkPipelineLayout,
    shadow_extent: c.VkExtent2D,
    shadow_data_set: c.VkDescriptorSet,
};

/// How many frames the CPU may work on before it has to wait for the GPU.
/// Two lets the CPU prepare frame N+1 while the GPU draws frame N. Three would
/// hide a little more jitter at the cost of a frame of input latency.
pub const max_frames_in_flight = 2;

pub const Renderer = struct {
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,

    pool: c.VkCommandPool,
    /// One per frame in flight: the GPU may still be reading last frame's while
    /// we record this one.
    buffers: [max_frames_in_flight]c.VkCommandBuffer,

    /// Signalled by acquire, waited on by the submit. Per frame in flight is
    /// safe here: the in_flight fence proves the submit that consumed it has
    /// finished before the slot comes round again.
    image_available: [max_frames_in_flight]c.VkSemaphore,

    /// Signalled by the submit, waited on by *presentation* -- and presentation
    /// has no fence, so there is no way to learn when it is done with the
    /// semaphore. Indexing by frame would therefore risk reusing one the
    /// presentation engine still holds, which is exactly what the validation
    /// layers catch. Indexing by swapchain image instead is safe, because
    /// vkAcquireNextImageKHR will not hand back image N until N's previous
    /// presentation has completed.
    render_finished: [max_swapchain_images]c.VkSemaphore,
    image_count: u32,

    /// GPU-to-CPU: the only one we can wait on ourselves, so it is what stops us
    /// overwriting a command buffer the GPU is still executing.
    in_flight: [max_frames_in_flight]c.VkFence,

    frame: usize = 0,

    pub fn init(device: *const Device, swapchain: *const Swapchain) !Renderer {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            // RESET_COMMAND_BUFFER: buffers are re-recorded every frame rather
            // than allocated fresh, so they need to be individually resettable.
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = device.families.graphics,
        };

        var pool: c.VkCommandPool = null;
        try check(
            c.vkCreateCommandPool(device.handle, &pool_info, null, &pool),
            "vkCreateCommandPool",
        );
        errdefer c.vkDestroyCommandPool(device.handle, pool, null);

        var buffers: [max_frames_in_flight]c.VkCommandBuffer = undefined;
        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = max_frames_in_flight,
        };
        try check(
            c.vkAllocateCommandBuffers(device.handle, &alloc_info, &buffers),
            "vkAllocateCommandBuffers",
        );
        // Command buffers are freed with the pool; no separate cleanup.

        const sem_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        // Created signalled, or the very first frame would wait forever for a
        // GPU that has not been given anything to do.
        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var image_available: [max_frames_in_flight]c.VkSemaphore = undefined;
        var in_flight: [max_frames_in_flight]c.VkFence = undefined;
        var render_finished: [max_swapchain_images]c.VkSemaphore = undefined;

        var frames_made: usize = 0;
        errdefer for (0..frames_made) |i| {
            c.vkDestroySemaphore(device.handle, image_available[i], null);
            c.vkDestroyFence(device.handle, in_flight[i], null);
        };
        while (frames_made < max_frames_in_flight) : (frames_made += 1) {
            try check(
                c.vkCreateSemaphore(device.handle, &sem_info, null, &image_available[frames_made]),
                "vkCreateSemaphore",
            );
            try check(
                c.vkCreateFence(device.handle, &fence_info, null, &in_flight[frames_made]),
                "vkCreateFence",
            );
        }

        var images_made: u32 = 0;
        errdefer for (0..images_made) |i| {
            c.vkDestroySemaphore(device.handle, render_finished[i], null);
        };
        while (images_made < swapchain.count) : (images_made += 1) {
            try check(
                c.vkCreateSemaphore(device.handle, &sem_info, null, &render_finished[images_made]),
                "vkCreateSemaphore",
            );
        }

        return .{
            .device = device.handle,
            .graphics_queue = device.graphics_queue,
            .present_queue = device.present_queue,
            .pool = pool,
            .buffers = buffers,
            .image_available = image_available,
            .render_finished = render_finished,
            .image_count = swapchain.count,
            .in_flight = in_flight,
        };
    }

    pub fn deinit(self: *Renderer) void {
        // Nothing may be destroyed while the GPU might still be using it.
        _ = c.vkDeviceWaitIdle(self.device);

        for (0..max_frames_in_flight) |i| {
            c.vkDestroySemaphore(self.device, self.image_available[i], null);
            c.vkDestroyFence(self.device, self.in_flight[i], null);
        }
        for (0..self.image_count) |i| {
            c.vkDestroySemaphore(self.device, self.render_finished[i], null);
        }
        c.vkDestroyCommandPool(self.device, self.pool, null);
        self.* = undefined;
    }

    /// Acquire an image, record a pass that clears it and draws the scene,
    /// submit, and queue the result for display.
    pub fn drawFrame(
        self: *Renderer,
        swapchain: *const Swapchain,
        res: FrameResources,
        items: []const DrawItem,
    ) !void {
        const i = self.frame;

        // Wait until the GPU is done with this slot's command buffer.
        try check(
            c.vkWaitForFences(self.device, 1, &self.in_flight[i], c.VK_TRUE, std.math.maxInt(u64)),
            "vkWaitForFences",
        );

        var image_index: u32 = 0;
        const acquired = c.vkAcquireNextImageKHR(
            self.device,
            swapchain.handle,
            std.math.maxInt(u64),
            self.image_available[i],
            null,
            &image_index,
        );
        // A resized or otherwise invalidated swapchain has to be rebuilt; there
        // is nothing to draw into until it is.
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) return Error.SwapchainLost;
        if (acquired != c.VK_SUCCESS and acquired != c.VK_SUBOPTIMAL_KHR) {
            return Error.VulkanCall;
        }

        // Reset only now: had we returned early above, the fence would have to
        // stay signalled or the next frame would deadlock on it.
        try check(c.vkResetFences(self.device, 1, &self.in_flight[i]), "vkResetFences");

        const cmd = self.buffers[i];
        try check(c.vkResetCommandBuffer(cmd, 0), "vkResetCommandBuffer");
        try recordCommands(cmd, swapchain, res, image_index, items);

        // Keyed by image, not by frame -- see the field's comment.
        const finished = self.render_finished[image_index];

        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        const submit = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            // Vertex work can start immediately; only the write to the colour
            // attachment has to wait for the image to actually be available.
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.image_available[i],
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &finished,
        };
        try check(
            c.vkQueueSubmit(self.graphics_queue, 1, &submit, self.in_flight[i]),
            "vkQueueSubmit",
        );

        const present = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &finished,
            .swapchainCount = 1,
            .pSwapchains = &swapchain.handle,
            .pImageIndices = &image_index,
            .pResults = null,
        };
        const presented = c.vkQueuePresentKHR(self.present_queue, &present);
        if (presented == c.VK_ERROR_OUT_OF_DATE_KHR or presented == c.VK_SUBOPTIMAL_KHR) {
            return Error.SwapchainLost;
        }
        if (presented != c.VK_SUCCESS) return Error.VulkanCall;

        self.frame = (self.frame + 1) % max_frames_in_flight;
    }
};

fn recordCommands(
    cmd: c.VkCommandBuffer,
    swapchain: *const Swapchain,
    res: FrameResources,
    image_index: u32,
    items: []const DrawItem,
) !void {
    const begin = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    try check(c.vkBeginCommandBuffer(cmd, &begin), "vkBeginCommandBuffer");

    // -- shadow pass: depth as the light sees it -------------------------
    // Rendered first, into its own framebuffer. The render pass leaves the
    // image in a layout the main pass can sample, and its dependencies order
    // the write before that read.
    const shadow_clear = c.VkClearValue{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } };
    const shadow_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = res.shadow_pass,
        .framebuffer = res.shadow_framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = res.shadow_extent },
        .clearValueCount = 1,
        .pClearValues = &shadow_clear,
    };
    c.vkCmdBeginRenderPass(cmd, &shadow_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.shadow_pipeline);

    const shadow_viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(res.shadow_extent.width),
        .height = @floatFromInt(res.shadow_extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(cmd, 0, 1, &shadow_viewport);
    const shadow_scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = res.shadow_extent,
    };
    c.vkCmdSetScissor(cmd, 0, 1, &shadow_scissor);

    for (items) |item| {
        if (item.bone_set) |bone_set| {
            // Skinned: the same bones the main pass uses, so the shape that
            // blocks the light is the posed one.
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.shadow_skinned_pipeline);
            var bs = bone_set;
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.shadow_skinned_layout, 1, 1, &bs, 0, null);
            c.vkCmdPushConstants(cmd, res.shadow_skinned_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), &item.shadow_push);
        } else {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.shadow_pipeline);
            c.vkCmdPushConstants(cmd, res.shadow_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), &item.shadow_push);
        }
        item.mesh.draw(cmd);
    }

    c.vkCmdEndRenderPass(cmd);

    // One clear value ptr attachment, in the order the render pass declared
    // them. Depth clears to 1.0: the far plane, since the test is LESS.
    const clears = [_]c.VkClearValue{
        .{ .color = .{ .float32 = .{ 0.06, 0.07, 0.11, 1.0 } } },
        .{ .depthStencil = .{ .depth = 1.0, .stencil = 0 } },
    };
    const pass_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = res.render_pass,
        .framebuffer = swapchain.framebuffers[image_index],
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
        .clearValueCount = clears.len,
        .pClearValues = &clears,
    };
    c.vkCmdBeginRenderPass(cmd, &pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.pipeline);

    // Declared dynamic when the pipeline was built, so they are supplied here
    // and a window resize does not mean rebuilding it.
    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(swapchain.extent.width),
        .height = @floatFromInt(swapchain.extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(cmd, 0, 1, &viewport);

    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain.extent,
    };
    c.vkCmdSetScissor(cmd, 0, 1, &scissor);

    for (items) |item| {
        if (item.bone_set) |bone_set| {
            // Skinned: texture at set 0, bones at set 1, shadow data at set 2.
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.skinned_pipeline);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.skinned_layout, 0, 1, &item.texture, 0, null);
            var bs = bone_set;
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.skinned_layout, 1, 1, &bs, 0, null);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.skinned_layout, 2, 1, &res.shadow_data_set, 0, null);
            c.vkCmdPushConstants(cmd, res.skinned_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), &item.push);
        } else {
            // Static: the original pipeline, texture at set 0.
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.pipeline);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.layout, 0, 1, &item.texture, 0, null);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, res.layout, 2, 1, &res.shadow_data_set, 0, null);
            c.vkCmdPushConstants(cmd, res.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), &item.push);
        }
        item.mesh.draw(cmd);
    }

    c.vkCmdEndRenderPass(cmd);
    try check(c.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
}
