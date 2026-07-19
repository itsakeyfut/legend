//! The render pass and the graphics pipeline.
//!
//! Vulkan does not let you flip render state at draw time. Everything that
//! affects how triangles become pixels -- the shaders, the blend rules, the
//! depth test, the winding order -- is baked into one immutable VkPipeline, so
//! the driver can compile it down to GPU commands ahead of time. That is why
//! this file is long: it is stating, once, every decision the rasterizer used to
//! make on the fly.

const std = @import("std");

const vk = @import("vk.zig");
const c = vk.c;
const check = vk.check;
const Error = vk.Error;
const gpu_mesh = @import("mesh.zig");

/// SPIR-V is a stream of 32-bit words, so the byte slice has to be 4-byte
/// aligned before Vulkan will look at it.
fn createShaderModule(device: c.VkDevice, spirv: []align(4) const u8) !c.VkShaderModule {
    const info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = spirv.len,
        .pCode = @ptrCast(spirv.ptr),
    };
    var module: c.VkShaderModule = null;
    try check(c.vkCreateShaderModule(device, &info, null, &module), "vkCreateShaderModule");
    return module;
}

/// Declares what images a pass touches and what happens to them at each end.
/// Clear on entry, store on exit, and hand the result to the presentation engine.
pub const RenderPass = struct {
    handle: c.VkRenderPass,
    device: c.VkDevice,

    pub fn init(device: c.VkDevice, format: c.VkFormat, depth_format: c.VkFormat) !RenderPass {
        const attachments = [_]c.VkAttachmentDescription{
            // 0: colour
            .{
                .flags = 0,
                .format = format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            },
            // 1: depth. DONT_CARE on store: nothing reads it after the pass, and
            // saying so lets a tiled GPU skip writing it to memory at all.
            .{
                .flags = 0,
                .format = depth_format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            },
        };

        const color_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const depth_ref = c.VkAttachmentReference{
            .attachment = 1,
            .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = &depth_ref,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        var handle: c.VkRenderPass = null;
        try check(c.vkCreateRenderPass(device, &info, null, &handle), "vkCreateRenderPass");
        return .{ .handle = handle, .device = device };
    }

    pub fn deinit(self: *RenderPass) void {
        c.vkDestroyRenderPass(self.device, self.handle, null);
        self.* = undefined;
    }
};

pub const Pipeline = struct {
    layout: c.VkPipelineLayout,
    handle: c.VkPipeline,
    device: c.VkDevice,

    /// The static pipeline: static vertex layout. The set layouts are the same
    /// three every pipeline declares -- texture, bones, shadow -- so the set
    /// numbers mean one thing across every shader, whether or not a given shader
    /// reads them all.
    pub fn init(
        device: c.VkDevice,
        render_pass: c.VkRenderPass,
        spirv: []align(4) const u8,
        texture_layout: c.VkDescriptorSetLayout,
        bone_layout: c.VkDescriptorSetLayout,
        shadow_layout: c.VkDescriptorSetLayout,
    ) !Pipeline {
        const set_layouts = [_]c.VkDescriptorSetLayout{ texture_layout, bone_layout, shadow_layout };
        return create(
            device,
            render_pass,
            spirv,
            &gpu_mesh.binding_description,
            &gpu_mesh.attribute_descriptions,
            &set_layouts,
            false,
        );
    }

    /// The skinning pipeline: skinned vertex layout (joints + weights), same
    /// three set layouts.
    pub fn initSkinned(
        device: c.VkDevice,
        render_pass: c.VkRenderPass,
        spirv: []align(4) const u8,
        texture_layout: c.VkDescriptorSetLayout,
        bone_layout: c.VkDescriptorSetLayout,
        shadow_layout: c.VkDescriptorSetLayout,
    ) !Pipeline {
        const set_layouts = [_]c.VkDescriptorSetLayout{ texture_layout, bone_layout, shadow_layout };
        return create(
            device,
            render_pass,
            spirv,
            &gpu_mesh.skinned_binding_description,
            &gpu_mesh.skinned_attribute_description,
            &set_layouts,
            false,
        );
    }

    /// The shadow pipeline: static vertex layout, no descriptor sets at all --
    /// the depth pass needs no texture and no bones, only the light-space
    /// matrix it gets through push constants.
    pub fn initShadow(
        device: c.VkDevice,
        render_pass: c.VkRenderPass,
        spirv: []align(4) const u8,
    ) !Pipeline {
        return create(
            device,
            render_pass,
            spirv,
            &gpu_mesh.binding_description,
            &gpu_mesh.attribute_descriptions,
            &.{},
            true,
        );
    }

    fn create(
        device: c.VkDevice,
        render_pass: c.VkRenderPass,
        spirv: []align(4) const u8,
        binding_desc: *const c.VkVertexInputBindingDescription,
        attribute_descs: []const c.VkVertexInputAttributeDescription,
        set_layouts: []const c.VkDescriptorSetLayout,
        depth_only: bool,
    ) !Pipeline {
        const module = try createShaderModule(device, spirv);
        // The pipeline copies what it needs; the module can go immediately.
        defer c.vkDestroyShaderModule(device, module, null);

        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = module,
                .pName = "vertexMain",
                .pSpecializationInfo = null,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = module,
                .pName = "fragmentMain",
                .pSpecializationInfo = null,
            },
        };

        // The mesh's layout, declared once in gpu/mesh.zig and used both here and
        // by the shader's attribute locations.
        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = binding_desc,
            .vertexAttributeDescriptionCount = @intCast(attribute_descs.len),
            .pVertexAttributeDescriptions = attribute_descs.ptr,
        };

        const assembly = c.VkPipelineInputAssemblyStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = c.VK_FALSE,
        };

        // Viewport and scissor are left dynamic. Baking them in would mean
        // rebuilding the whole pipeline every time the window resizes.
        const dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        const dynamic = c.VkPipelineDynamicStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const viewport_state = c.VkPipelineViewportStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null, // supplied per-frame
            .scissorCount = 1,
            .pScissors = null,
        };

        const raster = c.VkPipelineRasterizationStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = c.VK_FALSE,
            .rasterizerDiscardEnable = c.VK_FALSE,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            // Back faces are now culled. Vulkan's clip space has Y pointing down,
            // which flips the winding a right-handed, CCW-front convention
            // produces -- hence CLOCKWISE here rather than the CCW the maths says.
            .cullMode = c.VK_CULL_MODE_BACK_BIT,
            .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1.0,
        };

        const multisample = c.VkPipelineMultisampleStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = c.VK_FALSE,
            .minSampleShading = 1.0,
            .pSampleMask = null,
            .alphaToCoverageEnable = c.VK_FALSE,
            .alphaToOneEnable = c.VK_FALSE,
        };

        const depth_stencil = c.VkPipelineDepthStencilStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            // LESS, and the projection maps near to 0: the same convention the
            // software rasterizer used, so nothing about the maths changes.
            .depthCompareOp = c.VK_COMPARE_OP_LESS,
            .depthBoundsTestEnable = c.VK_FALSE,
            .stencilTestEnable = c.VK_FALSE,
            .front = std.mem.zeroes(c.VkStencilOpState),
            .back = std.mem.zeroes(c.VkStencilOpState),
            .minDepthBounds = 0,
            .maxDepthBounds = 1,
        };

        const blend_attachment = c.VkPipelineColorBlendAttachmentState{
            .blendEnable = c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const blend = c.VkPipelineColorBlendStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = if (depth_only) 0 else 1,
            .pAttachments = &blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        // Push constants: the fastest way to get a little data to a shader --
        // no descriptor sets, no buffers, straight into the command buffer.
        // 128 bytes is the minimum every implementation must support, and the
        // MVP plus the normal matrix plus the light direction fits exactly.
        const push_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstants),
        };

        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = @intCast(set_layouts.len),
            .pSetLayouts = set_layouts.ptr,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        };
        var layout: c.VkPipelineLayout = null;
        try check(
            c.vkCreatePipelineLayout(device, &layout_info, null, &layout),
            "vkCreatePipelineLayout",
        );
        errdefer c.vkDestroyPipelineLayout(device, layout, null);

        const info = c.VkGraphicsPipelineCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = &depth_stencil,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic,
            .layout = layout,
            .renderPass = render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };

        var handle: c.VkPipeline = null;
        try check(
            c.vkCreateGraphicsPipelines(device, null, 1, &info, null, &handle),
            "vkCreateGraphicsPipelines",
        );

        return .{ .layout = layout, .handle = handle, .device = device };
    }

    pub fn deinit(self: *Pipeline) void {
        c.vkDestroyPipeline(self.device, self.handle, null);
        c.vkDestroyPipelineLayout(self.device, self.layout, null);
        self.* = undefined;
    }
};

/// Mirrors the PushConstants block in shaders/mesh.slang, byte for byte.
///
/// Matrices go across as columns rather than as float4x4, which sidesteps the
/// row- versus column-major question entirely: the shader recombines them
/// explicitly, so no convention has to line up by luck.
///
/// Eight float4s is exactly the 128 bytes every Vulkan implementation is
/// required to allow -- and no more. The tint therefore rides in the w channels
/// of the three normal-matrix columns, which the maths does not use. That looks
/// like a hack, and it is; the alternative is exceeding a guaranteed limit and
/// discovering on someone else's GPU that it was not guaranteed for them.
pub const PushConstants = extern struct {
    mvp0: [4]f32,
    mvp1: [4]f32,
    mvp2: [4]f32,
    mvp3: [4]f32,
    /// xyz: the inverse-transpose columns, for normals. w: the tint's r, g, b.
    normal0: [4]f32,
    normal1: [4]f32,
    normal2: [4]f32,
    /// xyz is the light direction; w is unused.
    light_dir: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 128);
}
