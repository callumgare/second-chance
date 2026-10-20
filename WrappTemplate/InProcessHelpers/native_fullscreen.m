//
//  native_fullscreen.m
//  Puts a Wine game window into real macOS fullscreen -- its own Space,
//  notch-aware, swipe-compatible -- without any Accessibility permission.
//
//  macOS only lets a process fullscreen its own NSWindow. Doing it from another
//  process means the Accessibility API or synthetic keystrokes, both of which
//  need the Accessibility TCC grant. So this code runs *inside* the Wine process
//  that owns the window and calls -toggleFullScreen: directly, which is exactly
//  what the green title-bar button does. Wine only lets a resizable window go
//  fullscreen, so for a Direct3D game's borderless window this file also
//  overrides a few of Wine's own methods (see "Overriding Wine" below).
//
//  Getting loaded is the hard part, and it is why this is not a
//  DYLD_INSERT_LIBRARIES bundle. Wine launches each Windows process through
//  wine-preloader, which produces two dyld passes: the preloader reaches its
//  entry point before dyld's initializer phase, then loads the real wine binary
//  in a second pass. An inserted dylib belongs only to the first pass, so it gets
//  mapped into the game process but its constructor never runs. Instead,
//  patch-winemac.swift adds a weak dependency on this dylib to winemac.so, putting
//  it in the second pass's image graph where dyld does run initializers.
//
//  winemac.so is loaded by every process that talks to Wine's Mac driver
//  (explorer.exe, the game, ...), so NATIVE_MACOS_FULLSCREEN_EXE names the one
//  executable that should act; helper_common.h has how the game's process
//  is recognised.
//
//  The same dylib also carries cursor_lock.m, which uses this loading trick
//  for a different job and is armed separately (docs/wine-in-process-helpers.md).
//
//  Built and installed by WrappTemplate/setup-wine.sh.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "helper_common.h"

// Require the frame to be unchanged across one extra poll before toggling, so a
// window caught mid-resize is not dragged into a wrongly-sized Space. Measured on
// Danger by Design, cnc-ddraw's window is already at its final size the moment it
// becomes visible and never moves again, so this is cheap insurance for other
// games rather than a wait this one needs -- keep it far below the ~1.6s the
// window takes to become key, which is latency the player would notice.
static const double kSettleSeconds = 0.2;
static const double kPollInterval = 0.1;
static const double kGiveUpSeconds = 90.0;
static const double kWatchInterval = 0.25;

static os_log_t gLog;
static BOOL gEntered = NO;
/// Set once this helper has given up on finding a window to put in a Space.
static volatile BOOL gGaveUp = NO;
static NSWindow *gCandidate = nil;
static NSRect gCandidateFrame;
static double gStableSince = 0.0;

static double nowSeconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / NSEC_PER_SEC;
}

/// Appends to IN_PROCESS_HELPERS_LOG when that variable is set. Worth having
/// alongside os_log because this runs inside Wine child processes, whose log
/// output is otherwise awkward to attribute to a particular game.
static void debugLog(const char *format, ...) {
    const char *path = getenv("IN_PROCESS_HELPERS_LOG");
    if (!path || !*path) return;

    char executable[PATH_MAX] = {0};
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) {
        strlcpy(executable, "?", sizeof(executable));
    }
    const char *name = strrchr(executable, '/');
    name = name ? name + 1 : executable;

    char message[2048];
    int length = snprintf(message, sizeof(message), "pid=%d exe=%s | ", getpid(), name);

    va_list args;
    va_start(args, format);
    length += vsnprintf(message + length, sizeof(message) - length, format, args);
    va_end(args);

    if (length < (int)sizeof(message) - 1) message[length++] = '\n';

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, message, length);
        close(fd);
    }
}

// Wine's own WineWindow and WineApplicationController methods this file calls
// or replaces (dlls/winemac.drv/cocoa_window.m). Declared here so the compiler
// knows their types; they are looked up at run time.
@interface NSView (WineContentViewMethods)
- (BOOL)hasGLDescendant;
@end

@interface NSWindow (WineWindowMethods)
- (BOOL)isFullscreen;
- (BOOL)closing;
- (void)adjustFeaturesForState;
- (void)adjustFullScreenBehavior:(NSWindowCollectionBehavior)behavior;
@end

@interface NSObject (WineApplicationControllerMethods)
+ (id)sharedController;
- (void)adjustWindowLevels;
@end

// Per-window state, kept on the window itself so nothing outlives it.
static char kAdoptedKey;   // this file has taken charge of the window's fullscreen
static char kEnteredKey;   // the window has been put into a Space once
static char kReenterKey;   // Wine closed the window's Space; put it back when shown

static BOOL windowFlag(NSWindow *window, const void *key) {
    return [objc_getAssociatedObject(window, key) boolValue];
}

