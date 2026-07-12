#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import "macos_privacy.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>

#include <CoreGraphics/CoreGraphics.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <vector>
#include <mutex>
#include <system_error>
#include <thread>

extern "C" bool CanUseNewApiForScreenCaptureCheck() {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion >= 11;
    #endif
}

extern "C" uint32_t majorVersion() {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion;
}

extern "C" bool IsCanScreenRecording(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    bool res = CGPreflightScreenCaptureAccess();
    if (!res && prompt) {
        CGRequestScreenCaptureAccess();
    }
    return res;
    #endif
}


// https://github.com/codebytere/node-mac-permissions/blob/main/permissions.mm

extern "C" bool InputMonitoringAuthStatus(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return true;
    #else
    if (floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_15) {
        IOHIDAccessType theType = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
        NSLog(@"IOHIDCheckAccess = %d, kIOHIDAccessTypeGranted = %d", theType, kIOHIDAccessTypeGranted);
        switch (theType) {
            case kIOHIDAccessTypeGranted:
                return true;
                break;
            case kIOHIDAccessTypeDenied: {
                if (prompt) {
                    NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent";
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
                }
                break;
            }
            case kIOHIDAccessTypeUnknown: {
                if (prompt) {
                    bool result = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
                    NSLog(@"IOHIDRequestAccess result = %d", result);
                }
                break;
            }
            default:
                break;
        }
    } else {
        return true;
    }
    return false;
    #endif
}

extern "C" bool Elevate(char* process, char** args) {
    AuthorizationRef authRef;
    OSStatus status;

    status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        printf("Failed to create AuthorizationRef\n");
        return false;
    }

    AuthorizationItem authItem = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights authRights = {1, &authItem};
    AuthorizationFlags flags = kAuthorizationFlagDefaults |
                                kAuthorizationFlagInteractionAllowed |
                                kAuthorizationFlagPreAuthorize |
                                kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(authRef, &authRights, kAuthorizationEmptyEnvironment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        printf("Failed to authorize\n");
        return false;
    }

    if (process != NULL) {
        FILE *pipe = NULL;
        status = AuthorizationExecuteWithPrivileges(authRef, process, kAuthorizationFlagDefaults, args, &pipe);
        if (status != errAuthorizationSuccess) {
            printf("Failed to run as root\n");
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return false;
        }
    }

    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    return true;
}

extern "C" bool MacCheckAdminAuthorization() {
    return Elevate(NULL, NULL);
}

// https://gist.github.com/briankc/025415e25900750f402235dbf1b74e42
extern "C" float BackingScaleFactor(uint32_t display) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSScreen *screen in screens) {
        NSDictionary *deviceDescription = [screen deviceDescription];
        NSNumber *screenNumber = [deviceDescription objectForKey:@"NSScreenNumber"];
        CGDirectDisplayID screenDisplayID = [screenNumber unsignedIntValue];
        if (screenDisplayID == display) {
            return [screen backingScaleFactor];
        }
    }
    return 1;
}

// https://github.com/jhford/screenresolution/blob/master/cg_utils.c
// https://github.com/jdoupe/screenres/blob/master/setgetscreen.m

size_t bitDepth(CGDisplayModeRef mode) {
    size_t depth = 0;
    // Deprecated, same display same bpp? 
    // https://stackoverflow.com/questions/8210824/how-to-avoid-cgdisplaymodecopypixelencoding-to-get-bpp
    // https://github.com/libsdl-org/SDL/pull/6628
	CFStringRef pixelEncoding = CGDisplayModeCopyPixelEncoding(mode);	
    // my numerical representation for kIO16BitFloatPixels and kIO32bitFloatPixels	
    // are made up and possibly non-sensical	
    if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO32BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 96;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO64BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 64;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO16BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 48;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 32;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO30BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 30;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 16;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive)) {	
        depth = 8;	
    }	
    CFRelease(pixelEncoding);	
    return depth;	
}

static bool isHiDPIMode(CGDisplayModeRef mode) {
    // Check if the mode is HiDPI by comparing pixel width to width
    // If pixel width is greater than width, it's a HiDPI mode
    return CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode);
}

CFArrayRef getAllModes(CGDirectDisplayID display) {
    // Create options dictionary to include HiDPI modes
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    // Include HiDPI modes
    CFDictionarySetValue(options, kCGDisplayShowDuplicateLowResolutionModes, kCFBooleanTrue);
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(display, options);
    CFRelease(options);
    return allModes;
}

extern "C" bool MacGetModeNum(CGDirectDisplayID display, uint32_t *numModes) {
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        return false;
    }
    *numModes = CFArrayGetCount(allModes);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetModes(CGDirectDisplayID display, uint32_t *widths, uint32_t *heights, bool *hidpis, uint32_t max, uint32_t *numModes) {
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return false;
    }
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return false;
    }
    uint32_t allModeCount = CFArrayGetCount(allModes);
    uint32_t realNum = 0;
    for (uint32_t i = 0; i < allModeCount && realNum < max; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {
            widths[realNum] = (uint32_t)CGDisplayModeGetWidth(mode);
            heights[realNum] = (uint32_t)CGDisplayModeGetHeight(mode);
            hidpis[realNum] = isHiDPIMode(mode);
            realNum++;
        }
    }
    *numModes = realNum;
    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetMode(CGDirectDisplayID display, uint32_t *width, uint32_t *height) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode == NULL) {
        return false;
    }
    *width = (uint32_t)CGDisplayModeGetWidth(mode);
    *height = (uint32_t)CGDisplayModeGetHeight(mode);
    CGDisplayModeRelease(mode);
    return true;
}

