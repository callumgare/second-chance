//
//  puppet_control.m
//  Lets WrappPuppeteer, the integration tests' driver, see and click the game
//  window from inside the game's own process.
//
//  macOS lets a process capture its own windows without the Screen Recording
//  permission (ScreenCaptureKit's current-process content), and post events to
//  them without Accessibility (-[NSApp postEvent:], as cursor_lock.m does). So
//  rather than WrappPuppeteer needing both permissions to act on the game from
//  outside, it asks this helper over a Unix socket.
//
//  Armed only when WrappPuppeteer starts the wrapp: SECOND_CHANCE_PUPPET_DIR
//  names a private directory, and PUPPET_CONTROL_EXE (set by
//  WineEnvironment.inProcessHelperVariables when that directory is) names the
//  game's .exe -- or `scummvm`, which the wrapp loads this dylib into with
//  DYLD_INSERT_LIBRARIES. Nothing a player runs sets either.
//
//  One request per connection to $SECOND_CHANCE_PUPPET_DIR/game.sock, one line
//  each way; replies start `ok` or `error`. Coordinates are points in the game
//  window, top-left origin -- a capture's pixels divided by its `scale`.
//
//    state            -> ok window=<n> size=<w>x<h> scale=<s> fullscreen=0|1 native=0|1 key=0|1 active=0|1
//                           cursor=held|free cursorlock=off|waiting|locked|not-locked
//    capture <path>   -> ok <w>x<h>     PNG of the game window
//    click <x> <y>    -> ok             mouse moved, a pause, then left button down and up
//    move <x> <y>     -> ok             mouse moved only
//
//  `cursor` is whether cnc-ddraw holds the mouse right now, and `cursorlock`
//  how cursor_lock.m got on (helper_common.h). WrappPuppeteer compares
//  `cursor` either side of its first click: a click that took the cursor was
//  one cnc-ddraw swallowed (docs/wine-in-process-helpers.md#cursor-lock).
//
//  The game window is the biggest visible window the process has. Each capture
//  lists the process's windows for ScreenCaptureKit afresh: a window kept from
//  an earlier listing can stop capturing with nothing to say so -- after the
//  window moves into its fullscreen Space, or once a Direct3D game skips its
//  intro -- and a capture with it then hangs until it times out.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh.
//
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <fcntl.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "helper_common.h"

/// How long to wait on ScreenCaptureKit, or on the main thread, before giving
/// a request up. Generous: a loaded Mac's replayd can take seconds.
static const int64_t kRequestTimeoutSeconds = 30;

/// The Nancy Drew games poll the mouse (GetAsyncKeyState, GetCursorPos)
/// rather than read click events, a frame at a time. So a click moves the
/// cursor there and waits for the game to see it arrive -- a menu button only
/// takes a press once it's highlighted under the cursor -- then holds the
/// button long enough that a poll sees it down.
static const useconds_t kHoverBeforeClickMicroseconds = 150 * 1000;
static const useconds_t kClickHoldMicroseconds = 100 * 1000;

static os_log_t gLog;

/// Appends to IN_PROCESS_HELPERS_LOG when set, alongside os_log, as the other
/// helpers do.
static void debugLog(const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    os_log(gLog, "[PuppetControl] %{public}s", message);
    const char *path = getenv("IN_PROCESS_HELPERS_LOG");
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "pid=%d puppet-control | %s\n", getpid(), message);
        close(fd);
    }
}

/// Run a block on the main thread and wait for its result: AppKit is
/// main-thread only, and Wine's main thread (like SDL's) runs a CFRunLoop
/// that drains performed blocks. NO on timeout.
static BOOL onMainThread(BOOL (^block)(void)) {
    __block BOOL result = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        result = block();
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kRequestTimeoutSeconds * NSEC_PER_SEC)) != 0) {
        return NO;
    }
    return result;
}

/// The game window: the biggest visible window this process has. Main thread.
static NSWindow *gameWindow(void) {
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            best = window;
            bestArea = area;
        }
    }
    return best;
}

static NSString *stateCommand(void) {
    __block NSString *reply = @"error no game window";
    onMainThread(^BOOL {
        NSWindow *window = gameWindow();
        if (!window) return NO;
        // Fullscreen either way a game gets there: a macOS fullscreen Space
        // (native fullscreen, ScummVM's -f), or a borderless window exactly
        // covering the screen, as Direct3D games draw (Ghost of Thornton
        // Hall's native fullscreen finds no eligible window and leaves it).
        // In its Space once it has finished moving there: AppKit marks the
        // window fullscreen as the move begins.
        BOOL native = (window.styleMask & NSWindowStyleMaskFullScreen) != 0 && !windowIsEnteringFullscreen(window);
        BOOL coversScreen = window.screen && NSEqualRects(window.frame, window.screen.frame);
        reply = [NSString stringWithFormat:@"ok window=%ld size=%.0fx%.0f scale=%.2f fullscreen=%d native=%d key=%d active=%d cursor=%s cursorlock=%s",
                 (long)window.windowNumber, window.frame.size.width, window.frame.size.height,
                 window.backingScaleFactor, native || coversScreen, native, window.isKeyWindow, NSApp.isActive,
                 cursorLockHeld() ? "held" : "free", cursorLockStatus()];
        return YES;
    });
    return reply;
}

