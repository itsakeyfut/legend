//! The render pass and the graphics pipeline.
//!
//! Vulkan does not let you flip render state at draw time. Everything that
//! affects how triangles become pixels -- the shaders, the blend rules, the
//! depth test, the winding order -- is baked into one immutable VkPipeline, so
//! the driver can compile it down to GPU commands ahead of time. That is why
//! this file is long: it is stating, once, every decision the rasterizer used to
//! make on the fly.

const std = @import("std");
const c = @import("../platform/c.zig").c;

pub const Error = error{VulkanCall};

fn check(result: c.VkResult, comptime what: []const u8) !void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult = {d}\n", .{ what, result });
        return Error.VulkanCall;
    }
}

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

    pub fn init(device: c.VkDevice, format: c.VkFormat) !RenderPass {
        const color = c.VkAttachmentDescription{
            .flags = 0,
            .format = format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            // CLEAR beats LOAD here: the previous contents are garbage, and
            // saying so lets the driver skip fetching them.
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        // Without this the pass could start writing the image before the
        // presentation engine has finished reading it.
        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color,
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

    pub fn init(
        device: c.VkDevice,
        render_pass: c.VkRenderPass,
        spirv: []align(4) const u8,
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

        // Empty: the triangle's vertices are constants in the shader, indexed by
        // SV_VertexID. Vertex buffers arrive in the next milestone.
        const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
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
            // Culling off for now: Vulkan's clip space has Y pointing down,
            // which inverts the winding the software renderer assumed. Getting
            // that wrong would make the triangle silently vanish, so the
            // question is deferred until real meshes arrive.
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
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
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };

        // Nothing is passed to the shaders yet, so the layout is empty. Uniforms
        // and textures will be declared here.
        const layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
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
            .pDepthStencilState = null,
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
