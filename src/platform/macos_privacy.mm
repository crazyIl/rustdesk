#import "macos_privacy.h"

#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <chrono>
#include <cstdio>
#include <thread>
#include <unistd.h>

static NSString *const kRustDeskPrivacyWindowTitle = @"RustDesk Privacy Screen";
static constexpr int64_t kOperationTimeoutNanos = 5 * NSEC_PER_SEC;

static void WriteError(char *buffer, std::size_t buffer_size, NSString *message) {
    if (buffer == nullptr || buffer_size == 0) {
        return;
    }
    std::snprintf(buffer, buffer_size, "%s", message.UTF8String ?: "Unknown error");
}

@interface RustDeskPrivacyOverlayController : NSObject
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL cursorHidden;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
- (BOOL)start;
- (void)stop;
- (NSDictionary<NSNumber *, NSNumber *> *)windowIDsByDisplay;
@end

@implementation RustDeskPrivacyOverlayController

- (instancetype)init {
    self = [super init];
    if (self) {
        _windows = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSWindow *)createWindowForScreen:(NSScreen *)screen {
    NSRect contentRect = NSMakeRect(0, 0, NSWidth(screen.frame), NSHeight(screen.frame));
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:contentRect
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    window.title = kRustDeskPrivacyWindowTitle;
    window.releasedWhenClosed = NO;
    window.backgroundColor = NSColor.blackColor;
    window.opaque = YES;
    window.hasShadow = NO;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    window.ignoresMouseEvents = YES;
    window.hidesOnDeactivate = NO;
    window.sharingType = NSWindowSharingReadOnly;
    window.level = CGShieldingWindowLevel();
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle;
    return window;
}

- (BOOL)syncWindows {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count == 0) {
        return NO;
    }

    NSMutableSet<NSNumber *> *onlineDisplays = [NSMutableSet setWithCapacity:screens.count];
    for (NSScreen *screen in screens) {
        NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"];
        if (displayID == nil) {
            continue;
        }
        [onlineDisplays addObject:displayID];

        NSWindow *window = self.windows[displayID];
        if (window == nil) {
            window = [self createWindowForScreen:screen];
            self.windows[displayID] = window;
        } else {
            [window setFrame:screen.frame display:YES];
        }
        [window orderFrontRegardless];
        [window displayIfNeeded];
    }

    for (NSNumber *displayID in self.windows.allKeys.copy) {
        if (![onlineDisplays containsObject:displayID]) {
            [self.windows[displayID] close];
            [self.windows removeObjectForKey:displayID];
        }
    }
    return self.windows.count == screens.count;
}

- (void)screenParametersDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.active) {
        [self syncWindows];
    }
}

- (BOOL)start {
    if (self.active) {
        return [self syncWindows];
    }
    self.active = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(screenParametersDidChange:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil];
    if (![self syncWindows]) {
        [self stop];
        return NO;
    }
    CGError cursorError = CGDisplayHideCursor(kCGNullDirectDisplay);
    if (cursorError == kCGErrorSuccess) {
        self.cursorHidden = YES;
    } else {
        NSLog(@"Failed to hide privacy cursor: %d", cursorError);
    }
    return YES;
}

- (void)stop {
    if (self.cursorHidden) {
        CGError cursorError = CGDisplayShowCursor(kCGNullDirectDisplay);
        if (cursorError == kCGErrorSuccess) {
            self.cursorHidden = NO;
        } else {
            NSLog(@"Failed to restore privacy cursor: %d", cursorError);
        }
    }
    if (!self.active) {
        return;
    }
    self.active = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (NSWindow *window in self.windows.allValues) {
        [window close];
    }
    [self.windows removeAllObjects];
}

- (NSDictionary<NSNumber *, NSNumber *> *)windowIDsByDisplay {
    NSMutableDictionary<NSNumber *, NSNumber *> *windowIDs =
        [NSMutableDictionary dictionaryWithCapacity:self.windows.count];
    for (NSNumber *displayID in self.windows) {
        NSWindow *window = self.windows[displayID];
        if (window.windowNumber > 0) {
            windowIDs[displayID] = @(window.windowNumber);
        }
    }
    return windowIDs;
}

@end

static RustDeskPrivacyOverlayController *g_overlayController;

static NSDictionary<NSNumber *, NSNumber *> *GetPrivacyOverlayWindowIDsByDisplay() {
    __block NSDictionary<NSNumber *, NSNumber *> *windowIDs = nil;
    void (^readBlock)(void) = ^{
        windowIDs = g_overlayController == nil
            ? @{}
            : [g_overlayController windowIDsByDisplay];
    };
    if (NSThread.isMainThread) {
        readBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readBlock);
    }
    return windowIDs;
}

