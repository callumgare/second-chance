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
//  fullscreen, and the bars beside a picture of another shape are black. And
//  two win32u calls are skipped while the game is in the background, so its
//  picture is still right when the player comes back to it.
//
//  A program drawing with GDI is scaled up by win32u itself, but its picture
//  is shown off-centre from where the mouse is; that's put right here too
//  (see "A GDI picture scaled up"), for a launch that sets a display mode
//  (--wine.display-mode) as much as for a game that switches to one.
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
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
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

// MARK: - Keeping the picture while the game is in the background
//
// When a fullscreen Direct3D game loses focus, wined3d puts the desktop mode
// back and minimizes the game's window (wined3d_swapchain_activate), as
// Windows does. Here that goes wrong twice over:
//
// - The window is restored at once, while the game is still behind other
//   apps: a window in a fullscreen Space can't be minimized, and Wine then
//   restores it. Wine's Mac driver gives the restored window the Mac window's
//   frame (macdrv_ShowWindow), which is in the display's points, not the
//   emulated mode's, so the game's 800x600 window becomes 1512x945 in an
//   800x600 world, scaled up off the screen. Restoring it also makes it the
//   active window again, so when the player really comes back nothing is
//   left to put it right, and wined3d never moves it back to 800x600.
// - With the desktop mode back, Wine stops scaling the window, and the game
//   resets its device as soon as it is restored, before it is in front, so
//   the game's own mode isn't asked for again.
//
// Either way the picture comes back half a screen up with black below. With
// the mode emulated, neither step does anything for the real display, so
// from the moment the game's app is put in the background a request to
// restore the desktop's mode (a NULL mode) and one to minimize a window are
// answered as done without doing them. The window stays in its Space, scaled,
// and on the player's return wined3d activates it as normal, and the game's
// reset finds the mode it asks for already set.
//
// The game hears of losing focus through its message queue, after the app
// has. A quick Cmd-Tab brings the app back before the game has handled
// losing focus, so coming back to the front doesn't end this: the game asking
// for its own mode again (a mode that isn't NULL) does, as wined3d does when
// it handles the return.
//
// The game's Windows side reaches win32u.so's functions through the syscall
// table in win32u.so's __DATA,__data, which ntdll keeps a pointer to; the
// two entries are replaced there.

#if defined(__x86_64__)

typedef int32_t (*ChangeDisplaySettingsFn)(void *device, void *mode, void *hwnd, uint32_t flags, void *lparam);
typedef int32_t (*ShowWindowFn)(void *hwnd, int32_t cmd);
static ChangeDisplaySettingsFn gChangeDisplaySettings;
static ShowWindowFn gShowWindow;
/// Whether the game's app has been in the background since the game last
/// asked for its own mode: set on the main thread as the app resigns active,
/// cleared and read on the game's threads.
static _Atomic BOOL gInBackground;
static _Atomic BOOL gReportedKept;

static BOOL keepingInBackground(const char *what) {
    if (!gInBackground || fabs(wineScale() - 1.0) < 0.01) return NO;
    os_log(gLog, "[EmulatedMode] in the background, so not %{public}s", what);
    if (!gReportedKept) {
        gReportedKept = YES;
        helperReport("EmulatedMode", "notice", "keeping the game's display mode and window while it's in the background");
    }
    return YES;
}

static int32_t changeDisplaySettingsKeepingMode(void *device, void *mode, void *hwnd, uint32_t flags, void *lparam) {
    if (!mode && keepingInBackground("restoring the desktop's display mode")) return 0;   // DISP_CHANGE_SUCCESSFUL
    if (mode && gInBackground) {
        gInBackground = NO;
        os_log(gLog, "[EmulatedMode] the game asked for its mode again, so it has handled coming back");
    }
    return gChangeDisplaySettings(device, mode, hwnd, flags, lparam);
}

static int32_t showWindowKeepingWindow(void *hwnd, int32_t cmd) {
    enum { SW_MINIMIZE = 6 };
    if (cmd == SW_MINIMIZE && keepingInBackground("minimizing the game's window")) return 1;   // it was visible
    return gShowWindow(hwnd, cmd);
}

/// Point win32u's syscall table entry for `name` at `replacement`, returning
/// the original, or NULL if the entry wasn't found.
static void *replaceWin32uSyscall(const struct mach_header_64 *win32u, const char *name, void *replacement) {
    void *original = dlsym(RTLD_DEFAULT, name);
    if (!original) return NULL;
    unsigned long size = 0;
    void **entries = (void **)getsectiondata(win32u, "__DATA", "__data", &size);
    BOOL replaced = NO;
    for (unsigned long i = 0; entries && i < size / sizeof(void *); i++) {
        if (entries[i] != original) continue;
        entries[i] = replacement;
        replaced = YES;
    }
    return replaced ? original : NULL;
}

