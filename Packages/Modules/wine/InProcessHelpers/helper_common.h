//
//  helper_common.h
//  What both in-process helpers share: recognising the game's process, and
//  reporting how they got on.
//
//  ## Recognising the game's process
//
//  Wine's Mac driver is loaded by every Wine process (explorer.exe, services,
//  the game, ...), so each helper arms only in the process running the .exe
//  its variable names. Wine identifies that process in one of two ways,
//  depending on the build:
//
//  - Older Wine started each Windows program through a copy of its loader
//    named after the .exe, so the Mach-O executable itself is `Game.exe`.
//  - Wine 10 runs every program from the one `bin/wine` binary and instead
//    rewrites the process's arguments in place, so argv[0] -- as the kernel
//    reports it, and `ps` shows -- is the Windows path,
//    `C:\Program Files (x86)\...\Game.exe`.
//
//  Either matches. The argv check reads the arguments back from the kernel
//  (KERN_PROCARGS2) rather than through _NSGetArgv(), so it sees exactly what
//  Wine left there, and takes the last component after either separator.
//

//  ## Reporting
//
//  helperReport() prints one status line to stderr, which Wine passes on to
//  whatever started the game -- the wrapp's own pipe, or Steam's -- so the
//  line lands in the wrapp's log. The wrapp (InProcessHelperReport.swift)
//  watches for these lines and says when a helper it armed never reported
//  arming: the helpers' failure mode is otherwise silence. Only the few lines
//  that say how a helper got on go here; the step-by-step detail stays in
//  os_log and IN_PROCESS_HELPERS_LOG. The format is a contract with
//  InProcessHelperReport and SubprocessLineClassifier:
//
//      second-chance-helper[<helper>] <notice|warning|error>: <message>
//
//  A game Wine starts with no output of the wrapp's to write to -- an owned
//  Big Fish game, which Big Fish's DRM service starts -- also appends each
//  line to the file SECOND_CHANCE_HELPER_REPORTS names, which the wrapp
//  reads instead (HelperReportFile.swift).
//

#ifndef HELPER_COMMON_H
#define HELPER_COMMON_H

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>

#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>
#include <sys/syslimits.h>
#include <unistd.h>

/// The part of `path` after its last '/' or '\'.
static inline const char *processIdentityBasename(const char *path) {
    const char *name = path;
    for (const char *c = path; *c; c++) {
        if (*c == '/' || *c == '\\') name = c + 1;
    }
    return name;
}

/// Whether this process's Mach-O executable is named `wanted` (older Wine).
static inline int processExecutableIs(const char *wanted) {
    char path[PATH_MAX] = {0};
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return 0;
    return strcasecmp(processIdentityBasename(path), wanted) == 0;
}

/// Whether this process's argv[0], as the kernel reports it, names `wanted`
/// (Wine 10). Layout of KERN_PROCARGS2: argc, the exec path, NUL padding,
/// then argv[0].
static inline int processArgv0Is(const char *wanted) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) return 0;
    char *buffer = malloc(size);
    if (!buffer) return 0;
    int matches = 0;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) == 0 && size > sizeof(int)) {
        char *end = buffer + size;
        char *p = buffer + sizeof(int);
        while (p < end && *p) p++;   // the exec path
        while (p < end && !*p) p++;  // its padding
        if (p < end && memchr(p, '\0', end - p)) {
            matches = strcasecmp(processIdentityBasename(p), wanted) == 0;
        }
    }
    free(buffer);
    return matches;
}

/// Whether this process runs the .exe that `variable` names. Unset or empty
/// means no process does -- what the off switches rely on.
static inline int processRunsExeNamedBy(const char *variable) {
    const char *wanted = getenv(variable);
    if (!wanted || !*wanted) return 0;
    return processExecutableIs(wanted) || processArgv0Is(wanted);
}

