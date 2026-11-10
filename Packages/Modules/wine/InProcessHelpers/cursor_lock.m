//
//  cursor_lock.m
//  Gets cnc-ddraw to take hold of the mouse as soon as the game is up, so the
//  player's first click is not swallowed.
//
//  Second Chance runs DirectDraw games through cnc-ddraw in windowed mode
//  (WineManager sets windowed=true; native fullscreen then turns that window
//  into a macOS fullscreen Space). In windowed mode cnc-ddraw only "locks" the
//  cursor -- hides the system cursor and confines it to the game -- once it
//  sees a mouse-button release inside the window, and it eats that release.
//  Until then its GetCursorPos hook hands the game a stale position, so the
//  first click lands nowhere: on a menu, nothing happens. (cnc-ddraw also
//  unlocks whenever the app is deactivated, so the same happens after
//  Cmd-Tabbing back, or after another app's panel takes key.) None of its ini options lock on start without giving up
//  windowed mode or the lock altogether.
//
//  So this posts a *middle* click to the game window, which cnc-ddraw locks on
//  just the same, but which the Nancy Drew games never see: cnc-ddraw drops the
//  click while unlocked, and the games poll only the left and right buttons
//  (GetAsyncKeyState). A left click here would skip the publisher logo; a
//  middle one does not.
//
//  It then checks that the lock took, and clicks again if not. Wine's Mac
//  driver records both halves of the lock -- clippingCursor and
//  clientWantsCursorHidden on WineApplicationController -- and runs in this
//  same process, so they can be read directly.
//
//  Everything is in-process, so no Accessibility permission is involved. It
//  rides in in_process_helpers.dylib to share its loading trick (see
//  native_fullscreen.m) but is armed separately, by CURSOR_LOCK_EXE.
//
//  Built and installed by WrappTemplate/setup-wine.sh.
//

#import <Cocoa/Cocoa.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <unistd.h>

#include "helper_common.h"

static const double kPollInterval = 0.25;
/// Without native fullscreen, the window must hold one frame this long before
/// clicking, so a lock is not taken mid-resize and confined to the old frame.
/// With it, AppKit says when the window has finished moving into its Space,
/// which is when its frame is final, and nothing is waited for after that.
static const double kSettleSeconds = 1.0;
/// When native fullscreen is armed, wait for the window to be in its
/// fullscreen Space first. A frame holding still is not enough on its own: on
/// a slow machine the window can sit at its initial size for well over
/// kSettleSeconds before native fullscreen toggles it. Past this, fall back on
/// the frame holding still, in case native fullscreen never happens (it can
/// give up and stay windowed).
static const double kFullscreenWaitSeconds = 20.0;
static const double kGiveUpWaitingSeconds = 100.0;
/// Both lock flags are briefly true at startup before cnc-ddraw first releases
/// the cursor -- the game hides it and Wine clips fullscreen windows itself --
/// so a lock found without a click of ours only counts once it has held this
/// long. One that appears after our click needn't: clicks are only posted
/// while the cursor is free, so cnc-ddraw had already let go, and the lock is
/// the click's.
static const double kLockedForSeconds = 2.0;
/// Time for cnc-ddraw to act on a click before clicking again. Generous, since
/// a slow machine can take a while to settle after the fullscreen transition;
/// the lock is looked for throughout, so a quick one is seen at once.
static const double kAfterClickSeconds = 2.0;
static const int kMaxClicks = 15;

static BOOL nativeFullscreenArmed(void);

static os_log_t gLog;
/// Bumped for each run of the locker, so a run started by re-activation
/// supersedes one still in progress.
static volatile int gGeneration = 0;
/// See cursorLockStatus() in helper_common.h. Always a string literal.
static const char *volatile gStatus = "off";

const char *cursorLockStatus(void) {
    return gStatus;
}

#define debugLog(...) helperDebugLog(gLog, "CursorLock", __VA_ARGS__)

/// AppKit and Wine's controller are main-thread only.
static BOOL onMainThread(BOOL (^block)(void)) {
    return helperOnMainThread(2, block);
}

/// Whether cnc-ddraw holds the cursor: clipped *and* hidden, as its lock does.
static BOOL cursorLocked(void) {
    Class controllerClass = NSClassFromString(@"WineApplicationController");
    if (![controllerClass respondsToSelector:@selector(sharedController)]) return NO;
    id controller = [controllerClass performSelector:@selector(sharedController)];
    @try {
        // clientWantsCursorHidden is an ivar with no accessor; KVC reads it.
        return [[controller valueForKey:@"clippingCursor"] boolValue] &&
               [[controller valueForKey:@"clientWantsCursorHidden"] boolValue];
    } @catch (NSException *exception) {
        debugLog("cannot read Wine's cursor state: %s", exception.reason.UTF8String);
        return NO;
    }
}