extern "C" bool MacPrivacyModeSupported() {
    if (@available(macOS 12.3, *)) {
        return NSClassFromString(@"SCStream") != nil;
    }
    return false;
}

extern "C" bool MacPrivacyCreateOverlays() {
    __block BOOL success = NO;
    void (^createBlock)(void) = ^{
        if (g_overlayController == nil) {
            g_overlayController = [[RustDeskPrivacyOverlayController alloc] init];
        }
        success = [g_overlayController start];
    };
    if (NSThread.isMainThread) {
        createBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), createBlock);
    }
    return success == YES;
}

extern "C" void MacPrivacyDestroyOverlays() {
    void (^destroyBlock)(void) = ^{
        [g_overlayController stop];
        g_overlayController = nil;
    };
    if (NSThread.isMainThread) {
        destroyBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), destroyBlock);
    }
}

API_AVAILABLE(macos(12.3))
@interface RustDeskPrivacyCapture : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) MacPrivacyFrameHandler frameHandler;
@property(nonatomic) MacPrivacyErrorHandler errorHandler;
@property(nonatomic) void *context;
- (void)invalidateHandler;
- (void)tearDownStream;
- (BOOL)stopWithError:(NSError **)error;
@end

@implementation RustDeskPrivacyCapture

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                    ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || self.frameHandler == nullptr) {
        return;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
        return;
    }
    NSDictionary *attachment = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
    NSNumber *status = attachment[SCStreamFrameInfoStatus];
    if (status == nil || status.integerValue != SCFrameStatusComplete) {
        return;
    }
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == nullptr) {
        return;
    }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(imageBuffer);
    if (surface != nullptr) {
        self.frameHandler(surface, self.context);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    NSLog(@"RustDesk privacy capture stopped: %@", error.localizedDescription);
    NSString *message = error.localizedDescription ?: @"Privacy capture stopped";
    dispatch_queue_t queue = self.queue;
    if (queue != nil) {
        dispatch_async(queue, ^{
            if (self.errorHandler != nullptr) {
                self.errorHandler(message.UTF8String, self.context);
            }
        });
    }
}

- (void)invalidateHandler {
    if (self.queue == nil) {
        self.frameHandler = nullptr;
        self.errorHandler = nullptr;
        self.context = nullptr;
        return;
    }
    dispatch_sync(self.queue, ^{
        self.frameHandler = nullptr;
        self.errorHandler = nullptr;
        self.context = nullptr;
    });
}

- (void)tearDownStream {
    SCStream *stream = self.stream;
    [self invalidateHandler];
    if (stream != nil) {
        NSError *removeError = nil;
        if (![stream removeStreamOutput:self
                                   type:SCStreamOutputTypeScreen
                                  error:&removeError] && removeError != nil) {
            NSLog(@"Failed to remove RustDesk privacy stream output: %@", removeError.localizedDescription);
        }
    }
    self.stream = nil;
}

- (BOOL)stopWithError:(NSError **)error {
    if (self.stream == nil) {
        [self tearDownStream];
        return YES;
    }
    SCStream *stream = self.stream;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *stopError = nil;
    [stream stopCaptureWithCompletionHandler:^(NSError *captureError) {
        stopError = captureError;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, kOperationTimeoutNanos)) != 0) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"RustDeskPrivacyCapture"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"Timed out stopping privacy capture"}];
        }
        [self tearDownStream];
        return NO;
    }
    [self tearDownStream];
    if (error != nullptr) {
        *error = stopError;
    }
    return stopError == nil;
}

@end

static SCShareableContent *GetShareableContent(
    NSError **error,
    dispatch_time_t deadline) API_AVAILABLE(macos(12.3));
static SCShareableContent *GetShareableContent(NSError **error, dispatch_time_t deadline) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block SCShareableContent *content = nil;
    __block NSError *contentError = nil;
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:NO
                                  completionHandler:^(SCShareableContent *shareableContent,
                                                      NSError *captureError) {
        content = shareableContent;
        contentError = captureError;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
        if (error != nullptr) {
            *error = [NSError errorWithDomain:@"RustDeskPrivacyCapture"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"Timed out loading shareable content"}];
        }
        return nil;
    }
    if (error != nullptr) {
        *error = contentError;
    }
    return content;
}

