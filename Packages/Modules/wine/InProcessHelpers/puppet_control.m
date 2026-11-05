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
//  Wine.inProcessHelperVariables when that directory is) names the
//  game's .exe -- or `scummvm`, which the wrapp loads this dylib into with
//  DYLD_INSERT_LIBRARIES. Nothing a player runs sets either.
//
//  One request per connection to $SECOND_CHANCE_PUPPET_DIR/game-<pid>.sock, a
//  line in, a reply out (one line, but for `windows`); replies start `ok` or
//  `error`. Connections are served at once, each on a thread of its own, so a
//  slow capture holds up nothing else. Coordinates are points in the game
//  window, top-left origin -- a capture's pixels divided by its `scale`.
//  Options are `name=value` words after the arguments.
//
//    hello            -> ok version=2 pid=<n> exe=<name> commands=<list>   (version 1 helpers say error)
//    state            -> ok window=<n> size=<w>x<h> scale=<s> fullscreen=0|1 native=0|1 key=0|1 active=0|1 onspace=0|1
//                           cursor=held|free cursorlock=off|waiting|locked|not-locked
//    windows          -> ok <n> windows, then a line each: id=<n> frame=<x>,<y>,<w>,<h> level=<n> visible=0|1
//                           key=0|1 main=0|1 kind=game|panel|other title=<percent-encoded>
//                                       (`game` is the window the other requests act on:
//                                       the biggest visible one)
//    capture <path> [region=<x>,<y>,<w>,<h>] [scale=<s>]
//                     -> ok <w>x<h>     PNG of the game window, or a part of it (in points), at its
//                                       backing scale or the one given
//    click <x> <y> [button=left|right] [count=1-3] [hold=<ms>]
//                     -> ok             mouse moved, a pause, then the button down and up
//    move <x> <y>     -> ok             mouse moved only
//    down|up <x> <y> [button=]   -> ok  a press or a release alone
//    drag <x> <y> <x2> <y2> [steps=<n>] [hold=<ms>] -> ok   press, moves along the line, release
//    key <name>[+<mod>...] [hold=<ms>] -> ok   key down, held (60 ms), up, with the key's own
//                                       keycode: a-z, 0-9, return, escape, tab, space, delete,
//                                       left, right, up, down, f1-f12, home, end, pageup,
//                                       pagedown, or a punctuation character; mods cmd, shift,
//                                       opt, ctrl
//    type <text>      -> ok             each character as its key (US layout), shift as needed;
//                                       the text percent-encoded (%20 a space)
//    focus            -> ok             the app active and the game window key
//    yield <pid>      -> ok             hand activation to that app, as Cmd-Tab away would
//    quit             -> ok             ask the app to quit, as its Quit menu item (Cmd-Opt-Q in Wine) does
//
//  PUPPET_CONTROL_EXE=* arms it in every process that loads it, so an
//  installer or launcher answers too, each on its own socket.
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
/// A key is held long enough for a game polling once a frame to see it down,
/// and typed keys are spaced as a person's are.
static const int kKeyHoldMilliseconds = 60;
static const useconds_t kBetweenKeysMicroseconds = 40 * 1000;

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
        reply = [NSString stringWithFormat:@"ok window=%ld size=%.0fx%.0f scale=%.2f fullscreen=%d native=%d key=%d active=%d onspace=%d cursor=%s cursorlock=%s",
                 (long)window.windowNumber, window.frame.size.width, window.frame.size.height,
                 window.backingScaleFactor, native || coversScreen, native, window.isKeyWindow, NSApp.isActive,
                 window.isOnActiveSpace,
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

/// Where a window's OpenGL surface lies in a capture of it, in pixels, when
/// it doesn't fill the window, or CGRectNull. On macOS 15 the move into a
/// fullscreen Space left a Direct3D game's surface at a size from partway
/// through it, 2485x1399 of a 2560x1440 window. The screen shows it
/// scaled up to fill the window, but a capture takes it as it is, in the bottom-left
/// corner with the rest transparent, so every click aimed by one landed left
/// of and above its target.
static CGRect undersizedSurface(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (width < 2 || height < 2) return CGRectNull;
    // Its alpha, read by drawing it into a buffer of its own: a capture's
    // pixel format isn't fixed.
    uint8_t *alpha = calloc(width * height, 1);
    if (!alpha) return CGRectNull;
    CGContextRef context = CGBitmapContextCreate(alpha, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) {
        free(alpha);
        return CGRectNull;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    // Rows run top to bottom. Opaque at the bottom-left, see-through at the
    // top-right: then how far the opaque part reaches along the bottom row
    // and up the left column.
    const uint8_t *bottom = alpha + (height - 1) * width;
    CGRect surface = CGRectNull;
    if (bottom[0] == 255 && alpha[width - 1] == 0) {
        size_t right = width, top = 0;
        while (right > 0 && bottom[right - 1] == 0) right--;
        while (top < height && alpha[top * width] == 0) top++;
        if (right > 0 && top < height && (right < width || top > 0)) {
            surface = CGRectMake(0, top, right, height - top);
        }
    }
    free(alpha);
    return surface;
}

/// `image` with its part `surface` scaled up to fill it, as the screen shows
/// it. Owned by the caller.
static CGImageRef scaledUp(CGImageRef image, CGRect surface) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRef part = CGImageCreateWithImageInRect(image, surface);
    if (!part) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGImageRef result = NULL;
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), part);
        result = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
    }
    CGImageRelease(part);
    return result;
}

