//
//  ddraw_mode_watch.m
//  Tells native_fullscreen.m whether a DirectDraw game asked for fullscreen:
//  whether it set a display mode through cnc-ddraw.
//
//  Second Chance runs cnc-ddraw with windowed=true, so a game that asks
//  DirectDraw for exclusive fullscreen and a display mode
//  (DDSCL_FULLSCREEN, SetDisplayMode) gets the same window as one that asks
//  for a normal window (DDSCL_NORMAL): cnc-ddraw gives either a resizable,
//  captioned window the size of the mode, and blocks the game's own changes
//  to its window's style (SetWindowLong, ShowWindow's maximise). Nothing Wine's
//  Mac driver sees of the window tells the two apart.
//
//  What does: when the game itself sets the display mode, cnc-ddraw ends
//  dd_SetDisplayMode by sending the window two private messages,
//  WM_SIZE_DDRAW and WM_DISPLAYCHANGE_DDRAW (WM_APP+114 and +116, wParam the
//  depth, lParam the size), which its window procedure hands the game as
//  WM_SIZE and WM_DISPLAYCHANGE. A mode it makes up for a DDSCL_NORMAL game
//  (fake_mode, or the window's size) sends neither. In Wine 10 a sent
//  message goes through win32u's NtUserMessageCall, a system call into
//  win32u.so, in this process's Unix side, where this file can see it.
//
//  The request lasts until cnc-ddraw lets go of the window: releasing
//  DirectDraw puts the game's window procedure back, and attaching again
//  replaces it (SetWindowLong(GWLP_WNDPROC) both times, NtUserSetWindowLong
//  or NtUserSetWindowLongPtr). A game switching from fullscreen to a window
//  (Icy Tower's Options › GFX) releases DirectDraw and starts again with
//  DDSCL_NORMAL; one switching back starts again and sets a mode.
//
//  To see those calls, the entries for NtUserMessageCall,
//  NtUserSetWindowLong and NtUserSetWindowLongPtr in win32u.so's system call
//  table are pointed at wrappers that note them and call on. The table is
//  found as the one place in win32u.so's data holding each function's
//  address; anything else (none, or more than one) and nothing is replaced,
//  and native fullscreen goes on as it did before it followed the game.
//  Wine's dispatcher calls them with the Mac's own calling convention (it
//  moves a system call's Windows-convention arguments into place first), so
//  the wrappers are plain C functions with Wine's prototypes. x86_64 only:
//  Wine runs as x86_64, and the arm64 slice of this dylib is ScummVM's.
//
//  Pinned to cnc-ddraw's messages: the cnc-ddraw that winetricks installs
//  (v7.0.0.0, Modules/wine/functions/cnc-ddraw) sends both. A cnc-ddraw that
//  stopped would leave every DirectDraw game in a window, which the
//  integration tests' fullscreen check catches.
//
//  docs/wine-in-process-helpers.md has the whole story.
//

#include <stdatomic.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <os/log.h>
#include <sys/mman.h>
#include <unistd.h>

#include "helper_common.h"

/// The game's request: see ddrawModeRequest.
static atomic_ulong gRequest;

#if defined(__x86_64__)

// cnc-ddraw's inc/wndproc.h.
static const unsigned kWMApp = 0x8000;
static const unsigned kWMSizeDdraw = kWMApp + 114;
static const unsigned kWMDisplayChangeDdraw = kWMApp + 116;
static const int kGWLPWndProc = -4;

static os_log_t gLog;

/// The window the game last set a mode on, and that request's number: 0
/// while it has none.
static _Atomic(uintptr_t) gRequestWindow;
static atomic_ulong gRequestsMade;

/// WM_SIZE_DDRAW's window and size, waiting for WM_DISPLAYCHANGE_DDRAW to
/// confirm it came from cnc-ddraw: the pair, for the same window and size,
/// is what it sends.
static _Atomic(uintptr_t) gSizedWindow;
static _Atomic(intptr_t) gSizedTo;

static atomic_bool gInstalled;

static void noteMessage(uintptr_t window, unsigned message, uintptr_t wparam, intptr_t lparam) {
    if (message == kWMSizeDdraw) {
        atomic_store(&gSizedTo, lparam);
        atomic_store(&gSizedWindow, window);
        return;
    }
    // message == kWMDisplayChangeDdraw
    if (atomic_load(&gSizedWindow) != window || atomic_load(&gSizedTo) != lparam) return;
    if (wparam != 8 && wparam != 16 && wparam != 32) return;
    atomic_store(&gSizedWindow, 0);

    int width = (int)(lparam & 0xffff), height = (int)((lparam >> 16) & 0xffff);
    // A new mode while one is set (a game changing resolution) is the same
    // request: a player who took the window out of its Space keeps it out.
    if (atomic_load(&gRequest) != 0 && atomic_load(&gRequestWindow) == window) {
        os_log(gLog, "[NativeFS] the game set the display mode again: %dx%dx%d", width, height, (int)wparam);
        return;
    }
    atomic_store(&gRequestWindow, window);
    unsigned long request = atomic_fetch_add(&gRequestsMade, 1) + 1;
    atomic_store(&gRequest, request);
    os_log(gLog, "[NativeFS] the game set a display mode, %dx%dx%d: it asks for fullscreen", width, height, (int)wparam);
    helperReport("NativeFullscreen", "notice", "the game set a display mode (%dx%dx%d): it asks for fullscreen",
                 width, height, (int)wparam);
}

static void noteWindowProcedure(uintptr_t window, int offset) {
    if (offset != kGWLPWndProc || window == 0 || atomic_load(&gRequestWindow) != window) return;
    if (atomic_exchange(&gRequest, 0) == 0) return;
    os_log(gLog, "[NativeFS] cnc-ddraw let go of the game's window: it no longer asks for fullscreen");
    helperReport("NativeFullscreen", "notice", "DirectDraw let go of the game's window: it no longer asks for fullscreen");
}