extern "C" void *MacPrivacyCapturerCreate(
    CGDirectDisplayID displayID,
    std::size_t width,
    std::size_t height,
    MacPrivacyFrameHandler frameHandler,
    MacPrivacyErrorHandler errorHandler,
    void *context,
    char *error_buffer,
    std::size_t error_buffer_size) {
    if (@available(macOS 12.3, *)) {
        @autoreleasepool {
            dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, kOperationTimeoutNanos);
            auto discoveryDeadline = std::chrono::steady_clock::now() +
                                     std::chrono::nanoseconds(kOperationTimeoutNanos);
            NSError *error = nil;
            SCShareableContent *content = nil;
            SCDisplay *targetDisplay = nil;
            NSMutableArray<SCWindow *> *excludedWindows = nil;
            BOOL targetOverlayFound = NO;
            while (std::chrono::steady_clock::now() < discoveryDeadline) {
                NSDictionary<NSNumber *, NSNumber *> *windowIDsByDisplay =
                    GetPrivacyOverlayWindowIDsByDisplay();
                NSNumber *targetOverlayWindowID = windowIDsByDisplay[@(displayID)];
                if (targetOverlayWindowID == nil) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    continue;
                }
                NSSet<NSNumber *> *overlayWindowIDs =
                    [NSSet setWithArray:windowIDsByDisplay.allValues];
                content = GetShareableContent(&error, deadline);
                if (content == nil) {
                    WriteError(error_buffer, error_buffer_size, error.localizedDescription);
                    return nullptr;
                }

                targetDisplay = nil;
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == displayID) {
                        targetDisplay = display;
                        break;
                    }
                }
                if (targetDisplay == nil) {
                    WriteError(error_buffer, error_buffer_size, @"Display is not available to ScreenCaptureKit");
                    return nullptr;
                }

                excludedWindows = [NSMutableArray array];
                targetOverlayFound = NO;
                pid_t processID = getpid();
                for (SCWindow *window in content.windows) {
                    BOOL matchesWindowID = [overlayWindowIDs containsObject:@(window.windowID)];
                    BOOL matchesLegacyIdentity =
                        window.owningApplication.processID == processID &&
                        [window.title isEqualToString:kRustDeskPrivacyWindowTitle];
                    if (matchesWindowID || matchesLegacyIdentity) {
                        [excludedWindows addObject:window];
                    }
                    if (window.windowID == targetOverlayWindowID.unsignedIntValue) {
                        targetOverlayFound = YES;
                    }
                }
                if (targetOverlayFound) {
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            if (!targetOverlayFound) {
                WriteError(error_buffer, error_buffer_size, @"Privacy overlay windows are not shareable yet");
                return nullptr;
            }

            SCContentFilter *filter = [[SCContentFilter alloc]
                initWithDisplay:targetDisplay
               excludingWindows:excludedWindows];
            SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
            configuration.width = width;
            configuration.height = height;
            configuration.pixelFormat = kCVPixelFormatType_32BGRA;
            configuration.queueDepth = 3;
            configuration.minimumFrameInterval = CMTimeMake(1, 60);
            configuration.showsCursor = NO;

            RustDeskPrivacyCapture *capture = [[RustDeskPrivacyCapture alloc] init];
            capture.frameHandler = frameHandler;
            capture.errorHandler = errorHandler;
            capture.context = context;
            capture.queue = dispatch_queue_create("com.rustdesk.privacy-capture", DISPATCH_QUEUE_SERIAL);
            capture.stream = [[SCStream alloc]
                initWithFilter:filter
                 configuration:configuration
                      delegate:capture];

            if (![capture.stream addStreamOutput:capture
                                            type:SCStreamOutputTypeScreen
                              sampleHandlerQueue:capture.queue
                                           error:&error]) {
                WriteError(error_buffer, error_buffer_size, error.localizedDescription);
                return nullptr;
            }

            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block NSError *startError = nil;
            [capture.stream startCaptureWithCompletionHandler:^(NSError *captureError) {
                startError = captureError;
                dispatch_semaphore_signal(semaphore);
            }];
            if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
                [capture.stream stopCaptureWithCompletionHandler:nil];
                [capture tearDownStream];
                WriteError(error_buffer, error_buffer_size, @"Timed out starting privacy capture");
                return nullptr;
            }
            if (startError != nil) {
                [capture.stream stopCaptureWithCompletionHandler:nil];
                [capture tearDownStream];
                WriteError(error_buffer, error_buffer_size, startError.localizedDescription);
                return nullptr;
            }
            return (__bridge_retained void *)capture;
        }
    }
    WriteError(error_buffer, error_buffer_size, @"Privacy mode requires macOS 12.3 or later");
    return nullptr;
}

extern "C" void MacPrivacyCapturerDestroy(void *capturer) {
    if (capturer == nullptr) {
        return;
    }
    if (@available(macOS 12.3, *)) {
        RustDeskPrivacyCapture *capture = (__bridge_transfer RustDeskPrivacyCapture *)capturer;
        NSError *error = nil;
        if (![capture stopWithError:&error]) {
            NSLog(@"Failed to stop RustDesk privacy capture: %@", error.localizedDescription);
        }
    }
}