static void setWindowFlag(NSWindow *window, const void *key, BOOL value) {
    objc_setAssociatedObject(window, key, value ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Whether Wine counts the window as covering a screen: how a Direct3D game
/// in fullscreen mode presents itself -- a borderless window the size of the
/// display, which Wine raises above the menu bar and the Dock.
static BOOL wineCoversScreen(NSWindow *window) {
    return [window respondsToSelector:@selector(isFullscreen)] && [window isFullscreen];
}

/// Whether Direct3D is drawing into the window: Wine has given its content
/// an OpenGL view (wined3d) or a Metal view (Vulkan).
///
/// This is what tells a Direct3D game's window from a window that is only
/// passing through the size of the screen. Last Train to Blue Moon Canyon's
/// window first appears the size of the screen and only becomes cnc-ddraw's
/// 640x512 window 0.5-2.5s later; Wine paints it in between, so it has
/// content, but cnc-ddraw attaches its OpenGL view only after the resize.
/// Ghost of Thornton Hall's window has its OpenGL view within half a second.
static BOOL direct3DDrawsInto(NSWindow *window) {
    NSView *content = window.contentView;
    if ([content respondsToSelector:@selector(hasGLDescendant)] && [(id)content hasGLDescendant]) return YES;
    NSMutableArray<NSView *> *views = [content.subviews mutableCopy];
    while (views.count) {
        NSView *view = views.lastObject;
        [views removeLastObject];
        if ([NSStringFromClass(view.class) isEqualToString:@"WineMetalView"]) return YES;
        [views addObjectsFromArray:view.subviews];
    }
    return NO;
}

// MARK: - Overriding Wine for the adopted window
//
// Wine decides from the game's Win32 window style whether a window may go
// fullscreen: adjustFullScreenBehavior: grants FullScreenPrimary only to
// resizable, parentless windows, and takes a window that no longer qualifies
// out of its Space. A Direct3D game's borderless window never qualifies, and
// Wine checks again whenever the window's style or state changes -- which it
// does when the game loses and regains focus -- so a Space given to it lasts
// only until the player first switches away. For the one
// window this file adopts, three of Wine's methods are replaced:
//
// - adjustFullScreenBehavior: always grants FullScreenPrimary, and never
//   takes the window out of its Space.
// - minimumLevelForActive: is the normal level. Wine raises a window covering
//   the screen to just above the status bar so it hides the menu bar and the
//   Dock; in a Space they are hidden anyway, and a raised window would sit in
//   front of every other app's windows.
// - doOrderOut leaves the window, and its Space, alone while the app is
//   inactive. Direct3D may hide a fullscreen game's window when the game
//   loses focus (Ghost of Thornton Hall's windowed mode does), and Wine
//   hides a fullscreen window by closing it, which ends its Space; kept, the
//   Space shows the last frame until the player comes back and the game
//   shows its window again. Hidden while the app is active, the window goes
//   as usual and comes back into a Space when shown again (kReenterKey).
//
// Every other window keeps Wine's behaviour.

static IMP gWineAdjustFullScreenBehavior;
static IMP gWineMinimumLevelForActive;
static IMP gWineDoOrderOut;

static void adoptedAdjustFullScreenBehavior(NSWindow *self, SEL _cmd, NSWindowCollectionBehavior behavior) {
    if (!windowFlag(self, &kAdoptedKey)) {
        ((void (*)(id, SEL, NSWindowCollectionBehavior))gWineAdjustFullScreenBehavior)(self, _cmd, behavior);
        return;
    }
    behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
    if (behavior != self.collectionBehavior) {
        self.collectionBehavior = behavior;
        [self adjustFeaturesForState];
    }
}

static NSInteger adoptedMinimumLevelForActive(NSWindow *self, SEL _cmd, BOOL active) {
    if (windowFlag(self, &kAdoptedKey)) return NSNormalWindowLevel;
    return ((NSInteger (*)(id, SEL, BOOL))gWineMinimumLevelForActive)(self, _cmd, active);
}

static void adoptedDoOrderOut(NSWindow *self, SEL _cmd) {
    if (windowFlag(self, &kAdoptedKey) && (self.styleMask & NSWindowStyleMaskFullScreen) && ![self closing]) {
        if (!NSApp.isActive) {
            debugLog("keeping the fullscreen window while the app is inactive");
            return;
        }
        debugLog("the fullscreen window is being hidden; it goes back into a Space when shown");
        setWindowFlag(self, &kReenterKey, YES);
    }
    ((void (*)(id, SEL))gWineDoOrderOut)(self, _cmd);
}

static IMP replaceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    return method ? method_setImplementation(method, replacement) : NULL;
}

/// Install the overrides; NO if Wine's classes aren't what this file expects,
/// in which case only windows Wine already lets go fullscreen are adopted.
static BOOL installOverrides(void) {
    static BOOL attempted = NO, installed = NO;
    if (attempted) return installed;
    attempted = YES;

    Class wineWindow = NSClassFromString(@"WineWindow");
    SEL selectors[] = { @selector(adjustFullScreenBehavior:), @selector(minimumLevelForActive:),
                        @selector(doOrderOut), @selector(closing), @selector(isFullscreen),
                        @selector(adjustFeaturesForState) };
    for (size_t i = 0; wineWindow && i < sizeof(selectors) / sizeof(*selectors); i++) {
        if (!class_getInstanceMethod(wineWindow, selectors[i])) {
            helperReport("NativeFullscreen", "warning", "WineWindow has no -%s; windows covering the screen stay out of a Space",
                         sel_getName(selectors[i]));
            return NO;
        }
    }
    if (!wineWindow) {
        helperReport("NativeFullscreen", "warning", "no WineWindow class; windows covering the screen stay out of a Space");
        return NO;
    }

    gWineAdjustFullScreenBehavior = replaceMethod(wineWindow, @selector(adjustFullScreenBehavior:), (IMP)adoptedAdjustFullScreenBehavior);
    gWineMinimumLevelForActive = replaceMethod(wineWindow, @selector(minimumLevelForActive:), (IMP)adoptedMinimumLevelForActive);
    gWineDoOrderOut = replaceMethod(wineWindow, @selector(doOrderOut), (IMP)adoptedDoOrderOut);
    installed = YES;
    return YES;
}

static void adjustWineWindowLevels(void) {
    Class controllerClass = NSClassFromString(@"WineApplicationController");
    if ([controllerClass respondsToSelector:@selector(sharedController)]) {
        id controller = [controllerClass sharedController];
        if ([controller respondsToSelector:@selector(adjustWindowLevels)]) [controller adjustWindowLevels];
    }
}

// MARK: - Choosing and entering

/// The game's window: one Wine lets go fullscreen, or one covering the
/// screen.
///
/// The first are what Wine's adjustFullScreenBehavior: grants
/// FullScreenPrimary -- resizable, non-utility, parentless windows, precisely
/// the ones with a working green title-bar button -- which is how cnc-ddraw's
/// window arrives. cnc-ddraw's transient helper windows and Wine's hidden
/// IME/message windows never qualify. The second are Direct3D games' windows,
/// which only the overrides above let into a Space, taken once Direct3D draws
/// into them (direct3DDrawsInto).
///
/// Main thread only: AppKit state is not safe to read from the watcher thread.
static NSWindow *findGameWindow(BOOL overridesInstalled) {
    NSWindow *best = nil;
    CGFloat bestArea = 0.0;

    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;

        // Something is already fullscreen, so leave this process alone.
        if (window.styleMask & NSWindowStyleMaskFullScreen) return nil;

        if (window.parentWindow) continue;
        BOOL eligible = (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) ||
                        (overridesInstalled && (windowFlag(window, &kAdoptedKey) ||
                                                (wineCoversScreen(window) && direct3DDrawsInto(window))));
        if (!eligible) continue;

        // Normally exactly one window qualifies; prefer the largest just to keep
        // the choice deterministic if a game ever shows two.
        NSRect frame = window.frame;
        CGFloat area = frame.size.width * frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = window;
        }
    }
    return best;
}

