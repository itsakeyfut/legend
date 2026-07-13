//! The engine's single @cImport
//!
//! One block, not several: two separate @cImport calls produce *distinct*
//! opaque types for the same C struct, so a `*c.SDL_Window` made in one file
//! could not be passed to another. Vulkan comes first so that SDL_vulkan.h
//! picks up the real handle types instead of declaring its own.

pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_vulkan.h");
});