/// Take a screenshot of `window` for `request`, cut to `region` (in pixels of
/// the whole window) unless it's null.
static void startCapture(SCWindow *window, NSSize size, CGFloat scale, CGRect region, CaptureRequest *request) API_AVAILABLE(macos(14.4)) {
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
                CGImageRef cut = NULL;
                CGRect surface = undersizedSurface(image);
                if (!CGRectIsNull(surface)) {
                    debugLog("the window's surface is %.0fx%.0f of %zux%zu; scaling it up as the screen does",
                             surface.size.width, surface.size.height, CGImageGetWidth(image), CGImageGetHeight(image));
                    cut = scaledUp(image, surface);
                    if (cut) image = cut;
                }
                CGImageRef part = NULL;
                if (!CGRectIsNull(region)) {
                    part = CGImageCreateWithImageInRect(image, region);
                    if (part) image = part;
                }
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
                if (cut) CGImageRelease(cut);
                if (part) CGImageRelease(part);
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

static NSString *captureCommand(NSString *path, NSDictionary<NSString *, NSString *> *options) {
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
        if (options[@"scale"]) {
            scale = options[@"scale"].doubleValue;
            if (scale <= 0 || scale > 4) return @"error scale is between 0 and 4";
        }
        CGRect region = CGRectNull;
        if (options[@"region"]) {
            NSArray<NSString *> *numbers = [options[@"region"] componentsSeparatedByString:@","];
            if (numbers.count != 4) return @"error region is <x>,<y>,<w>,<h>";
            region = CGRectIntegral(CGRectMake(numbers[0].doubleValue * scale, numbers[1].doubleValue * scale,
                                               numbers[2].doubleValue * scale, numbers[3].doubleValue * scale));
            if (CGRectIsEmpty(CGRectIntersection(region, CGRectMake(0, 0, size.width * scale, size.height * scale)))) {
                return @"error region is outside the window";
            }
        }
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
        startCapture(found, size, scale, region, request);
        if (dispatch_semaphore_wait(request->done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSecondCaptureAfterSeconds * NSEC_PER_SEC))) != 0) {
            debugLog("no answer to a capture after %.0fs; asking again alongside it", kSecondCaptureAfterSeconds);
            SCWindow *again = listGameWindow(windowID, &error);
            if (again) startCapture(again, size, scale, region, request);
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

static NSEvent *mouseEvent(NSEventType type, NSPoint point, NSWindow *window, NSInteger clickCount) {
    BOOL down = type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown || type == NSEventTypeLeftMouseDragged;
    NSEvent *event = [NSEvent mouseEventWithType:type
                                        location:point
                                   modifierFlags:0
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:window.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:clickCount
                                        pressure:down ? 1.0 : 0.0];
    // Marked as ours, for virtual_pointer.m. Of the event's fields, its
    // CGEvent's user data is the one -postEvent: keeps (it renumbers events).
    CGEventRef cgEvent = event.CGEvent;
    if (!cgEvent) return event;
    CGEventSetIntegerValueField(cgEvent, kCGEventSourceUserData, kPuppetEventTag);
    return [NSEvent eventWithCGEvent:cgEvent] ?: event;
}

/// Post a mouse event of `type` at a window point given with a top-left
/// origin. Wine ignores mouse events not tied to one of its windows, so each
/// must come out on the game window (as in cursor_lock.m). nil when posted.
static NSString *postMouseEvent(NSEventType type, double x, double y, NSInteger clickCount) {
    __block NSString *error = @"error no game window";
    onMainThread(^BOOL {
        NSWindow *window = gameWindow();
        if (!window) return NO;
        NSPoint point = NSMakePoint(x, window.frame.size.height - y);  // window coordinates are bottom-left
        NSEvent *event = mouseEvent(type, point, window, clickCount);
        if (event.window != window) {
            error = @"error the event would not land on the game window";
            return NO;
        }
        // Where it points, for virtual_pointer.m: global, from the top left.
        NSPoint screen = [window convertPointToScreen:point];
        CGFloat mainHeight = CGDisplayBounds(CGMainDisplayID()).size.height;
        virtualPointerNotePuppetMove(CGPointMake(screen.x, mainHeight - screen.y));
        [NSApp postEvent:event atStart:NO];
        error = nil;
        return YES;
    });
    return error;
}

static BOOL rightButton(NSDictionary<NSString *, NSString *> *options) {
    return [options[@"button"] isEqualToString:@"right"];
}

static useconds_t milliseconds(NSString *value, int otherwise) {
    int ms = value ? value.intValue : otherwise;
    return (useconds_t)MAX(0, MIN(ms, 10000)) * 1000;
}

/// A mouse move, and if `click`, then a pause for the game to see it and a
/// click held for kClickHoldMicroseconds (or `hold=`), `count=` times.
static NSString *mouseCommand(double x, double y, BOOL click, NSDictionary<NSString *, NSString *> *options) {
    NSString *error = postMouseEvent(NSEventTypeMouseMoved, x, y, 0);
    if (error || !click) return error ?: @"ok";
    usleep(kHoverBeforeClickMicroseconds);
    NSEventType down = rightButton(options) ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown;
    NSEventType up = rightButton(options) ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp;
    NSInteger count = MAX(1, MIN(options[@"count"] ? options[@"count"].integerValue : 1, 3));
    useconds_t hold = options[@"hold"] ? milliseconds(options[@"hold"], 0) : kClickHoldMicroseconds;
    for (NSInteger n = 1; n <= count; n++) {
        if ((error = postMouseEvent(down, x, y, n))) return error;
        usleep(hold);
        if ((error = postMouseEvent(up, x, y, n))) return error;
        if (n < count) usleep(kClickHoldMicroseconds);
    }
    return @"ok";
}

static NSString *pressCommand(double x, double y, BOOL press, NSDictionary<NSString *, NSString *> *options) {
    NSEventType type = rightButton(options) ? (press ? NSEventTypeRightMouseDown : NSEventTypeRightMouseUp)
                                            : (press ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp);
    return postMouseEvent(type, x, y, 1) ?: @"ok";
}

/// Press at the start, move along the line in `steps=` moves (default 10),
/// release at the end.
static NSString *dragCommand(double x1, double y1, double x2, double y2, NSDictionary<NSString *, NSString *> *options) {
    NSString *error = postMouseEvent(NSEventTypeMouseMoved, x1, y1, 0);
    if (error) return error;
    usleep(kHoverBeforeClickMicroseconds);
    if ((error = postMouseEvent(NSEventTypeLeftMouseDown, x1, y1, 1))) return error;
    usleep(milliseconds(options[@"hold"], 100));
    int steps = MAX(1, MIN(options[@"steps"] ? options[@"steps"].intValue : 10, 200));
    for (int step = 1; step <= steps; step++) {
        double x = x1 + (x2 - x1) * step / steps, y = y1 + (y2 - y1) * step / steps;
        if ((error = postMouseEvent(NSEventTypeLeftMouseDragged, x, y, 1))) return error;
        usleep(16 * 1000);
    }
    usleep(kClickHoldMicroseconds);
    return postMouseEvent(NSEventTypeLeftMouseUp, x2, y2, 1) ?: @"ok";
}

#pragma mark - Keys

/// A key's virtual keycode (US layout) and whether shift types it: a
/// character, or a name. -1 when it has none.
static int keyCodeFor(NSString *name, BOOL *shift) {
    static NSDictionary<NSString *, NSNumber *> *named, *plain;
    static NSString *shifted = @"~!@#$%^&*()_+{}|:\"<>?", *unshifted = @"`1234567890-=[]\\;',./";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{@"return": @36, @"enter": @36, @"tab": @48, @"space": @49, @"delete": @51, @"backspace": @51,
                  @"escape": @53, @"esc": @53, @"forwarddelete": @117, @"home": @115, @"end": @119,
                  @"pageup": @116, @"pagedown": @121, @"left": @123, @"right": @124, @"down": @125, @"up": @126,
                  @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97, @"f7": @98,
                  @"f8": @100, @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111};
        plain = @{@"a": @0, @"s": @1, @"d": @2, @"f": @3, @"h": @4, @"g": @5, @"z": @6, @"x": @7, @"c": @8,
                  @"v": @9, @"b": @11, @"q": @12, @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17,
                  @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"6": @22, @"5": @23, @"=": @24, @"9": @25,
                  @"7": @26, @"-": @27, @"8": @28, @"0": @29, @"]": @30, @"o": @31, @"u": @32, @"[": @33,
                  @"i": @34, @"p": @35, @"l": @37, @"j": @38, @"'": @39, @"k": @40, @";": @41, @"\\": @42,
                  @",": @43, @"/": @44, @"n": @45, @"m": @46, @".": @47, @"`": @50, @" ": @49};
    });
    *shift = NO;
    NSNumber *code = named[name.lowercaseString];
    if (code) return code.intValue;
    if (name.length != 1) return -1;
    if ((code = plain[name])) return code.intValue;
    if ((code = plain[name.lowercaseString])) {
        *shift = YES;
        return code.intValue;
    }
    NSRange at = [shifted rangeOfString:name];
    if (at.location != NSNotFound) {
        *shift = YES;
        return plain[[unshifted substringWithRange:at]].intValue;
    }
    return -1;
}

