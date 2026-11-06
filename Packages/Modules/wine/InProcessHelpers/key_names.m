//
//  key_names.m
//  The keys the helpers can press, by name: puppet control's keys (sc puppet,
//  WrappPuppeteer) and the quit watch's quit keys (a launch's
//  --wine.quit-key and --wine.quit-confirm-key). One table, so a key one of
//  them can press the other can too, with the same characters; and one
//  reader of a key sequence's canonical form (helperKeySteps), which both
//  are handed. KeySequence (WrappKit's KeyNotation) parses what people
//  write and mirrors this table's names, which KeyNamesTests keeps in step.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import "helper_common.h"

/// A key's virtual keycode (US layout) and whether shift types it: a
/// character, or a name. -1 when it has none.
int helperKeyCode(NSString *name, BOOL *shift) {
    static NSDictionary<NSString *, NSNumber *> *named, *plain;
    static NSString *shifted = @"~!@#$%^&*()_+{}|:\"<>?", *unshifted = @"`1234567890-=[]\\;',./";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        named = @{@"return": @36, @"enter": @36, @"tab": @48, @"space": @49, @"delete": @51, @"backspace": @51,
                  @"escape": @53, @"esc": @53, @"forwarddelete": @117, @"home": @115, @"end": @119,
                  @"pageup": @116, @"pagedown": @121, @"left": @123, @"right": @124, @"down": @125, @"up": @126,
                  @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97, @"f7": @98,
                  @"f8": @100, @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111};
        plain = @{@"a": @0, @"s": @1, @"d": @2, @"f": @3, @"h": @4, @"g": @5, @"z": @6, @"x": @7, @"c": @8,
                  @"v": @9, @"b": @11, @"q": @12, @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17,
                  @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"6": @22, @"5": @23, @"=": @24, @"9": @25,
                  @"7": @26, @"-": @27, @"8": @28, @"0": @29, @"]": @30, @"o": @31, @"u": @32, @"[": @33,
                  @"i": @34, @"p": @35, @"l": @37, @"j": @38, @"'": @39, @"k": @40, @";": @41, @"\\": @42,
                  @",": @43, @"/": @44, @"n": @45, @"m": @46, @".": @47, @"`": @50, @" ": @49};
    });
    *shift = NO;
    NSNumber *code = named[name.lowercaseString];
    if (code) return code.intValue;
    if (name.length != 1) return -1;
    if ((code = plain[name])) return code.intValue;
    if ((code = plain[name.lowercaseString])) {
        *shift = YES;
        return code.intValue;
    }
    NSRange at = [shifted rangeOfString:name];
    if (at.location != NSNotFound) {
        *shift = YES;
        return plain[[unshifted substringWithRange:at]].intValue;
    }
    return -1;
}

/// The characters a key types, for the event: Wine reads the keycode, but
/// AppKit wants characters on a key event.
NSString *helperKeyCharacters(NSString *name, int code) {
    if (name.length == 1) return name;
    switch (code) {
        case 36: return @"\r";
        case 48: return @"\t";
        case 49: return @" ";
        case 51: return @"\x7f";
        case 53: return @"\x1b";
        default: return @"";
    }
}

const HelperModifierKey helperModifierKeys[4] = {
    {NSEventModifierFlagControl, 59}, {NSEventModifierFlagOption, 58},
    {NSEventModifierFlagShift, 56}, {NSEventModifierFlagCommand, 55},
};

/// A modifier's flag by name; 0 for none. The canonical form writes the
/// short names; the rest are read too, as people write them.
static NSEventModifierFlags modifierFlag(NSString *name) {
    static NSDictionary<NSString *, NSNumber *> *flags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flags = @{@"ctrl": @(NSEventModifierFlagControl), @"control": @(NSEventModifierFlagControl),
                  @"alt": @(NSEventModifierFlagOption), @"opt": @(NSEventModifierFlagOption),
                  @"option": @(NSEventModifierFlagOption), @"shift": @(NSEventModifierFlagShift),
                  @"cmd": @(NSEventModifierFlagCommand), @"command": @(NSEventModifierFlagCommand)};
    });
    return flags[name.lowercaseString].unsignedIntegerValue;
}

