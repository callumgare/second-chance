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

static NSApplicationTerminateReply reportingShouldTerminate(id self, SEL _cmd, NSApplication *sender) {
    helperReport("QuitWatch", "notice", "quit requested");
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
    gWineFlushBuffer = method_setImplementation(flush, (IMP)reportingFlushBuffer);
    gWineShouldTerminate = method_setImplementation(terminate, (IMP)reportingShouldTerminate);
    helperReport("QuitWatch", "notice", "armed in %s", getenv("QUIT_WATCH_EXE"));
}