/// The characters a key types, for the event: Wine reads the keycode, but
/// AppKit wants characters on a key event.
static NSString *charactersFor(NSString *name, int code) {
    if (name.length == 1) return name;
    switch (code) {
        case 36: return @"\r";
        case 48: return @"\t";
        case 49: return @" ";
        case 51: return @"\x7f";
        case 53: return @"\x1b";
        default: return @"";
    }
}

/// Post a key's events on the game window: modifiers down (as flag changes,
/// which is how Wine learns of them), the key down, held, up, the modifiers up.
static NSString *postKey(int code, NSString *characters, NSEventModifierFlags flags, useconds_t hold) {
    static const struct { NSEventModifierFlags flag; unsigned short code; } modifiers[] = {
        {NSEventModifierFlagCommand, 55}, {NSEventModifierFlagShift, 56},
        {NSEventModifierFlagOption, 58}, {NSEventModifierFlagControl, 59},
    };
    __block NSString *error = @"error no game window";
    NSEvent *(^keyEvent)(NSEventType, NSEventModifierFlags, unsigned short, NSString *) =
        ^NSEvent *(NSEventType type, NSEventModifierFlags held, unsigned short keyCode, NSString *chars) {
            __block NSEvent *event = nil;
            onMainThread(^BOOL {
                NSWindow *window = gameWindow();
                if (!window) return NO;
                event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:held
                                        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                                          context:nil characters:chars charactersIgnoringModifiers:chars
                                        isARepeat:NO keyCode:keyCode];
                if (event) [NSApp postEvent:event atStart:NO];
                return event != nil;
            });
            return event;
        };
    NSEventModifierFlags held = 0;
    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (!(flags & modifiers[i].flag)) continue;
        held |= modifiers[i].flag;
        if (!keyEvent(NSEventTypeFlagsChanged, held, modifiers[i].code, @"")) return error;
    }
    if (!keyEvent(NSEventTypeKeyDown, held, (unsigned short)code, characters)) return error;
    usleep(hold);
    if (!keyEvent(NSEventTypeKeyUp, held, (unsigned short)code, characters)) return error;
    for (size_t i = sizeof(modifiers) / sizeof(modifiers[0]); i-- > 0;) {
        if (!(flags & modifiers[i].flag)) continue;
        held &= ~modifiers[i].flag;
        if (!keyEvent(NSEventTypeFlagsChanged, held, modifiers[i].code, @"")) return error;
    }
    return nil;
}

