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
//  Several keys, separated by spaces, are pressed in turn instead,
//  kQuitKeyGapSeconds apart: for a game that quits through its own menus, as
//  Icy Tower does on Escape pressed four times from a game.
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

/// How long each of several quit keys is down, and how long from one to the
/// next: long enough for a game that polls its keyboard each frame to see
/// the press, and to have changed screens before the next. Icy Tower's menu,
/// back from a game, takes over 1.2 s to read keys again; 2.5 s does.
static const double kQuitKeyPressSeconds = 0.15;
static const double kQuitKeyGapSeconds = 2.5;

/// How soon after the quit key a second quit presses the confirm keys
/// (QUIT_CONFIRM_KEY) rather than the quit key again.
static const double kQuitConfirmSeconds = 10;

/// When the quit key was last pressed for a launch with confirm keys, in
/// system uptime; 0 when a quit since has pressed them. Main thread only.
static double gQuitKeyPressedAt;

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

/// A key's down or up in the game's window, with the characters it types
/// (key_names.m).
static void postQuitKey(NSEventType type, NSString *name, unsigned short code, NSInteger windowNumber) {
    NSString *characters = helperKeyCharacters(name, code);
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber
                                       context:nil characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:NO keyCode:code];
    if (event) [NSApp postEvent:event atStart:NO];
}

/// The names in a launch's quit keys, space-separated; empty when there are
/// none, or when one isn't a key it can press (reported): a name key_names.m
/// doesn't know, or a character that needs shift, which it doesn't hold.
static NSArray<NSString *> *quitKeyNames(const char *variable) {
    const char *value = getenv(variable);
    if (!value || !*value) return @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *name in [@(value) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (name.length == 0) continue;
        BOOL shift = NO;
        if (helperKeyCode(name, &shift) < 0 || shift) {
            helperReport("QuitWatch", "warning", "quit key %s isn't one it can press; quitting as Wine does", name.UTF8String);
            return @[];
        }
        [names addObject:name];
    }
    return names;
}

/// Press keys in turn in the game's window, or with `holdOne`, hold a single
/// key down (Iji's F12), on the main thread, where applicationShouldTerminate:
/// is called: each down now or later and up later still, so the run loop
/// goes on delivering events meanwhile. NO when there's no window to press
/// them in.
static BOOL pressQuitKeys(NSArray<NSString *> *names, BOOL holdOne) {
    NSWindow *window = gameWindowForKeys();
    NSString *keys = [names componentsJoinedByString:@" "];
    if (!window) {
        helperReport("QuitWatch", "warning", "no game window to press the quit key %s in; quitting as Wine does", keys.UTF8String);
        return NO;
    }
    NSInteger windowNumber = window.windowNumber;
    [window makeKeyAndOrderFront:nil];
    BOOL shift = NO;
    if (names.count == 1 && holdOne) {
        NSString *name = names[0];
        unsigned short code = (unsigned short)helperKeyCode(name, &shift);
        postQuitKey(NSEventTypeKeyDown, name, code, windowNumber);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuitKeyHoldSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            postQuitKey(NSEventTypeKeyUp, name, code, windowNumber);
        });
        helperReport("QuitWatch", "notice", "holding %s for %.0f s, the game's own quit, rather than quitting", keys.UTF8String, kQuitKeyHoldSeconds);
        return YES;
    }
    [names enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        BOOL unused = NO;
        unsigned short code = (unsigned short)helperKeyCode(name, &unused);
        double down = index * kQuitKeyGapSeconds;
        // The up is timed from when the down was posted, not from now: the
        // main thread can be held up for seconds (Icy Tower's menu, back
        // from a game), and a down and up let out together are a press a
        // game polling its keyboard never sees.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(down * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            postQuitKey(NSEventTypeKeyDown, name, code, windowNumber);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuitKeyPressSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                postQuitKey(NSEventTypeKeyUp, name, code, windowNumber);
            });
        });
    }];
    helperReport("QuitWatch", "notice", "pressing %s in turn, the game's own quit, rather than quitting", keys.UTF8String);
    return YES;
}

/// A quit request, for a launch with quit keys: press them, and say whether
/// that's what happened (else the quit goes to Wine). With confirm keys too,
/// a first request presses the quit key alone, which in a game like Icy
/// Tower brings up its own question, and one within kQuitConfirmSeconds of it
/// presses the confirm keys, which see the quit through.
static BOOL quitThroughKeys(void) {
    NSArray<NSString *> *quit = quitKeyNames("QUIT_KEY");
    if (quit.count == 0) return NO;
    NSArray<NSString *> *confirm = quitKeyNames("QUIT_CONFIRM_KEY");
    if (confirm.count == 0) return pressQuitKeys(quit, YES);
    double now = NSProcessInfo.processInfo.systemUptime;
    if (gQuitKeyPressedAt > 0 && now - gQuitKeyPressedAt <= kQuitConfirmSeconds) {
        gQuitKeyPressedAt = 0;
        return pressQuitKeys(confirm, NO);
    }
    if (!pressQuitKeys(quit, NO)) return NO;
    gQuitKeyPressedAt = now;
    helperReport("QuitWatch", "notice", "a quit within %.0f s presses the confirm keys", kQuitConfirmSeconds);
    return YES;
}

static NSApplicationTerminateReply reportingShouldTerminate(id self, SEL _cmd, NSApplication *sender) {
    helperReport("QuitWatch", "notice", "quit requested");
    if (quitThroughKeys()) return NSTerminateCancel;
    return ((NSApplicationTerminateReply (*)(id, SEL, NSApplication *))gWineShouldTerminate)(self, _cmd, sender);
}

// MARK: - WineWindow

static IMP gWineWindowShouldClose;

/// The game's window's close button, for a launch with quit keys: a quit,
/// as ⌘Q is. Wine would pass it on to the game as its window closing
/// (SC_CLOSE), which games that need quit keys ignore. Any other window, or
/// a launch without quit keys, closes as Wine does.
static BOOL quitKeysShouldClose(id self, SEL _cmd, id sender) {
    if (quitKeyNames("QUIT_KEY").count > 0 && self == gameWindowForKeys()) {
        helperReport("QuitWatch", "notice", "quit requested (window closed)");
        if (quitThroughKeys()) return NO;
    }
    return ((BOOL (*)(id, SEL, id))gWineWindowShouldClose)(self, _cmd, sender);
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
    if (getenv("QUIT_KEY") && *getenv("QUIT_KEY")) {
        gWineWindowShouldClose = replaceOwnMethod(NSClassFromString(@"WineWindow"), @selector(windowShouldClose:),
                                                  (IMP)quitKeysShouldClose);
        if (!gWineWindowShouldClose) {
            helperReport("QuitWatch", "warning", "no -[WineWindow windowShouldClose:]; the game's close button closes its window as Wine does");
        }
    }
    helperReport("QuitWatch", "notice", "armed in %s", getenv("QUIT_WATCH_EXE"));
}
