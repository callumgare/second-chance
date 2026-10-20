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

#ifndef HELPER_COMMON_H
#define HELPER_COMMON_H

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
    if (length > 0) write(STDERR_FILENO, line, (size_t)length);
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

#endif