static NSString *keyCommand(NSString *spec, NSDictionary<NSString *, NSString *> *options) {
    // `+` alone is a key; otherwise the last part is the key and the rest its modifiers.
    NSArray<NSString *> *parts = [spec isEqualToString:@"+"] ? @[@"+"] : [spec componentsSeparatedByString:@"+"];
    NSEventModifierFlags flags = 0;
    for (NSString *modifier in [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]) {
        NSString *name = modifier.lowercaseString;
        if ([name isEqualToString:@"cmd"]) flags |= NSEventModifierFlagCommand;
        else if ([name isEqualToString:@"shift"]) flags |= NSEventModifierFlagShift;
        else if ([name isEqualToString:@"opt"] || [name isEqualToString:@"alt"]) flags |= NSEventModifierFlagOption;
        else if ([name isEqualToString:@"ctrl"]) flags |= NSEventModifierFlagControl;
        else return [@"error unknown modifier: " stringByAppendingString:modifier];
    }
    NSString *name = parts.lastObject;
    BOOL shift = NO;
    int code = keyCodeFor(name, &shift);
    if (code < 0) return [@"error unknown key: " stringByAppendingString:name];
    if (shift) flags |= NSEventModifierFlagShift;
    return postKey(code, charactersFor(name, code), flags, milliseconds(options[@"hold"], kKeyHoldMilliseconds)) ?: @"ok";
}