int cursorLockHeld(void) {
    return cursorLocked();
}

/// The game window, if this app is active and it is key.
static NSWindow *activeGameWindow(void) {
    if (!NSApp.isActive) return nil;
    NSWindow *window = NSApp.keyWindow;
    if (!window.isVisible) return nil;
    if (![NSStringFromClass([window class]) isEqualToString:@"WineWindow"]) return nil;
    return window;
}

/// Post a middle-button down/up to the window, in its content, at the cursor
/// if it is over the window so cnc-ddraw does not move it. Returns NO, posting
/// nothing, if the events would not be a middle click on that window.
static BOOL postMiddleClick(NSWindow *window) {
    NSRect content = [window contentRectForFrameRect:window.frame];
    NSPoint mouse = NSEvent.mouseLocation;
    NSPoint onScreen = NSMouseInRect(mouse, content, NO) ? mouse : NSMakePoint(NSMidX(content), NSMidY(content));
    NSPoint point = [window convertPointFromScreen:onScreen];

    NSEventType types[2] = { NSEventTypeOtherMouseDown, NSEventTypeOtherMouseUp };
    NSEvent *events[2];
    for (int i = 0; i < 2; i++) {
        // mouseEventWithType: ties the event to the window -- Wine ignores
        // mouse events without one -- but gives it button 0, which Wine would
        // deliver as a *left* click. Re-wrap its CGEvent with the middle button.
        NSEvent *base = [NSEvent mouseEventWithType:types[i]
                                           location:point
                                      modifierFlags:0
                                          timestamp:NSProcessInfo.processInfo.systemUptime
                                       windowNumber:window.windowNumber
                                            context:nil
                                        eventNumber:0
                                         clickCount:1
                                           pressure:i == 0 ? 1.0 : 0.0];
        CGEventRef cgEvent = CGEventCreateCopy(base.CGEvent);
        if (!cgEvent) return NO;
        CGEventSetIntegerValueField(cgEvent, kCGMouseEventButtonNumber, kCGMouseButtonCenter);
        events[i] = [NSEvent eventWithCGEvent:cgEvent];
        CFRelease(cgEvent);
        if (events[i].window != window || events[i].buttonNumber != kCGMouseButtonCenter) {
            debugLog("not posting: event would be button %ld on %s",
                     (long)events[i].buttonNumber, events[i].window == window ? "the game window" : "another window");
            return NO;
        }
    }
    [NSApp postEvent:events[0] atStart:NO];
    [NSApp postEvent:events[1] atStart:NO];
    return YES;
}


