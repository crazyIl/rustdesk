#import "macos_privacy.h"

#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include <cstdio>
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
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
- (BOOL)start;
- (void)stop;
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
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:screen.frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    window.title = kRustDeskPrivacyWindowTitle;
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
    return YES;
}

- (void)stop {
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

@end

static RustDeskPrivacyOverlayController *g_overlayController;

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
@property(nonatomic) MacPrivacyFrameHandler handler;
@property(nonatomic) void *context;
- (void)invalidateHandler;
- (BOOL)stopWithError:(NSError **)error;
@end

@implementation RustDeskPrivacyCapture

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                    ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || self.handler == nullptr) {
        return;
    }
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == nullptr) {
        return;
    }
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(imageBuffer);
    if (surface != nullptr) {
        self.handler(surface, self.context);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    NSLog(@"RustDesk privacy capture stopped: %@", error.localizedDescription);
}

- (void)invalidateHandler {
    if (self.queue == nil) {
        self.handler = nullptr;
        self.context = nullptr;
        return;
    }
    dispatch_sync(self.queue, ^{
        self.handler = nullptr;
        self.context = nullptr;
    });
}

- (BOOL)stopWithError:(NSError **)error {
    if (self.stream == nil) {
        [self invalidateHandler];
        return YES;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *stopError = nil;
    [self.stream stopCaptureWithCompletionHandler:^(NSError *captureError) {
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
        [self invalidateHandler];
        return NO;
    }
    [self invalidateHandler];
    self.stream = nil;
    if (error != nullptr) {
        *error = stopError;
    }
    return stopError == nil;
}

@end

static SCShareableContent *GetShareableContent(NSError **error) API_AVAILABLE(macos(12.3));
static SCShareableContent *GetShareableContent(NSError **error) {
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
    if (dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, kOperationTimeoutNanos)) != 0) {
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
    MacPrivacyFrameHandler handler,
    void *context,
    char *error_buffer,
    std::size_t error_buffer_size) {
    if (@available(macOS 12.3, *)) {
        @autoreleasepool {
            NSError *error = nil;
            SCShareableContent *content = GetShareableContent(&error);
            if (content == nil) {
                WriteError(error_buffer, error_buffer_size, error.localizedDescription);
                return nullptr;
            }

            SCDisplay *targetDisplay = nil;
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

            NSMutableArray<SCWindow *> *excludedWindows = [NSMutableArray array];
            pid_t processID = getpid();
            for (SCWindow *window in content.windows) {
                if (window.owningApplication.processID == processID &&
                    [window.title isEqualToString:kRustDeskPrivacyWindowTitle]) {
                    [excludedWindows addObject:window];
                }
            }
            if (excludedWindows.count == 0) {
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
            capture.handler = handler;
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
            if (dispatch_semaphore_wait(
                    semaphore,
                    dispatch_time(DISPATCH_TIME_NOW, kOperationTimeoutNanos)) != 0) {
                [capture.stream stopCaptureWithCompletionHandler:nil];
                [capture invalidateHandler];
                WriteError(error_buffer, error_buffer_size, @"Timed out starting privacy capture");
                return nullptr;
            }
            if (startError != nil) {
                [capture invalidateHandler];
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
