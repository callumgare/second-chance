//
//  display_below_notch.m
//  On a display with a notch, shows Wine only the part of the display below
//  it, so a game in a fullscreen Space gets mouse positions that match its
//  picture.
//
//  A fullscreen Space on a notched display leaves out the strip the notch
//  sits in: on a 1512x982 display, the game's window is 1512x945. Wine tells
//  the game its window has shrunk, but a Direct3D game keeps drawing for the
//  whole display, and Direct3D squeezes that picture into the window while
//  mouse positions stay as they are. Measured on Secrets Can Kill Remastered,
//  the game's cursor sat 12 points above the real one near the top of the
//  screen and 37 points above it near the bottom.
//
//  So, in every Wine process of a wrapp, this file makes Wine's Mac driver
//  (winemac.so) see a display that ends at the notch:
//
//  - -[NSScreen frame] and -visibleFrame, when winemac.so asks, leave out the
//    strip. Wine builds its displays and converts window and cursor positions
//    from these.
//  - CGDisplayCopyDisplayMode returns the display's own below-notch mode
//    (1512x945 on that display), which Wine sizes the Win32 desktop from.
//    CGDisplaySetDisplayMode asked for that mode does nothing, so Wine
//    restoring "the original mode" never really switches the display.
//  - CGEventGetLocation and CGWarpMouseCursorPosition, which give and take
//    positions from the true top of the display, are shifted by the strip.
//
//  The first is a method replacement that looks at its caller; the others
//  replace winemac.so's imported addresses (its __got entries) with wrappers,
//  so nothing else in the process is affected. It acts in every Wine process
//  rather than only the game's because the Win32 desktop's displays are
//  registered by explorer.exe, and the game takes them from there.
//
//  Armed by NATIVE_FULLSCREEN_BELOW_NOTCH, which a wrapp sets on itself
//  (WineEnvironment.wrappSessionVariables), so Second Chance's own installer
//  runs never see it. It does nothing unless the main display is a built-in
//  one with a notch, and stops shifting anything if that display's mode
//  changes while the game runs.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/mman.h>
#include <unistd.h>

#include "helper_common.h"

static os_log_t gLog;
static const struct mach_header_64 *gWinemac;

// Set once by findNotch(); read from any thread afterwards.
static CGDirectDisplayID gDisplay;
static CGDisplayModeRef gBelowNotchMode;
static CGFloat gFullHeight;   // the display's height in points with the strip
static CGFloat gStrip;        // the strip's height in points; 0 when there is no notch

/// The below-notch mode of a notched built-in main display: the same width
/// and pixel width as the current mode, 2-6% shorter (1512x945 against
/// 1512x982). macOS offers it so that apps can run below the notch.
static void findNotch(void) {
    CGDirectDisplayID display = CGMainDisplayID();
    if (!CGDisplayIsBuiltin(display)) return;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    if (!current) return;
    size_t width = CGDisplayModeGetWidth(current), height = CGDisplayModeGetHeight(current);
    size_t pixelWidth = CGDisplayModeGetPixelWidth(current);
    CGDisplayModeRelease(current);

    // Without this option the list leaves out the HiDPI modes, the
    // below-notch one among them.
    NSDictionary *options = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
    CGDisplayModeRef best = NULL;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t h = CGDisplayModeGetHeight(mode);
        if (CGDisplayModeGetWidth(mode) != width || CGDisplayModeGetPixelWidth(mode) != pixelWidth) continue;
        if (h >= height || h < height * 0.94 || h > height * 0.98) continue;
        if (!best || h > CGDisplayModeGetHeight(best)) best = mode;
    }
    if (best) {
        gBelowNotchMode = CGDisplayModeRetain(best);
        gDisplay = display;
        gFullHeight = height;
        gStrip = height - CGDisplayModeGetHeight(best);
    }
    if (modes) CFRelease(modes);
}

static void ensureNotchFound(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ findNotch(); });
}

/// Whether to show Wine the display below the notch right now: there is a
/// notch, and the display is still in the mode it was found in.
static BOOL belowNotchActive(void) {
    ensureNotchFound();
    return gStrip > 0 && CGDisplayBounds(gDisplay).size.height == gFullHeight;
}

static BOOL calledFromWinemac(void *returnAddress) {
    Dl_info info;
    return gWinemac && dladdr(returnAddress, &info) && info.dli_fbase == (const void *)gWinemac;
}

// MARK: - NSScreen

static IMP gScreenFrame, gScreenVisibleFrame;

static NSRect withoutStrip(NSScreen *screen, NSRect rect) {
    if (!belowNotchActive() || [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] != gDisplay) return rect;
    NSRect below = ((NSRect (*)(id, SEL))gScreenFrame)(screen, @selector(frame));
    below.size.height -= gStrip;   // AppKit's origin is the bottom, so this cuts the top
    return NSIntersectionRect(rect, below);
}

// objc_msgSend tail-calls these, so the return address is in their caller.
static NSRect belowNotchFrame(NSScreen *self, SEL _cmd) {
    NSRect frame = ((NSRect (*)(id, SEL))gScreenFrame)(self, _cmd);
    return calledFromWinemac(__builtin_return_address(0)) ? withoutStrip(self, frame) : frame;
}

static NSRect belowNotchVisibleFrame(NSScreen *self, SEL _cmd) {
    NSRect frame = ((NSRect (*)(id, SEL))gScreenVisibleFrame)(self, _cmd);
    return calledFromWinemac(__builtin_return_address(0)) ? withoutStrip(self, frame) : frame;
}