typedef intptr_t (*MessageCallFunction)(uintptr_t, unsigned, uintptr_t, intptr_t, void *, unsigned, int);
typedef int32_t (*SetWindowLongFunction)(uintptr_t, int, int32_t, int);
typedef intptr_t (*SetWindowLongPtrFunction)(uintptr_t, int, intptr_t, int);

static MessageCallFunction gMessageCall;
static SetWindowLongFunction gSetWindowLong;
static SetWindowLongPtrFunction gSetWindowLongPtr;

static intptr_t watchMessageCall(uintptr_t window, unsigned message, uintptr_t wparam, intptr_t lparam,
                                 void *resultInfo, unsigned type, int ansi) {
    if (message == kWMSizeDdraw || message == kWMDisplayChangeDdraw) noteMessage(window, message, wparam, lparam);
    return gMessageCall(window, message, wparam, lparam, resultInfo, type, ansi);
}

static int32_t watchSetWindowLong(uintptr_t window, int offset, int32_t value, int ansi) {
    noteWindowProcedure(window, offset);
    return gSetWindowLong(window, offset, value, ansi);
}

static intptr_t watchSetWindowLongPtr(uintptr_t window, int offset, intptr_t value, int ansi) {
    noteWindowProcedure(window, offset);
    return gSetWindowLongPtr(window, offset, value, ansi);
}

/// The one pointer-sized slot in `image`'s data segments holding `function`,
/// or NULL when there are none or several.
static void **onlySlotHolding(const struct mach_header_64 *image, intptr_t slide, void *function) {
    void **found = NULL;
    int matches = 0;
    const struct load_command *command = (const struct load_command *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__DATA", 6) == 0) {
                const struct section_64 *section = (const struct section_64 *)(segment + 1);
                for (uint32_t s = 0; s < segment->nsects; s++, section++) {
                    // The GOT holds what win32u imports, not its own functions.
                    if (strcmp(section->sectname, "__got") == 0) continue;
                    uint8_t type = section->flags & SECTION_TYPE;
                    if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
                    void **slots = (void **)(section->addr + slide);
                    for (uint64_t n = 0; n < section->size / sizeof(void *); n++) {
                        if (slots[n] == function) {
                            found = &slots[n];
                            matches++;
                        }
                    }
                }
            }
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    return matches == 1 ? found : NULL;
}

static BOOL replaceSlot(void **slot, void *replacement) {
    long pageSize = getpagesize();
    void *page = (void *)((uintptr_t)slot & ~(uintptr_t)(pageSize - 1));
    // An aligned pointer never straddles two pages. The page stays writable:
    // it may be __DATA, which was, and is the system call table's alone.
    if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) return NO;
    *slot = replacement;
    return YES;
}

int installDdrawModeWatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLog = os_log_create("com.secondchance.gamewrapper", "NativeFullscreen");
        const struct mach_header_64 *win32u = NULL;
        intptr_t slide = 0;
        const char *path = NULL;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            if (strcmp(processIdentityBasename(_dyld_get_image_name(i)), "win32u.so") == 0) {
                win32u = (const struct mach_header_64 *)_dyld_get_image_header(i);
                slide = _dyld_get_image_vmaddr_slide(i);
                path = _dyld_get_image_name(i);
            }
        }
        if (!win32u) {
            helperReport("NativeFullscreen", "warning", "win32u.so not found; every game window goes fullscreen");
            return;
        }
        void *handle = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
        void *messageCall = handle ? dlsym(handle, "NtUserMessageCall") : NULL;
        void *setWindowLong = handle ? dlsym(handle, "NtUserSetWindowLong") : NULL;
        void *setWindowLongPtr = handle ? dlsym(handle, "NtUserSetWindowLongPtr") : NULL;
        void **messageSlot = messageCall ? onlySlotHolding(win32u, slide, messageCall) : NULL;
        void **longSlot = setWindowLong ? onlySlotHolding(win32u, slide, setWindowLong) : NULL;
        void **longPtrSlot = setWindowLongPtr ? onlySlotHolding(win32u, slide, setWindowLongPtr) : NULL;
        if (!messageSlot || !longSlot || !longPtrSlot) {
            helperReport("NativeFullscreen", "warning",
                         "win32u's system call table not found (message %d, window long %d, %d); every game window goes fullscreen",
                         messageSlot != NULL, longSlot != NULL, longPtrSlot != NULL);
            return;
        }
        gMessageCall = (MessageCallFunction)messageCall;
        gSetWindowLong = (SetWindowLongFunction)setWindowLong;
        gSetWindowLongPtr = (SetWindowLongPtrFunction)setWindowLongPtr;
        // All three or none: a request seen but never let go of would keep a
        // game fullscreen after it asked for a window.
        if (!replaceSlot(longSlot, (void *)watchSetWindowLong) || !replaceSlot(longPtrSlot, (void *)watchSetWindowLongPtr) ||
            !replaceSlot(messageSlot, (void *)watchMessageCall)) {
            *longSlot = setWindowLong;
            *longPtrSlot = setWindowLongPtr;
            helperReport("NativeFullscreen", "warning", "couldn't change win32u's system call table; every game window goes fullscreen");
            return;
        }
        atomic_store(&gInstalled, true);
        os_log(gLog, "[NativeFS] watching for the game setting a display mode through cnc-ddraw");
    });
    return atomic_load(&gInstalled);
}

#else

int installDdrawModeWatch(void) {
    return 0;
}

#endif

unsigned long ddrawModeRequest(void) {
    return atomic_load(&gRequest);
}
