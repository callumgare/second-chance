//
//  cocoa_start_wait.m
//  Lets a Wine process's Mac driver wait for its main thread to start Cocoa,
//  however long a busy Mac makes that take.
//
//  Every Wine process that talks to the Mac driver starts it the same way
//  (macdrv_start_cocoa_app, in Wine's dlls/winemac.drv/cocoa_main.m): it
//  puts a struct on its own stack, asks the main thread to turn itself into
//  a Cocoa app, passing it a pointer to that struct, and waits for it -- for
//  5 seconds:
//
//      timeLimit = [NSDate dateWithTimeIntervalSinceNow:5];
//      ...
//      if ([startup_info.lock lockWhenCondition:COCOA_APP_RUNNING beforeDate:timeLimit])
//
//  On a Mac with every core busy, under Rosetta, the main thread hasn't
//  always got that far in 5 seconds. The driver then fails ("Failed to start
//  Cocoa app main loop"), so the process has no display driver for good: the
//  game never shows a window, or explorer.exe's desktop never comes up and
//  the game is told "The explorer process failed to start". And the main
//  thread, when it does get to the request, reads the struct from a stack
//  frame long gone and crashes ("-[__NSMallocBlock__ lock]: unrecognized
//  selector"). Nothing recovers either when the load goes.
//
//  So this replaces -[NSConditionLock lockWhenCondition:beforeDate:] with one
//  that, for that one call -- from winemac.so, waiting for COCOA_APP_RUNNING
//  -- waits up to 10 minutes instead, as long as a build waits for Wine's
//  desktop. Every other call goes straight to the original. A start that took
//  longer than Wine's 5 seconds is reported.
//
//  Runs in every Wine process, not armed per game: explorer.exe and Wine's
//  services start the driver too. SECOND_CHANCE_COCOA_START_WAIT=0 leaves it
//  off, for comparison.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

#include "helper_common.h"

/// macdrv_start_cocoa_app's condition for "the main thread is running Cocoa".
static const NSInteger kCocoaAppRunning = 1;
/// Wine's own limit, and the one used instead.
static const NSTimeInterval kWineLimit = 5;
static const NSTimeInterval kLimit = 10 * 60;

static IMP gLockWhenConditionBeforeDate;

/// Whether `address` is in winemac.so, the Mac driver.
static BOOL isInMacDriver(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fname) return NO;
    const char *name = strrchr(info.dli_fname, '/');
    return strcmp(name ? name + 1 : info.dli_fname, "winemac.so") == 0;
}

static BOOL waitingLockWhenConditionBeforeDate(NSConditionLock *self, SEL _cmd, NSInteger condition, NSDate *limit) {
    typedef BOOL (*Original)(NSConditionLock *, SEL, NSInteger, NSDate *);
    // objc_msgSend jumps here, so the return address is its caller's.
    if (condition != kCocoaAppRunning || !isInMacDriver(__builtin_return_address(0))) {
        return ((Original)gLockWhenConditionBeforeDate)(self, _cmd, condition, limit);
    }
    NSDate *started = [NSDate date];
    BOOL locked = ((Original)gLockWhenConditionBeforeDate)(self, _cmd, condition,
                                                           [NSDate dateWithTimeIntervalSinceNow:kLimit]);
    NSTimeInterval took = -[started timeIntervalSinceNow];
    if (!locked) {
        helperReport("CocoaStart", "error", "the main thread didn't start Cocoa in %.0fs", took);
    } else if (took > kWineLimit) {
        helperReport("CocoaStart", "warning", "the main thread took %.1fs to start Cocoa, past Wine's %.0fs limit", took, kWineLimit);
    }
    return locked;
}

__attribute__((constructor))
static void cocoaStartWaitInit(void) {
    const char *off = getenv("SECOND_CHANCE_COCOA_START_WAIT");
    if (off && strcmp(off, "0") == 0) return;
    Method method = class_getInstanceMethod([NSConditionLock class], @selector(lockWhenCondition:beforeDate:));
    if (!method) {
        helperReport("CocoaStart", "warning", "no -[NSConditionLock lockWhenCondition:beforeDate:]; Wine's 5 s limit on starting Cocoa stays");
        return;
    }
    gLockWhenConditionBeforeDate = method_setImplementation(method, (IMP)waitingLockWhenConditionBeforeDate);
}
