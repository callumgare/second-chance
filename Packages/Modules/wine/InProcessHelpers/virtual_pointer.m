//
//  virtual_pointer.m
//  Shows a game a pointer that goes where it's put, in a login where the
//  Mac's pointer can't be moved: so a test's clicks land in a test session.
//  Wine's Mac driver reads the pointer; so does SDL in ScummVM 2026.4 after a
//  warp (see armInScummVM below).
//
//  A test session (docs/dev-cli.md#test-sessions) is a user's login made
//  through Screen Sharing, running in the background. There the pointer stays
//  where Screen Sharing's viewer last put it (10,10 when it never has), and
//  CGWarpMouseCursorPosition, while it reports success, puts it back to
//  (10,10) whatever it was asked for. Wine reads the pointer for
//  GetCursorPos, and a game that holds the cursor -- cnc-ddraw's lock --
//  warps it to where the game's cursor should be and reads it straight back.
//  So a click WrappPuppeteer posts at the Exit button arrived at the button,
//  and the game, reading the pointer, found it in the picture's top-left
//  corner: every click landed there. Keys don't involve the pointer, so they
//  worked.
//
//  So where the pointer can't be moved, this keeps one of its own for Wine.
//  A warp moves it (and still goes through), and so does a move or click
//  puppet control posted, which it marks (kPuppetEventTag). Wine is given it
//  when it reads the pointer (+[NSEvent mouseLocation], for GetCursorPos) and
//  as the position of every other mouse event, all of which carry the stuck
//  pointer. It wraps winemac.so's imports of CGEventGetLocation and
//  CGWarpMouseCursorPosition, as display_below_notch.m does and on top of it
//  (helper_common.h), and +[NSEvent mouseLocation] for calls from winemac.so.
//
//  It arms only where puppet control does (WrappPuppeteer started the wrapp,
//  and this is the game's process), and only once a warp is seen not to
//  move the pointer: on a console the real pointer is left to do its job.
//  The check is made on the first read, when Wine first asks where the
//  pointer is.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh, after
//  display_below_notch.m; see docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <dlfcn.h>
#include <math.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <os/lock.h>
#include <unistd.h>

#include "helper_common.h"

static os_log_t gLog;

typedef CGPoint (*GetLocationFunction)(CGEventRef);
typedef CGError (*WarpFunction)(CGPoint);
// What winemac.so imported before these wrappers: the CoreGraphics
// functions, or display_below_notch.m's wrappers of them.
static GetLocationFunction gGetLocation;
static WarpFunction gWarp;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CGPoint gPointer;
static BOOL gHasPointer;
// Decided once, on the first read: whether the pointer here can be moved.
static BOOL gStuck;

static void setPointer(CGPoint point) {
    os_unfair_lock_lock(&gLock);
    gPointer = point;
    gHasPointer = YES;
    os_unfair_lock_unlock(&gLock);
}

static CGPoint realPointer(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = event ? gGetLocation(event) : CGPointZero;
    if (event) CFRelease(event);
    return point;
}

/// Whether a warp moves the pointer here: one point across and back, which
/// on a console nobody sees.
static BOOL pointerMoves(void) {
    CGPoint start = realPointer();
    CGPoint target = CGPointMake(start.x >= 1 ? start.x - 1 : start.x + 1, start.y);
    gWarp(target);
    usleep(50 * 1000);
    CGPoint landed = realPointer();
    gWarp(start);
    return fabs(landed.x - target.x) < 0.5 && fabs(landed.y - target.y) < 0.5;
}

static void decideOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStuck = !pointerMoves();
        if (gStuck) {
            CGPoint at = realPointer();
            helperReport("PuppetControl", "notice",
                         "the pointer can't be moved in this login (it stays at %.0f,%.0f); showing the game one that can",
                         at.x, at.y);
        } else {
            os_log(gLog, "[VirtualPointer] the pointer moves here; leaving it to Wine");
        }
    });
}

/// A move or a left or right button: what puppet control posts to aim and click.
static BOOL movesPointer(CGEventType type) {
    switch (type) {
    case kCGEventLeftMouseDown: case kCGEventLeftMouseUp:
    case kCGEventRightMouseDown: case kCGEventRightMouseUp:
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged: case kCGEventRightMouseDragged:
        return YES;
    default:
        return NO;
    }
}

