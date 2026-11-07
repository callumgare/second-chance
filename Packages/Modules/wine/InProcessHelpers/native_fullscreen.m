//
//  native_fullscreen.m
//  Puts a Wine game window into real macOS fullscreen -- its own Space,
//  notch-aware, swipe-compatible -- without any Accessibility permission,
//  when the game asks for fullscreen, and takes it out again when the game
//  asks for a window (see "What the game asks for" below).
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

#include <stdatomic.h>
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
- (BOOL)disabled;
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
static char kCoversScreenKey;  // adopted as a window covering the screen, not one Wine lets go fullscreen

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
// - windowWillStartLiveResize: and windowDidEndLiveResize: do nothing while
//   a window covering the screen moves into or out of its Space (a window
//   Wine lets go fullscreen really is resized, and cnc-ddraw rescales its
//   picture and the mouse when told the resize ended). AppKit calls them for the
//   move, and Wine turns them into WM_ENTERSIZEMOVE and WM_EXITSIZEMOVE,
//   as though the player had started dragging an edge -- which nobody can
//   do to a fullscreen Direct3D window on Windows, where the game never
//   gets them. Warnings at Waverly Academy and Shadow at the Water's Edge,
//   from Steam, stopped drawing for good more often than not when their
//   frame timer's tick landed in between, and the Space stayed black. The
//   window is the size of the screen before and after, so nothing is lost.
//
// Every other window keeps Wine's behaviour.

static IMP gWineAdjustFullScreenBehavior;
static IMP gWineMinimumLevelForActive;
static IMP gWineDoOrderOut;
static IMP gWineWillStartLiveResize;
static IMP gWineDidEndLiveResize;

static char kSkippedResizeKey;  // a live resize of the move into or out of a Space went unreported

static BOOL windowIsMovingSpaces(NSWindow *window);

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

static void adoptedWillStartLiveResize(NSWindow *self, SEL _cmd, NSNotification *notification) {
    if (windowFlag(self, &kCoversScreenKey) && windowIsMovingSpaces(self)) {
        os_log(gLog, "[NativeFS] not telling the game about the live resize of the move into or out of its Space");
        debugLog("not telling the game about the live resize of the move into or out of its Space");
        setWindowFlag(self, &kSkippedResizeKey, YES);
        return;
    }
    ((void (*)(id, SEL, NSNotification *))gWineWillStartLiveResize)(self, _cmd, notification);
}

static void adoptedDidEndLiveResize(NSWindow *self, SEL _cmd, NSNotification *notification) {
    if (windowFlag(self, &kSkippedResizeKey)) {
        setWindowFlag(self, &kSkippedResizeKey, NO);
        return;
    }
    ((void (*)(id, SEL, NSNotification *))gWineDidEndLiveResize)(self, _cmd, notification);
}

static IMP replaceMethod(Class cls, SEL selector, IMP replacement) {
    return replaceOwnMethod(cls, selector, replacement);
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
                        @selector(adjustFeaturesForState), @selector(windowWillStartLiveResize:),
                        @selector(windowDidEndLiveResize:) };
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
    gWineWillStartLiveResize = replaceMethod(wineWindow, @selector(windowWillStartLiveResize:), (IMP)adoptedWillStartLiveResize);
    gWineDidEndLiveResize = replaceMethod(wineWindow, @selector(windowDidEndLiveResize:), (IMP)adoptedDidEndLiveResize);
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

// MARK: - What the game asks for
//
// A window goes into a Space when the game asks for fullscreen, and back out
// when it asks for a window again:
//
// - A window covering the screen that Direct3D draws into is a Direct3D
//   game in fullscreen mode. Its request lasts as long as the window. So is
//   one covering the screen that shows a GDI picture win32u scaled up from an
//   emulated display mode (windowShowsScaledPicture, emulated_mode_scaling.m):
//   a program drawing with GDI in the mode its launch set.
// - Any other window is cnc-ddraw's (or a program's own): it asks for
//   fullscreen while the game has a display mode set through cnc-ddraw
//   (ddraw_mode_watch.m), and for a window otherwise -- a DirectDraw game
//   that asked for a normal window (DDSCL_NORMAL), a Direct3D game in its
//   windowed mode, a program that draws with GDI.
//
// Each request has a number. A window the player took out of its Space stays
// out until the game makes a new request (switches to a window and back);
// one Wine closed the Space of goes back in when it's shown again.
//
// NATIVE_MACOS_FULLSCREEN_FORCE=1 (the launch's --wine.window=fullscreen)
// makes every window that could go fullscreen ask, for a program this
// misjudges; so does a win32u this can't watch, which is how native
// fullscreen worked before it followed the game.

