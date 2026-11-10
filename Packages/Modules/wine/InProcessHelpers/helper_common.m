//
//  helper_common.m
//  The code more than one in-process helper runs, declared in
//  helper_common.h: the debug log, waiting on the main thread, finding a
//  loaded library and changing a function pointer in it, and noticing the
//  game's window losing key to another app.
//

#import <Cocoa/Cocoa.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "helper_common.h"

#pragma mark - The debug log

void helperDebugLog(os_log_t log, const char *tag, const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    if (log) os_log(log, "[%{public}s] %{public}s", tag, message);
    const char *path = getenv("IN_PROCESS_HELPERS_LOG");
    if (!path || !*path) return;
    // Every Wine process loads the helpers, so each line says whose it is.
    char executable[PATH_MAX] = {0};
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) strlcpy(executable, "?", sizeof(executable));
    // One write, so lines from several threads and processes don't interleave.
    char line[1400];
    int length = snprintf(line, sizeof(line), "pid=%d exe=%s %s | %s\n",
                          getpid(), processIdentityBasename(executable), tag, message);
    if (length > (int)sizeof(line) - 1) length = (int)sizeof(line) - 1;
    if (length <= 0) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        write(fd, line, (size_t)length);
        close(fd);
    }
}

#pragma mark - The main thread

double helperNowSeconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / NSEC_PER_SEC;
}

BOOL helperOnMainThread(double timeoutSeconds, BOOL (^block)(void)) {
    __block BOOL result = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        result = block();
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC))) != 0) {
        return NO;
    }
    return result;
}

#pragma mark - Loaded libraries

const struct mach_header_64 *loadedImageNamed(const char *name, intptr_t *slide, const char **path) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *imagePath = _dyld_get_image_name(i);
        if (!imagePath || strcmp(processIdentityBasename(imagePath), name) != 0) continue;
        if (slide) *slide = _dyld_get_image_vmaddr_slide(i);
        if (path) *path = imagePath;
        return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

void **imageSlotHolding(const struct mach_header_64 *image, intptr_t slide, void *function) {
    void **found = NULL;
    int matches = 0;
    const struct load_command *command = (const struct load_command *)(image + 1);
    for (uint32_t i = 0; i < image->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__DATA", 6) == 0) {
                const struct section_64 *section = (const struct section_64 *)(segment + 1);
                for (uint32_t s = 0; s < segment->nsects; s++, section++) {
                    // The GOT holds what the image imports, not its own functions.
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

BOOL replaceImageSlot(void **slot, void *replacement) {
    long pageSize = getpagesize();
    void *page = (void *)((uintptr_t)slot & ~(uintptr_t)(pageSize - 1));
    // An aligned pointer never straddles two pages. The page stays writable:
    // it may be __DATA, which was, or a table other helpers change too.
    if (mprotect(page, pageSize, PROT_READ | PROT_WRITE) != 0) return NO;
    *slot = replacement;
    return YES;
}

#pragma mark - Losing key to another app
//
// A non-activating panel -- Gatekeeper's "Verifying…", which a build running
// alongside raises -- takes key without the game's app ever resigning active,
// so no NSApplication notification marks it. Wine's Mac driver still treats
// the lost key as the game losing focus (WINDOW_LOST_FOCUS: the desktop
// becomes the foreground window, and the game gets WM_ACTIVATEAPP false), so
// whatever the game does on a switch away happens: wined3d puts the desktop's
// display mode back, and cnc-ddraw lets go of the cursor. The helpers that
// undo or redo those (emulated_mode_scaling.m, cursor_lock.m) watch for it
// here.
//
// Key moving between this process's own windows isn't a loss. Leaving the app
// altogether is left to the helpers' own NSApplication observers: a key lost
// on the way out may still be reported, but getting key back on the return
// isn't, so a return is handled once, by the app's notification.

void watchKeyLostToAnotherApp(void (^lost)(NSWindow *window), void (^regained)(NSWindow *window)) {
    // Only touched on the main thread, where AppKit posts these.
    __block BOOL away = NO;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSWindowDidResignKeyNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        NSWindow *window = note.object;
        NSWindow *key = NSApp.keyWindow;
        if (key && key != window) return;
        away = YES;
        lost(window);
    }];
    [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        (void)note;
        away = NO;
    }];
    if (!regained) return;
    [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        if (!away || !NSApp.isActive) return;
        away = NO;
        regained(note.object);
    }];
}
