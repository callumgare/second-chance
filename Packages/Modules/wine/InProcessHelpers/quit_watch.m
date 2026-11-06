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
//  With QUIT_KEY set (a launch's --wine.quit-key), a quit request presses
//  those keys in the game's window instead, and the quit itself is
//  cancelled: for a game that ignores Wine's quit, its window closing and
//  Alt+F4, but quits on a key of its own, as Iji does on F12 held down. The
//  keys come in a key sequence's canonical form (helperKeySteps,
//  key_names.m), which the wrapp makes from the launch's own (KeySequence),
//  and are done exactly as it says: presses in turn, each `wait=` from one's
//  release to the next's press (the quit keys' usual 2.5 s spelled out by
//  the wrapp, RecordedLaunch.quitKeyGapMilliseconds, unless the keys say
//  otherwise), and `:hold=` held that long, repeating as a held Mac key
//  does, so a game that takes repeats as presses steps through its own
//  menus, as a player holding the key would. With QUIT_CONFIRM_KEY, a first quit presses the quit keys
//  (Icy Tower's Escape asks the player) and a second one soon after the
//  confirm keys (Icy Tower's Escape held).
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

/// A held key repeats as a Mac keyboard's does by default: the first repeat
/// after this long, then one each kQuitKeyRepeatSeconds. A posted key down
/// doesn't repeat by itself, and a game that reads key presses rather than
/// key state sees a posted hold as one press.
static const double kQuitKeyRepeatDelaySeconds = 0.25;
static const double kQuitKeyRepeatSeconds = 0.05;

/// How long a pressed quit key is down: long enough for a game that polls
/// its keyboard each frame to see the press. The time from its release to
/// the next press is the keys' own `wait=`.
static const double kQuitKeyPressSeconds = 0.15;

/// How soon after the quit keys a second quit presses the confirm keys
/// (QUIT_CONFIRM_KEY) rather than the quit keys again.
static const double kQuitConfirmSeconds = 10;

/// When the quit keys were last pressed for a launch with confirm keys, in
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

static void afterSeconds(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

/// A key's event in the game's window, with the modifiers held and the
/// characters it types (key_names.m).
static void postQuitKey(NSEventType type, HelperKeyStep step, NSEventModifierFlags held, NSInteger windowNumber, BOOL repeat) {
    NSString *characters = type == NSEventTypeFlagsChanged ? @"" : helperKeyCharacters(@(step.name), step.code);
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:held
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:windowNumber
                                       context:nil characters:characters charactersIgnoringModifiers:characters
                                     isARepeat:repeat keyCode:step.code];
    if (event) [NSApp postEvent:event atStart:NO];
}

/// A step's modifiers down, in order (as flag changes, which is how Wine
/// learns of them), or up in reverse.
static void postQuitModifiers(HelperKeyStep step, BOOL down, NSInteger windowNumber) {
    NSEventModifierFlags held = down ? 0 : step.flags;
    for (int n = 0; n < 4; n++) {
        HelperModifierKey modifier = helperModifierKeys[down ? n : 3 - n];
        if (!(step.flags & modifier.flag)) continue;
        held = down ? (held | modifier.flag) : (held & ~modifier.flag);
        HelperKeyStep flagStep = step;
        flagStep.code = modifier.code;
        postQuitKey(NSEventTypeFlagsChanged, flagStep, held, windowNumber, NO);
    }
}

/// Do the steps from `index` on: each down now, its up later, and the next
/// press its `wait=` after the up,
/// each from a timer on the main queue, so the run loop goes on delivering
/// events meanwhile. A held step repeats as a held Mac key does. Each up is
/// timed from when its down was posted, not from the start: the main thread
/// can be held up for seconds (Icy Tower's menu, back from a game), and a
/// down and up let out together are a press a game polling its keyboard
/// never sees.
static void runQuitSteps(NSData *steps, NSUInteger index, NSInteger windowNumber) {
    NSUInteger count = steps.length / sizeof(HelperKeyStep);
    if (index >= count) return;
    HelperKeyStep step = ((const HelperKeyStep *)steps.bytes)[index];
    BOOL held = step.holdMilliseconds > 0;
    double seconds = held ? step.holdMilliseconds / 1000.0 : kQuitKeyPressSeconds;
    postQuitModifiers(step, YES, windowNumber);
    postQuitKey(NSEventTypeKeyDown, step, step.flags, windowNumber, NO);
    if (held) {
        for (double at = kQuitKeyRepeatDelaySeconds; at < seconds; at += kQuitKeyRepeatSeconds) {
            afterSeconds(at, ^{ postQuitKey(NSEventTypeKeyDown, step, step.flags, windowNumber, YES); });
        }
    }
    afterSeconds(seconds, ^{
        postQuitKey(NSEventTypeKeyUp, step, step.flags, windowNumber, NO);
        postQuitModifiers(step, NO, windowNumber);
        if (index + 1 >= count) return;
        HelperKeyStep next = ((const HelperKeyStep *)steps.bytes)[index + 1];
        afterSeconds(next.waitMilliseconds / 1000.0, ^{ runQuitSteps(steps, index + 1, windowNumber); });
    });
}

/// A launch's quit keys in canonical form (helperKeySteps); nil when there
/// are none, or when they can't be read (reported): the wrapp hands over
/// only keys KeySequence has checked.
static NSData *quitKeySteps(const char *variable) {
    const char *value = getenv(variable);
    if (!value || !*value) return nil;
    NSString *error = nil;
    NSData *steps = helperKeySteps(@(value), &error);
    if (!steps) helperReport("QuitWatch", "warning", "%s isn't keys it can press (%s); quitting as Wine does", variable, error.UTF8String);
    return steps;
}

/// Do a launch's quit steps in the game's window, on the main thread,
/// where applicationShouldTerminate: is called. NO when there's no window
/// to press them in.
static BOOL pressQuitKeys(NSData *steps, const char *variable) {
    NSWindow *window = gameWindowForKeys();
    const char *keys = getenv(variable);
    if (!window) {
        helperReport("QuitWatch", "warning", "no game window to press the quit keys %s in; quitting as Wine does", keys);
        return NO;
    }
    [window makeKeyAndOrderFront:nil];
    runQuitSteps(steps, 0, window.windowNumber);
    helperReport("QuitWatch", "notice", "pressing %s, the game's own quit, rather than quitting", keys);
    return YES;
}

/// A quit request, for a launch with quit keys: press them, and say whether
/// that's what happened (else the quit goes to Wine). With confirm keys too,
/// a first request presses the quit keys, which in a game like Icy Tower
/// bring up its own question, and one within kQuitConfirmSeconds of it
/// presses the confirm keys, which see the quit through.
static BOOL quitThroughKeys(void) {
    NSData *quit = quitKeySteps("QUIT_KEY");
    if (!quit) return NO;
    NSData *confirm = quitKeySteps("QUIT_CONFIRM_KEY");
    if (!confirm) return pressQuitKeys(quit, "QUIT_KEY");
    double now = NSProcessInfo.processInfo.systemUptime;
    if (gQuitKeyPressedAt > 0 && now - gQuitKeyPressedAt <= kQuitConfirmSeconds) {
        gQuitKeyPressedAt = 0;
        return pressQuitKeys(confirm, "QUIT_CONFIRM_KEY");
    }
    if (!pressQuitKeys(quit, "QUIT_KEY")) return NO;
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
    if (quitKeySteps("QUIT_KEY") && self == gameWindowForKeys()) {
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