static void attemptFullscreen(void) {
    BOOL overridesInstalled = installOverrides();

    NSWindow *window = findGameWindow(overridesInstalled);
    if (!window) {
        gCandidate = nil;
        return;
    }

    // A window put into a Space before goes back only if Wine closed the
    // Space -- not if the player left it -- and only once they're back in
    // the game.
    BOOL reentering = windowFlag(window, &kEnteredKey);
    if (reentering && !(windowFlag(window, &kReenterKey) && NSApp.isActive)) {
        gCandidate = nil;
        return;
    }

    // Only toggle once the frame has held steady for kSettleSeconds.
    NSRect frame = window.frame;
    if (window != gCandidate || !NSEqualRects(frame, gCandidateFrame)) {
        gCandidate = window;
        gCandidateFrame = frame;
        gStableSince = nowSeconds();
        return;
    }
    if (nowSeconds() - gStableSince < kSettleSeconds) return;

    gCandidate = nil;
    gEntered = YES;
    setWindowFlag(window, &kEnteredKey, YES);
    setWindowFlag(window, &kReenterKey, NO);

    BOOL wineEligible = (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0;
    if (overridesInstalled) {
        setWindowFlag(window, &kAdoptedKey, YES);
        [window adjustFullScreenBehavior:window.collectionBehavior];
        adjustWineWindowLevels();
    }

    const char *title = window.title.length ? window.title.UTF8String : "(untitled)";
    const char *kind = reentering ? "re-entering" : "entering";
    const char *how = wineEligible ? "" : " (a window covering the screen)";
    os_log(gLog, "[NativeFS] %{public}s native fullscreen: %{public}s %dx%d%{public}s",
           kind, title, (int)frame.size.width, (int)frame.size.height, how);
    debugLog("%s native fullscreen: '%s' %dx%d%s", kind, title, (int)frame.size.width, (int)frame.size.height, how);
    helperReport("NativeFullscreen", "notice", "%s native fullscreen: '%s' %dx%d%s",
                 kind, title, (int)frame.size.width, (int)frame.size.height, how);

    [window toggleFullScreen:nil];
}

/// Wine dedicates the process's main thread to a CFRunLoop (see __wine_main in
/// ntdll) and runs the Windows code on other threads, so blocks queued onto the
/// main run loop do get drained. This thread only schedules; every AppKit call
/// happens on the main thread.
///
/// It keeps watching after the first entry, for a window Wine closed the Space
/// of, and for a new game window -- slower once the game is in its Space.
static void *watcherMain(void *unused) {
    (void)unused;

    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    if (!mainLoop) {
        os_log_error(gLog, "[NativeFS] no main run loop; giving up");
        debugLog("no main run loop; giving up");
        helperReport("NativeFullscreen", "error", "no main run loop; giving up");
        return NULL;
    }

    double giveUpAt = nowSeconds() + kGiveUpSeconds;
    BOOL reportedGivingUp = NO;
    while (true) {
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{ attemptFullscreen(); });
        CFRunLoopWakeUp(mainLoop);
        usleep((useconds_t)((gEntered ? kWatchInterval : kPollInterval) * USEC_PER_SEC));

        if (!gEntered && !reportedGivingUp && nowSeconds() > giveUpAt) {
            reportedGivingUp = YES;
            gGaveUp = YES;
            os_log(gLog, "[NativeFS] no eligible window after %.0fs; staying windowed", kGiveUpSeconds);
            debugLog("no eligible window after %.0fs; staying windowed", kGiveUpSeconds);
            helperReport("NativeFullscreen", "warning", "no eligible window after %.0fs; staying windowed", kGiveUpSeconds);
        }
    }
    return NULL;
}