#pragma mark - Capture

/// Find the game window among this process's ScreenCaptureKit content.
static SCWindow *listGameWindow(CGWindowID windowID, NSString **error) API_AVAILABLE(macos(14.4)) {
    __block SCWindow *found = nil;
    __block NSString *failure = @"timed out listing this process's windows";
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    double started = CFAbsoluteTimeGetCurrent();
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *listError) {
        for (SCWindow *window in content.windows) {
            if (window.windowID == windowID) found = window;
        }
        failure = found ? nil : [NSString stringWithFormat:@"window %u is not among this process's windows (%@)",
                                 windowID, listError.localizedDescription ?: @"no error"];
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kRequestTimeoutSeconds * NSEC_PER_SEC));
    double seconds = CFAbsoluteTimeGetCurrent() - started;
    if (seconds > 2) debugLog("listing this process's windows took %.1fs", seconds);
    if (error) *error = failure;
    return found;
}

/// How long a capture may go unanswered before a second is asked for
/// alongside it. Nothing about the window says a request will be lost --
/// ScreenCaptureKit now and then never answers one, at the same point in a game
/// where it otherwise answers in a fraction of a second, and answers the next
/// at once -- so the only sign is that it hasn't answered. The first request
/// isn't given up: on a slow Mac it can still win, so this only decides when a
/// spare request starts, not whether a capture fails.
static const double kSecondCaptureAfterSeconds = 2.0;

/// One `capture` request's outcome, shared by the screenshots taken for it:
/// the first to bring a picture back writes it; an error only stands once no
/// screenshot is outstanding.
@interface CaptureRequest : NSObject {
@public
    NSString *path;
    NSString *reply;
    NSString *lastError;
    BOOL finished;
    int outstanding;
    dispatch_semaphore_t done;
}
@end
@implementation CaptureRequest
@end

/// Take a screenshot of `window` for `request`.
static void startCapture(SCWindow *window, NSSize size, CGFloat scale, CaptureRequest *request) API_AVAILABLE(macos(14.4)) {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = (size_t)(size.width * scale);
    config.height = (size_t)(size.height * scale);
    config.showsCursor = NO;
    @synchronized (request) {
        request->outstanding++;
    }
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError *captureError) {
        @synchronized (request) {
            request->outstanding--;
            if (request->finished) return;
            if (!image) {
                request->lastError = [NSString stringWithFormat:@"error capture failed: %@", captureError.localizedDescription];
                if (request->outstanding > 0) return;
                request->reply = request->lastError;
            } else {
                CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)[NSURL fileURLWithPath:request->path], CFSTR("public.png"), 1, NULL);
                BOOL written = NO;
                if (destination) {
                    CGImageDestinationAddImage(destination, image, NULL);
                    written = CGImageDestinationFinalize(destination);
                    CFRelease(destination);
                }
                request->reply = written ? [NSString stringWithFormat:@"ok %zux%zu", CGImageGetWidth(image), CGImageGetHeight(image)]
                                         : [NSString stringWithFormat:@"error could not write %@", request->path];
            }
            request->finished = YES;
            dispatch_semaphore_signal(request->done);
        }
    }];
}

/// Whether ScreenCaptureKit can list this process's own windows (macOS 14.4),
/// which capturing starts from. Asked of ScreenCaptureKit itself rather than
/// with @available: ScummVM is linked against the macOS 10.14 SDK, so macOS
/// runs it in compatibility mode and tells it an older version than its own,
/// and on macOS 15 @available there said no on a Mac that has the API.
static BOOL canListOwnWindows(void) {
    Class content = NSClassFromString(@"SCShareableContent");
    return [content respondsToSelector:@selector(getCurrentProcessShareableContentWithCompletionHandler:)];
}

static NSString *captureCommand(NSString *path) {
    if (!canListOwnWindows()) return @"error capturing needs macOS 14.4";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    {
        __block CGWindowID windowID = 0;
        __block NSSize size = NSZeroSize;
        __block CGFloat scale = 1;
        __block BOOL settled = NO;
        onMainThread(^BOOL {
            NSWindow *window = gameWindow();
            windowID = (CGWindowID)window.windowNumber;
            size = window.frame.size;
            scale = window.backingScaleFactor;
            settled = nativeFullscreenSettled();
            return window != nil;
        });
        if (!windowID) return @"error no game window";
        // Captured around its move into a fullscreen Space -- even just before
        // the move begins -- a window can be refused as though Screen
        // Recording were denied, and then left out of this process's windows
        // for good. So nothing is captured until native fullscreen is done
        // with it.
        if (!settled) return @"error the game window isn't in its fullscreen Space yet";

        NSString *error = nil;
        SCWindow *found = listGameWindow(windowID, &error);
        if (!found) return [@"error " stringByAppendingString:error];

        CaptureRequest *request = [CaptureRequest new];
        request->path = path;
        request->reply = @"error timed out capturing the game window";
        request->done = dispatch_semaphore_create(0);
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, kRequestTimeoutSeconds * NSEC_PER_SEC);
        startCapture(found, size, scale, request);
        if (dispatch_semaphore_wait(request->done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSecondCaptureAfterSeconds * NSEC_PER_SEC))) != 0) {
            debugLog("no answer to a capture after %.0fs; asking again alongside it", kSecondCaptureAfterSeconds);
            SCWindow *again = listGameWindow(windowID, &error);
            if (again) startCapture(again, size, scale, request);
            dispatch_semaphore_wait(request->done, deadline);
        }
        @synchronized (request) {
            request->finished = YES;
            return request->reply;
        }
    }