/// Whether both entries were replaced; neither is unless both are found.
static BOOL keepPictureInBackground(void) {
    const struct mach_header_64 *win32u = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(processIdentityBasename(_dyld_get_image_name(i)), "win32u.so") == 0) {
            win32u = (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    if (!win32u) return NO;
    gChangeDisplaySettings = replaceWin32uSyscall(win32u, "NtUserChangeDisplaySettings", (void *)changeDisplaySettingsKeepingMode);
    if (!gChangeDisplaySettings) return NO;
    gShowWindow = replaceWin32uSyscall(win32u, "NtUserShowWindow", (void *)showWindowKeepingWindow);
    if (!gShowWindow) {
        replaceWin32uSyscall(win32u, "NtUserChangeDisplaySettings", (void *)gChangeDisplaySettings);
        return NO;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) { (void)note; gInBackground = YES; }];
    return YES;
}

#endif

// MARK: - WineOpenGLContext

@interface NSOpenGLContext (WineOpenGLContextMethods)
- (void)wine_updateBackingSize:(const CGSize *)size;
@end

static IMP gWineUpdateBackingSize;
static char kScaledBackingKey;   // the size this file last gave the context's surface, as an NSValue
/// Whether a picture is being scaled up now: set and cleared on Wine's
/// threads, read on the main thread.
static _Atomic BOOL gScaling;

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
            gScaling = NO;
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
    gScaling = YES;
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
// OpenGL view gets is painted black outside that view -- and one with a title
// bar, while a picture is being scaled: White Wolf's window has been seen
// with one, still covering the display, and its right bar white. What gives
// it one is unknown -- not the title bar macOS shows over a fullscreen window
// while the cursor rests at the top of the screen, which leaves the bars
// black without this. An ordinary titled window's OpenGL view fills it.
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
- (BOOL)isFullscreen;
@end

/// The OpenGL view filling part of a borderless window's content -- or a
/// titled one's while a picture is scaled -- in the content view's
/// coordinates; NO if there isn't one, or it fills the content.
static BOOL partialGLViewFrame(NSView *content, NSRect *frame) {
    NSWindow *window = content.window;
    if (!window || content.subviews.count != 1) return NO;
    if ((window.styleMask & NSWindowStyleMaskTitled) && !gScaling) return NO;
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
    if (self.isOpaque && windowShowsScaledPicture(self) && ![self.backgroundColor isEqual:NSColor.blackColor]) {
        self.backgroundColor = NSColor.blackColor;
    }
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

// MARK: - A GDI picture scaled up
//
// A program that draws with GDI (a Director projector, Bioscopia's) is scaled
// up by win32u itself: its window surface is drawn at the emulated mode's
// size and stretched into one at the display's (win32u's scaled_surface).
// Wine's Mac window covers the display, and inside its content view the
// window's client view is centred where the scaled picture belongs, which is
// where the mouse is mapped to (map_window_rects_virt_to_raw). But the
// content view's layer shows the stretched surface from its own top left:
// on a 1920x1080 display, the client view is at 240-1680 while the 800x600
// picture is drawn across 0-1440, so every click lands 240 points to the
// left of what it was aimed at, and past the picture the rest of the surface
// shows, white. (Seen with Wine 10.0 and 11.21, on Bioscopia, 2026-11-07.)
//
// So for such a window, after -[WineContentView updateLayer] has given the
// layer its image, this file crops the image to the client view's size and
// moves the layer to the client view's place, and makes the window's
// background, which the bars beside the picture show, black.

static IMP gWineUpdateLayer;
static BOOL gArmed = NO;
static char kReportedCentringKey;   // the client frame last reported for the window, as an NSValue

/// The rect Wine's window surface covers in its content view: WineContentView's
/// surfaceRect, which -updateLayer places the surface's layer at.
static BOOL wineSurfaceRect(NSView *content, CGRect *rect) {
    Ivar ivar = class_getInstanceVariable(content.class, "surfaceRect");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || strncmp(type, "{CGRect=", 8) != 0) return NO;
    *rect = *(CGRect *)((uint8_t *)(__bridge void *)content + ivar_getOffset(ivar));
    return YES;
}

/// Where the scaled picture belongs in `window`'s content view: its client
/// view's frame, when that is a part of the content view off its top left.
/// NO unless the window shows a scaled GDI picture: borderless, counted by
/// Wine as covering the screen or in a fullscreen Space, with no OpenGL or
/// Metal view drawing into it
/// (whose own placement is right, emulatedModeScaling's OpenGL part above).
static BOOL scaledPictureFrame(NSWindow *window, NSRect *frame) {
    if (!gArmed || !window || (window.styleMask & NSWindowStyleMaskTitled)) return NO;
    // Wine stops counting the window as covering the screen once native
    // fullscreen has put it in a Space, where it still does.
    BOOL inSpace = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    BOOL coversScreen = [window respondsToSelector:@selector(isFullscreen)] && [(id)window isFullscreen];
    if (!inSpace && !coversScreen) return NO;
    NSView *content = window.contentView;
    if (!content || content.subviews.count != 1) return NO;
    if ([content respondsToSelector:@selector(hasGLDescendant)] && [content hasGLDescendant]) return NO;
    NSView *client = content.subviews.firstObject;
    if (![NSStringFromClass(client.class) isEqualToString:NSStringFromClass(content.class)]) return NO;
    NSRect clientFrame = client.frame;
    if (NSEqualPoints(clientFrame.origin, NSZeroPoint) || !NSContainsRect(content.bounds, clientFrame)) return NO;
    if (clientFrame.size.width < 1.0 || clientFrame.size.height < 1.0) return NO;
    *frame = clientFrame;
    return YES;
}