static bool setDisplayToMode(CGDirectDisplayID display, CGDisplayModeRef mode) {
    CGError rc;
    CGDisplayConfigRef config;
    rc = CGBeginDisplayConfiguration(&config);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    return true;
}

// Set the display to a specific mode based on width and height.
// Returns true if the display mode was successfully changed, false otherwise.
// If no such mode is available, it will not change the display mode.
//
// If `tryHiDPI` is true, it will try to set the display to a HiDPI mode if available.
// If no HiDPI mode is available, it will fall back to a non-HiDPI mode with the same resolution.
// If `tryHiDPI` is false, it sets the display to the first mode with the same resolution, no matter if it's HiDPI or not.
extern "C" bool MacSetMode(CGDirectDisplayID display, uint32_t width, uint32_t height, bool tryHiDPI)
{
    bool ret = false;
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return ret;
    }
    CFArrayRef allModes = getAllModes(display);

    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return ret;
    }
    int numModes = CFArrayGetCount(allModes);
    CGDisplayModeRef preferredHiDPIMode = NULL;
    CGDisplayModeRef fallbackMode = NULL;
    for (int i = 0; i < numModes; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (width == CGDisplayModeGetWidth(mode) &&
            height == CGDisplayModeGetHeight(mode) && 
            CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {

            if (isHiDPIMode(mode)) {
                preferredHiDPIMode = mode;
                break;
            } else {
                fallbackMode = mode;
                if (!tryHiDPI) {
                    break;
                }
            }
        }
    }

    if (preferredHiDPIMode) {
        ret = setDisplayToMode(display, preferredHiDPIMode);
    } else if (fallbackMode) {
        ret = setDisplayToMode(display, fallbackMode);
    }

    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return ret;
}

static std::atomic<CFMachPortRef> g_eventTap{NULL};
static std::atomic<CFRunLoopRef> g_eventTapRunLoop{NULL};
static std::atomic<bool> g_privacyInputBlocked{false};
static std::mutex g_eventTapStateMutex;
static std::condition_variable g_eventTapStateCondition;
enum class EventTapState {
    Idle,
    Starting,
    Ready,
};
static EventTapState g_eventTapState = EventTapState::Idle;
static std::mutex g_privacyModeMutex;
static bool g_privacyModeActive = false;

// The event source user data value used by enigo library for injected events.
// This allows us to distinguish remote input (which should be allowed) from local physical input.
// See: libs/enigo/src/macos/macos_impl.rs - ENIGO_INPUT_EXTRA_VALUE
static const int64_t ENIGO_INPUT_EXTRA_VALUE = 100;

static CGEventRef PrivacyEventTapCallback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *refcon) {
    (void)proxy;
    (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CFMachPortRef eventTap = g_eventTap.load(std::memory_order_acquire);
        if (eventTap) {
            CGEventTapEnable(eventTap, true);
        }
        return event;
    }

    if (!g_privacyInputBlocked.load(std::memory_order_acquire)) {
        return event;
    }

    if (event == NULL) {
        return NULL;
    }

    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (userData == ENIGO_INPUT_EXTRA_VALUE) {
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState) {
        return NULL;
    }
    return event;
}