static NSString *typeCommand(NSString *encoded) {
    NSString *text = encoded.stringByRemovingPercentEncoding;
    if (!text) return @"error the text isn't percent-encoded";
    __block NSString *error = nil;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        BOOL shift = NO;
        int code = keyCodeFor([character isEqualToString:@"\n"] ? @"return" : character, &shift);
        if (code < 0) {
            error = [@"error no key types " stringByAppendingString:character];
            *stop = YES;
            return;
        }
        error = postKey(code, character, shift ? NSEventModifierFlagShift : 0, kKeyHoldMilliseconds * 1000);
        if (error) *stop = YES;
        usleep(kBetweenKeysMicroseconds);
    }];
    return error ?: @"ok";
}

#pragma mark - Windows

static NSString *windowsCommand(void) {
    __block NSString *reply = @"error timed out";
    onMainThread(^BOOL {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSWindow *game = gameWindow();
        for (NSWindow *window in NSApp.windows) {
            NSRect frame = window.frame;
            NSRect screen = window.screen ? window.screen.frame : NSScreen.screens.firstObject.frame;
            NSString *kind = window == game ? @"game" : [window isKindOfClass:NSPanel.class] ? @"panel" : @"other";
            NSString *title = [window.title stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
            [lines addObject:[NSString stringWithFormat:@"id=%ld frame=%.0f,%.0f,%.0f,%.0f level=%ld visible=%d key=%d main=%d kind=%@ title=%@",
                              (long)window.windowNumber, frame.origin.x, NSMaxY(screen) - NSMaxY(frame),
                              frame.size.width, frame.size.height, (long)window.level, window.isVisible,
                              window.isKeyWindow, window.isMainWindow, kind, title]];
        }
        reply = [[NSString stringWithFormat:@"ok %lu windows", (unsigned long)lines.count]
                 stringByAppendingString:lines.count ? [@"\n" stringByAppendingString:[lines componentsJoinedByString:@"\n"]] : @""];
        return YES;
    });
    return reply;
}

static NSString *focusCommand(void) {
    __block NSString *reply = @"error no game window";
    onMainThread(^BOOL {
        NSWindow *window = gameWindow();
        if (!window) return NO;
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        reply = @"ok";
        return YES;
    });
    return reply;
}

static NSString *helloCommand(void) {
    const char *exe = getprogname();
    return [NSString stringWithFormat:@"ok version=2 pid=%d exe=%s commands=hello,state,windows,capture,click,move,down,up,drag,key,type,focus,yield,quit",
            getpid(), exe ? exe : "?"];
}

/// Hand activation to the app with `pid`, so it can make itself active:
/// WrappPuppeteer switching away from the game, as Cmd-Tab would. Since
/// macOS 14 only the active app may hand it on; the game is. Whether AppKit
/// has the method is asked of AppKit, not @available, as for capturing
/// (`canListOwnWindows`): in ScummVM, linked against the 10.14 SDK,
/// @available said macOS 14 wasn't there on macOS 15.
static NSString *yieldCommand(pid_t pid) {
    if (![NSApplication instancesRespondToSelector:@selector(yieldActivationToApplication:)]) return @"error needs macOS 14";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    __block BOOL found = NO;
    BOOL ran = onMainThread(^BOOL {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app) return NO;
        [NSApp yieldActivationToApplication:app];
        found = YES;
        return YES;
    });
#pragma clang diagnostic pop
    if (!ran) return found ? @"error timed out" : @"error no such app";
    return @"ok";
}

