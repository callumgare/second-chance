//
//  basilisk_mac.m
//  What the wrapp needs of Basilisk II's own process, the emulated classic
//  Mac's window (docs/modules.md#the-basilisk-modules-mac).
//
//  Armed by BASILISK_MAC_EXE (set by the wrapp's BasiliskRuntime on every
//  launch), in the process running the executable it names:
//
//  - **Its picture.** Basilisk II presents a frame only when the Mac's screen
//    changes, and macOS drops what a window presents while it counts the
//    window as occluded, which it does from the start for a window on a
//    screen nobody is watching (a test user's background login, where the
//    window counted as occluded though it was frontmost and on screen). So
//    the Mac boots to the Finder behind a stale "Welcome to Macintosh" until
//    something both marks the window visible and makes Basilisk present
//    again. A picture of the window taken in-process (ScreenCaptureKit, as
//    puppet control's `capture`, needing no permission) marks it visible;
//    then an SDL "exposed" event, which Basilisk II answers with a full
//    redraw, puts the Mac's current screen in it. The exposed event goes
//    again whenever the window becomes visible or changes size. In such a
//    login, what the window presents later still reaches the screen only
//    when it's pictured, so it's pictured twice a second while Basilisk II
//    runs; on the Mac's own screen it isn't.
//  - **The Mac's first pointer position.** The Finder doesn't draw its
//    desktop until the Mac has one, which it gets only when the pointer
//    moves over the window. So it's given one as an SDL event, where the
//    person's pointer is if it's over the window, else in the middle; never
//    once the person has moved the pointer there, and the person's pointer
//    itself is never moved.
//  - **Shutting the Mac down.** SIGUSR2 (the wrapp's, when it quits) raises
//    the Mac's power key, as Basilisk II does for SIGTERM, then presses
//    Return, Shut Down being the dialog's default, until the Mac has shut
//    down and Basilisk II exits: its disk is left clean, the person's files
//    on it safe. The wrapp ends it only if this hasn't in its time.

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>
#import "helper_common.h"

static const char *kHelper = "BasiliskMac";

/// Basilisk II's window: its one titled, visible window.
static NSWindow *macWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if (window.visible && (window.styleMask & NSWindowStyleMaskTitled)) return window;
    }
    return nil;
}

static BOOL countsAsVisible(NSWindow *window) {
    return (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

#pragma mark - Its picture

/// SDL2's SDL_WindowEvent, as it is laid out in the 56-byte SDL_Event union.
typedef struct {
    uint32_t type;       // SDL_WINDOWEVENT, 0x200
    uint32_t timestamp;
    uint32_t windowID;
    uint8_t event;       // SDL_WINDOWEVENT_EXPOSED, 3
    uint8_t padding[3];
    int32_t data1;
    int32_t data2;
    uint8_t rest[56 - 24];
} SDLWindowEvent;

/// Have Basilisk II redraw the whole Mac screen: an SDL "exposed" event,
/// which its event loop answers with force_complete_window_refresh(). SDL2
/// is Basilisk II's, found when needed, as this dylib goes into other
/// programs too.
static void redrawAll(const char *why) {
    typedef int (*PushEvent)(void *);
    static PushEvent push;
    if (!push) push = (PushEvent)dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    if (!push) {
        helperReport(kHelper, "warning", "can't redraw the Mac's screen: no SDL_PushEvent");
        return;
    }
    SDLWindowEvent event = { .type = 0x200, .windowID = 1, .event = 3 };
    if (push(&event) < 0) helperReport(kHelper, "warning", "can't redraw the Mac's screen: SDL_PushEvent failed");
    else helperReport(kHelper, "notice", "redrawing the Mac's screen (%s)", why);
}

/// Whether the person (or puppet control) has moved the pointer over the
/// window: then the Mac has its pointer, and nothing more is given it.
static BOOL pointerMoved = NO;

/// SDL2's SDL_MouseMotionEvent, as laid out in the 56-byte SDL_Event union.
typedef struct {
    uint32_t type;       // SDL_MOUSEMOTION, 0x400
    uint32_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t state;
    int32_t x, y, xrel, yrel;
    uint8_t rest[56 - 36];
} SDLMouseMotionEvent;

/// The Mac's first pointer position: the Mac waits for one before the
/// Finder draws its desktop, and gets none until the pointer moves over the
/// window. Given to Basilisk II as an SDL event, so the Mac's pointer goes
/// where the person's is if it's over the window, else to the middle of the
/// screen, and the person's pointer is never moved.
static void givePointer(NSWindow *window) {
    if (pointerMoved) return;
    typedef int (*PushEvent)(void *);
    typedef uint32_t (*GetMouseState)(int *, int *);
    typedef void *(*GetMouseFocus)(void);
    PushEvent push = (PushEvent)dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    GetMouseState mouseState = (GetMouseState)dlsym(RTLD_DEFAULT, "SDL_GetMouseState");
    GetMouseFocus mouseFocus = (GetMouseFocus)dlsym(RTLD_DEFAULT, "SDL_GetMouseFocus");
    if (!push) return;
    NSSize content = window.contentView.frame.size;
    int x = (int)(content.width / 2), y = (int)(content.height / 2);
    if (mouseState && mouseFocus && mouseFocus()) mouseState(&x, &y);
    SDLMouseMotionEvent event = { .type = 0x400, .windowID = 1, .x = x, .y = y };
    if (push(&event) >= 0) helperReport(kHelper, "notice", "gave the Mac its pointer at %d,%d", x, y);
}

/// Whether ScreenCaptureKit can picture this process's own windows (macOS
/// 14.4), asked of it rather than with @available, as puppet_control.m does.
static BOOL canPictureOwnWindows(void) {
    Class content = NSClassFromString(@"SCShareableContent");
    return [content respondsToSelector:@selector(getCurrentProcessShareableContentWithCompletionHandler:)];
}

/// Whether a picture has failed yet: said once, not twice a second.
static BOOL pictureFailed = NO;

/// A small picture of the window, taken only for macOS to count the window
/// as visible and put what it presented on the screen; the picture itself is
/// thrown away.
static void pictureWindow(CGWindowID windowID) {
    if (!canPictureOwnWindows()) {
        helperReport(kHelper, "warning", "the Mac's window counts as hidden, and this macOS can't picture it to show it");
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        SCWindow *found = nil;
        for (SCWindow *window in content.windows) {
            if (window.windowID == windowID) found = window;
        }
        if (!found) {
            if (!pictureFailed) helperReport(kHelper, "warning", "the Mac's window isn't among this process's windows (%s)",
                                             error.localizedDescription.UTF8String ?: "no error");
            pictureFailed = YES;
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:found];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = 64;
        config.height = 48;
        config.showsCursor = NO;
        [SCScreenshotManager captureImageWithFilter:filter configuration:config
                                  completionHandler:^(CGImageRef image, NSError *captureError) {
            if (!image && !pictureFailed) {
                pictureFailed = YES;
                helperReport(kHelper, "warning", "picturing the Mac's window failed: %s",
                             captureError.localizedDescription.UTF8String ?: "no error");
            }
        }];
    }];
#pragma clang diagnostic pop
}

/// Whether this login is the one on the Mac's screen (not a background one,
/// as a test user's is).
static BOOL sessionOnConsole(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return YES;
    CFBooleanRef onConsole = CFDictionaryGetValue(session, kCGSessionOnConsoleKey);
    BOOL result = !onConsole || CFBooleanGetValue(onConsole);
    CFRelease(session);
    return result;
}

/// In a login that isn't on the Mac's screen, what the window presents
/// reaches the screen only when something takes a picture of it, so one is
/// taken twice a second for as long as Basilisk II runs.
static void keepPicturing(NSWindow *window) {
    static dispatch_source_t timer;
    if (timer) return;
    helperReport(kHelper, "notice", "this login isn't on the Mac's screen: picturing the Mac's window twice a second to keep it drawn");
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    CGWindowID windowID = (CGWindowID)window.windowNumber;
    dispatch_source_set_event_handler(timer, ^{ pictureWindow(windowID); });
    dispatch_resume(timer);
}

/// Until macOS counts the window as visible: a picture of it now and then (a
/// few tries, a while apart), the exposed event following from the change.
static void showWindow(NSWindow *window, int tries) {
    if (countsAsVisible(window)) return;
    if (tries == 0) helperReport(kHelper, "notice", "the Mac's window counts as hidden: picturing it to show it");
    if (tries >= 6) {
        helperReport(kHelper, "warning", "the Mac's window still counts as hidden after %d pictures", tries);
        return;
    }
    pictureWindow((CGWindowID)window.windowNumber);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 + tries) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showWindow(window, tries + 1);
    });
}