int windowShowsScaledPicture(NSWindow *window) {
    NSRect frame;
    return scaledPictureFrame(window, &frame);
}

static void centredUpdateLayer(NSView *self, SEL _cmd) {
    ((void (*)(id, SEL))gWineUpdateLayer)(self, _cmd);
    NSWindow *window = self.window;
    NSRect picture;
    if (!window || window.contentView != self || !scaledPictureFrame(window, &picture)) return;
    CALayer *layer = self.layer;
    CGImageRef image = (__bridge CGImageRef)layer.contents;
    CGRect surface;
    if (!image || CFGetTypeID(image) != CGImageGetTypeID() || !wineSurfaceRect(self, &surface)) return;

    // The picture starts at the image's top left; the image is in pixels.
    CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1.0;
    CGRect crop = CGRectMake(0, 0, picture.size.width * scale, picture.size.height * scale);
    if (CGImageGetWidth(image) > crop.size.width + 0.5 || CGImageGetHeight(image) > crop.size.height + 0.5) {
        CGImageRef cropped = CGImageCreateWithImageInRect(image, crop);
        if (cropped) {
            layer.contents = (__bridge id)cropped;
            CGImageRelease(cropped);
        }
    }
    layer.position = CGPointMake(surface.origin.x + picture.origin.x, surface.origin.y + picture.origin.y);
    if (window.isOpaque && ![window.backgroundColor isEqual:NSColor.blackColor]) window.backgroundColor = NSColor.blackColor;

    NSValue *now = [NSValue valueWithRect:picture];
    if ([objc_getAssociatedObject(window, &kReportedCentringKey) isEqual:now]) return;
    objc_setAssociatedObject(window, &kReportedCentringKey, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    os_log(gLog, "[EmulatedMode] placing the scaled picture at %.0f,%.0f, %.0fx%.0f, in a %.0fx%.0f window",
           picture.origin.x, picture.origin.y, picture.size.width, picture.size.height, self.bounds.size.width, self.bounds.size.height);
    helperReport("EmulatedMode", "notice", "placing the program's scaled picture at %.0f,%.0f, %.0fx%.0f, in its %.0fx%.0f window",
                 picture.origin.x, picture.origin.y, picture.size.width, picture.size.height,
                 self.bounds.size.width, self.bounds.size.height);
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
    gWineUpdateBackingSize = replaceOwnMethod(context, @selector(wine_updateBackingSize:), (IMP)scaledUpdateBackingSize);

    Method setColorImage = class_getInstanceMethod(NSClassFromString(@"WineContentView"), @selector(setColorImage:));
    if (setColorImage) {
        gWineSetColorImage = replaceOwnMethod(NSClassFromString(@"WineContentView"), @selector(setColorImage:), (IMP)blackOutsideGLView);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineContentView setColorImage:]; bars beside a scaled picture are grey");
    }
    Class contentView = NSClassFromString(@"WineContentView");
    Ivar surfaceRect = contentView ? class_getInstanceVariable(contentView, "surfaceRect") : NULL;
    if (contentView && surfaceRect && class_getInstanceMethod(contentView, @selector(updateLayer))) {
        gWineUpdateLayer = replaceOwnMethod(contentView, @selector(updateLayer), (IMP)centredUpdateLayer);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineContentView updateLayer] or surfaceRect; a GDI program's scaled picture "
                     "stays off-centre, and clicks miss it");
    }

    Class wineWindow = NSClassFromString(@"WineWindow");
    Method checkTransparency = class_getInstanceMethod(wineWindow, @selector(checkTransparency));
    if (checkTransparency) {
        gWineCheckTransparency = replaceOwnMethod(wineWindow, @selector(checkTransparency), (IMP)checkTransparencyKeepingBlack);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineWindow checkTransparency]; the bar right of a scaled picture may be grey");
    }

    Method constrain = class_getInstanceMethod(wineWindow, @selector(constrainFrameRect:toScreen:));
    if (constrain) {
        gWineConstrainFrameRect = replaceOwnMethod(wineWindow, @selector(constrainFrameRect:toScreen:), (IMP)unconstrainedBorderless);
    } else {
        helperReport("EmulatedMode", "warning", "no -[WineWindow constrainFrameRect:toScreen:]; a game's window may start below the menu bar");
    }
#if defined(__x86_64__)
    if (!keepPictureInBackground()) {
        helperReport("EmulatedMode", "warning", "win32u's syscall table not as expected; "
                     "a game switched away from may come back with its picture misplaced");
    }
#endif
    gArmed = YES;
    helperReport("EmulatedMode", "notice", "armed in %s", getenv("EMULATED_MODE_SCALING_EXE"));
}
