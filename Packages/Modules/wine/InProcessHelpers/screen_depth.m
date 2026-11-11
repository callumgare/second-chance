//
//  screen_depth.m
//  Tells a program the screen has fewer colours than the Mac's, for a
//  program that won't run on anything but a 256-colour screen, while Wine
//  keeps drawing in full colour.
//
//  Old programs check how many colours the screen has before they start,
//  and some refuse anything but 256: Webmaster's installer and game say
//  "Your screen is not set to 256 colors" and quit. They ask
//  GetDeviceCaps(BITSPIXEL) of the screen. Wine 10's Mac driver answers that
//  with the depth of the Mac display's own mode, read once
//  (winemac.drv/gdi.c's device_init): always 32, whatever mode the session
//  is in. (Wine 10.20 stopped overriding it, upstream 1907a5b039, so
//  BITSPIXEL follows the emulated mode there; Director's projector dies at
//  once under Rosetta on every Wine since, so Wine 10 is what such a program
//  runs on.)
//
//  The answer can't change for Wine as a whole. win32u asks the same
//  question for itself: CreateCompatibleBitmap of the screen makes a bitmap
//  of the screen's BITSPIXEL, and Wine's 8-bit bitmaps have a fixed colour
//  table (a coarse colour cube, win32u/dib.c's get_default_color_table),
//  never the program's palette, as Wine's Mac driver has no system palette.
//  A program drawing through one has every colour forced to that cube:
//  its pictures come out speckled and in the wrong colours.
//
//  So only the program is told. Its GetDeviceCaps reaches win32u.so as a
//  system call, NtGdiGetDeviceCaps, dispatched through win32u's table of
//  them (syscall.c's `syscalls`, which ntdll keeps a pointer to and reads on
//  every call), while win32u's own questions call the function directly.
//  This file points the table's entry at a wrapper that answers BITSPIXEL
//  for a screen (a DT_RASDISPLAY device) with the depth asked for, when the
//  real one is more. Every other question, and every question win32u asks
//  itself, gets Wine's answer: its window surfaces and the bitmaps made for
//  the screen stay 32-bit, and the program's 8-bit pictures are converted
//  to them as any DIB is, with their own colours.
//
//  The display modes a session lists aren't changed: EmulateModeset already
//  offers 8 and 16-bit modes at every size, and a launch that also sets one
//  (--wine.display-mode=800x600x8) has EnumDisplaySettings agree with
//  GetDeviceCaps.
//
//  Wine's unix side is x86_64 only (Wine runs under Rosetta), so this is
//  built for x86_64 alone; the arm64 slice (ScummVM's) has nothing to do.
//
//  Armed by SCREEN_DEPTH (8 or 16), which a launch or a build step that says
//  --wine.colors sets for its session (Wine.sessionVariables); unset, or any
//  other value, leaves the screen as it is.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh; see
//  docs/wine-in-process-helpers.md#screen-depth.
//

#import <Foundation/Foundation.h>
#import <os/log.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <os/lock.h>
#include <sys/mman.h>

#include "helper_common.h"

#if defined(__x86_64__)

// wingdi.h's and ntgdi.h's values.
enum { kTechnology = 2, kBitsPixel = 12, kRasterDisplay = 1 };
enum { kGetPaletteEntries = 2, kGetSystemPaletteEntries = 3 };

typedef struct { uint8_t red, green, blue, flags; } PaletteEntry;

// win32u.so's system calls this replaces, as the dispatcher calls them. Wine's
// unix side keeps the Mac's calling convention: the dispatcher moves a call's
// arguments into it before calling the table's entry.
typedef int (*GetDeviceCapsFunction)(void *hdc, int cap);
typedef long (*DoPaletteFunction)(void *handle, uint16_t start, uint16_t count, void *entries,
                                  uint32_t function, int inbound);
typedef void *(*SelectPaletteFunction)(void *hdc, void *palette, uint16_t background);

static GetDeviceCapsFunction gGetDeviceCaps;
static DoPaletteFunction gDoPalette;
static SelectPaletteFunction gSelectPalette;
static int gDepth;

static int isScreen(void *hdc) {
    return gGetDeviceCaps(hdc, kTechnology) == kRasterDisplay;
}

static int screenDepthGetDeviceCaps(void *hdc, int cap) {
    int value = gGetDeviceCaps(hdc, cap);
    if (cap == kBitsPixel && value > gDepth && isScreen(hdc)) return gDepth;
    return value;
}

