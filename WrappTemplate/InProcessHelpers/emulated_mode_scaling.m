//
//  emulated_mode_scaling.m
//  Scales a Direct3D game's picture up to the display when Wine is emulating
//  the display mode the game asked for.
//
//  Old games switch the display to the mode they were made for -- The White
//  Wolf of Icicle Creek asks for 800x600 -- and quit when the switch fails,
//  as it does on a display that has no such mode (a MacBook's built-in one
//  has no 4:3 modes at all). With EmulateModeset on, Wine's win32u says yes
//  to any common mode without touching the real display, and maps the game's
//  windows up to the real display's size: the 800x600 window becomes a
//  1260x945 Mac window on a 1512x945 display, the scale kept equal on both
//  axes. Mouse positions are mapped back down the same way.
//
//  Wine 10's Mac driver doesn't scale what Direct3D draws, though. wined3d
//  presents its 800x600 frame into the window's OpenGL surface, which Wine
//  sizes to the 1260x945 view, so the frame lands in the view's bottom-left
//  corner. (winex11 renders into an offscreen drawable of the game's size and
//  blits it up; winemac has nothing of the kind.)
//
//  So this file gives the OpenGL surface the game's size -- the view's size
//  divided by Wine's scale -- through the CGL surface backing size, which
//  macOS then stretches to fill the view. Wine uses the same mechanism for
//  Retina mode, in -[WineOpenGLContext wine_updateBackingSize:], which does
//  nothing when Retina mode is off, as it is in a wrapp; that method is
//  replaced here.
//
//  The emulated mode comes from win32u (NtUserEnumDisplaySettings, a real
//  export rather than one of its version-specific NtUserCall* codes), called
//  from the game's own thread as Wine makes its context current, which is
//  where Wine's drivers call win32u from too.
//
//  Two more replacements get the scaled window to cover the display and look
//  right there (each explained at its MARK below): a game's borderless window
//  isn't pushed below the menu bar, which would stop Wine treating it as
//  fullscreen, and the bars beside a picture of another shape are black.
//
//  Armed by EMULATED_MODE_SCALING_EXE, in the process running that .exe.
//
//  Built into in_process_helpers.dylib by WrappTemplate/setup-wine.sh; see
//  docs/wine-in-process-helpers.md.
//

// Wine's Mac driver draws Direct3D through OpenGL, deprecated or not.
#define GL_SILENCE_DEPRECATION

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <dlfcn.h>
#include <math.h>

#include "helper_common.h"

static os_log_t gLog;

#if defined(__x86_64__)

// The parts of Windows' DEVMODEW this file reads, laid out as Windows does.
typedef struct {
    uint16_t dmDeviceName[32];
    uint16_t dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    uint32_t dmFields;
    uint8_t union1[16];
    int16_t dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    uint16_t dmFormName[32];
    uint16_t dmLogPixels;
    uint32_t dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    uint8_t rest[220 - 180];
} WineDevMode;
_Static_assert(sizeof(WineDevMode) == 220, "DEVMODEW is 220 bytes");
_Static_assert(__builtin_offsetof(WineDevMode, dmPelsWidth) == 172, "dmPelsWidth is at 172");

// win32u.so's exports are its Unix side, built with the platform's own
// calling convention (not the Microsoft one WINAPI means in PE code).
typedef int (*EnumDisplaySettingsFn)(void *device, uint32_t index, WineDevMode *mode, uint32_t flags);
static EnumDisplaySettingsFn gEnumDisplaySettings;
static const uint32_t kEnumCurrentSettings = (uint32_t)-1;

/// The display mode the game sees, emulated or real; NO if win32u can't say.
static BOOL emulatedModeSize(CGSize *size) {
    if (!gEnumDisplaySettings) return NO;
    WineDevMode mode = {0};
    mode.dmSize = sizeof(mode);
    if (!gEnumDisplaySettings(NULL, kEnumCurrentSettings, &mode, 0) || !mode.dmPelsWidth || !mode.dmPelsHeight) return NO;
    *size = CGSizeMake(mode.dmPelsWidth, mode.dmPelsHeight);
    return YES;
}

#else

static BOOL emulatedModeSize(CGSize *size) { (void)size; return NO; }

#endif

/// How much Wine scales the game's windows up: the real display's size over
/// the mode's, the smaller of the two axes (win32u's monitor_get_dpi). 1
/// when the mode isn't emulated or matches the display.
static CGFloat wineScale(void) {
    CGSize mode;
    if (!emulatedModeSize(&mode)) return 1.0;
    CGSize display = wineMainDisplaySize();
    if (display.width <= 0 || display.height <= 0) return 1.0;
    return fmin(display.width / mode.width, display.height / mode.height);
}