/// Print one status line to stderr in the format above.
__attribute__((format(printf, 3, 4)))
static inline void helperReport(const char *helper, const char *level, const char *format, ...) {
    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    // One write, so lines from the game's threads don't interleave.
    char line[1200];
    int length = snprintf(line, sizeof(line), "second-chance-helper[%s] %s: %s\n", helper, level, message);
    if (length > (int)sizeof(line) - 1) length = (int)sizeof(line) - 1;
    if (length <= 0) return;
    write(STDERR_FILENO, line, (size_t)length);
    const char *reports = getenv("SECOND_CHANCE_HELPER_REPORTS");
    if (reports && *reports) {
        // O_APPEND keeps each line whole, whichever process writes it.
        int fd = open(reports, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        if (fd >= 0) {
            write(fd, line, (size_t)length);
            close(fd);
        }
    }
}

// ## Cursor lock, for puppet control
//
// cursor_lock.m's outcome and Wine's cursor state, which puppet_control.m
// reports in its `state` reply so WrappPuppeteer can tell whether its first
// click was the one that locked the cursor -- that is, swallowed.

/// What the cursor lock helper is doing: "off" (not armed in this process),
/// "waiting" (for the window, or for a middle click to take), "locked", or
/// "not-locked" (it gave up, as it does in a game that isn't cnc-ddraw's).
const char *cursorLockStatus(void);

/// Whether cnc-ddraw holds the cursor right now: Wine has it clipped and
/// hidden. Main thread only.
int cursorLockHeld(void);

// ## Moving into a fullscreen Space
//
// native_fullscreen.m watches AppKit's fullscreen transition notifications
// for every window in the process, whichever helper is armed. A window part
// way into its fullscreen Space can't be relied on: a ScreenCaptureKit capture
// taken then can fail as though Screen Recording were denied and leave the
// window out of the process's capturable windows from then on, and the
// window's frame is still changing.

@class NSWindow;

/// Start watching, if nothing has yet. Safe to call more than once and from
/// any thread; the helpers that rely on the one below call it as they arm.
void watchFullscreenTransitions(void);

/// Whether `window` is moving into a fullscreen Space: AppKit said it will
/// enter, hasn't yet said it did, and the window is still marked fullscreen
/// (an entry that fails takes the mark away, with no notification). Main
/// thread only.
int windowIsEnteringFullscreen(NSWindow *window);

/// Whether native fullscreen is done with this process's windows: it isn't
/// armed here, or the window it moved has finished entering its Space (and no
/// other is on its way), or it gave up. Before then a ScreenCaptureKit capture
/// can wedge, even one finished just before the move begins. Main thread only.
int nativeFullscreenSettled(void);

// ## The display Wine sees
//
// display_below_notch.m may show Wine less of the main display than there
// is; emulated_mode_scaling.m needs the size Wine scales the game up to.

#include <CoreGraphics/CoreGraphics.h>

/// The main display's size in points as Wine's Mac driver sees it: below the
/// notch when display_below_notch.m is showing it that, else the whole display.
CGSize wineMainDisplaySize(void);

// ## Replacing one of Wine's methods
//
// class_getInstanceMethod also finds a method a class only inherits, and
// method_setImplementation on that changes the superclass's: if a Wine class
// stopped overriding, say, -constrainFrameRect:toScreen:, replacing "its"
// method would change NSWindow's, for every window in the process. So the
// class is given its own copy of an inherited method first (calling the
// superclass's, as before), and only that copy is replaced.

#ifdef __OBJC__
#include <objc/runtime.h>

/// Whether `cls` itself defines `selector`, rather than inheriting it.
static inline int classDefinesMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int found = 0;
    for (unsigned int i = 0; i < count && !found; i++) {
        found = method_getName(methods[i]) == selector;
    }
    free(methods);
    return found;
}

/// Replace `cls`'s own `selector` with `replacement`, and return what it
/// did before (to call on), or NULL if `cls` has no such method at all.
static inline IMP replaceOwnMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls) return NULL;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    if (!classDefinesMethod(cls, selector)) {
        class_addMethod(cls, selector, method_getImplementation(method), method_getTypeEncoding(method));
        method = class_getInstanceMethod(cls, selector);
    }
    return method_setImplementation(method, replacement);
}
#endif

#endif
