//
//  screen_depth.m
//  Shows Wine's Mac driver a display of fewer colours than the Mac's, for a
//  program that won't run on anything but a 256-colour screen.
//
//  Old programs check how many colours the screen has before they start,
//  and some refuse anything but 256: Webmaster's installer says "Your screen
//  is not set to 256 colors" and quits. They ask GetDeviceCaps(BITSPIXEL)
//  of the screen. The prefix's EmulateModeset lets a program switch to an
//  8-bit mode, but Wine 10's Mac driver answers BITSPIXEL itself, with the
//  depth of the Mac display's own mode, read once (winemac.drv/gdi.c's
//  device_init): always 32, whatever mode the session is in. (Wine 10.20
//  stopped overriding it, upstream 1907a5b039, so BITSPIXEL follows the
//  emulated mode there; Director's projector dies at once under Rosetta on
//  every Wine since, so Wine 10 is what such a program runs on.)
//
//  The driver reads that depth, and the depth of each of the display's
//  modes (display.c's display_mode_bits_per_pixel), through
//  CGDisplayModeCopyPixelEncoding. So this file replaces winemac.so's
//  imported address of it (its __got entry, as display_below_notch.m does
//  for its imports) with one that names the pixel encoding of the depth
//  asked for. Wine then sees a Mac display of that depth, in every way it
//  looks: GetDeviceCaps says it, the display's modes are of it, and with
//  EmulateModeset the modes Wine offers are of it and the depths below.
//  What Wine draws is unchanged: its window surfaces are 32-bit whatever
//  the display says, and the program's 8-bit picture is converted to them as
//  any DIB is.
//
//  It acts in every Wine process of the session, as the displays and their
//  modes are registered by explorer.exe and the program takes them from
//  there. Armed by SCREEN_DEPTH (8 or 16), which a launch or a build step
//  that says --wine.colors sets for its session (Wine.sessionVariables);
//  unset, or any other value, leaves the display as it is.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh; see
//  docs/wine-in-process-helpers.md#screen-depth.
//

#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#import <os/log.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <string.h>

#include "helper_common.h"

static os_log_t gLog;
static CFStringRef gEncoding;

// CGDisplayModeCopyPixelEncoding is deprecated, but it is what winemac.so
// imports, and so what has to be replaced.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void *const kCopyPixelEncoding = (void *)CGDisplayModeCopyPixelEncoding;
#pragma clang diagnostic pop

/// What winemac.so gets for a mode's pixel encoding: the depth asked for,
/// owned by the caller as the real function's answer is.
static CFStringRef screenDepthCopyPixelEncoding(CGDisplayModeRef mode) {
    (void)mode;
    return CFRetain(gEncoding);
}

/// The pixel encoding Wine's Mac driver reads as `depth`, or NULL for one it
/// has none for.
static CFStringRef encodingForDepth(int depth) {
    switch (depth) {
    case 8: return CFSTR(IO8BitIndexedPixels);
    case 16: return CFSTR(IO16BitDirectPixels);
    default: return NULL;
    }
}

__attribute__((constructor))
static void screenDepthInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "ScreenDepth");
    const char *armed = getenv("SCREEN_DEPTH");
    if (!armed || !*armed) return;
    // Only the program's process reports, so the log gets one line; a build
    // step's program has no name for it, so there every process does.
    const char *program = getenv("SCREEN_DEPTH_EXE");
    BOOL reports = !program || !*program || processRunsExeNamedBy("SCREEN_DEPTH_EXE");

    int depth = atoi(armed);
    gEncoding = encodingForDepth(depth);
    if (!gEncoding) {
        if (reports) helperReport("ScreenDepth", "error", "SCREEN_DEPTH=%s isn't a depth it can show (8 or 16)", armed);
        return;
    }
    const struct mach_header_64 *winemac = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(processIdentityBasename(_dyld_get_image_name(i)), "winemac.so") == 0) {
            winemac = (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    if (!winemac) {
        // Not a Wine process (ScummVM loads this dylib too): nothing to do.
        return;
    }
    int replaced = replaceImageImport(winemac, kCopyPixelEncoding, (void *)screenDepthCopyPixelEncoding);
    if (replaced == 0) {
        if (reports) helperReport("ScreenDepth", "error", "couldn't redirect winemac.so's CGDisplayModeCopyPixelEncoding; the screen keeps the Mac's colours");
        return;
    }
    os_log(gLog, "showing Wine a %d-bit display (%d imports redirected)", depth, replaced);
    if (reports) helperReport("ScreenDepth", "notice", "armed: the screen has %d-bit colour", depth);
}