// ## The system palette, at 256 colours
//
// A program on a 256-colour screen selects its palette and realizes it, which
// puts its colours in the screen's own palette, and then reads that back
// (GetSystemPaletteEntries) to know which colour each of its pixels will show
// as. Director does, and dithers its pictures to what it read. Wine's Mac
// driver has no system palette and answers with nothing, so the program
// dithers to nonsense. So at 8 bits the program is answered as Windows would
// after the palette it last selected for the foreground was realized: the 20
// colours Windows keeps for itself at either end, and that palette's own
// entries between them, each at its own index. What Wine draws is unchanged:
// the program's pictures keep their palette's colours as they reach Wine's
// 32-bit surfaces, so the program's idea of the screen and the picture agree.

static os_unfair_lock gPaletteLock = OS_UNFAIR_LOCK_INIT;
static void *gProgramPalette;
static PaletteEntry gSystemPalette[256];

/// The colours Windows keeps for itself: the first ten and the last ten of
/// the system palette.
static const PaletteEntry kStaticColours[20] = {
    {0x00, 0x00, 0x00, 0}, {0x80, 0x00, 0x00, 0}, {0x00, 0x80, 0x00, 0}, {0x80, 0x80, 0x00, 0},
    {0x00, 0x00, 0x80, 0}, {0x80, 0x00, 0x80, 0}, {0x00, 0x80, 0x80, 0}, {0xc0, 0xc0, 0xc0, 0},
    {0xc0, 0xdc, 0xc0, 0}, {0xa6, 0xca, 0xf0, 0},
    {0xff, 0xfb, 0xf0, 0}, {0xa0, 0xa0, 0xa4, 0}, {0x80, 0x80, 0x80, 0}, {0xff, 0x00, 0x00, 0},
    {0x00, 0xff, 0x00, 0}, {0xff, 0xff, 0x00, 0}, {0x00, 0x00, 0xff, 0}, {0xff, 0x00, 0xff, 0},
    {0x00, 0xff, 0xff, 0}, {0xff, 0xff, 0xff, 0},
};

static void *screenDepthSelectPalette(void *hdc, void *palette, uint16_t background) {
    void *previous = gSelectPalette(hdc, palette, background);
    // The default palette has the 20 static colours alone; a program's own
    // is bigger.
    if (previous && !background && gDoPalette(palette, 0, 0, NULL, kGetPaletteEntries, 0) > 20 && isScreen(hdc)) {
        os_unfair_lock_lock(&gPaletteLock);
        gProgramPalette = palette;
        os_unfair_lock_unlock(&gPaletteLock);
    }
    return previous;
}

static long screenDepthDoPalette(void *handle, uint16_t start, uint16_t count, void *entries,
                                 uint32_t function, int inbound) {
    if (function != kGetSystemPaletteEntries || !isScreen(handle)) {
        return gDoPalette(handle, start, count, entries, function, inbound);
    }
    if (!entries) return 256;
    os_unfair_lock_lock(&gPaletteLock);
    // Read the palette now rather than when it was selected: the program may
    // have changed its entries since (SetPaletteEntries, AnimatePalette).
    // One it has deleted since leaves what was last read.
    PaletteEntry program[256];
    long read = gProgramPalette ? gDoPalette(gProgramPalette, 0, 256, program, kGetPaletteEntries, 0) : 0;
    for (long i = 10; i < read && i < 246; i++) {
        gSystemPalette[i] = program[i];
        gSystemPalette[i].flags = 0;
    }
    long copied = 0;
    for (long i = start; i < 256 && copied < count; i++, copied++) {
        ((PaletteEntry *)entries)[copied] = gSystemPalette[i];
    }
    os_unfair_lock_unlock(&gPaletteLock);
    return copied;
}

// ## Replacing a system call

/// The entries in `image`'s data segments that hold `pointer`, at most
/// `capacity` of them written to `found`. Returns how many there are.
static int findPointerInData(const struct mach_header_64 *image, intptr_t slide, void *pointer,
                             void ***found, int capacity) {
    int count = 0;
    const struct load_command *command = (const struct load_command *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__DATA", 6) == 0) {
                void **start = (void **)(segment->vmaddr + slide);
                for (uint64_t j = 0; j < segment->vmsize / sizeof(void *); j++) {
                    if (start[j] != pointer) continue;
                    if (count < capacity) found[count] = &start[j];
                    count++;
                }
            }
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
    return count;
}