static void EventTapThreadMain() {
    bool initialAttempt = true;
    for (;;) {
        if (!initialAttempt &&
            !g_privacyInputBlocked.load(std::memory_order_acquire)) {
            std::lock_guard<std::mutex> lock(g_eventTapStateMutex);
            g_eventTapState = EventTapState::Idle;
            g_eventTapStateCondition.notify_all();
            return;
        }
        initialAttempt = false;
        bool setupSucceeded = false;
        @autoreleasepool {
            CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown) |
                                    CGEventMaskBit(kCGEventKeyUp) |
                                    CGEventMaskBit(kCGEventLeftMouseDown) |
                                    CGEventMaskBit(kCGEventLeftMouseUp) |
                                    CGEventMaskBit(kCGEventRightMouseDown) |
                                    CGEventMaskBit(kCGEventRightMouseUp) |
                                    CGEventMaskBit(kCGEventOtherMouseDown) |
                                    CGEventMaskBit(kCGEventOtherMouseUp) |
                                    CGEventMaskBit(kCGEventLeftMouseDragged) |
                                    CGEventMaskBit(kCGEventRightMouseDragged) |
                                    CGEventMaskBit(kCGEventOtherMouseDragged) |
                                    CGEventMaskBit(kCGEventMouseMoved) |
                                    CGEventMaskBit(kCGEventScrollWheel);

            CFMachPortRef eventTap = CGEventTapCreate(
                kCGHIDEventTap,
                kCGHeadInsertEventTap,
                kCGEventTapOptionDefault,
                eventMask,
                PrivacyEventTapCallback,
                NULL);
            CFRunLoopSourceRef runLoopSource = eventTap
                ? CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                : NULL;
            CFRunLoopRef runLoop = NULL;
            if (eventTap && runLoopSource) {
                runLoop = CFRunLoopGetCurrent();
                CFRunLoopAddSource(runLoop, runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }

            setupSucceeded = eventTap && runLoopSource && runLoop;
            if (setupSucceeded) {
                CFRetain(runLoop);
                {
                    std::lock_guard<std::mutex> lock(g_eventTapStateMutex);
                    g_eventTap.store(eventTap, std::memory_order_release);
                    g_eventTapRunLoop.store(runLoop, std::memory_order_release);
                    g_eventTapState = EventTapState::Ready;
                }
                g_eventTapStateCondition.notify_all();
                CFRunLoopRun();
                CGEventTapEnable(eventTap, false);
                CFRunLoopRemoveSource(runLoop, runLoopSource, kCFRunLoopCommonModes);
                CFMachPortInvalidate(eventTap);
            }

            {
                std::lock_guard<std::mutex> lock(g_eventTapStateMutex);
                g_eventTap.store(NULL, std::memory_order_release);
                g_eventTapRunLoop.store(NULL, std::memory_order_release);
                g_eventTapState = EventTapState::Idle;
            }
            g_eventTapStateCondition.notify_all();
            if (setupSucceeded) {
                CFRelease(runLoop);
            }
            if (runLoopSource) {
                CFRelease(runLoopSource);
            }
            if (eventTap) {
                CFRelease(eventTap);
            }
        }

        if (!g_privacyInputBlocked.load(std::memory_order_acquire)) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(g_eventTapStateMutex);
            if (!g_privacyInputBlocked.load(std::memory_order_acquire) ||
                g_eventTapState != EventTapState::Idle) {
                return;
            }
            g_eventTapState = EventTapState::Starting;
        }
        std::this_thread::sleep_for(
            setupSucceeded ? std::chrono::milliseconds(100) : std::chrono::seconds(1));
    }
}

static bool SetupEventTap() {
    std::unique_lock<std::mutex> lock(g_eventTapStateMutex);
    if (g_eventTapState == EventTapState::Ready &&
        g_eventTap.load(std::memory_order_acquire) != NULL) {
        return true;
    }
    if (g_eventTapState == EventTapState::Idle) {
        g_eventTapState = EventTapState::Starting;
        try {
            std::thread(EventTapThreadMain).detach();
        } catch (const std::system_error &error) {
            g_eventTapState = EventTapState::Idle;
            NSLog(@"MacSetPrivacyMode: Failed to start CGEventTap thread: %s", error.what());
            return false;
        }
    }

    bool finished = g_eventTapStateCondition.wait_for(
        lock,
        std::chrono::seconds(5),
        [] { return g_eventTapState != EventTapState::Starting; });
    bool success = finished &&
                   g_eventTapState == EventTapState::Ready &&
                   g_eventTap.load(std::memory_order_acquire) != NULL;
    if (!success) {
        NSLog(@"MacSetPrivacyMode: Failed to create CGEventTap; input blocking not enabled.");
    }
    return success;
}

static bool StopEventTap() {
    std::unique_lock<std::mutex> lock(g_eventTapStateMutex);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (g_eventTapState != EventTapState::Idle) {
        if (g_eventTapState == EventTapState::Ready) {
            CFRunLoopRef runLoop = g_eventTapRunLoop.load(std::memory_order_acquire);
            if (runLoop != NULL) {
                CFRunLoopStop(runLoop);
            }
        }
        if (g_eventTapStateCondition.wait_until(lock, deadline) == std::cv_status::timeout) {
            NSLog(@"MacSetPrivacyMode: Timed out stopping CGEventTap");
            return false;
        }
    }
    return true;
}

static bool TurnOffPrivacyModeInternal() {
    if (!g_privacyModeActive) {
        g_privacyInputBlocked.store(false, std::memory_order_release);
        StopEventTap();
        return true;
    }

    g_privacyInputBlocked.store(false, std::memory_order_release);
    MacPrivacyDestroyOverlays();
    g_privacyModeActive = false;
    StopEventTap();
    return true;
}

extern "C" bool MacSetPrivacyMode(bool on) {
    std::lock_guard<std::mutex> lock(g_privacyModeMutex);
    if (on) {
        if (g_privacyModeActive) {
            return SetupEventTap();
        }

        if (!SetupEventTap()) {
            return false;
        }
        g_privacyInputBlocked.store(true, std::memory_order_release);
        if (!MacPrivacyCreateOverlays()) {
            NSLog(@"MacSetPrivacyMode: Failed to create privacy overlays");
            g_privacyInputBlocked.store(false, std::memory_order_release);
            StopEventTap();
            return false;
        }

        g_privacyModeActive = true;
        return true;
    }
    return TurnOffPrivacyModeInternal();
}
