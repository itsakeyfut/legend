//! The shadow map: an offscreen depth image rendered from the light's point of
//! view, and the render pass that fills it.
//!
//! A shadow is a place the light cannot reach. Rendering the scene from the
//! light and keeping only depth gives, for every direction the light looks, the
//! distance to the nearest surface. In the main pass a point is then in shadow
//! if it sits further from the light than what that depth says -- something else
//! got there first.
//!
//! Unlike the swapchain's depth buffer, this one is read afterwards: it carries
//! SAMPLED usage, its pass stores rather than discards it, and it ends in a
//! layout the fragment shader can sample.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;

const Device = @import("device.zig").Device;
const findMemoryType = @import("memory.zig").findMemoryType;
const findDepthFormat = @import("depth.zig").findDepthFormat;

/// The shadow map's resolution. Square and fixed: the light's whole box is
/// projected into it, so more texels mean crisper shadow edges and more memory.
/// 2048 is the usual starting point -- enough for one directional light over a
/// scene of this size.
pub const resolution: u32 = 2048;

pub const ShadowMap = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    format: c.VkFormat,
    render_pass: c.VkRenderPass,
    framebuffer: c.VkFramebuffer,
    device: c.VkDevice,

    pub fn init(device: *const Device) !ShadowMap {
        const format = try findDepthFormat(device.physical);

        // -- the depth image, sampled as well as written -------------------
        const image_info = c.VkImageCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = resolution, .height = resolution, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            // SAMPLED as well as ATTACHMENT: this depth is read back by the main
            // pass, which the swapchain's depth buffer never is.
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT |
                c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var image: c.VkImage = null;
        try check(c.vkCreateImage(device.handle, &image_info, null, &image), "vkCreateImage");
        errdefer c.vkDestroyImage(device.handle, image, null);

        var reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(device.handle, image, &reqs);

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = reqs.size,
            .memoryTypeIndex = try findMemoryType(
                device.physical,
                reqs.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ),
        };
        var memory: c.VkDeviceMemory = null;
        try check(c.vkAllocateMemory(device.handle, &alloc_info, null, &memory), "vkAllocateMemory");
        errdefer c.vkFreeMemory(device.handle, memory, null);
        try check(c.vkBindImageMemory(device.handle, image, memory, 0), "vkBindImageMemory");

        const view_info = c.VkImageViewCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        var view: c.VkImageView = null;
        try check(c.vkCreateImageView(device.handle, &view_info, null, &view), "vkCreateImageView");
        errdefer c.vkDestroyImageView(device.handle, view, null);

        // -- the sampler ---------------------------------------------------
        // Clamped to a white border so that sampling outside the light's box
        // returns depth 1.0 -- the far plane, meaning "nothing blocked the
        // light". Without it, everything beyond the shadow map's reach would
        // read as shadowed.
        const sampler_info = c.VkSamplerCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = c.VK_FILTER_LINEAR,
            .minFilter = c.VK_FILTER_LINEAR,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
            .mipLodBias = 0,
            .anisotropyEnable = c.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
            .unnormalizedCoordinates = c.VK_FALSE,
        };
        var sampler: c.VkSampler = null;
        try check(c.vkCreateSampler(device.handle, &sampler_info, null, &sampler), "vkCreateSampler");
        errdefer c.vkDestroySampler(device.handle, sampler, null);

        // -- the render pass: depth only, stored, left readable ------------
        const attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            // STORE, unlike the main pass's depth: this is the whole output.
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            // Ends ready for the main pass's fragment shader to sample.
            .finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        const depth_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        // No colour attachments at all: the fragment stage writes nothing.
        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 0,
            .pColorAttachments = null,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        // Two dependencies, one on each side: last frame's readers must finish
        // before this frame writes, and this frame's write must finish before
        // the main pass reads.
        const dependencies = [_]c.VkSubpassDependency{
            .{
                .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = 0,
                .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                .dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
            .{
                .srcSubpass = 0,
                .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                .srcStageMask = c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
        };

        const pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = dependencies.len,
            .pDependencies = &dependencies,
        };
        var render_pass: c.VkRenderPass = null;
        try check(
            c.vkCreateRenderPass(device.handle, &pass_info, null, &render_pass),
            "vkCreateRenderPass",
        );
        errdefer c.vkDestroyRenderPass(device.handle, render_pass, null);

        // -- the framebuffer -----------------------------------------------
        const fb_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &view,
            .width = resolution,
            .height = resolution,
            .layers = 1,
        };
        var framebuffer: c.VkFramebuffer = null;
        try check(
            c.vkCreateFramebuffer(device.handle, &fb_info, null, &framebuffer),
            "vkCreateFramebuffer",
        );

        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
            .format = format,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
            .device = device.handle,
        };
    }

    pub fn deinit(self: *ShadowMap) void {
        c.vkDestroyFramebuffer(self.device, self.framebuffer, null);
        c.vkDestroyRenderPass(self.device, self.render_pass, null);
        c.vkDestroySampler(self.device, self.sampler, null);
        c.vkDestroyImageView(self.device, self.view, null);
        c.vkDestroyImage(self.device, self.image, null);
        c.vkFreeMemory(self.device, self.memory, null);
        self.* = undefined;
    }
};
