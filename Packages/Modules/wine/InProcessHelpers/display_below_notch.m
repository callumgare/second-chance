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
//  replace winemac.so's imported addresses (its __got or lazy pointer
//  entries) with wrappers,
//  so nothing else in the process is affected. It acts in every Wine process
//  rather than only the game's because the Win32 desktop's displays are
//  registered by explorer.exe, and the game takes them from there.
//
//  Armed by NATIVE_FULLSCREEN_BELOW_NOTCH, which a wrapp sets on itself
//  (Wine.wrappSessionVariables), so Second Chance's own installer
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
#include <mach-o/nlist.h>
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

enum { kMaxImportLibraries = 256 };

static BOOL isDylibLoadCommand(uint32_t cmd) {
    return cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB
        || cmd == LC_LOAD_UPWARD_DYLIB || cmd == LC_LAZY_LOAD_DYLIB;
}

/// The address binding `symbol` (named `name`, without its underscore) in
/// `image` would give: looked up in the library its two-level ordinal names,
/// and through what that library re-exports, as dyld does. A flat lookup
/// could find a same-named function of another image first. Falls back to
/// that flat lookup for a flat-namespace image, a special ordinal, or a
/// library that can't be named from here (an @rpath one).
static void *importedAddress(const struct mach_header_64 *image, const char *const *libraries, uint32_t libraryCount,
                             const struct nlist_64 *symbol, const char *name) {
    uint32_t ordinal = GET_LIBRARY_ORDINAL(symbol->n_desc);
    if ((image->flags & MH_TWOLEVEL) && ordinal >= 1 && ordinal <= libraryCount && ordinal <= kMaxImportLibraries) {
        void *handle = dlopen(libraries[ordinal - 1], RTLD_NOLOAD | RTLD_LAZY);
        if (handle) {
            void *address = dlsym(handle, name);
            dlclose(handle);
            return address;
        }
    }
    return dlsym(RTLD_DEFAULT, name);
}

/// Each entry of `image`'s import pointer sections (__got, __nl_symbol_ptr,
/// __la_symbol_ptr, whatever their segment) that is `original`: one holding
/// that address, or a lazy pointer not yet bound (still pointing into the
/// image's own stub helper) whose symbol resolves to it. A build for macOS 12
/// or later binds every import up front, into __got; one for an older macOS
/// (Gcenx's, wine-mac-builds') binds its calls lazily, through
/// __la_symbol_ptr, so until the first call the address isn't there to find.
/// With `replacement`, points each at it; without, only counts them.
static int visitImageImports(const struct mach_header_64 *image, void *original, void *replacement) {
    if (!image || !original) return 0;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL, *text = NULL;
    const char *libraries[kMaxImportLibraries];
    uint32_t libraryCount = 0;
    const struct load_command *command = (const struct load_command *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (isDylibLoadCommand(command->cmd)) {
            // Each library the image links counts as the next ordinal, from 1,
            // whatever kind of link it is.
            const struct dylib_command *dylib = (const void *)command;
            if (libraryCount < kMaxImportLibraries) libraries[libraryCount] = (const char *)dylib + dylib->dylib.name.offset;
            libraryCount++;
        } else if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const void *)command;
        else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
            else if (strcmp(segment->segname, SEG_TEXT) == 0) text = segment;
        }
    }
    if (!text) return 0;
    uintptr_t slide = (uintptr_t)image - (uintptr_t)text->vmaddr;
    uintptr_t textStart = (uintptr_t)image, textEnd = textStart + (uintptr_t)text->vmsize;
    const struct nlist_64 *symbols = NULL;
    const char *strings = NULL;
    const uint32_t *indirect = NULL;
    if (symtab && dysymtab && linkedit) {
        uintptr_t linkeditBase = slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
        symbols = (const void *)(linkeditBase + symtab->symoff);
        strings = (const char *)(linkeditBase + symtab->stroff);
        indirect = (const void *)(linkeditBase + dysymtab->indirectsymoff);
    }
    long pageSize = getpagesize();
    int found = 0;
    command = (const struct load_command *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        // A segment dyld makes read-only once it's bound goes back to that.
        BOOL readOnlyAfter = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
        const struct section_64 *sections = (const void *)(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; j++) {
            uint32_t type = sections[j].flags & SECTION_TYPE;
            BOOL lazy = type == S_LAZY_SYMBOL_POINTERS;
            if (!lazy && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **entries = (void **)(slide + (uintptr_t)sections[j].addr);
            for (uint64_t k = 0; k < sections[j].size / sizeof(void *); k++) {
                BOOL match = entries[k] == original;
                if (!match && lazy && indirect && (uintptr_t)entries[k] >= textStart && (uintptr_t)entries[k] < textEnd) {
                    uint32_t index = indirect[sections[j].reserved1 + k];
                    if (index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                    const char *name = strings + symbols[index].n_un.n_strx;
                    match = name[0] == '_' && importedAddress(image, libraries, libraryCount, &symbols[index], name + 1) == original;
                }
                if (!match) continue;
                if (!replacement) { found++; continue; }
                void *page = (void *)((uintptr_t)&entries[k] & ~(uintptr_t)(pageSize - 1));
                if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) continue;
                entries[k] = replacement;
                if (readOnlyAfter) mprotect(page, pageSize, PROT_READ);
                found++;
            }
        }
    }
    return found;
}

int replaceImageImport(const struct mach_header_64 *image, void *original, void *replacement) {
    return replacement ? visitImageImports(image, original, replacement) : 0;
}

int imageImports(const struct mach_header_64 *image, void *original) {
    return visitImageImports(image, original, NULL);
}

static int replaceWinemacImport(void *original, void *replacement) {
    return replaceImageImport(gWinemac, original, replacement);
}

void *belowNotchWinemacImport(void *original) {
    // gScreenFrame is set only once every replacement is in.
    if (!gScreenFrame) return original;
    if (original == (void *)CGEventGetLocation) return (void *)belowNotchEventGetLocation;
    if (original == (void *)CGWarpMouseCursorPosition) return (void *)belowNotchWarpMouseCursorPosition;
    return original;
}

__attribute__((constructor))
static void displayBelowNotchInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "BelowNotch");
    const char *armed = getenv("NATIVE_FULLSCREEN_BELOW_NOTCH");
    if (!armed || strcmp(armed, "1") != 0) return;

    gWinemac = loadedImageNamed("winemac.so", NULL, NULL);
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
        if (imageImports(gWinemac, imports[i].original) == 0) {
            if (inGame) helperReport("NativeFullscreen", "warning", "winemac.so doesn't import %s; a notched display is shown to the game whole", imports[i].name);
            return;
        }
    }
    // And all or nothing in the patching too: an entry that couldn't be made
    // writable puts back the ones already replaced.
    size_t count = sizeof(imports) / sizeof(*imports);
    for (size_t i = 0; i < count; i++) {
        if (replaceWinemacImport(imports[i].original, imports[i].replacement) > 0) continue;
        for (size_t j = 0; j < i; j++) replaceWinemacImport(imports[j].replacement, imports[j].original);
        if (inGame) helperReport("NativeFullscreen", "warning", "couldn't redirect winemac.so's %s; a notched display is shown to the game whole", imports[i].name);
        return;
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

CGSize wineMainDisplaySize(void) {
    // gScreenFrame is set only once the replacements are in.
    if (gScreenFrame && belowNotchActive()) {
        return CGSizeMake(CGDisplayModeGetWidth(gBelowNotchMode), CGDisplayModeGetHeight(gBelowNotchMode));
    }
    return CGDisplayBounds(CGMainDisplayID()).size;
}