// MARK: - WineOpenGLContext

@interface NSOpenGLContext (WineOpenGLContextMethods)
- (void)wine_updateBackingSize:(const CGSize *)size;
@end

static IMP gWineUpdateBackingSize;
static char kScaledBackingKey;   // the size this file last gave the context's surface, as an NSValue

static void scaledUpdateBackingSize(NSOpenGLContext *self, SEL _cmd, const CGSize *size) {
    ((void (*)(id, SEL, const CGSize *))gWineUpdateBackingSize)(self, _cmd, size);

    // Wine calls this with a size from the thread making the context current,
    // and with NULL (from -clearDrawable) on any thread. win32u can only be
    // asked from a Wine thread, which the main thread isn't.
    if (size && [NSThread isMainThread]) return;
    CGLContextObj cgl = self.CGLContextObj;
    NSValue *previous = objc_getAssociatedObject(self, &kScaledBackingKey);
    CGFloat scale = size ? wineScale() : 1.0;

    if (!size || fabs(scale - 1.0) < 0.01) {
        if (previous) {
            CGLDisable(cgl, kCGLCESurfaceBackingSize);
            objc_setAssociatedObject(self, &kScaledBackingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            os_log(gLog, "[EmulatedMode] surface back to its view's size");
        }
        return;
    }

    GLint backing[2] = { (GLint)lround(size->width / scale), (GLint)lround(size->height / scale) };
    if (backing[0] < 1 || backing[1] < 1) return;
    NSSize wanted = NSMakeSize(backing[0], backing[1]);
    if (previous && NSEqualSizes(previous.sizeValue, wanted)) return;

    CGLSetParameter(cgl, kCGLCPSurfaceBackingSize, backing);
    CGLEnable(cgl, kCGLCESurfaceBackingSize);
    objc_setAssociatedObject(self, &kScaledBackingKey, [NSValue valueWithSize:wanted], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_log(gLog, "[EmulatedMode] surface %dx%d for a %.0fx%.0f view (scale %.3f)",
           backing[0], backing[1], size->width, size->height, scale);
    helperReport("EmulatedMode", "notice", "scaling Direct3D's %dx%d picture up to %.0fx%.0f",
                 backing[0], backing[1], size->width, size->height);
}

// MARK: - WineWindow
//
// Wine scales a window up to cover the whole display only when it exactly
// covers the emulated mode's screen (win32u's map_window_rects_virt_to_raw).
// A game creates its window at the mode's size before switching to it -- an
// 800x600 window at (0,0) of a 1512x945 display -- and AppKit pushes a
// window at the top of the display down below the menu bar. Wine takes the
// new position, the game keeps it, and after the switch its window starts a
// little below the emulated screen's top, so Wine scales it as an ordinary
// window and it covers neither the display nor the menu bar. A game's
// borderless window is left where Wine put it instead; windows with a title
// bar are still kept clear of the menu bar.

static IMP gWineConstrainFrameRect;

static NSRect unconstrainedBorderless(NSWindow *self, SEL _cmd, NSRect frame, NSScreen *screen) {
    if (!(self.styleMask & NSWindowStyleMaskTitled)) return frame;
    return ((NSRect (*)(id, SEL, NSRect, NSScreen *))gWineConstrainFrameRect)(self, _cmd, frame, screen);
}

// MARK: - WineContentView
//
// The scaled window keeps the mode's shape, so on a display of another shape
// Wine centres it in a window covering the whole display: Wine's window spans
// the display, the game's OpenGL view only the middle. The rest of the window
// shows Wine's window surface, which nothing draws into there -- Wine fills a
// new surface with AppKit's light grey window background, so the bars at the
// sides would be grey. Here every surface image a borderless window with an
// OpenGL view gets is painted black outside that view.
//
// The surface doesn't reach the right-hand bar, though: it covers the mode's
// screen scaled up (0-1920 of a 2560-wide display for 800x600), not the
// display, so past it the Mac window's own background shows -- AppKit's
// window background colour, which Wine gives an opaque window in
// -checkTransparency. That window's background is made black too, and again
// whenever -checkTransparency sets it back.

static IMP gWineSetColorImage;
static IMP gWineCheckTransparency;

@interface NSView (WineContentViewMethods)
- (BOOL)hasGLDescendant;
- (void)setColorImage:(CGImageRef)image;
@end

@interface NSWindow (WineWindowMethods)
- (void)checkTransparency;
@end

/// The OpenGL view filling part of a borderless window's content, in the
/// content view's coordinates; NO if there isn't one, or it fills the content.
static BOOL partialGLViewFrame(NSView *content, NSRect *frame) {
    NSWindow *window = content.window;
    if (!window || (window.styleMask & NSWindowStyleMaskTitled) || content.subviews.count != 1) return NO;
    if (![content respondsToSelector:@selector(hasGLDescendant)] || ![content hasGLDescendant]) return NO;
    *frame = content.subviews.firstObject.frame;
    return !NSContainsRect(*frame, content.bounds);
}

/// Makes an opaque window's background black when its content is a partial
/// OpenGL view, so no bar beside the picture shows AppKit's light grey.
static void blackenBackgroundBesideGLView(NSWindow *window) {
    NSRect glFrame;
    if (!window.isOpaque || !partialGLViewFrame(window.contentView, &glFrame)) return;
    if ([window.backgroundColor isEqual:NSColor.blackColor]) return;
    window.backgroundColor = NSColor.blackColor;
}

static void checkTransparencyKeepingBlack(NSWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))gWineCheckTransparency)(self, _cmd);
    blackenBackgroundBesideGLView(self);
}

