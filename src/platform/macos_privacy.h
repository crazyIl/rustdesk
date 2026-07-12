#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <cstddef>
#include <cstdint>

using MacPrivacyFrameHandler = void (*)(IOSurfaceRef surface, void *context);
using MacPrivacyErrorHandler = void (*)(const char *message, void *context);

extern "C" bool MacPrivacyModeSupported();
extern "C" bool MacPrivacyCreateOverlays();
extern "C" void MacPrivacyDestroyOverlays();
extern "C" void *MacPrivacyCapturerCreate(
    CGDirectDisplayID display,
    std::size_t width,
    std::size_t height,
    MacPrivacyFrameHandler frame_handler,
    MacPrivacyErrorHandler error_handler,
    void *context,
    char *error_buffer,
    std::size_t error_buffer_size);
extern "C" void MacPrivacyCapturerDestroy(void *capturer);