static BOOL isMouseEvent(CGEventType type) {
    return movesPointer(type) || type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp ||
           type == kCGEventOtherMouseDragged || type == kCGEventNull;
}

/// Where Wine is told an event happened. The pointer follows the moves and
/// clicks puppet control posts, and only those, told by their mark
/// (kPuppetEventTag, in the event's user data). Everything else here carries the stuck pointer: the
/// window server's events, the moves AppKit makes up itself when the app is
/// activated (which a click does) -- those even carry this process's id --
/// and cursor_lock.m's middle clicks, aimed at the real pointer. Each would
/// drag the game's cursor back to the corner, so they are given the pointer.
static CGPoint virtualEventGetLocation(CGEventRef event) {
    CGPoint location = gGetLocation(event);
    decideOnce();
    if (!gStuck || !event) return location;
    CGEventType type = CGEventGetType(event);
    if (!isMouseEvent(type)) return location;
    if (movesPointer(type) && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kPuppetEventTag) {
        setPointer(location);
        return location;
    }
    os_unfair_lock_lock(&gLock);
    if (gHasPointer) location = gPointer;
    os_unfair_lock_unlock(&gLock);
    return location;
}

static CGError virtualWarpMouseCursorPosition(CGPoint point) {
    decideOnce();
    if (gStuck) setPointer(point);
    return gWarp(point);
}

typedef CGError (*DisplayMoveFunction)(CGDirectDisplayID, CGPoint);
static DisplayMoveFunction gDisplayMove;

/// ScummVM's: a move to a point on one display.
static CGError virtualDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint point) {
    decideOnce();
    if (gStuck) {
        CGPoint origin = CGDisplayBounds(display).origin;
        setPointer(CGPointMake(origin.x + point.x, origin.y + point.y));
    }
    return gDisplayMove(display, point);
}

// The image whose reads and warps are redirected: winemac.so in a Wine
// process, scummvm itself in ScummVM's.
static const struct mach_header_64 *gTarget;
static BOOL gArmed;
static IMP gMouseLocation;

static BOOL calledFromTarget(void *returnAddress) {
    Dl_info info;
    return dladdr(returnAddress, &info) && info.dli_fbase == (const void *)gTarget;
}

void virtualPointerNotePuppetMove(CGPoint point) {
    if (!gArmed) return;
    decideOnce();
    if (gStuck) setPointer(point);
}

// +[NSEvent mouseLocation] is how Wine's Mac driver reads the pointer for
// GetCursorPos, and how SDL (in ScummVM) reads it after a warp. It's in
// AppKit's coordinates, from the bottom of the main display, which Wine turns
// over with the display's height as it sees it. objc_msgSend tail-calls this,
// so the return address is in its caller.
static NSPoint virtualMouseLocation(id self, SEL _cmd) {
    NSPoint location = ((NSPoint (*)(id, SEL))gMouseLocation)(self, _cmd);
    if (!calledFromTarget(__builtin_return_address(0))) return location;
    decideOnce();
    if (!gStuck) return location;
    os_unfair_lock_lock(&gLock);
    BOOL has = gHasPointer;
    CGPoint pointer = gPointer;
    os_unfair_lock_unlock(&gLock);
    if (!has) return location;
    return NSMakePoint(pointer.x, wineMainDisplaySize().height - pointer.y);
}

/// Point every import of `symbol` ("_CGWarpMouseCursorPosition") the main
/// executable has at `replacement`, found by name through its indirect symbol
/// table: scummvm binds the old way, through lazy pointers that hold a stub
/// until the first call, so the address to look for isn't there yet (the
/// fishhook technique). Returns how many it replaced. basilisk_mac.m uses it
/// too, for Basilisk II's SDL_RenderPresent (helper_common.h).
int rebindMainImport(const char *symbol, void *replacement) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const void *)command;
        else if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)command;
    }
    if (!symtab || !dysymtab || !linkedit) return 0;
    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const void *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const void *)(linkeditBase + dysymtab->indirectsymoff);
    long pageSize = getpagesize();
    int replaced = 0;
    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        const struct section_64 *sections = (const void *)(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; j++) {
            uint32_t type = sections[j].flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **entries = (void **)((uintptr_t)slide + sections[j].addr);
            for (uint64_t k = 0; k < sections[j].size / sizeof(void *); k++) {
                uint32_t index = indirect[sections[j].reserved1 + k];
                if (index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                if (strcmp(strings + symbols[index].n_un.n_strx, symbol) != 0) continue;
                void *page = (void *)((uintptr_t)&entries[k] & ~(uintptr_t)(pageSize - 1));
                if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) continue;
                entries[k] = replacement;
                replaced++;
            }
        }
    }
    return replaced;
}

