//
//  input_recorder.m
//  Writes down the clicks and keys a person gives the game, so that `sc
//  puppet replay` can give it them again: a route through a game played
//  once by hand, replayed whenever a change needs trying on it.
//
//  Armed when INPUT_RECORDER_EXE names this process's .exe and
//  INPUT_RECORDER_FILE names the file to write (Wine.inProcessHelperVariables
//  sets both when SECOND_CHANCE_RECORD_INPUT is set: `sc wrapp run --debug
//  record-input`). Nothing a player runs sets either.
//
//  The file is JSON lines. The first says what was recorded:
//
//    {"format":1,"exe":"Waverly.exe","started":"2026-11-17T10:00:00Z"}
//
//  then a line an event, `t` its seconds since the recorder armed:
//
//    {"t":12.345,"event":"down","button":"left","x":0.4123,"y":0.5521,"points":"620,540","picture":"104,0,1304,982"}
//    {"t":12.456,"event":"up","button":"left","x":0.4123,"y":0.5521,...}
//    {"t":15.000,"event":"key","key":"escape","mods":"cmd"}
//
//  A button's x and y are its share of the game's picture
//  (helperGamePicture: the display mode fitted to a window covering the
//  screen, or the window), so a replay on a screen of another shape lands
//  where the person clicked; `points` and `picture` are the window points
//  they came from. A key is its name in the key notation
//  (helperKeyName), `mods` those held with it, joined by `+`; a held key's
//  repeats aren't written. Puppet control's own events (kPuppetEventTag) are
//  left out, so a replay isn't recorded over its recording.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh; see
//  docs/wine-in-process-helpers.md#input-recorder.
//

#import <Cocoa/Cocoa.h>
#import <os/log.h>
#import "helper_common.h"

static const char *kHelper = "InputRecorder";
static os_log_t gLog;
static int gFile = -1;
static NSTimeInterval gStarted;

#define debugLog(...) helperDebugLog(gLog, kHelper, __VA_ARGS__)

/// `value` to `places` decimal places, as a number JSON writes as it reads
/// (a double would come out as 0.78969999999999996).
static NSDecimalNumber *rounded(double value, int places) {
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.*f", places, value]
                                             locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
}

static void writeLine(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!data || gFile < 0) return;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    // One write, appended, so a line is whole whenever the file is read.
    if (write(gFile, line.bytes, line.length) != (ssize_t)line.length) debugLog("a line wasn't written whole");
}

/// The game window: the biggest visible window this process has, as puppet
/// control acts on.
static NSWindow *gameWindow(void) {
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            best = window;
            bestArea = area;
        }
    }
    return best;
}

static NSString *modifierNames(NSEventModifierFlags flags) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (flags & NSEventModifierFlagControl) [names addObject:@"ctrl"];
    if (flags & NSEventModifierFlagOption) [names addObject:@"alt"];
    if (flags & NSEventModifierFlagShift) [names addObject:@"shift"];
    if (flags & NSEventModifierFlagCommand) [names addObject:@"cmd"];
    return [names componentsJoinedByString:@"+"];
}

static void recordButton(NSEvent *event, NSString *what, NSString *button) {
    NSWindow *window = gameWindow();
    if (!window) return;
    NSPoint screen = event.window ? [event.window convertPointToScreen:event.locationInWindow] : event.locationInWindow;
    NSPoint point = [window convertPointFromScreen:screen];
    CGFloat x = point.x, y = window.frame.size.height - point.y;  // from the top left, as puppet control's are
    NSRect picture = helperGamePicture(window);
    if (picture.size.width < 1 || picture.size.height < 1) return;
    writeLine(@{
        @"t": rounded(event.timestamp - gStarted, 3),
        @"event": what,
        @"button": button,
        @"x": rounded((x - picture.origin.x) / picture.size.width, 4),
        @"y": rounded((y - picture.origin.y) / picture.size.height, 4),
        @"points": [NSString stringWithFormat:@"%.0f,%.0f", x, y],
        @"picture": [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f", picture.origin.x, picture.origin.y,
                     picture.size.width, picture.size.height],
    });
}

static void record(NSEvent *event) {
    CGEventRef cgEvent = event.CGEvent;
    if (cgEvent && CGEventGetIntegerValueField(cgEvent, kCGEventSourceUserData) == kPuppetEventTag) return;
    switch (event.type) {
        case NSEventTypeLeftMouseDown: recordButton(event, @"down", @"left"); break;
        case NSEventTypeLeftMouseUp: recordButton(event, @"up", @"left"); break;
        case NSEventTypeRightMouseDown: recordButton(event, @"down", @"right"); break;
        case NSEventTypeRightMouseUp: recordButton(event, @"up", @"right"); break;
        case NSEventTypeKeyDown: {
            if (event.isARepeat) break;
            NSString *name = helperKeyName(event.keyCode);
            if (!name) {
                debugLog("a key without a name (keycode %d) left out", event.keyCode);
                break;
            }
            NSMutableDictionary *line = [@{@"t": rounded(event.timestamp - gStarted, 3),
                                           @"event": @"key", @"key": name} mutableCopy];
            NSString *mods = modifierNames(event.modifierFlags);
            if (mods.length) line[@"mods"] = mods;
            writeLine(line);
            break;
        }
        default: break;
    }
}

__attribute__((constructor))
static void inputRecorderInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", kHelper);
    const char *path = getenv("INPUT_RECORDER_FILE");
    if (!path || !*path || !processRunsExeNamedBy("INPUT_RECORDER_EXE")) return;
    gFile = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (gFile < 0) {
        helperReport(kHelper, "error", "couldn't open %s to record into", path);
        return;
    }
    gStarted = NSProcessInfo.processInfo.systemUptime;
    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    writeLine(@{@"format": @1, @"exe": @(getenv("INPUT_RECORDER_EXE")), @"started": [iso stringFromDate:[NSDate date]]});
    helperReport(kHelper, "notice", "armed in %s, recording clicks and keys into %s", getenv("INPUT_RECORDER_EXE"), path);
    // AppKit's monitors are the main thread's, which runs once Wine's Cocoa
    // side has started.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown
            | NSEventMaskRightMouseUp | NSEventMaskKeyDown;
        [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
            record(event);
            return event;
        }];
        debugLog("watching the game's events");
    });
}