/// Until the window shows (a minute at most), then: shown if it counts as
/// hidden, and redrawn whenever it becomes visible or changes size.
static void watchForWindow(int tries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp ? macWindow() : nil;
        if (!window) {
            if (tries < 240) watchForWindow(tries + 1);
            else helperReport(kHelper, "warning", "no window to show after a minute");
            return;
        }
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:NSWindowDidChangeOcclusionStateNotification object:window queue:nil
                        usingBlock:^(NSNotification *note) {
            helperReport(kHelper, "notice", "the Mac's window counts as %s", countsAsVisible(window) ? "visible" : "hidden");
            // What it presented while hidden was dropped.
            if (countsAsVisible(window)) redrawAll("the window became visible");
        }];
        [center addObserverForName:NSWindowDidResizeNotification object:window queue:nil
                        usingBlock:^(NSNotification *note) { redrawAll("the window changed size"); }];
        // The person's own pointer over the window: the Mac has it from them.
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
            if (event.window == window) pointerMoved = YES;
            return event;
        }];
        showWindow(window, 0);
        givePointer(window);
        if (!sessionOnConsole()) keepPicturing(window);
    });
}

#pragma mark - Shutting the Mac down

/// Return, pressed and let go, to the window.
static void pressReturn(NSWindow *window) {
    NSEventType types[2] = { NSEventTypeKeyDown, NSEventTypeKeyUp };
    for (int i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:types[i] location:NSZeroPoint modifierFlags:0
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:window.windowNumber context:nil characters:@"\r"
                       charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        if (event) [NSApp postEvent:event atStart:NO];
    }
}

/// SIGUSR2: shut the Mac down, as its power key and Return would.
static void startShutDown(void) {
    helperReport(kHelper, "notice", "shutting the Mac down");
    // Basilisk II turns SIGTERM into the Mac's power key, which asks "shut
    // down now?" with Shut Down as its default.
    kill(getpid(), SIGTERM);
    // Return once the dialog may be up, again every two seconds, while the
    // process lasts; the wrapp ends it if the Mac never shuts down.
    for (int i = 0; i < 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 + 2 * i) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSWindow *window = macWindow();
            if (window) pressReturn(window);
        });
    }
}

__attribute__((constructor))
static void armBasiliskMac(void) {
    if (!processRunsExeNamedBy("BASILISK_MAC_EXE")) return;
    signal(SIGUSR2, SIG_IGN);
    static dispatch_source_t shutDown;
    shutDown = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(shutDown, ^{ startShutDown(); });
    dispatch_resume(shutDown);
    dispatch_async(dispatch_get_main_queue(), ^{ watchForWindow(0); });
    helperReport(kHelper, "notice", "armed in %s", getenv("BASILISK_MAC_EXE"));
}