/// Ask the app to quit as its Quit menu item does: Wine's is ⌘⌥Q, and
/// -[NSApplication terminate:] is its action. Not waited for: terminate runs
/// a loop of its own on the main thread until the app has agreed, which is
/// what a hang would be stuck in.
static NSString *quitCommand(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    return @"ok";
}

#pragma mark - Serving

/// The words before the first `name=value` option, and the options.
static NSArray<NSString *> *splitRequest(NSString *line, NSMutableDictionary<NSString *, NSString *> *options) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [line componentsSeparatedByString:@" "]) {
        if (word.length == 0) continue;
        NSRange equals = [word rangeOfString:@"="];
        BOOL option = words.count > 0 && equals.location != NSNotFound && equals.location > 0
            && [[word substringToIndex:equals.location] rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet.invertedSet].location == NSNotFound;
        if (option) {
            options[[word substringToIndex:equals.location]] = [word substringFromIndex:equals.location + 1];
        } else if (options.count == 0) {
            [words addObject:word];
        }
    }
    return words;
}

static NSString *handle(NSString *line) {
    NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
    NSArray<NSString *> *parts = splitRequest(line, options);
    NSString *command = parts.firstObject;
    NSUInteger count = parts.count;
    if ([command isEqualToString:@"hello"] && count == 1) return helloCommand();
    if ([command isEqualToString:@"state"] && count == 1) return stateCommand();
    if ([command isEqualToString:@"windows"] && count == 1) return windowsCommand();
    if ([command isEqualToString:@"capture"] && count == 2) return captureCommand(parts[1], options);
    if (([command isEqualToString:@"click"] || [command isEqualToString:@"move"]) && count == 3) {
        return mouseCommand(parts[1].doubleValue, parts[2].doubleValue, [command isEqualToString:@"click"], options);
    }
    if (([command isEqualToString:@"down"] || [command isEqualToString:@"up"]) && count == 3) {
        return pressCommand(parts[1].doubleValue, parts[2].doubleValue, [command isEqualToString:@"down"], options);
    }
    if ([command isEqualToString:@"drag"] && count == 5) {
        return dragCommand(parts[1].doubleValue, parts[2].doubleValue, parts[3].doubleValue, parts[4].doubleValue, options);
    }
    if ([command isEqualToString:@"key"] && count == 2) return keyCommand(parts[1], options);
    if ([command isEqualToString:@"type"] && count == 2) return typeCommand(parts[1]);
    if ([command isEqualToString:@"focus"] && count == 1) return focusCommand();
    if ([command isEqualToString:@"yield"] && count == 2) return yieldCommand((pid_t)parts[1].intValue);
    if ([command isEqualToString:@"quit"] && count == 1) return quitCommand();
    return [@"error unknown request: " stringByAppendingString:line];
}