static BOOL gForced = NO;
/// Not forced, and the DirectDraw watch is in: follow what the game asks.
static BOOL gFollowsGame = NO;

/// The request a window covering the screen makes while it's adopted.
static const unsigned long kCoversScreenRequest = ULONG_MAX;

static char kEnteredRequestKey;  // the request the window last went into a Space for
static char kLeftRequestKey;     // the request whose Space the window left, other than by Wine closing it

static unsigned long windowRequestValue(NSWindow *window, const void *key) {
    return [objc_getAssociatedObject(window, key) unsignedLongValue];
}

static void setWindowRequestValue(NSWindow *window, const void *key, unsigned long value) {
    objc_setAssociatedObject(window, key, value ? @(value) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// What the game asks of `window`: 0 for a window, else the number of its
/// request for fullscreen. Main thread only.
static unsigned long fullscreenRequest(NSWindow *window) {
    if (!gFollowsGame) return 1;
    // Only a window Wine wouldn't let go fullscreen itself: borderless, as a
    // Direct3D game's fullscreen window is. cnc-ddraw's captioned window can
    // come to cover the screen too, and draws with OpenGL, when cnc-ddraw
    // remembers it at the size of the Space.
    BOOL wineLetsGo = (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0;
    if (windowFlag(window, &kCoversScreenKey) || (!wineLetsGo && wineCoversScreen(window) && (direct3DDrawsInto(window) || windowShowsScaledPicture(window)))) {
        return kCoversScreenRequest;
    }
    return ddrawModeRequest();
}

/// Why the window is going into a Space, for the log.
static const char *requestReason(unsigned long request) {
    if (gForced) return " (as its launch says)";
    if (!gFollowsGame) return "";
    if (request == kCoversScreenRequest) return " (a window covering the screen)";
    return " (the game set a display mode)";
}

static char kFrameBeforeKey;  // the window's frame before this file last put it into a Space
static char kSizeBackKey;     // it left its Space at the game's asking: put it back at that frame once out

/// Have Wine bring the window out of its Space at the frame it had before,
/// rather than the one the game gave it meanwhile.
///
/// Wine takes a frame the game sets while its window is in a Space as the
/// one to give it on leaving (nonFullscreenFrame, in cocoa_window.m). A game
/// that switches to a window starts DirectDraw again while still in its
/// Space, and cnc-ddraw sizes the window as it remembers it: the size of the
/// Space, which AppKit's move into it told it. Left so, the window would
/// come out bigger than the screen. This sets Wine's frame for the way out;
/// cnc-ddraw can still set its own as the window moves, so
/// putBackOldSize() checks once it's out. Main thread only.
static void restoreFrameOnLeaving(NSWindow *window) {
    NSValue *before = objc_getAssociatedObject(window, &kFrameBeforeKey);
    if (!before) return;
    setWindowFlag(window, &kSizeBackKey, YES);
    Ivar ivar = class_getInstanceVariable(window.class, "nonFullscreenFrame");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || strncmp(type, "{CGRect=", 8) != 0) return;
    NSRect *nonFullscreenFrame = (NSRect *)((uint8_t *)(__bridge void *)window + ivar_getOffset(ivar));
    *nonFullscreenFrame = before.rectValue;
}

/// Once a window that left its Space at the game's asking is out, give it
/// the frame it had before, if it came out at another. Wine passes the
/// change on wrapped in WM_ENTERSIZEMOVE and WM_EXITSIZEMOVE, as a player's
/// resize, so cnc-ddraw remembers the size and redraws to fit. Main thread
/// only.
static void putBackOldSize(NSWindow *window) {
    if (!windowFlag(window, &kSizeBackKey) || (window.styleMask & NSWindowStyleMaskFullScreen) ||
        windowIsMovingSpaces(window)) return;
    setWindowFlag(window, &kSizeBackKey, NO);
    NSValue *before = objc_getAssociatedObject(window, &kFrameBeforeKey);
    if (!before || NSEqualRects(window.frame, before.rectValue)) return;
    NSRect frame = before.rectValue;
    os_log(gLog, "[NativeFS] the window left its Space at %dx%d; putting it back at %dx%d",
           (int)window.frame.size.width, (int)window.frame.size.height, (int)frame.size.width, (int)frame.size.height);
    debugLog("the window left its Space at %dx%d; putting it back at %dx%d",
             (int)window.frame.size.width, (int)window.frame.size.height, (int)frame.size.width, (int)frame.size.height);
    [window setFrame:frame display:YES];
}

// MARK: - Who moved the window
//
// The wrapp keeps the player's choice in the game's own fullscreen setting
// (`--wine.fullscreen-setting`) when the session's last change was theirs,
// so each move into or out of a Space is reported with its cause:
//
//   fullscreen changed by the player: fullscreen|windowed
//   fullscreen changed by the game: fullscreen|windowed
//
// The player's are what reach WineWindow's -toggleFullScreen: from anywhere
// but this file: the green title-bar button, and the Window menu's Enter Full
// Screen and its key (Control-Option-Command-F, Wine's). This file's own
// calls go through helperToggle(), which names the cause while AppKit posts its
// will-enter or will-exit notification, inside the call. A move with no cause
// (Wine taking a window that no longer qualifies out with NSWindow's own
// method, or the window going as the game quits) is reported as nothing,
// nor is this file putting a window back into the Space Wine closed.
//
// A window the player put into a Space stays there until the game makes a
// new request (switches its mode), as one the player took out stays out
// until then; once it does, the game decides again, and that is the game's
// change.

typedef NS_ENUM(int, ToggleCause) {
    kToggleNone = 0,
    kTogglePlayer,
    kToggleGame,     // following the game's request (or, forced, the launch's)
    kToggleRestore,  // back into the Space Wine closed: no change
};

/// Whose -toggleFullScreen: is running. Main thread only.
static ToggleCause gToggling = kToggleNone;
static IMP gWineToggleFullScreen;

static char kTransitionCauseKey;  // the cause of the move into or out of a Space under way
static char kPlayerSpaceKey;      // in a Space the player chose: the game's request then, plus one

/// Who a change is by, as the report names them.
static const char *causeName(ToggleCause cause) {
    if (cause == kTogglePlayer) return "the player";
    return gForced ? "the launch" : "the game";
}

static void reportChange(ToggleCause cause, BOOL fullscreen, const char *how) {
    const char *state = fullscreen ? "fullscreen" : "windowed";
    os_log(gLog, "[NativeFS] fullscreen changed by %{public}s: %{public}s%{public}s", causeName(cause), state, how);
    debugLog("fullscreen changed by %s: %s%s", causeName(cause), state, how);
    helperReport("NativeFullscreen", "notice", "fullscreen changed by %s: %s%s", causeName(cause), state, how);
}

/// This file's own move of `window` into or out of its Space.
static void helperToggle(NSWindow *window, ToggleCause cause) {
    ToggleCause was = gToggling;
    gToggling = cause;
    [window toggleFullScreen:nil];
    gToggling = was;
}

/// Whether Wine counts `window` as maximized (its `maximized` ivar): Wine's
/// -toggleFullScreen: does nothing for such a window. NO if it can't tell.
static BOOL wineMaximized(NSWindow *window) {
    Ivar ivar = class_getInstanceVariable(window.class, "maximized");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || (strcmp(type, "c") != 0 && strcmp(type, "B") != 0)) return NO;
    return *((uint8_t *)(__bridge void *)window + ivar_getOffset(ivar)) != 0;
}

/// Wine's -toggleFullScreen:, but AppKit's for a window covering the screen
/// that this file adopted and Wine counts as maximized.
///
/// Wine moves a window into or out of a Space only if it isn't disabled (a
/// modal dialog of its own is up) and isn't maximized. A Director projector
/// maximizes its stage window, which covers the screen anyway (Bioscopia's),
/// so the toggle did nothing and the window never reached its Space, while
/// this file asked again every half second. Such a window is already the
/// size of the Space, so being maximized changes nothing there.
static void wineToggleFullScreen(NSWindow *window, SEL selector, id sender) {
    BOOL disabled = [window respondsToSelector:@selector(disabled)] && [(id)window disabled];
    if (windowFlag(window, &kCoversScreenKey) && !disabled && wineMaximized(window)) {
        static BOOL reported = NO;
        if (!reported) {
            reported = YES;
            helperReport("NativeFullscreen", "notice", "the window is maximized, which Wine won't move into or out of a Space: "
                         "moving it as AppKit does");
        }
        IMP appKit = class_getMethodImplementation([NSWindow class], selector);
        ((void (*)(id, SEL, id))appKit)(window, selector, sender);
        return;
    }
    ((void (*)(id, SEL, id))gWineToggleFullScreen)(window, selector, sender);
}

static void playerAwareToggleFullScreen(NSWindow *self, SEL _cmd, id sender) {
    if (gToggling != kToggleNone) {
        wineToggleFullScreen(self, _cmd, sender);
        return;
    }
    BOOL entering = !(self.styleMask & NSWindowStyleMaskFullScreen);
    debugLog("the player asks to %s fullscreen: window %ld", entering ? "enter" : "leave", (long)self.windowNumber);
    if (entering) {
        objc_setAssociatedObject(self, &kFrameBeforeKey, [NSValue valueWithRect:self.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gToggling = kTogglePlayer;
    wineToggleFullScreen(self, _cmd, sender);
    gToggling = kToggleNone;
}

static IMP gWineValidateMenuItem;

/// Wine's -validateMenuItem:, but with Enter and Exit Full Screen (and their
/// key) left on for the window wineToggleFullScreen() moves although Wine
/// counts it as maximized, which Wine's turns off.
static BOOL validateMenuItemForMaximized(NSWindow *self, SEL _cmd, NSMenuItem *item) {
    BOOL valid = ((BOOL (*)(id, SEL, NSMenuItem *))gWineValidateMenuItem)(self, _cmd, item);
    if (valid || item.action != @selector(toggleFullScreen:) || !windowFlag(self, &kCoversScreenKey)) return valid;
    BOOL disabled = [self respondsToSelector:@selector(disabled)] && [(id)self disabled];
    return !disabled && wineMaximized(self);
}

/// Watch for the player's -toggleFullScreen: on Wine's windows. Main thread.
static void installToggleWatch(void) {
    static BOOL attempted = NO;
    if (attempted) return;
    attempted = YES;
    Class wineWindow = NSClassFromString(@"WineWindow");
    gWineToggleFullScreen = replaceOwnMethod(wineWindow, @selector(toggleFullScreen:), (IMP)playerAwareToggleFullScreen);
    if (!gWineToggleFullScreen) {
        helperReport("NativeFullscreen", "warning", "WineWindow has no -toggleFullScreen:; the player's fullscreen changes go unreported");
    }
    if (classDefinesMethod(wineWindow, @selector(validateMenuItem:))) {
        gWineValidateMenuItem = replaceOwnMethod(wineWindow, @selector(validateMenuItem:), (IMP)validateMenuItemForMaximized);
    }
}

// MARK: - Choosing, entering and leaving

/// Whether a window has held still for kSettleSeconds asking for a window,
/// and whether that's been reported since the window last went into a Space.
static volatile BOOL gDecidedWindowed = NO;
static BOOL gReportedWindowed = NO;
/// The window in a Space whose game has asked for a window, and since when.
static NSWindow *gLeaving = nil;
static double gLeavingSince = 0.0;
static unsigned long gCandidateRequest = 0;

/// The game's window: one Wine lets go fullscreen, or one covering the
/// screen.
///
/// The first are what Wine's adjustFullScreenBehavior: grants
/// FullScreenPrimary -- resizable, non-utility, parentless windows, precisely
/// the ones with a working green title-bar button -- which is how cnc-ddraw's
/// window arrives. cnc-ddraw's transient helper windows and Wine's hidden
/// IME/message windows never qualify. The second are Direct3D games' windows,
/// which only the overrides above let into a Space, taken once Direct3D draws
/// into them (direct3DDrawsInto), or once win32u shows a GDI picture scaled
/// up from an emulated mode in them (windowShowsScaledPicture).
///
/// Main thread only: AppKit state is not safe to read from the watcher thread.
static NSWindow *findGameWindow(BOOL overridesInstalled) {
    NSWindow *best = nil;
    CGFloat bestArea = 0.0;

    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        if (window.parentWindow) continue;
        BOOL eligible = (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) ||
                        (overridesInstalled && (windowFlag(window, &kAdoptedKey) ||
                                                (wineCoversScreen(window) && (direct3DDrawsInto(window) ||
                                                                               windowShowsScaledPicture(window)))));
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

/// Whether a window is in a fullscreen Space; if it's one this file put
/// there and the game has asked for a window since, take it out once that
/// has held for kSettleSeconds. Main thread only.
static BOOL handleFullscreenWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!(window.styleMask & NSWindowStyleMaskFullScreen)) continue;

        // Something is fullscreen, so leave the rest of this process alone.
        if (!gFollowsGame || windowIsMovingSpaces(window)) {
            gLeaving = nil;
            return YES;
        }
        unsigned long request = fullscreenRequest(window);
        NSNumber *playerChose = objc_getAssociatedObject(window, &kPlayerSpaceKey);
        if (playerChose) {
            // The player's Space holds until the game switches its mode.
            if (playerChose.unsignedLongValue == request + 1) {
                gLeaving = nil;
                return YES;
            }
            objc_setAssociatedObject(window, &kPlayerSpaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            setWindowFlag(window, &kEnteredKey, YES);
            setWindowRequestValue(window, &kEnteredRequestKey, request);
            if (request != 0) {
                reportChange(kToggleGame, YES, " (the window was in its Space already)");
                gLeaving = nil;
                return YES;
            }
        }
        if (!windowFlag(window, &kEnteredKey) || request != 0) {
            gLeaving = nil;
            return YES;
        }
        if (window != gLeaving) {
            gLeaving = window;
            gLeavingSince = nowSeconds();
            return YES;
        }
        if (nowSeconds() - gLeavingSince < kSettleSeconds) return YES;
        gLeaving = nil;

        const char *title = window.title.length ? window.title.UTF8String : "(untitled)";
        os_log(gLog, "[NativeFS] leaving native fullscreen: the game asked for a window: %{public}s", title);
        debugLog("leaving native fullscreen: the game asked for a window: '%s'", title);
        helperReport("NativeFullscreen", "notice", "leaving native fullscreen: the game asked for a window: '%s'", title);
        restoreFrameOnLeaving(window);
        helperToggle(window, kToggleGame);
        return YES;
    }
    gLeaving = nil;
    return NO;
}

/// Wine's Window menu has Enter Full Screen on ⌃⌥⌘F; every other Mac app has
/// it on ⌃⌘F, which in a Wine game would go to the game as a key instead.
/// Wine builds the menu once the process is a foreground app, which may be
/// after this helper arms, so this looks each time until it finds the item.
/// Main thread only.
static NSMenuItem *menuItemWithAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return item;
        if (item.submenu) {
            NSMenuItem *found = menuItemWithAction(item.submenu, action);
            if (found) return found;
        }
    }
    return nil;
}

static void useMacFullScreenShortcut(void) {
    static BOOL done = NO;
    if (done) return;
    NSMenuItem *item = menuItemWithAction(NSApp.mainMenu, @selector(toggleFullScreen:));
    if (!item) return;
    done = YES;
    item.keyEquivalent = @"f";
    item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    debugLog("Enter Full Screen is on ctrl+cmd+F");
    helperReport("NativeFullscreen", "notice", "Enter Full Screen is on ⌃⌘F, as in other Mac apps");
}

static void attemptFullscreen(void) {
    useMacFullScreenShortcut();
    installToggleWatch();
    BOOL overridesInstalled = installOverrides();
    for (NSWindow *window in NSApp.windows) putBackOldSize(window);

    if (handleFullscreenWindow()) {
        gCandidate = nil;
        return;
    }

    NSWindow *window = findGameWindow(overridesInstalled);
    if (!window || windowIsMovingSpaces(window)) {
        gCandidate = nil;
        return;
    }
    unsigned long request = fullscreenRequest(window);

    // A window goes back into a Space if Wine closed the Space -- once the
    // player is back in the game -- but not if it was taken out of one,
    // until the game asks again.
    if (request != 0) {
        BOOL reenter = windowFlag(window, &kReenterKey);
        unsigned long left = windowRequestValue(window, &kLeftRequestKey);
        if ((reenter && !NSApp.isActive) || (!reenter && left == request)) {
            gCandidate = nil;
            return;
        }
    }

    // Only act once the frame and the request have held steady for
    // kSettleSeconds.
    NSRect frame = window.frame;
    if (window != gCandidate || !NSEqualRects(frame, gCandidateFrame) || request != gCandidateRequest) {
        gCandidate = window;
        gCandidateFrame = frame;
        gCandidateRequest = request;
        gStableSince = nowSeconds();
        return;
    }
    if (nowSeconds() - gStableSince < kSettleSeconds) return;

    const char *title = window.title.length ? window.title.UTF8String : "(untitled)";
    if (request == 0) {
        gDecidedWindowed = YES;
        if (!gReportedWindowed) {
            gReportedWindowed = YES;
            os_log(gLog, "[NativeFS] the game asks for a window: leaving %{public}s %dx%d in it",
                   title, (int)frame.size.width, (int)frame.size.height);
            debugLog("the game asks for a window: leaving '%s' %dx%d in it", title, (int)frame.size.width, (int)frame.size.height);
            helperReport("NativeFullscreen", "notice", "the game asks for a window: leaving '%s' %dx%d in it",
                         title, (int)frame.size.width, (int)frame.size.height);
        }
        return;
    }

    gCandidate = nil;
    gReportedWindowed = NO;
    BOOL reentering = windowFlag(window, &kEnteredKey);
    BOOL wasReenter = windowFlag(window, &kReenterKey);
    gEntered = YES;
    setWindowFlag(window, &kEnteredKey, YES);
    setWindowFlag(window, &kReenterKey, NO);
    setWindowRequestValue(window, &kEnteredRequestKey, request);
    objc_setAssociatedObject(window, &kFrameBeforeKey, [NSValue valueWithRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL wineEligible = (window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary) != 0;
    if (overridesInstalled) {
        setWindowFlag(window, &kAdoptedKey, YES);
        // Re-entering, the window has the behaviour the overrides gave it.
        if (!wineEligible) setWindowFlag(window, &kCoversScreenKey, YES);
        [window adjustFullScreenBehavior:window.collectionBehavior];
        adjustWineWindowLevels();
    }

    const char *kind = reentering ? "re-entering" : "entering";
    const char *how = wineEligible ? requestReason(request) : " (a window covering the screen)";
    os_log(gLog, "[NativeFS] %{public}s native fullscreen: %{public}s %dx%d%{public}s",
           kind, title, (int)frame.size.width, (int)frame.size.height, how);
    debugLog("%s native fullscreen: '%s' %dx%d%s", kind, title, (int)frame.size.width, (int)frame.size.height, how);
    helperReport("NativeFullscreen", "notice", "%s native fullscreen: '%s' %dx%d%s",
                 kind, title, (int)frame.size.width, (int)frame.size.height, how);

    // Back into the Space Wine closed is no change; anything else follows a
    // request of the game's (or, forced, the launch).
    helperToggle(window, wasReenter ? kToggleRestore : kToggleGame);
}

/// A window left its Space: unless Wine closed it (and it goes back when
/// shown), it stays out until the game makes a new request. Main thread.
static void noteWindowLeftSpace(NSWindow *window, ToggleCause cause) {
    objc_setAssociatedObject(window, &kPlayerSpaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cause == kTogglePlayer && fullscreenRequest(window) != 0) {
        setWindowRequestValue(window, &kLeftRequestKey, fullscreenRequest(window));
        return;
    }
    if (!windowFlag(window, &kEnteredKey) || windowFlag(window, &kReenterKey)) return;
    setWindowRequestValue(window, &kLeftRequestKey, windowRequestValue(window, &kEnteredRequestKey));
}

/// The cause the will-enter or will-exit notification found, taken.
static ToggleCause takeTransitionCause(NSWindow *window) {
    ToggleCause cause = (ToggleCause)[objc_getAssociatedObject(window, &kTransitionCauseKey) intValue];
    objc_setAssociatedObject(window, &kTransitionCauseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cause;
}

static void noteTransitionCause(NSWindow *window) {
    objc_setAssociatedObject(window, &kTransitionCauseKey, gToggling == kToggleNone ? nil : @(gToggling),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// A window finished moving into (`entered`) or out of a Space: say who
/// moved it. Main thread.
static void noteTransitionEnded(NSWindow *window, BOOL entered) {
    ToggleCause cause = takeTransitionCause(window);
    if (entered && cause == kTogglePlayer) {
        objc_setAssociatedObject(window, &kPlayerSpaceKey, @(fullscreenRequest(window) + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (entered) {
        objc_setAssociatedObject(window, &kPlayerSpaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!entered) noteWindowLeftSpace(window, cause);
    if (cause == kTogglePlayer || cause == kToggleGame) {
        reportChange(cause, entered, "");
    } else {
        debugLog("window %ld %s its Space, by %s", (long)window.windowNumber, entered ? "entered" : "left",
                 cause == kToggleRestore ? "this file, putting it back" : "neither the player nor the game");
    }
}

/// Wine dedicates the process's main thread to a CFRunLoop (see __wine_main in
/// ntdll) and runs the Windows code on other threads, so blocks queued onto the
/// main run loop do get drained. This thread only schedules; every AppKit call
/// happens on the main thread.
///
/// It keeps watching after the first entry, for a window Wine closed the Space
/// of, for the game asking for a window or for fullscreen again, and for a new
/// game window -- slower once the game is in its Space or in the window it
/// asked for.
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
    // One attempt queued at a time: a main thread that is busy (a game
    // loading) would otherwise collect a block every interval and then run
    // them all at once.
    static atomic_bool queued = false;
    while (true) {
        if (!atomic_exchange(&queued, true)) {
            CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
                atomic_store(&queued, false);
                attemptFullscreen();
            });
            CFRunLoopWakeUp(mainLoop);
        }
        // Slower once in the Space or the window the game asked for, or once
        // it has given up and the game stays in its window: only a change is
        // still worth catching.
        usleep((useconds_t)((gEntered || gDecidedWindowed || gGaveUp ? kWatchInterval : kPollInterval) * USEC_PER_SEC));

        if (!gEntered && !gDecidedWindowed && !reportedGivingUp && nowSeconds() > giveUpAt) {
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

    const char *force = getenv("NATIVE_MACOS_FULLSCREEN_FORCE");
    gForced = force && strcmp(force, "1") == 0;
    gFollowsGame = !gForced && installDdrawModeWatch();

    os_log(gLog, "[NativeFS] armed");
    debugLog("armed%s", gForced ? ", forced" : gFollowsGame ? "" : ", not following the game");
    watchFullscreenTransitions();
    helperReport("NativeFullscreen", "notice", "armed in %s%s", getenv("NATIVE_MACOS_FULLSCREEN_EXE"),
                 gForced ? ": fullscreen whatever the game asks, as its launch says" : "");

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

/// Windows AppKit said will enter fullscreen and hasn't yet said did, the
/// same for leaving it, and whether one ever finished entering. Main thread
/// only.
static NSHashTable<NSWindow *> *gEnteringWindows;
static NSHashTable<NSWindow *> *gExitingWindows;
static BOOL gAWindowEntered = NO;

void watchFullscreenTransitions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
            gEnteringWindows = [NSHashTable weakObjectsHashTable];
            gExitingWindows = [NSHashTable weakObjectsHashTable];
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:NSWindowWillEnterFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows addObject:notification.object];
                noteTransitionCause(notification.object);
                transitionLog("window %ld will enter fullscreen", (long)[notification.object windowNumber]);
            }];
            [center addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows removeObject:notification.object];
                gAWindowEntered = YES;
                transitionLog("window %ld did enter fullscreen", (long)[notification.object windowNumber]);
                noteTransitionEnded(notification.object, YES);
            }];
            [center addObserverForName:NSWindowWillExitFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gExitingWindows addObject:notification.object];
                noteTransitionCause(notification.object);
            }];
            [center addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:nil
                            usingBlock:^(NSNotification *notification) {
                [gEnteringWindows removeObject:notification.object];
                [gExitingWindows removeObject:notification.object];
                transitionLog("window %ld did exit fullscreen", (long)[notification.object windowNumber]);
                noteTransitionEnded(notification.object, NO);
            }];
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
}

static BOOL windowIsMovingSpaces(NSWindow *window) {
    return [gEnteringWindows containsObject:window] || [gExitingWindows containsObject:window];
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
    if (!(gEntered && gAWindowEntered) && !gDecidedWindowed) return 0;
    for (NSWindow *window in gEnteringWindows) {
        if (windowIsEnteringFullscreen(window)) return 0;
    }
    // On its way out of a Space, at the game's asking, a window is moving
    // just as it is on its way in.
    return gExitingWindows.allObjects.count == 0;
}