// MARK: - CoreGraphics, as winemac.so imports it

static CGDisplayModeRef belowNotchCopyDisplayMode(CGDirectDisplayID display) {
    if (belowNotchActive() && (display == gDisplay || (display == kCGDirectMainDisplay && CGMainDisplayID() == gDisplay)))
        return CGDisplayModeRetain(gBelowNotchMode);
    return CGDisplayCopyDisplayMode(display);
}

static CGError belowNotchSetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options) {
    if (gBelowNotchMode && mode &&
        CGDisplayModeGetWidth(mode) == CGDisplayModeGetWidth(gBelowNotchMode) &&
        CGDisplayModeGetHeight(mode) == CGDisplayModeGetHeight(gBelowNotchMode) &&
        CGDisplayModeGetPixelHeight(mode) == CGDisplayModeGetPixelHeight(gBelowNotchMode)) {
        os_log(gLog, "[BelowNotch] Wine asked for the below-notch mode; the display stays as it is");
        return kCGErrorSuccess;
    }
    return CGDisplaySetDisplayMode(display, mode, options);
}

static CGPoint belowNotchEventGetLocation(CGEventRef event) {
    CGPoint point = CGEventGetLocation(event);
    if (belowNotchActive()) point.y -= gStrip;
    return point;
}

static CGError belowNotchWarpMouseCursorPosition(CGPoint point) {
    if (belowNotchActive()) point.y += gStrip;
    return CGWarpMouseCursorPosition(point);
}

/// Point winemac.so's imported address of `original` at `replacement`. Its
/// imports are bound before this dylib's constructor runs (dyld binds a
/// whole batch of images before running any initializer), so the entries
/// already hold the real addresses. Returns how many entries it replaced.
static int replaceWinemacImport(void *original, void *replacement) {
    unsigned long size = 0;
    void **entries = (void **)getsectiondata(gWinemac, "__DATA_CONST", "__got", &size);
    long pageSize = getpagesize();
    int replaced = 0;
    for (unsigned long i = 0; entries && i < size / sizeof(void *); i++) {
        if (entries[i] != original) continue;
        void *page = (void *)((uintptr_t)&entries[i] & ~(uintptr_t)(pageSize - 1));
        if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) continue;
        entries[i] = replacement;
        mprotect(page, pageSize, PROT_READ);
        replaced++;
    }
    return replaced;
}

__attribute__((constructor))
static void displayBelowNotchInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "BelowNotch");
    const char *armed = getenv("NATIVE_FULLSCREEN_BELOW_NOTCH");
    if (!armed || strcmp(armed, "1") != 0) return;

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(processIdentityBasename(_dyld_get_image_name(i)), "winemac.so") == 0) {
            gWinemac = (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    // Only the game's process reports, so the wrapp's log gets one line.
    BOOL inGame = processRunsExeNamedBy("NATIVE_MACOS_FULLSCREEN_EXE");
    if (!gWinemac) {
        if (inGame) helperReport("NativeFullscreen", "warning", "winemac.so not found; a notched display is shown to the game whole");
        return;
    }

    struct { void *original, *replacement; const char *name; } imports[] = {
        { (void *)CGDisplayCopyDisplayMode, (void *)belowNotchCopyDisplayMode, "CGDisplayCopyDisplayMode" },
        { (void *)CGDisplaySetDisplayMode, (void *)belowNotchSetDisplayMode, "CGDisplaySetDisplayMode" },
        { (void *)CGEventGetLocation, (void *)belowNotchEventGetLocation, "CGEventGetLocation" },
        { (void *)CGWarpMouseCursorPosition, (void *)belowNotchWarpMouseCursorPosition, "CGWarpMouseCursorPosition" },
    };
    // All or nothing: a display shrunk for some of Wine's conversions and
    // not others would put clicks in the wrong place everywhere.
    for (size_t i = 0; i < sizeof(imports) / sizeof(*imports); i++) {
        unsigned long size = 0;
        void **entries = (void **)getsectiondata(gWinemac, "__DATA_CONST", "__got", &size);
        BOOL found = NO;
        for (unsigned long j = 0; entries && j < size / sizeof(void *); j++) found |= entries[j] == imports[i].original;
        if (!found) {
            if (inGame) helperReport("NativeFullscreen", "warning", "winemac.so doesn't import %s; a notched display is shown to the game whole", imports[i].name);
            return;
        }
    }
    for (size_t i = 0; i < sizeof(imports) / sizeof(*imports); i++) {
        replaceWinemacImport(imports[i].original, imports[i].replacement);
    }
    gScreenFrame = method_setImplementation(class_getInstanceMethod([NSScreen class], @selector(frame)), (IMP)belowNotchFrame);
    gScreenVisibleFrame = method_setImplementation(class_getInstanceMethod([NSScreen class], @selector(visibleFrame)), (IMP)belowNotchVisibleFrame);

    if (inGame) {
        ensureNotchFound();
        if (gStrip > 0) {
            helperReport("NativeFullscreen", "notice", "showing Wine the display below the notch: %.0fx%.0f, leaving out %.0f points",
                         (double)CGDisplayModeGetWidth(gBelowNotchMode), (double)CGDisplayModeGetHeight(gBelowNotchMode), (double)gStrip);
        }
    }
    os_log(gLog, "[BelowNotch] armed, strip %.0f", (double)gStrip);
}
