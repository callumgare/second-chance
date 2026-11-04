//
//  hidden_windows.m
//  Keeps a Wine program's windows, and its Dock icon, off the screen until
//  asked to show them: Big Fish's Game Manager, which Second Chance drives
//  through its page and whose window people should only see to sign in, as
//  Steam's `-silent` gives Steam. Unlike Steam, the Game Manager has no
//  option that starts it without its window.
//
//  - Windows. AppKit puts a window on screen through
//    -[NSWindow orderWindow:relativeTo:], which every orderFront: and
//    makeKeyAndOrderFront: comes down to, and which Wine's Mac driver calls
//    for each window the program shows. While hidden, a window ordered in is
//    remembered instead, and each window already on screen is ordered out
//    and remembered; when shown, the remembered ones are ordered back in. A
//    window the program itself ordered out (or closed) since is forgotten.
//  - The Dock icon. Wine gives a program its Dock icon and activates it in
//    -[WineApplicationController transformProcessToForeground:], as its
//    first window is shown. While hidden that does nothing, and the app is
//    an accessory (no Dock icon, never active); when shown it runs as Wine
//    would have.
//
//  Shown while the file HIDDEN_WINDOWS_SHOW_FILE names exists, hidden
//  otherwise (and always, if it's unset): the main thread looks four times a
//  second. Only the Game Manager's sign-in creates it (BigFishGameManager).
//
//  Armed by HIDDEN_WINDOWS_EXE, in the process running that .exe, or in
//  every process that has it when it is `*`: a Wine program passes its
//  environment on to the programs it starts, so that takes in what the Game
//  Manager runs during a build -- the game's installer, Microsoft's DirectX
//  setup -- as well as the Game Manager itself.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#include "helper_common.h"

@interface NSObject (WineApplicationControllerHiddenWindowsMethods)
+ (id)sharedController;
- (void)transformProcessToForeground:(BOOL)activateIfTransformed;
@end

// Main thread only, as AppKit's ordering is.
static BOOL gHidden = YES;
/// Windows that would be on screen if they weren't hidden.
static NSHashTable<NSWindow *> *gWanted;
static IMP gOrderWindow;
static IMP gTransformToForeground;
static NSString *gShowFile;
/// Watches for the show file, for the life of the process.
static dispatch_source_t gShowFileTimer;

static void callOrderWindow(NSWindow *window, NSWindowOrderingMode place, NSInteger relativeTo) {
    ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))gOrderWindow)(window, @selector(orderWindow:relativeTo:), place, relativeTo);
}

static void hidingOrderWindow(NSWindow *self, SEL _cmd, NSWindowOrderingMode place, NSInteger relativeTo) {
    if (place == NSWindowOut) {
        [gWanted removeObject:self];
    } else if (gHidden) {
        [gWanted addObject:self];
        return;
    }
    callOrderWindow(self, place, relativeTo);
}

static void hidingTransformToForeground(id self, SEL _cmd, BOOL activateIfTransformed) {
    if (gHidden) return;
    ((void (*)(id, SEL, BOOL))gTransformToForeground)(self, _cmd, activateIfTransformed);
}

static void hide(void) {
    gHidden = YES;
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible) continue;
        callOrderWindow(window, NSWindowOut, 0);
        [gWanted addObject:window];
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    helperReport("HiddenWindows", "notice", "windows hidden");
}

static void show(void) {
    gHidden = NO;
    id controller = [NSClassFromString(@"WineApplicationController") sharedController];
    if (controller && gTransformToForeground) {
        ((void (*)(id, SEL, BOOL))gTransformToForeground)(controller, @selector(transformProcessToForeground:), YES);
    } else {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
    for (NSWindow *window in gWanted.allObjects) {
        callOrderWindow(window, NSWindowAbove, 0);
    }
    [gWanted removeAllObjects];
    [NSApp activateIgnoringOtherApps:YES];
    helperReport("HiddenWindows", "notice", "windows shown");
}

static void watchShowFile(void) {
    gShowFileTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gShowFileTimer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gShowFileTimer, ^{
        BOOL wantShown = gShowFile && [[NSFileManager defaultManager] fileExistsAtPath:gShowFile];
        if (wantShown == !gHidden) return;
        if (wantShown) show(); else hide();
    });
    dispatch_resume(gShowFileTimer);
}

/// Whether this process is one whose windows are hidden.
static int armedHere(void) {
    const char *wanted = getenv("HIDDEN_WINDOWS_EXE");
    if (wanted && strcmp(wanted, "*") == 0) return 1;
    return processRunsExeNamedBy("HIDDEN_WINDOWS_EXE");
}

__attribute__((constructor))
static void hiddenWindowsInit(void) {
    if (!armedHere()) return;

    Class controller = NSClassFromString(@"WineApplicationController");
    if (!class_getInstanceMethod(controller, @selector(transformProcessToForeground:))) {
        helperReport("HiddenWindows", "warning", "no -[WineApplicationController transformProcessToForeground:]; its windows are shown");
        return;
    }
    const char *showFile = getenv("HIDDEN_WINDOWS_SHOW_FILE");
    gShowFile = showFile && *showFile ? [NSString stringWithUTF8String:showFile] : nil;
    gWanted = [NSHashTable weakObjectsHashTable];
    gOrderWindow = replaceOwnMethod([NSWindow class], @selector(orderWindow:relativeTo:), (IMP)hidingOrderWindow);
    gTransformToForeground = replaceOwnMethod(controller, @selector(transformProcessToForeground:), (IMP)hidingTransformToForeground);
    // The main queue runs once Wine has started Cocoa.
    dispatch_async(dispatch_get_main_queue(), ^{ watchShowFile(); });
    helperReport("HiddenWindows", "notice", "armed in %s (pid %d)", getenv("HIDDEN_WINDOWS_EXE"), getpid());
}
