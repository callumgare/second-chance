//
//  key_names.m
//  The keys the helpers can press, by name: puppet control's keys (sc puppet,
//  WrappPuppeteer) and the quit watch's quit keys (a launch's
//  --wine.quit-key and --wine.quit-confirm-key). One table, so a key one of
//  them can press the other can too, with the same characters.
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