#pragma clang diagnostic pop
}

#pragma mark - Mouse

static NSEvent *mouseEvent(NSEventType type, NSPoint point, NSWindow *window) {
    return [NSEvent mouseEventWithType:type
                              location:point
                         modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:window.windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:1
                              pressure:type == NSEventTypeLeftMouseDown ? 1.0 : 0.0];
}

/// Post mouse events of `types` at a window point given with a top-left
/// origin. Wine ignores mouse events not tied to one of its windows, so each
/// must come out on the game window (as in cursor_lock.m). nil when posted.
static NSString *postMouseEvents(NSArray<NSNumber *> *types, double x, double y) {
    __block NSString *error = @"error no game window";
    onMainThread(^BOOL {
        NSWindow *window = gameWindow();
        if (!window) return NO;
        NSPoint point = NSMakePoint(x, window.frame.size.height - y);  // window coordinates are bottom-left
        NSMutableArray<NSEvent *> *events = [NSMutableArray array];
        for (NSNumber *type in types) {
            NSEvent *event = mouseEvent((NSEventType)type.unsignedIntegerValue, point, window);
            if (event.window != window) {
                error = @"error the event would not land on the game window";
                return NO;
            }
            [events addObject:event];
        }
        for (NSEvent *event in events) [NSApp postEvent:event atStart:NO];
        error = nil;
        return YES;
    });
    return error;
}

/// A mouse move, and if `click`, then a pause for the game to see it and a
/// left click held for kClickHoldMicroseconds.
static NSString *mouseCommand(double x, double y, BOOL click) {
    NSString *error = postMouseEvents(@[@(NSEventTypeMouseMoved)], x, y);
    if (error || !click) return error ?: @"ok";
    usleep(kHoverBeforeClickMicroseconds);
    error = postMouseEvents(@[@(NSEventTypeLeftMouseDown)], x, y);
    if (error) return error;
    usleep(kClickHoldMicroseconds);
    return postMouseEvents(@[@(NSEventTypeLeftMouseUp)], x, y) ?: @"ok";
}

#pragma mark - Serving

static NSString *handle(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    if ([command isEqualToString:@"state"] && parts.count == 1) return stateCommand();
    if ([command isEqualToString:@"capture"] && parts.count == 2) return captureCommand(parts[1]);
    if (([command isEqualToString:@"click"] || [command isEqualToString:@"move"]) && parts.count == 3) {
        return mouseCommand(parts[1].doubleValue, parts[2].doubleValue, [command isEqualToString:@"click"]);
    }
    return [@"error unknown request: " stringByAppendingString:line];
}

static void *serve(void *arg) {
    char *path = arg;
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    unlink(path);
    if (server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 4) != 0) {
        debugLog("cannot listen on %s: %s", path, strerror(errno));
        helperReport("PuppetControl", "error", "cannot listen on %s: %s", path, strerror(errno));
        return NULL;
    }
    debugLog("listening on %s", path);
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        char buffer[2048] = {0};
        ssize_t length = read(client, buffer, sizeof(buffer) - 1);
        if (length > 0) {
            @autoreleasepool {
                NSString *line = [[NSString stringWithUTF8String:buffer]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSString *reply = line ? handle(line) : @"error request is not UTF-8";
                debugLog("%s -> %s", line.UTF8String ?: "?", reply.UTF8String);
                const char *bytes = [reply stringByAppendingString:@"\n"].UTF8String;
                write(client, bytes, strlen(bytes));
            }
        }
        close(client);
    }
    return NULL;
}

__attribute__((constructor))
static void puppetControlInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "PuppetControl");
    const char *directory = getenv("SECOND_CHANCE_PUPPET_DIR");
    if (!directory || !*directory || !processRunsExeNamedBy("PUPPET_CONTROL_EXE")) return;

    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (snprintf(path, sizeof(path), "%s/game.sock", directory) >= (int)sizeof(path)) {
        helperReport("PuppetControl", "error", "socket path in %s is too long for a Unix socket", directory);
        return;
    }
    debugLog("armed");
    helperReport("PuppetControl", "notice", "armed in %s, listening on %s", getenv("PUPPET_CONTROL_EXE"), path);
    watchFullscreenTransitions();
    pthread_t thread;
    if (pthread_create(&thread, NULL, serve, strdup(path)) == 0) {
        pthread_detach(thread);
    } else {
        helperReport("PuppetControl", "error", "could not start the serving thread");
    }
}
