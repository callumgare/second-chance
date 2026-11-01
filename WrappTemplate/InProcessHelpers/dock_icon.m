//
//  dock_icon.m
//  Leaves the game's process out of the Dock and the app switcher, so the
//  wrapp's own icon is the game's only one.
//
//  Wine's Mac driver makes the process it runs in a regular app the first
//  time it shows a window (-[WineApplicationController
//  transformProcessToForeground:]), which gives the game an icon of its own
//  beside the wrapp's, named after Wine and showing the .exe's icon. Here that
//  method still runs once, building Wine's menu, but the process becomes an
//  accessory app rather than a regular one: it can still be active, take the
//  keyboard and go fullscreen, but has no Dock icon and no place in Cmd-Tab.
//  The wrapp stays in the Dock, and brings the game forward when it is
//  clicked there or chosen in Cmd-Tab (WrappTemplate's AppDelegate).
//
//  Armed by DOCK_ICON_EXE, in the process running that .exe.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <os/log.h>

#include "helper_common.h"

static os_log_t gLog;
static IMP gWineTransformProcessToForeground;
static IMP gSetActivationPolicy;
/// Set while Wine's transform runs, so its request for a regular app is
/// turned into one for an accessory; main thread only.
static BOOL gTransforming;
static BOOL gTransformed;

static BOOL accessoryActivationPolicy(NSApplication *self, SEL _cmd, NSApplicationActivationPolicy policy) {
    if (gTransforming && policy == NSApplicationActivationPolicyRegular) {
        policy = NSApplicationActivationPolicyAccessory;
        os_log(gLog, "[DockIcon] Wine made the game a regular app; making it an accessory instead");
    }
    return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))gSetActivationPolicy)(self, _cmd, policy);
}

/// Wine's transform runs whenever a window is shown, and does its work only
/// while the app isn't regular, which an accessory never is: so after the
/// first time it is skipped, or each window would build the menu again and
/// try to activate the app.
static void transformProcessToForegroundOnce(id self, SEL _cmd, BOOL activateIfTransformed) {
    if (gTransformed) return;
    gTransformed = YES;
    gTransforming = YES;
    ((void (*)(id, SEL, BOOL))gWineTransformProcessToForeground)(self, _cmd, activateIfTransformed);
    gTransforming = NO;
    helperReport("DockIcon", "notice", "the game has no Dock icon of its own");
}

__attribute__((constructor))
static void dockIconInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "DockIcon");
    if (!processRunsExeNamedBy("DOCK_ICON_EXE")) return;

    Method transform = class_getInstanceMethod(NSClassFromString(@"WineApplicationController"),
                                               @selector(transformProcessToForeground:));
    Method setPolicy = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
    if (!transform || !setPolicy) {
        helperReport("DockIcon", "warning", "no -[WineApplicationController transformProcessToForeground:]; the game keeps a Dock icon of its own");
        return;
    }
    gSetActivationPolicy = method_setImplementation(setPolicy, (IMP)accessoryActivationPolicy);
    gWineTransformProcessToForeground = method_setImplementation(transform, (IMP)transformProcessToForegroundOnce);
    helperReport("DockIcon", "notice", "armed in %s", getenv("DOCK_ICON_EXE"));
}