/// Answer one connection's request, then close it.
static void *answer(void *arg) {
    int client = (int)(intptr_t)arg;
    char buffer[4096] = {0};
    ssize_t length = read(client, buffer, sizeof(buffer) - 1);
    if (length > 0) {
        @autoreleasepool {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *reply = line ? handle(line) : @"error request is not UTF-8";
            debugLog("%s -> %s", line.UTF8String ?: "?", [reply componentsSeparatedByString:@"\n"].firstObject.UTF8String);
            const char *bytes = [reply stringByAppendingString:@"\n"].UTF8String;
            size_t total = strlen(bytes), sent = 0;
            while (sent < total) {
                ssize_t n = write(client, bytes + sent, total - sent);
                if (n <= 0) break;
                sent += (size_t)n;
            }
        }
    }
    close(client);
    return NULL;
}

static void *serve(void *arg) {
    char *path = arg;
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    unlink(path);
    if (server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 16) != 0) {
        debugLog("cannot listen on %s: %s", path, strerror(errno));
        helperReport("PuppetControl", "error", "cannot listen on %s: %s", path, strerror(errno));
        return NULL;
    }
    debugLog("listening on %s", path);
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        pthread_t thread;
        if (pthread_create(&thread, NULL, answer, (void *)(intptr_t)client) == 0) {
            pthread_detach(thread);
        } else {
            close(client);
        }
    }
    return NULL;
}

__attribute__((constructor))
static void puppetControlInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "PuppetControl");
    const char *directory = getenv("SECOND_CHANCE_PUPPET_DIR");
    const char *exe = getenv("PUPPET_CONTROL_EXE");
    BOOL everywhere = exe && strcmp(exe, "*") == 0;
    if (!directory || !*directory || !(everywhere || processRunsExeNamedBy("PUPPET_CONTROL_EXE"))) return;

    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    // One socket per process: a game that runs as two, as Armadillo's do, has
    // the helper in both, and WrappPuppeteer talks to the one with the window.
    // A shared path went to whichever started last, often the windowless one.
    if (snprintf(path, sizeof(path), "%s/game-%d.sock", directory, getpid()) >= (int)sizeof(path)) {
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