static void *lockerMain(void *arg) {
    int generation = (int)(intptr_t)arg;
    BOOL (^current)(void) = ^BOOL { return generation == gGeneration; };

    // Wait for an active game window whose frame is final: in its fullscreen
    // Space when native fullscreen is armed, else (or if it never gets there)
    // once its frame has held still.
    NSRect lastFrame = NSZeroRect;
    double stableSince = 0;
    double firstSeen = 0;
    double deadline = helperNowSeconds() + kGiveUpWaitingSeconds;
    while (current()) {
        if (helperNowSeconds() > deadline) {
            debugLog("no settled game window after %.0fs; not locking", kGiveUpWaitingSeconds);
            helperReport("CursorLock", "warning", "no settled game window after %.0fs; not locking", kGiveUpWaitingSeconds);
            if (current()) gStatus = "not-locked";
            return NULL;
        }
        __block NSRect frame = NSZeroRect;
        __block BOOL inSpace = NO;
        BOOL found = onMainThread(^BOOL {
            NSWindow *window = activeGameWindow();
            frame = window.frame;
            inSpace = (window.styleMask & NSWindowStyleMaskFullScreen) != 0 && !windowIsEnteringFullscreen(window);
            return window != nil;
        });
        if (found && firstSeen == 0) firstSeen = helperNowSeconds();
        if (found && nativeFullscreenArmed() && inSpace) {
            debugLog("window is in its fullscreen Space");
            break;
        }
        BOOL gaveUpOnFullscreen = firstSeen > 0 && helperNowSeconds() - firstSeen >= kFullscreenWaitSeconds;
        if (!found || !NSEqualRects(frame, lastFrame)) {
            stableSince = helperNowSeconds();
        } else if ((!nativeFullscreenArmed() || gaveUpOnFullscreen) && helperNowSeconds() - stableSince >= kSettleSeconds) {
            if (nativeFullscreenArmed()) {
                debugLog("window not fullscreen after %.0fs; locking anyway", kFullscreenWaitSeconds);
            }
            break;
        }
        lastFrame = frame;
        usleep((useconds_t)(kPollInterval * USEC_PER_SEC));
    }

    int clicks = 0;
    double lockedSince = 0;
    double lastClick = 0;
    while (current()) {
        if (onMainThread(^BOOL { return cursorLocked(); })) {
            if (lockedSince == 0) lockedSince = helperNowSeconds();
            if (clicks > 0 || helperNowSeconds() - lockedSince >= kLockedForSeconds) {
                if (clicks > 0) {
                    debugLog("cursor locked after %d middle click(s), %.2fs after the last", clicks, lockedSince - lastClick);
                } else {
                    debugLog("cursor locked after 0 middle clicks");
                }
                helperReport("CursorLock", "notice", "cursor locked after %d middle click(s)", clicks);
                if (current()) gStatus = "locked";
                return NULL;
            }
        } else if (clicks > 0 && helperNowSeconds() - lastClick < kAfterClickSeconds) {
            // Not yet: cnc-ddraw gets kAfterClickSeconds to act on a click
            // before there's another.
            lockedSince = 0;
        } else {
            lockedSince = 0;
            if (clicks >= kMaxClicks) {
                debugLog("gave up: cursor still not locked after %d middle clicks", clicks);
                // Expected in a game that doesn't draw through cnc-ddraw, so
                // not a warning: nothing there ever takes the cursor.
                helperReport("CursorLock", "notice", "cursor not locked after %d middle clicks; leaving it", clicks);
                if (current()) gStatus = "not-locked";
                return NULL;
            }
            BOOL posted = onMainThread(^BOOL {
                NSWindow *window = activeGameWindow();
                return window && postMiddleClick(window);
            });
            if (posted) {
                clicks++;
                lastClick = helperNowSeconds();
                debugLog("posted middle click %d", clicks);
            }
        }
        usleep((useconds_t)(kPollInterval * USEC_PER_SEC));
    }
    return NULL;
}

static void startLocker(void) {
    int generation = __sync_add_and_fetch(&gGeneration, 1);
    gStatus = "waiting";
    watchFullscreenTransitions();
    pthread_t thread;
    if (pthread_create(&thread, NULL, lockerMain, (void *)(intptr_t)generation) == 0) {
        pthread_detach(thread);
    } else {
        gStatus = "not-locked";
        debugLog("could not start locker thread");
        helperReport("CursorLock", "error", "could not start locker thread");
    }
}

static BOOL shouldActivate(void) {
    return processRunsExeNamedBy("CURSOR_LOCK_EXE");
}

/// Whether native_fullscreen.m is armed in this process, and so will resize
/// the window into a fullscreen Space.
static BOOL nativeFullscreenArmed(void) {
    return processRunsExeNamedBy("NATIVE_MACOS_FULLSCREEN_EXE");
}

__attribute__((constructor))
static void cursorLockInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "CursorLock");
    if (!shouldActivate()) return;
    debugLog("armed");
    helperReport("CursorLock", "notice", "armed in %s", getenv("CURSOR_LOCK_EXE"));
    startLocker();

    // cnc-ddraw unlocks when the app is deactivated; lock again on return.
    // Until then the lock is waiting, not still "locked": a click while it
    // says so (WrappPuppeteer's first, say) would be swallowed. Entering
    // native fullscreen can deactivate the app for a moment, just after
    // the first lock.
    //
    // Another app's panel taking key, with the app still active, lets go of
    // the cursor just the same, so that's a leaving and a return too
    // (focus_watch.m).
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *notification) {
            (void)notification;
            debugLog("app resigned active");
            __sync_add_and_fetch(&gGeneration, 1);
            gStatus = "waiting";
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *notification) {
            (void)notification;
            debugLog("app became active");
            startLocker();
        }];
        watchKeyLostToAnotherApp(^(NSWindow *window) {
            debugLog("window %ld lost key to another app", (long)window.windowNumber);
            __sync_add_and_fetch(&gGeneration, 1);
            gStatus = "waiting";
        }, ^(NSWindow *window) {
            debugLog("window %ld has key again", (long)window.windowNumber);
            startLocker();
        });
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
