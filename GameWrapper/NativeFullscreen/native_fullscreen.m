//
//  native_fullscreen.m
//  Puts a Wine game window into real macOS fullscreen -- its own Space,
//  notch-aware, swipe-compatible -- without any Accessibility permission.
//
//  macOS only lets a process fullscreen its own NSWindow. Doing it from another
//  process means the Accessibility API or synthetic keystrokes, both of which
//  need the Accessibility TCC grant. So this code runs *inside* the Wine process
//  that owns the window and calls -toggleFullScreen: directly, which is exactly
//  what the green title-bar button does.
//
//  Getting loaded is the hard part, and it is why this is not a
//  DYLD_INSERT_LIBRARIES bundle. Wine launches each Windows process through
//  wine-preloader, which produces two dyld passes: the preloader reaches its
//  entry point before dyld's initializer phase, then loads the real wine binary
//  in a second pass. An inserted dylib belongs only to the first pass, so it gets
//  mapped into the game process but its constructor never runs. Instead,
//  patch-winemac.py adds a weak dependency on this dylib to winemac.so, putting
//  it in the second pass's image graph where dyld does run initializers.
//
//  winemac.so is loaded by every process that talks to Wine's Mac driver
//  (explorer.exe, the game, ...), so NATIVE_MACOS_FULLSCREEN_EXE names the one
//  executable that should act. Wine names each child's loader copy after the
//  Windows .exe it runs, which makes the main executable's basename a reliable
//  way to recognise the game process.
//
//  Built and installed by GameWrapper/setup-wine.sh.
//

#import <Cocoa/Cocoa.h>
#import <os/log.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// Require the frame to be unchanged across one extra poll before toggling, so a
// window caught mid-resize is not dragged into a wrongly-sized Space. Measured on
// Danger by Design, cnc-ddraw's window is already at its final size the moment it
// becomes visible and never moves again, so this is cheap insurance for other
// games rather than a wait this one needs -- keep it far below the ~1.6s the
// window takes to become key, which is latency the player would notice.
static const double kSettleSeconds = 0.2;
static const double kPollInterval = 0.1;
static const double kGiveUpSeconds = 90.0;

static os_log_t gLog;
static BOOL gFinished = NO;
static NSWindow *gCandidate = nil;
static NSRect gCandidateFrame;
static double gStableSince = 0.0;

static double nowSeconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / NSEC_PER_SEC;
}

/// Appends to NATIVE_MACOS_FULLSCREEN_LOG when that variable is set. Worth having
/// alongside os_log because this runs inside Wine child processes, whose log
/// output is otherwise awkward to attribute to a particular game.
static void debugLog(const char *format, ...) {
    const char *path = getenv("NATIVE_MACOS_FULLSCREEN_LOG");
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

/// The window winemac.drv itself considers eligible for native fullscreen.
///
/// Rather than guessing from window size, this defers to the driver's own
/// decision: adjustFullScreenBehavior: grants FullScreenPrimary only to
/// resizable, non-utility, parentless windows -- precisely the ones that get a
/// working green title-bar button -- and downgrades everything else to
/// FullScreenAuxiliary, which ignores -toggleFullScreen:. cnc-ddraw's transient
/// helper windows and Wine's hidden IME/message windows never qualify.
///
/// Main thread only: AppKit state is not safe to read from the watcher thread.
static NSWindow *findGameWindow(void) {
    NSWindow *best = nil;
    CGFloat bestArea = 0.0;

    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;

        // Something is already fullscreen, so leave this process alone.
        if (window.styleMask & NSWindowStyleMaskFullScreen) return nil;

        if (!(window.collectionBehavior & NSWindowCollectionBehaviorFullScreenPrimary)) continue;
        if (window.parentWindow) continue;

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
    if (gFinished) return;

    NSWindow *window = findGameWindow();
    if (!window) {
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

    gFinished = YES;

    const char *title = window.title.length ? window.title.UTF8String : "(untitled)";
    os_log(gLog, "[NativeFS] entering native fullscreen: %{public}s %dx%d",
           title, (int)frame.size.width, (int)frame.size.height);
    debugLog("entering native fullscreen: '%s' %dx%d",
             title, (int)frame.size.width, (int)frame.size.height);

    [window toggleFullScreen:nil];
}

/// Wine dedicates the process's main thread to a CFRunLoop (see __wine_main in
/// ntdll) and runs the Windows code on other threads, so blocks queued onto the
/// main run loop do get drained. This thread only schedules; every AppKit call
/// happens on the main thread.
static void *watcherMain(void *unused) {
    (void)unused;

    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    if (!mainLoop) {
        os_log_error(gLog, "[NativeFS] no main run loop; giving up");
        debugLog("no main run loop; giving up");
        return NULL;
    }

    double deadline = nowSeconds() + kGiveUpSeconds;
    while (!gFinished && nowSeconds() < deadline) {
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{ attemptFullscreen(); });
        CFRunLoopWakeUp(mainLoop);
        usleep((useconds_t)(kPollInterval * USEC_PER_SEC));
    }

    if (!gFinished) {
        os_log(gLog, "[NativeFS] no eligible window after %.0fs; staying windowed",
               kGiveUpSeconds);
        debugLog("no eligible window after %.0fs; staying windowed", kGiveUpSeconds);
    }
    return NULL;
}

static BOOL shouldActivate(void) {
    const char *wanted = getenv("NATIVE_MACOS_FULLSCREEN_EXE");
    if (!wanted || !*wanted) return NO;

    char path[PATH_MAX] = {0};
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return NO;

    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    return strcasecmp(name, wanted) == 0;
}

__attribute__((constructor))
static void nativeFullscreenInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "NativeFullscreen");

    if (!shouldActivate()) return;

    os_log(gLog, "[NativeFS] armed");
    debugLog("armed");

    pthread_t thread;
    if (pthread_create(&thread, NULL, watcherMain, NULL) == 0) {
        pthread_detach(thread);
    } else {
        os_log_error(gLog, "[NativeFS] could not start watcher thread");
        debugLog("could not start watcher thread");
    }
}