/// ScummVM, which loads this dylib through DYLD_INSERT_LIBRARIES with puppet
/// control alone. SDL takes a click's position from its event, but after a
/// warp of its own reads the pointer (+[NSEvent mouseLocation]); ScummVM
/// 2026.4 warps where 2026.3 didn't, and its clicks then landed where the
/// stuck pointer was. Its warps and reads are redirected in its own image,
/// and puppet control tells this where it aims (virtualPointerNotePuppetMove),
/// since SDL never asks CGEventGetLocation.
static void armInScummVM(void) {
    const struct mach_header_64 *main = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!main || strcmp(processIdentityBasename(_dyld_get_image_name(0)), "scummvm") != 0) return;
    gTarget = main;
    gGetLocation = CGEventGetLocation;
    gWarp = CGWarpMouseCursorPosition;
    gDisplayMove = CGDisplayMoveCursorToPoint;
    // Each is optional here: an import scummvm doesn't have needs no wrapper.
    int warps = rebindMainImport("_CGWarpMouseCursorPosition", (void *)virtualWarpMouseCursorPosition);
    int moves = rebindMainImport("_CGDisplayMoveCursorToPoint", (void *)virtualDisplayMoveCursorToPoint);
    os_log(gLog, "[VirtualPointer] scummvm: %d warp and %d move imports redirected", warps, moves);
    gMouseLocation = method_setImplementation(class_getClassMethod([NSEvent class], @selector(mouseLocation)), (IMP)virtualMouseLocation);
    gArmed = YES;
    os_log(gLog, "[VirtualPointer] wrapping scummvm's pointer");
}

__attribute__((constructor))
static void virtualPointerInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "VirtualPointer");
    // Armed as puppet_control.m is: `*` arms it in every process (an
    // installer's, under sc puppet --wine).
    const char *directory = getenv("SECOND_CHANCE_PUPPET_DIR");
    const char *exe = getenv("PUPPET_CONTROL_EXE");
    BOOL everywhere = exe && strcmp(exe, "*") == 0;
    if (!directory || !*directory || !(everywhere || processRunsExeNamedBy("PUPPET_CONTROL_EXE"))) return;

    const struct mach_header_64 *winemac = loadedImageNamed("winemac.so", NULL, NULL);
    if (!winemac) {
        armInScummVM();
        return;
    }
    gTarget = winemac;

    gGetLocation = (GetLocationFunction)belowNotchWinemacImport((void *)CGEventGetLocation);
    gWarp = (WarpFunction)belowNotchWinemacImport((void *)CGWarpMouseCursorPosition);
    // Both or neither: a pointer that warps go to but reads don't come from
    // (or the reverse) would be worse than the real one.
    if (replaceImageImport(winemac, (void *)gGetLocation, (void *)virtualEventGetLocation) == 0) {
        helperReport("PuppetControl", "warning", "couldn't redirect winemac.so's CGEventGetLocation; clicks use the real pointer");
        return;
    }
    if (replaceImageImport(winemac, (void *)gWarp, (void *)virtualWarpMouseCursorPosition) == 0) {
        replaceImageImport(winemac, (void *)virtualEventGetLocation, (void *)gGetLocation);
        helperReport("PuppetControl", "warning", "couldn't redirect winemac.so's CGWarpMouseCursorPosition; clicks use the real pointer");
        return;
    }
    gMouseLocation = method_setImplementation(class_getClassMethod([NSEvent class], @selector(mouseLocation)), (IMP)virtualMouseLocation);
    gArmed = YES;
    os_log(gLog, "[VirtualPointer] wrapping winemac.so's pointer");
}
