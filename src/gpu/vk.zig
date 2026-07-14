//! Shared Vulkan plumbing: the error set, and the one place a VkResult becomes
//! a Zig error.
//!
//! Vulkan reports failure by return code. Checking every one is what keeps the
//! silent-corruption bugs out -- so every call in this subsystem goes through
//! `check`, and `check` lives here rather than being copied into each file. It
//! was copied into eight of them before this existed.

const std = @import("std");

pub const c = @import("../platform/c.zig").c;

/// One error set for the whole subsystem. Splitting it per file bought nothing:
/// no caller ever handled these individually, and every file needed VulkanCall.
pub const Error = error{
    /// A Vulkan call returned something other than VK_SUCCESS. The code is
    /// printed rather than carried, because Zig error sets hold no payload and
    /// the number is only ever useful to a human reading the log.
    VulkanCall,
    NoValidationLayer,
    TooManyExtensions,
    MissingDebugUtils,
    NoSuitableDevice,
    NoSurfaceFormat,
    TooManyImages,
    NoSuitableMemory,
    NoDepthFormat,
    UnsupportedTransition,
    TooManyTextures,
    SwapchainLost,
};

pub fn check(result: c.VkResult, comptime what: []const u8) Error!void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("{s} failed: VkResult = {d}\n", .{ what, result });
        return Error.VulkanCall;
    }
}