/// The whole number `text` holds, or -1.
static long wholeNumber(NSString *text) {
    if (text.length == 0 || text.length > 9) return -1;
    if ([text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return -1;
    return text.integerValue;
}

/// A canonical duration, `<n>ms`, in ms; -1 when it isn't one. `allowNone`
/// takes 0ms, as a wait does.
static long canonicalMilliseconds(NSString *value, BOOL allowNone) {
    long milliseconds = [value hasSuffix:@"ms"] ? wholeNumber([value substringToIndex:value.length - 2]) : -1;
    return milliseconds >= (allowNone ? 0 : 1) ? milliseconds : -1;
}

/// One canonical press, `[<mod>+...]<key>[:hold=<ms>ms]`, or why not.
static NSString *readKeyStep(NSString *word, HelperKeyStep *step) {
    memset(step, 0, sizeof(*step));
    NSString *chord = word;
    NSRange hold = [word rangeOfString:@":hold=" options:NSBackwardsSearch];
    if (hold.location != NSNotFound && hold.location > 0) {
        long milliseconds = canonicalMilliseconds([word substringFromIndex:NSMaxRange(hold)], NO);
        if (milliseconds < 1) return [NSString stringWithFormat:@"%@: a hold is :hold=<n>ms", word];
        step->holdMilliseconds = (int)milliseconds;
        chord = [word substringToIndex:hold.location];
    }
    // The last part is the key, `+` itself when the chord ends `++` or is `+`.
    NSString *key = chord;
    NSString *modifiers = @"";
    if ([chord isEqualToString:@"+"]) {
        key = @"+";
    } else if ([chord hasSuffix:@"++"]) {
        key = @"+";
        modifiers = [chord substringToIndex:chord.length - 2];
    } else {
        NSRange plus = [chord rangeOfString:@"+" options:NSBackwardsSearch];
        if (plus.location != NSNotFound) {
            key = [chord substringFromIndex:plus.location + 1];
            modifiers = [chord substringToIndex:plus.location];
        }
    }
    if (modifiers.length > 0) {
        for (NSString *name in [modifiers componentsSeparatedByString:@"+"]) {
            NSEventModifierFlags flag = modifierFlag(name);
            if (!flag) return [NSString stringWithFormat:@"%@: %@ isn't a modifier", word, name];
            step->flags |= flag;
        }
    }
    BOOL shift = NO;
    int code = helperKeyCode(key, &shift);
    if (code < 0 || key.length >= sizeof(step->name)) return [NSString stringWithFormat:@"%@: %@ isn't a key", word, key];
    if (shift) step->flags |= NSEventModifierFlagShift;
    step->code = (unsigned short)code;
    strlcpy(step->name, key.UTF8String, sizeof(step->name));
    return nil;
}

NSData *helperKeySteps(NSString *canonical, NSString **error) {
    NSMutableData *steps = [NSMutableData data];
    long wait = -1;  // the wait read since the last press; -1 for none
    NSString *problem = nil;
    for (NSString *word in [canonical componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length == 0) continue;
        if ([word hasPrefix:@"wait="]) {
            if (steps.length == 0 || wait >= 0) {
                problem = [NSString stringWithFormat:@"%@: a wait goes between two presses", word];
                break;
            }
            wait = canonicalMilliseconds([word substringFromIndex:5], YES);
            if (wait < 0) {
                problem = [NSString stringWithFormat:@"%@: a wait is wait=<n>ms", word];
                break;
            }
            continue;
        }
        if (steps.length > 0 && wait < 0) {
            // The canonical form says every wait, so the helpers have no
            // default of their own.
            problem = [NSString stringWithFormat:@"%@: no wait= before it", word];
            break;
        }
        HelperKeyStep step;
        if ((problem = readKeyStep(word, &step))) break;
        step.waitMilliseconds = (int)MAX(wait, 0);
        wait = -1;
        [steps appendBytes:&step length:sizeof(step)];
    }
    if (!problem && wait >= 0) problem = @"a wait at the end";
    if (!problem && steps.length == 0) problem = @"no keys";
    if (problem) {
        if (error) *error = problem;
        return nil;
    }
    return steps;
}