static void blackOutsideGLView(NSView *self, SEL _cmd, CGImageRef image) {
    NSRect glFrame;
    CGImageRef painted = NULL;
    if (image && partialGLViewFrame(self, &glFrame)) {
        blackenBackgroundBesideGLView(self.window);
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                                     kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        if (context) {
            // The image starts at the content view's top left (-updateLayer);
            // CoreGraphics counts y from the bottom.
            CGRect gl = NSRectToCGRect(glFrame);
            if (self.isFlipped) gl.origin.y = height - CGRectGetMaxY(gl);
            CGContextSetFillColorWithColor(context, CGColorGetConstantColor(kCGColorBlack));
            CGContextFillRect(context, CGRectMake(0, 0, width, height));
            CGContextClipToRect(context, gl);
            CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
            painted = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
        }
    }
    ((void (*)(id, SEL, CGImageRef))gWineSetColorImage)(self, _cmd, painted ? painted : image);
    if (painted) CGImageRelease(painted);
}

__attribute__((constructor))
static void emulatedModeScalingInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "EmulatedMode");
    if (!processRunsExeNamedBy("EMULATED_MODE_SCALING_EXE")) return;

#if defined(__x86_64__)
    gEnumDisplaySettings = (EnumDisplaySettingsFn)dlsym(RTLD_DEFAULT, "NtUserEnumDisplaySettings");
    if (!gEnumDisplaySettings) {
        helperReport("EmulatedMode", "warning", "win32u's NtUserEnumDisplaySettings not found; an emulated mode's picture isn't scaled");
        return;
    }
#endif
    Class context = NSClassFromString(@"WineOpenGLContext");
    Method method = context ? class_getInstanceMethod(context, @selector(wine_updateBackingSize:)) : NULL;
    if (!method) {
        helperReport("EmulatedMode", "warning", "no -[WineOpenGLContext wine_updateBackingSize:]; an emulated mode's picture isn't scaled");
        return;
    }
    gWineUpdateBackingSize = method_setImplementation(method, (IMP)scaledUpdateBackingSize);

    Method setColorImage = class_getInstanceMethod(NSClassFromString(@"WineContentView"), @selector(setColorImage:));
    if (setColorImage) {
        gWineSetColorImage = method_setImplementation(setColorImage, (IMP)blackOutsideGLView);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineContentView setColorImage:]; bars beside a scaled picture are grey");
    }

    Class wineWindow = NSClassFromString(@"WineWindow");
    Method checkTransparency = class_getInstanceMethod(wineWindow, @selector(checkTransparency));
    if (checkTransparency) {
        gWineCheckTransparency = method_setImplementation(checkTransparency, (IMP)checkTransparencyKeepingBlack);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineWindow checkTransparency]; the bar right of a scaled picture may be grey");
    }

    Method constrain = class_getInstanceMethod(wineWindow, @selector(constrainFrameRect:toScreen:));
    if (constrain) {
        gWineConstrainFrameRect = method_setImplementation(constrain, (IMP)unconstrainedBorderless);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineWindow constrainFrameRect:toScreen:]; a game's window may start below the menu bar");
    }
    helperReport("EmulatedMode", "notice", "armed in %s", getenv("EMULATED_MODE_SCALING_EXE"));
}