static BOOL shouldActivate(void) {
    return processRunsExeNamedBy("NATIVE_MACOS_FULLSCREEN_EXE");
}

__attribute__((constructor))
static void nativeFullscreenInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "NativeFullscreen");

    if (!shouldActivate()) return;

    os_log(gLog, "[NativeFS] armed");
    debugLog("armed");
    watchFullscreenTransitions();
    helperReport("NativeFullscreen", "notice", "armed in %s", getenv("NATIVE_MACOS_FULLSCREEN_EXE"));

    pthread_t thread;
    if (pthread_create(&thread, NULL, watcherMain, NULL) == 0) {
        pthread_detach(thread);
    } else {
        os_log_error(gLog, "[NativeFS] could not start watcher thread");
        debugLog("could not start watcher thread");
        helperReport("NativeFullscreen", "error", "could not start watcher thread");
    }
}

#pragma mark - Fullscreen transitions (helper_common.h)

/// To os_log and IN_PROCESS_HELPERS_LOG both.
#define transitionLog(format, ...) do { \
    os_log(gLog, "[NativeFS] " format, ##__VA_ARGS__); \
    debugLog(format, ##__VA_ARGS__); \
} while (0)

/// Windows AppKit said will enter fullscreen and hasn't yet said did, and
/// whether one ever finished entering. Main thread only.
static NSHashTable<NSWindow *> *gEnteringWindows;
static BOOL gAWindowEntered = NO;

void watchFullscreenTransitions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            gEnteringWindows = [NSHashTable weakObjectsHashTable];
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:NSWindowWillEnterFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows addObject:notification.object];
                transitionLog("window %ld will enter fullscreen", (long)[notification.object windowNumber]);
            }];
            [center addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows removeObject:notification.object];
                gAWindowEntered = YES;
                transitionLog("window %ld did enter fullscreen", (long)[notification.object windowNumber]);
            }];
            [center addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows removeObject:notification.object];
            }];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
}

int windowIsEnteringFullscreen(NSWindow *window) {
    return window && [gEnteringWindows containsObject:window] && (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

int nativeFullscreenSettled(void) {
    static int armed = -1;
    if (armed < 0) armed = shouldActivate();
    if (!armed || gGaveUp) return 1;
    // gEntered is set just before -toggleFullScreen:, which posts the will-enter
    // notification before it returns, all on this thread: no gap between them.
    if (!gEntered || !gAWindowEntered) return 0;
    for (NSWindow *window in gEnteringWindows) {
        if (windowIsEnteringFullscreen(window)) return 0;
    }
    return 1;
}
