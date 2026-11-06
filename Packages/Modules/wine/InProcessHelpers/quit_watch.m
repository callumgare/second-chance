//
//  quit_watch.m
//  Tells the wrapp what it needs to judge whether the game's exit was a quit
//  or a failure: when the game first put a frame on screen, and whether
//  anything asked the game's process to quit.
//
//  A game that can't run often just quits, exit code 0, with nothing on
//  screen -- The White Wolf of Icicle Creek did when the display had no mode
//  it could switch to -- which from outside looks exactly like a player
//  quitting. The wrapp reads these two lines from the game's output
//  (GameQuitCheck.swift) and reports such an exit as a failure.
//
//  - The first frame. Wine's Mac driver draws Direct3D through an OpenGL
//    context, and a frame reaches the screen only when the game presents one:
//    wglSwapBuffers ends in -[WineOpenGLContext flushBuffer]. Wine's own
//    painting of a new window goes through the window's surface image
//    instead, so the first flushBuffer is the game's. cnc-ddraw presents from
//    a timer whether the game has drawn or not, so the wrapp only reads this
//    line for a Direct3D game.
//  - A quit request. ⌘Q in the game, Quit from its Dock menu, and logging out
//    all reach the game's process as -[WineApplicationController
//    applicationShouldTerminate:], which Wine passes on to the game's windows.
//    The wrapp can't see those, as they go to the game's process, not to it.
//
//  With QUIT_KEY set (a launch's --wine.quit-key), a quit request holds that
//  key down in the game's window for kQuitKeyHoldSeconds instead, and the
//  quit itself is cancelled: for a game that ignores Wine's quit, its window
//  closing and Alt+F4, but quits on a key held down, as Iji does on F12.
//
//  Armed by QUIT_WATCH_EXE, in the process running that .exe.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <stdatomic.h>

#include "helper_common.h"

// MARK: - WineOpenGLContext

static IMP gWineFlushBuffer;
static atomic_bool gFrameReported;

// `id`, not `NSOpenGLContext *`: the class is deprecated, and only its
// method is called, through the original IMP.
static void reportingFlushBuffer(id self, SEL _cmd) {
    ((void (*)(id, SEL))gWineFlushBuffer)(self, _cmd);
    if (!atomic_exchange(&gFrameReported, true)) {
        helperReport("QuitWatch", "notice", "first frame on screen");
    }
}

// MARK: - WineApplicationController

static IMP gWineShouldTerminate;

/// How long the quit key is held: long enough for a game that wants it held
/// (Iji quits on F12 held for about a second).
static const double kQuitKeyHoldSeconds = 3;

/// A quit key's virtual keycode (US layout); -1 for a name it doesn't know.
static int quitKeyCode(const char *name) {
    static const struct { const char *name; int code; } keys[] = {
        {"f1", 122}, {"f2", 120}, {"f3", 99}, {"f4", 118}, {"f5", 96}, {"f6", 97}, {"f7", 98},
        {"f8", 100}, {"f9", 101}, {"f10", 109}, {"f11", 103}, {"f12", 111},
        {"escape", 53}, {"return", 36}, {"q", 12}, {"x", 7},
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strcasecmp(name, keys[i].name) == 0) return keys[i].code;
    }
    return -1;
}

/// The game's window: the biggest visible one of Wine's.
static NSWindow *gameWindowForKeys(void) {
    Class wineWindow = NSClassFromString(@"WineWindow");
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || (wineWindow && ![window isKindOfClass:wineWindow])) continue;
        CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            best = window;
            bestArea = area;
        }
    }
    return best;
}

static void postQuitKey(NSEventType type, unsigned short code, NSInteger windowNumber) {
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber
                                       context:nil characters:@"" charactersIgnoringModifiers:@""
                                     isARepeat:NO keyCode:code];
    if (event) [NSApp postEvent:event atStart:NO];
}

/// Hold the launch's quit key in the game's window, on the main thread,
/// where applicationShouldTerminate: is called: down now, up later, so the
/// run loop goes on delivering events meanwhile. NO when there is no key or
/// no window to hold it in.
static BOOL holdQuitKey(void) {
    const char *name = getenv("QUIT_KEY");
    if (!name || !*name) return NO;
    int code = quitKeyCode(name);
    NSWindow *window = gameWindowForKeys();
    if (code < 0 || !window) {
        helperReport("QuitWatch", "warning", code < 0 ? "quit key %s isn't one it knows; quitting as Wine does"
                                                      : "no game window to hold the quit key %s in; quitting as Wine does", name);
        return NO;
    }
    NSInteger windowNumber = window.windowNumber;
    [window makeKeyAndOrderFront:nil];
    postQuitKey(NSEventTypeKeyDown, (unsigned short)code, windowNumber);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuitKeyHoldSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        postQuitKey(NSEventTypeKeyUp, (unsigned short)code, windowNumber);
    });
    helperReport("QuitWatch", "notice", "holding %s for %.0f s, the game's own quit, rather than quitting", name, kQuitKeyHoldSeconds);
    return YES;
}

static NSApplicationTerminateReply reportingShouldTerminate(id self, SEL _cmd, NSApplication *sender) {
    helperReport("QuitWatch", "notice", "quit requested");
    if (holdQuitKey()) return NSTerminateCancel;
    return ((NSApplicationTerminateReply (*)(id, SEL, NSApplication *))gWineShouldTerminate)(self, _cmd, sender);
}

__attribute__((constructor))
static void quitWatchInit(void) {
    if (!processRunsExeNamedBy("QUIT_WATCH_EXE")) return;

    Method flush = class_getInstanceMethod(NSClassFromString(@"WineOpenGLContext"), @selector(flushBuffer));
    Method terminate = class_getInstanceMethod(NSClassFromString(@"WineApplicationController"),
                                               @selector(applicationShouldTerminate:));
    if (!flush || !terminate) {
        helperReport("QuitWatch", "warning", "no -[WineOpenGLContext flushBuffer] or -[WineApplicationController applicationShouldTerminate:]; a game that quits before drawing anything isn't reported");
        return;
    }
    gWineFlushBuffer = replaceOwnMethod(NSClassFromString(@"WineOpenGLContext"), @selector(flushBuffer), (IMP)reportingFlushBuffer);
    gWineShouldTerminate = replaceOwnMethod(NSClassFromString(@"WineApplicationController"),
                                            @selector(applicationShouldTerminate:), (IMP)reportingShouldTerminate);
    helperReport("QuitWatch", "notice", "armed in %s", getenv("QUIT_WATCH_EXE"));
}