/// The entry for `name` in win32u.so's table of system calls (`win32u` and
/// `handle` its image), or NULL with `failure` saying why. The table holds
/// each function once; anything else (none, or more than one) is a win32u
/// this wasn't written for, left alone.
static void **systemCallEntry(const struct mach_header_64 *win32u, intptr_t slide, void *handle,
                              const char *name, void **function, const char **failure) {
    *function = dlsym(handle, name);
    if (!*function) {
        *failure = "win32u.so is missing a function it replaces";
        return NULL;
    }
    void **entries[2];
    int count = findPointerInData(win32u, slide, *function, entries, 2);
    if (count != 1) {
        *failure = count == 0 ? "found no system call entry to replace" : "found a system call more than once";
        return NULL;
    }
    return entries[0];
}

static int replaceEntry(void **entry, void *replacement) {
    long pageSize = getpagesize();
    void *page = (void *)((uintptr_t)entry & ~(uintptr_t)(pageSize - 1));
    if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) return 0;
    __atomic_store_n(entry, replacement, __ATOMIC_SEQ_CST);
    return 1;
}

/// Points win32u.so's system call entries at the wrappers: GetDeviceCaps
/// for any depth, and at 8 bits the two that make up the system palette.
/// All are found before any is replaced, so a win32u it can't read is left
/// as it was. Returns NULL, or why it couldn't.
static const char *redirectSystemCalls(void) {
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
    if (!win32u) return "win32u.so isn't loaded";
    void *handle = dlopen(path, RTLD_NOLOAD | RTLD_LAZY);
    if (!handle) return "couldn't open win32u.so";
    const char *failure = NULL;
    void **capsEntry = systemCallEntry(win32u, slide, handle, "NtGdiGetDeviceCaps", (void **)&gGetDeviceCaps, &failure);
    void **paletteEntry = NULL, **selectEntry = NULL;
    if (capsEntry && gDepth == 8) {
        paletteEntry = systemCallEntry(win32u, slide, handle, "NtGdiDoPalette", (void **)&gDoPalette, &failure);
        if (paletteEntry) {
            selectEntry = systemCallEntry(win32u, slide, handle, "NtUserSelectPalette", (void **)&gSelectPalette, &failure);
        }
    }
    dlclose(handle);
    if (failure) return failure;

    if (gDepth == 8) {
        memcpy(gSystemPalette, kStaticColours, 10 * sizeof(PaletteEntry));
        memcpy(gSystemPalette + 246, kStaticColours + 10, 10 * sizeof(PaletteEntry));
        if (!replaceEntry(paletteEntry, (void *)screenDepthDoPalette)) return "couldn't make the system call table writable";
        if (!replaceEntry(selectEntry, (void *)screenDepthSelectPalette)) return "couldn't make the system call table writable";
    }
    if (!replaceEntry(capsEntry, (void *)screenDepthGetDeviceCaps)) return "couldn't make the system call table writable";
    return NULL;
}

#endif

__attribute__((constructor))
static void screenDepthInit(void) {
    const char *armed = getenv("SCREEN_DEPTH");
    if (!armed || !*armed) return;
    os_log_t log = os_log_create("com.secondchance.gamewrapper", "ScreenDepth");
    // Only the program's process reports, so the log gets one line; a build
    // step's program has no name for it, so there every process does.
    const char *program = getenv("SCREEN_DEPTH_EXE");
    BOOL reports = !program || !*program || processRunsExeNamedBy("SCREEN_DEPTH_EXE");

    int depth = atoi(armed);
    if (depth != 8 && depth != 16) {
        if (reports) helperReport("ScreenDepth", "error", "SCREEN_DEPTH=%s isn't a depth it can show (8 or 16)", armed);
        return;
    }
#if defined(__x86_64__)
    BOOL isWine = NO;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(processIdentityBasename(_dyld_get_image_name(i)), "winemac.so") == 0) isWine = YES;
    }
    // Not a Wine process (ScummVM loads this dylib too): nothing to do.
    if (!isWine) return;
    gDepth = depth;
    const char *failure = redirectSystemCalls();
    if (failure) {
        if (reports) helperReport("ScreenDepth", "error", "%s; the program is told the screen has the Mac's colours", failure);
        return;
    }
    os_log(log, "telling the program the screen is %d-bit", depth);
    if (reports) helperReport("ScreenDepth", "notice", "armed: the screen has %d-bit colour", depth);
#else
    (void)log;
    (void)reports;
#endif
}
