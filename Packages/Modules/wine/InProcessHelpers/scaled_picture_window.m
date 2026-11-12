//
//  scaled_picture_window.m
//  Shows a program whose window is its whole emulated screen in a Mac window
//  with a title bar, once the player takes it out of its fullscreen Space.
//
//  A program drawing with GDI in a display mode Wine emulates (a Director
//  projector in the 640x480 its launch set, Webmaster's) has no window of
//  its own: its window is the emulated screen, which win32u scales up to
//  the display, and Wine shows it as a borderless Mac window covering the
//  display. Native fullscreen puts that window in a Space; taken out of it,
//  the window goes back to covering the display, above everything, which
//  isn't what leaving fullscreen looks like anywhere else on a Mac.
//
//  Giving the window a title bar and a smaller frame for real would tell the
//  program its window had shrunk (Wine passes every frame change on), and
//  its picture would be cut short. So the window is shown smaller while Wine
//  and the program go on seeing it cover the screen:
//
//  - The frame. AppKit gets a title bar and a frame of the picture's shape,
//    centred on the screen at three quarters of it (or where the player left
//    it last time), which the player can move and resize, keeping the
//    picture's shape: Wine's live-resize handlers, which would ask the
//    program, are kept out of it. Wine's own record of the
//    frame (-wine_fractionalFrame) stays the one it had, and the frame
//    changes AppKit reports are kept from it (-postWindowFrameChanged:...).
//    A frame Wine sets that isn't the one it has, or a style that drops the
//    title bar, ends this first.
//  - The picture. emulated_mode_scaling.m crops the program's picture from
//    Wine's whole window surface, as it does in the Space, and the layer
//    scales it down to fit the smaller window (scaledPictureWindowNoteShown).
//  - The mouse. Wine works out where a click or move is from the pointer's
//    position on the screen, after checking it's in the window. The events
//    it then posts for the window (-[WineEventQueue postEvent:]) have their
//    position moved from the smaller window to where the picture is on the
//    screen Wine sees; the pointer Wine reads for GetCursorPos (+[NSEvent
//    mouseLocation]) is moved the same, and a warp of the program's
//    (-setCursorPosition:) the other way.
//
//  Going back into a Space (the green button, the Window menu) puts the
//  window back as Wine had it first (native_fullscreen.m calls
//  scaledPictureWindowEnd).
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh; see
//  docs/wine-in-process-helpers.md.
//

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <dlfcn.h>
#include <math.h>

#include "helper_common.h"

static os_log_t gLog;

// Main thread only, but gActive, which says whether any of it applies.
static NSWindow *__weak gWindow;
static volatile BOOL gActive;
static NSRect gTrueFrame;          // the frame Wine and the program go on seeing, AppKit's coordinates
static NSWindowStyleMask gTrueStyle;
static BOOL gTrueShadow;
static NSString *gTrueGravity;
static NSSize gTrueAspect;
static NSRect gLastSmaller;        // the smaller window's frame as the player left it, for next time
static BOOL gHasLastSmaller;
static NSRect gShown;              // the picture on the emulated screen, in the true content view's coordinates
static BOOL gHasShown;

// MARK: - Geometry
//
// Wine counts y down from the top of the main display as it sees it (below
// the notch, display_below_notch.m), which is where the mouse positions in
// its events and its warps are; AppKit counts up from the bottom.

static CGFloat wineScreenHeight(void) {
    return wineMainDisplaySize().height;
}

static NSRect inWineCoordinates(NSRect rect) {
    rect.origin.y = wineScreenHeight() - NSMaxY(rect);
    return rect;
}

/// Where the picture is in the smaller window, in Wine's coordinates: the
/// shown part's shape fitted in the window's content and centred, as the
/// layer's kCAGravityResizeAspect places it.
static NSRect pictureInWindow(NSWindow *window) {
    NSRect content = inWineCoordinates([window contentRectForFrameRect:window.frame]);
    if (!gHasShown || gShown.size.width < 1 || gShown.size.height < 1) return content;
    CGFloat ratio = fmin(content.size.width / gShown.size.width, content.size.height / gShown.size.height);
    CGSize size = CGSizeMake(gShown.size.width * ratio, gShown.size.height * ratio);
    return NSMakeRect(content.origin.x + (content.size.width - size.width) / 2,
                      content.origin.y + (content.size.height - size.height) / 2, size.width, size.height);
}

/// Where the picture is on the screen Wine sees, in its coordinates.
static NSRect pictureOnScreen(void) {
    NSRect window = inWineCoordinates(gTrueFrame);
    return NSMakeRect(window.origin.x + gShown.origin.x, window.origin.y + gShown.origin.y,
                      gShown.size.width, gShown.size.height);
}

static CGFloat clampTo(CGFloat value, CGFloat low, CGFloat high) {
    return fmax(low, fmin(high, value));
}

/// A point in the smaller window to the point on Wine's screen it shows,
/// held to the picture (the bars beside it are its edge). Wine's coordinates.
static CGPoint toScreen(NSWindow *window, CGPoint point) {
    NSRect from = pictureInWindow(window), to = pictureOnScreen();
    if (from.size.width < 1 || from.size.height < 1) return point;
    CGFloat x = to.origin.x + (point.x - from.origin.x) * to.size.width / from.size.width;
    CGFloat y = to.origin.y + (point.y - from.origin.y) * to.size.height / from.size.height;
    return CGPointMake(clampTo(x, NSMinX(to), NSMaxX(to) - 1), clampTo(y, NSMinY(to), NSMaxY(to) - 1));
}

/// The reverse: a point on Wine's screen to where it shows in the window.
static CGPoint toWindow(NSWindow *window, CGPoint point) {
    NSRect from = pictureOnScreen(), to = pictureInWindow(window);
    if (from.size.width < 1 || from.size.height < 1) return point;
    CGFloat x = to.origin.x + (point.x - from.origin.x) * to.size.width / from.size.width;
    CGFloat y = to.origin.y + (point.y - from.origin.y) * to.size.height / from.size.height;
    return CGPointMake(clampTo(x, NSMinX(to), NSMaxX(to) - 1), clampTo(y, NSMinY(to), NSMaxY(to) - 1));
}

/// The frame of the smaller window: where the player last left it, if that's
/// still on the screen, or else the picture's shape in a content area three
/// quarters the size of the screen's visible part, centred in it.
static NSRect smallerFrame(NSWindow *window, NSWindowStyleMask style) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    if (gHasLastSmaller && NSContainsRect(visible, gLastSmaller)) return gLastSmaller;
    CGSize shape = gHasShown ? gShown.size : gTrueFrame.size;
    if (shape.width < 1 || shape.height < 1) shape = CGSizeMake(4, 3);
    NSRect titled = [NSWindow frameRectForContentRect:NSMakeRect(0, 0, 100, 100) styleMask:style];
    CGFloat titleBar = titled.size.height - 100;
    CGFloat ratio = fmin(visible.size.width * 0.75 / shape.width, (visible.size.height - titleBar) * 0.75 / shape.height);
    CGSize content = CGSizeMake(round(shape.width * ratio), round(shape.height * ratio));
    NSRect frame = [NSWindow frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height) styleMask:style];
    frame.origin.x = round(NSMidX(visible) - frame.size.width / 2);
    frame.origin.y = round(NSMidY(visible) - frame.size.height / 2);
    return frame;
}

static const NSWindowStyleMask kSmallerStyle = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;

// MARK: - Keeping Wine's frame

@interface NSWindow (ScaledPictureWineWindowMethods)
- (void)adjustFeaturesForState;
@end

static IMP gWineFractionalFrame, gWinePostFrameChanged, gWineSetFrameFromWine, gWineSetWindowFeatures, gWineAdjustFeatures;
static IMP gWinePreventResizing, gWineWillResize, gWineWillStartLiveResize, gWineDidEndLiveResize;

static BOOL isOurs(id window) {
    return gActive && window && window == gWindow;
}

static NSRect fractionalFrameKept(NSWindow *self, SEL _cmd) {
    if (isOurs(self)) return gTrueFrame;
    return ((NSRect (*)(id, SEL))gWineFractionalFrame)(self, _cmd);
}

static void postFrameChangedUnlessSmaller(NSWindow *self, SEL _cmd, NSRect frame, BOOL fullscreen, BOOL resizing, BOOL skip) {
    if (isOurs(self)) return;
    ((void (*)(id, SEL, NSRect, BOOL, BOOL, BOOL))gWinePostFrameChanged)(self, _cmd, frame, fullscreen, resizing, skip);
}

static void endSmaller(NSWindow *window, const char *why);
static void watchMouseConfinement(void);
static void applyWineConfinement(NSWindow *window);

static void setFrameFromWineEndingSmaller(NSWindow *self, SEL _cmd, NSRect contentRect) {
    if (isOurs(self)) {
        // As Wine reads it: its content rect from the top of the screen.
        NSRect content = contentRect;
        content.origin.y = wineScreenHeight() - NSMaxY(content);
        NSRect frame = [NSWindow frameRectForContentRect:content styleMask:gTrueStyle];
        if (fabs(frame.origin.x - gTrueFrame.origin.x) < 1 && fabs(frame.origin.y - gTrueFrame.origin.y) < 1 &&
            fabs(frame.size.width - gTrueFrame.size.width) < 1 && fabs(frame.size.height - gTrueFrame.size.height) < 1) {
            return;   // the frame it has
        }
        endSmaller(self, "the program moved its window");
    }
    ((void (*)(id, SEL, NSRect))gWineSetFrameFromWine)(self, _cmd, contentRect);
}

static void keepSmallerResizable(NSWindow *self);

static void setWindowFeaturesKeepingTitle(NSWindow *self, SEL _cmd, const void *features) {
    BOOL ours = isOurs(self);
    NSRect frame = self.frame;
    ((void (*)(id, SEL, const void *))gWineSetWindowFeatures)(self, _cmd, features);
    if (!ours || !isOurs(self)) return;
    // Wine gives the window the style the program's window has; that is the
    // one to put back, and the title bar stays meanwhile, at the frame it
    // had: AppKit keeps the content rect through a change of style, so each
    // of these (two whenever the program opens or closes a dialog) cost the
    // window its title bar's height.
    gTrueStyle = self.styleMask & ~NSWindowStyleMaskFullScreen;
    if ((self.styleMask & kSmallerStyle) != kSmallerStyle) {
        self.styleMask = (self.styleMask & ~NSWindowStyleMaskBorderless) | kSmallerStyle;
    }
    if (!NSEqualRects(self.frame, frame)) [self setFrame:frame display:YES];
    // A change of style forgets the content's aspect ratio.
    keepSmallerResizable(self);
}

/// The smallest the window's content may be made: the picture at a third of
/// its size, or 320 points across.
static NSSize smallestContent(void) {
    CGSize shape = gHasShown ? gShown.size : gTrueFrame.size;
    if (shape.width < 1 || shape.height < 1) return NSMakeSize(320, 240);
    CGFloat width = fmax(320, round(shape.width / 3));
    return NSMakeSize(width, round(width * shape.height / shape.width));
}

/// Wine sizes a window it won't let be resized from its own frame, the
/// whole screen's; this one can be resized, keeping the picture's shape, and
/// moved.
static void keepSmallerResizable(NSWindow *self) {
    self.contentMinSize = smallestContent();
    self.contentMaxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    if (gHasShown && gShown.size.width >= 1 && gShown.size.height >= 1) self.contentAspectRatio = gShown.size;
    if (!self.isMovable) self.movable = YES;
}

static void adjustFeaturesKeepingSmaller(NSWindow *self, SEL _cmd) {
    ((void (*)(id, SEL))gWineAdjustFeatures)(self, _cmd);
    if (isOurs(self)) keepSmallerResizable(self);
}

// Resizing it is the player's alone: Wine's handlers would ask the program
// (WM_ENTERSIZEMOVE, WM_SIZING) about a window it thinks covers the screen,
// hold it to that size, and restore it if it counts as maximized.
static BOOL preventResizingUnlessSmaller(NSWindow *self, SEL _cmd) {
    if (isOurs(self)) return NO;
    return ((BOOL (*)(id, SEL))gWinePreventResizing)(self, _cmd);
}

/// The size the player drags the window to, as AppKit proposes it, already
/// held to the picture's shape by contentAspectRatio.
static NSSize willResizeKeepingSmaller(NSWindow *self, SEL _cmd, NSWindow *sender, NSSize size) {
    if (isOurs(self)) return size;
    return ((NSSize (*)(id, SEL, NSWindow *, NSSize))gWineWillResize)(self, _cmd, sender, size);
}

static void willStartLiveResizeKeepingSmaller(NSWindow *self, SEL _cmd, NSNotification *notification) {
    if (isOurs(self)) return;
    ((void (*)(id, SEL, NSNotification *))gWineWillStartLiveResize)(self, _cmd, notification);
}

static void didEndLiveResizeKeepingSmaller(NSWindow *self, SEL _cmd, NSNotification *notification) {
    if (isOurs(self)) {
        [self.contentView setNeedsDisplay:YES];
        return;
    }
    ((void (*)(id, SEL, NSNotification *))gWineDidEndLiveResize)(self, _cmd, notification);
}

// MARK: - The mouse

static IMP gWineHandleMouseMove, gWineHandleMouseButton, gWineHandleScrollWheel, gWinePostEvent, gWineSetCursorPosition;
static IMP gMouseLocation;

typedef NS_ENUM(int, MouseHandling) {
    kHandlingNone = 0,
    kHandlingMove,
    kHandlingButton,
    kHandlingScroll,
};

// Which of Wine's mouse handlers is running, and the button of a click.
// Main thread only.
static MouseHandling gHandling = kHandlingNone;
static NSInteger gButton;

static void handleMouseMoveMarked(id self, SEL _cmd, NSEvent *event) {
    MouseHandling was = gHandling;
    gHandling = kHandlingMove;
    ((void (*)(id, SEL, NSEvent *))gWineHandleMouseMove)(self, _cmd, event);
    gHandling = was;
}

static void handleMouseButtonMarked(id self, SEL _cmd, NSEvent *event) {
    MouseHandling was = gHandling;
    NSInteger button = gButton;
    gHandling = kHandlingButton;
    gButton = event.buttonNumber;
    ((void (*)(id, SEL, NSEvent *))gWineHandleMouseButton)(self, _cmd, event);
    gHandling = was;
    gButton = button;
}

static void handleScrollWheelMarked(id self, SEL _cmd, NSEvent *event) {
    MouseHandling was = gHandling;
    gHandling = kHandlingScroll;
    ((void (*)(id, SEL, NSEvent *))gWineHandleScrollWheel)(self, _cmd, event);
    gHandling = was;
}

// The parts of Wine's macdrv_event (macdrv_cocoa.h) read here. Wine 10 to
// 11.21 lay them out alike: three ints and the window, then the union --
// mouse_moved's x and y first, mouse_button's after its button and pressed
// flag, mouse_scroll's after its two amounts. Which kind an event is comes
// from the handler posting it, not its type, whose number differs between
// versions; a click's is checked by its button, a move's by being a point
// rather than relative movement.
static const size_t kEventWindowOffset = 16, kUnionOffset = 24;

static void moveEventPoint(void *event, size_t offset) {
    int32_t *xy = (int32_t *)((uint8_t *)event + offset);
    NSWindow *window = gWindow;
    CGPoint point = toScreen(window, CGPointMake(xy[0], xy[1]));
    xy[0] = (int32_t)floor(point.x);
    xy[1] = (int32_t)floor(point.y);
}

static void postEventMovingMouse(id self, SEL _cmd, void *event) {
    if (gActive && gHandling != kHandlingNone && event && [NSThread isMainThread]) {
        void *window = *(void **)((uint8_t *)event + kEventWindowOffset);
        NSWindow *ours = gWindow;
        if (ours && window == (__bridge void *)ours) {
            uint8_t *fields = (uint8_t *)event + kUnionOffset;
            if (gHandling == kHandlingMove) {
                // Wine sends relative movement, small numbers, only while the
                // pointer is pinned at an edge of the screen.
                int32_t x = ((int32_t *)fields)[0], y = ((int32_t *)fields)[1];
                if (abs(x) > 32 || abs(y) > 32) moveEventPoint(event, kUnionOffset);
            } else if (gHandling == kHandlingButton) {
                if (*(int32_t *)fields == (int32_t)gButton && fields[4] <= 1) moveEventPoint(event, kUnionOffset + 8);
            } else if (gHandling == kHandlingScroll) {
                moveEventPoint(event, kUnionOffset + 8);
            }
        }
    }
    ((void (*)(id, SEL, void *))gWinePostEvent)(self, _cmd, event);
}

static BOOL setCursorPositionInWindow(id self, SEL _cmd, CGPoint point) {
    NSWindow *window = gWindow;
    if (gActive && window && [NSThread isMainThread]) point = toWindow(window, point);
    return ((BOOL (*)(id, SEL, CGPoint))gWineSetCursorPosition)(self, _cmd, point);
}

NSPoint scaledPictureWindowMouseLocation(NSPoint location) {
    if (!gActive || ![NSThread isMainThread]) return location;
    NSWindow *window = gWindow;
    if (!window || !gHasShown) return location;
    CGFloat height = wineScreenHeight();
    CGPoint point = toScreen(window, CGPointMake(location.x, height - location.y));
    return NSMakePoint(point.x, height - point.y);
}

static const struct mach_header_64 *gWinemac;

static BOOL calledFromWinemac(void *returnAddress) {
    Dl_info info;
    return gWinemac && dladdr(returnAddress, &info) && info.dli_fbase == (const void *)gWinemac;
}

// objc_msgSend tail-calls this, so the return address is in its caller.
static NSPoint mouseLocationForWinemac(id self, SEL _cmd) {
    NSPoint location = ((NSPoint (*)(id, SEL))gMouseLocation)(self, _cmd);
    if (!calledFromWinemac(__builtin_return_address(0))) return location;
    return scaledPictureWindowMouseLocation(location);
}

// MARK: - Starting and ending

/// Replace what this needs of Wine's, once; NO if any of it isn't there.
static BOOL installReplacements(void) {
    static BOOL tried = NO, installed = NO;
    if (tried) return installed;
    tried = YES;
    Class window = NSClassFromString(@"WineWindow");
    Class controller = NSClassFromString(@"WineApplicationController");
    Class queue = NSClassFromString(@"WineEventQueue");
    struct { Class cls; SEL selector; } needed[] = {
        { window, @selector(wine_fractionalFrame) },
        { window, NSSelectorFromString(@"postWindowFrameChanged:fullscreen:resizing:skipSizeMove:") },
        { window, NSSelectorFromString(@"setFrameFromWine:") },
        { window, NSSelectorFromString(@"setWindowFeatures:") },
        { window, @selector(adjustFeaturesForState) },
        { controller, NSSelectorFromString(@"handleMouseMove:") },
        { controller, NSSelectorFromString(@"handleMouseButton:") },
        { controller, NSSelectorFromString(@"handleScrollWheel:") },
        { controller, NSSelectorFromString(@"setCursorPosition:") },
        { queue, NSSelectorFromString(@"postEvent:") },
        { window, NSSelectorFromString(@"preventResizing") },
        { window, @selector(windowWillResize:toSize:) },
        { window, @selector(windowWillStartLiveResize:) },
        { window, @selector(windowDidEndLiveResize:) },
    };
    for (size_t i = 0; i < sizeof(needed) / sizeof(*needed); i++) {
        if (!needed[i].cls || !class_getInstanceMethod(needed[i].cls, needed[i].selector)) {
            helperReport("ScaledPictureWindow", "warning", "Wine has no -[%s %s]; the program stays covering the screen out of fullscreen",
                         needed[i].cls ? class_getName(needed[i].cls) : "?", sel_getName(needed[i].selector));
            return NO;
        }
    }
    gWinemac = loadedImageNamed("winemac.so", NULL, NULL);
    gWineFractionalFrame = replaceOwnMethod(window, needed[0].selector, (IMP)fractionalFrameKept);
    gWinePostFrameChanged = replaceOwnMethod(window, needed[1].selector, (IMP)postFrameChangedUnlessSmaller);
    gWineSetFrameFromWine = replaceOwnMethod(window, needed[2].selector, (IMP)setFrameFromWineEndingSmaller);
    gWineSetWindowFeatures = replaceOwnMethod(window, needed[3].selector, (IMP)setWindowFeaturesKeepingTitle);
    gWineAdjustFeatures = replaceOwnMethod(window, needed[4].selector, (IMP)adjustFeaturesKeepingSmaller);
    gWineHandleMouseMove = replaceOwnMethod(controller, needed[5].selector, (IMP)handleMouseMoveMarked);
    gWineHandleMouseButton = replaceOwnMethod(controller, needed[6].selector, (IMP)handleMouseButtonMarked);
    gWineHandleScrollWheel = replaceOwnMethod(controller, needed[7].selector, (IMP)handleScrollWheelMarked);
    gWineSetCursorPosition = replaceOwnMethod(controller, needed[8].selector, (IMP)setCursorPositionInWindow);
    gWinePostEvent = replaceOwnMethod(queue, needed[9].selector, (IMP)postEventMovingMouse);
    gWinePreventResizing = replaceOwnMethod(window, needed[10].selector, (IMP)preventResizingUnlessSmaller);
    gWineWillResize = replaceOwnMethod(window, needed[11].selector, (IMP)willResizeKeepingSmaller);
    gWineWillStartLiveResize = replaceOwnMethod(window, needed[12].selector, (IMP)willStartLiveResizeKeepingSmaller);
    gWineDidEndLiveResize = replaceOwnMethod(window, needed[13].selector, (IMP)didEndLiveResizeKeepingSmaller);
    // virtual_pointer.m, armed in a test session, already wraps the pointer
    // Wine reads, and moves it through scaledPictureWindowMouseLocation.
    if (!virtualPointerWrapsMouseLocation()) {
        gMouseLocation = method_setImplementation(class_getClassMethod([NSEvent class], @selector(mouseLocation)),
                                                  (IMP)mouseLocationForWinemac);
    }
    installed = YES;
    return YES;
}

int windowIsScaledPictureWindow(NSWindow *window) {
    return isOurs(window);
}

NSRect scaledPictureWindowTrueBounds(NSWindow *window) {
    if (!isOurs(window)) return window.contentView.bounds;
    return NSMakeRect(0, 0, gTrueFrame.size.width, gTrueFrame.size.height);
}

void scaledPictureWindowNoteShown(NSWindow *window, NSRect shown) {
    if (!window || NSIsEmptyRect(shown)) return;
    if (gActive && window != gWindow) return;
    gShown = shown;
    gHasShown = YES;
}

int scaledPictureWindowBegin(NSWindow *window) {
    if (!window || gActive || (window.styleMask & NSWindowStyleMaskFullScreen)) return 0;
    if (!gHasShown) {
        helperReport("ScaledPictureWindow", "notice", "the program's picture hasn't been placed yet; leaving its window covering the screen");
        return 0;
    }
    if (!installReplacements()) return 0;
    gTrueFrame = window.frame;
    gTrueStyle = window.styleMask;
    gTrueShadow = window.hasShadow;
    gTrueGravity = window.contentView.layer.contentsGravity;
    gTrueAspect = window.contentAspectRatio;
    watchMouseConfinement();
    gWindow = window;
    gActive = YES;
    applyWineConfinement(window);

    NSWindowStyleMask style = (gTrueStyle & ~NSWindowStyleMaskBorderless) | kSmallerStyle;
    NSRect frame = smallerFrame(window, style);
    window.styleMask = style;
    window.hasShadow = YES;
    [window setFrame:frame display:YES];
    [window adjustFeaturesForState];
    [window.contentView setNeedsDisplay:YES];
    os_log(gLog, "[ScaledPictureWindow] showing the picture in a %.0fx%.0f window", frame.size.width, frame.size.height);
    helperReport("ScaledPictureWindow", "notice", "out of fullscreen: showing the program's %.0fx%.0f picture in a %.0fx%.0f window",
                 gShown.size.width, gShown.size.height, frame.size.width, frame.size.height);
    return 1;
}

static void endSmaller(NSWindow *window, const char *why) {
    if (!isOurs(window)) return;
    gLastSmaller = window.frame;
    gHasLastSmaller = YES;
    gActive = NO;
    gWindow = nil;
    applyWineConfinement(window);
    // A window with no aspect ratio of its own is resized freely again.
    if (gTrueAspect.width > 0 && gTrueAspect.height > 0) window.contentAspectRatio = gTrueAspect;
    else window.contentResizeIncrements = NSMakeSize(1, 1);
    window.styleMask = gTrueStyle;
    window.hasShadow = gTrueShadow;
    [window setFrame:gTrueFrame display:YES];
    [window adjustFeaturesForState];
    if (gTrueGravity) window.contentView.layer.contentsGravity = gTrueGravity;
    [window.contentView setNeedsDisplay:YES];
    os_log(gLog, "[ScaledPictureWindow] back to covering the screen: %{public}s", why);
    helperReport("ScaledPictureWindow", "notice", "the program's window covers the screen again: %s", why);
}

void scaledPictureWindowEnd(NSWindow *window) {
    endSmaller(window, "going into fullscreen");
}

// MARK: - The bars beside the picture in a Space
//
// In a Space the window covers the screen, the bars beside the picture
// included, so the pointer never leaves it: Wine shows the game's cursor
// over the bars too, and moves it there. Out of a Space, the Mac's cursor
// comes back as the pointer leaves the window, and the game's stays at the
// edge it left by: Wine finds the window under the pointer
// (+[NSWindow windowNumberAtPoint:...] in -handleMouseMove:) and leaves it
// alone if it isn't one of Wine's. So in a Space the bars are windows of
// this file's own, black, children of Wine's window, and the same happens
// at the picture's edge.

@interface SecondChancePictureBarWindow : NSWindow
@end

@implementation SecondChancePictureBarWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface SecondChancePictureBarView : NSView
@end

@implementation SecondChancePictureBarView
- (void)mouseDown:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor]; }
@end

static char kBarsKey;

// Wine keeps the pointer in a fullscreen window's picture when it clips the
// cursor to the window, as win32u does for every window covering the
// monitor: -[NSWindow setMouseConfinementRect:] (private) on the key window,
// a rect, relative to the window, that macOS unions with those of the key
// window's children. So while Wine confines its window, each bar confines
// to its own bounds, and the pointer can go over the bars as well as the
// picture; Wine still pins the position it reports to the program
// (-clipCursorLocation:), so the program's cursor stops at the picture's
// edge. A bar never confines otherwise: alone, its rect would hold the
// pointer in the bars. Shown smaller, the window keeps none: Wine, which
// still sees it cover the screen, goes on clipping, and its rect would hold
// the pointer in the smaller window. What Wine last asked for is kept and
// set again when the window covers the screen again.

@interface NSWindow (SecondChanceMouseConfinement)
- (NSRect)mouseConfinementRect;
- (void)setMouseConfinementRect:(NSRect)rect;
@end

static IMP gWineSetMouseConfinement;
static char kWineConfinementKey;

static void confineBarsLikeParent(NSWindow *window);

static void setConfinement(NSWindow *window, NSRect rect) {
    if (!gWineSetMouseConfinement) return;
    ((void (*)(id, SEL, NSRect))gWineSetMouseConfinement)(window, @selector(setMouseConfinementRect:), rect);
}

static void applyWineConfinement(NSWindow *window) {
    if (!gWineSetMouseConfinement) return;
    NSValue *wine = objc_getAssociatedObject(window, &kWineConfinementKey);
    NSRect rect = isOurs(window) || !wine ? NSZeroRect : wine.rectValue;
    if (!NSEqualRects(window.mouseConfinementRect, rect)) {
        helperReport("ScaledPictureWindow", "notice", NSIsEmptyRect(rect) ? "the pointer is free of the program's window"
                                                                          : "the pointer is held in the program's window again, as Wine asked");
        setConfinement(window, rect);
    }
    confineBarsLikeParent(window);
}

static void confineBarsLikeParent(NSWindow *window) {
    NSArray<NSWindow *> *bars = objc_getAssociatedObject(window, &kBarsKey);
    if (!bars || ![window respondsToSelector:@selector(mouseConfinementRect)]) return;
    BOOL confined = !NSIsEmptyRect(window.mouseConfinementRect);
    for (NSWindow *bar in bars) {
        NSRect rect = confined && bar.parentWindow == window ? bar.contentView.bounds : NSZeroRect;
        if (!NSEqualRects(bar.mouseConfinementRect, rect)) bar.mouseConfinementRect = rect;
    }
}

static void setMouseConfinementWithBars(NSWindow *self, SEL _cmd, NSRect rect) {
    NSValue *before = objc_getAssociatedObject(self, &kWineConfinementKey);
    if (!before || !NSEqualRects(before.rectValue, rect)) {
        helperReport("ScaledPictureWindow", "notice", "Wine %s the pointer in its window%s",
                     NSIsEmptyRect(rect) ? "lets go of" : "holds", isOurs(self) ? " (shown smaller: left free)" : "");
    }
    objc_setAssociatedObject(self, &kWineConfinementKey, [NSValue valueWithRect:rect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    applyWineConfinement(self);
}

static void watchMouseConfinement(void) {
    static BOOL attempted = NO;
    if (attempted) return;
    attempted = YES;
    SEL selector = @selector(setMouseConfinementRect:);
    Class window = NSClassFromString(@"WineWindow");
    if (window && [NSWindow instancesRespondToSelector:selector] && [NSWindow instancesRespondToSelector:@selector(mouseConfinementRect)]) {
        gWineSetMouseConfinement = replaceOwnMethod(window, selector, (IMP)setMouseConfinementWithBars);
    }
    // A rect Wine set before now is the one it asked for.
    for (NSWindow *each in NSApp.windows) {
        if (gWineSetMouseConfinement && [each isKindOfClass:window] && !isOurs(each) && !objc_getAssociatedObject(each, &kWineConfinementKey))
            objc_setAssociatedObject(each, &kWineConfinementKey, [NSValue valueWithRect:each.mouseConfinementRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!gWineSetMouseConfinement) {
        helperReport("ScaledPictureWindow", "warning",
                     "no -setMouseConfinementRect: to follow; while Wine clips the cursor, the pointer stays off the bars beside the picture");
    }
}

static NSWindow *newBar(void) {
    NSWindow *bar = [[SecondChancePictureBarWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                                                    styleMask:NSWindowStyleMaskBorderless
                                                                      backing:NSBackingStoreBuffered defer:NO];
    bar.releasedWhenClosed = NO;
    bar.opaque = YES;
    bar.backgroundColor = NSColor.blackColor;
    bar.hasShadow = NO;
    bar.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle |
                             NSWindowCollectionBehaviorTransient;
    bar.contentView = [[SecondChancePictureBarView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    return bar;
}

void scaledPictureBarsRemove(NSWindow *window) {
    NSArray<NSWindow *> *bars = objc_getAssociatedObject(window, &kBarsKey);
    if (!bars) return;
    objc_setAssociatedObject(window, &kBarsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSWindow *bar in bars) {
        if ([bar respondsToSelector:@selector(setMouseConfinementRect:)]) bar.mouseConfinementRect = NSZeroRect;
        if (bar.parentWindow) [bar.parentWindow removeChildWindow:bar];
        [bar orderOut:nil];
    }
}

void scaledPictureBarsShow(NSWindow *window, NSRect picture) {
    watchMouseConfinement();
    NSScreen *screen = window.screen;
    // Only once the window is in its Space, covering its screen: not while
    // it moves in or out, nor shown smaller.
    if (!screen || !(window.styleMask & NSWindowStyleMaskFullScreen) || isOurs(window) || !window.isVisible ||
        !NSEqualRects(NSIntegralRect(window.frame), NSIntegralRect(screen.frame))) {
        scaledPictureBarsRemove(window);
        return;
    }
    NSRect frame = window.frame;
    picture = NSIntersectionRect(NSIntegralRect(picture), frame);
    NSRect sides[4] = {
        NSMakeRect(NSMinX(frame), NSMinY(frame), NSMinX(picture) - NSMinX(frame), frame.size.height),
        NSMakeRect(NSMaxX(picture), NSMinY(frame), NSMaxX(frame) - NSMaxX(picture), frame.size.height),
        NSMakeRect(NSMinX(picture), NSMinY(frame), picture.size.width, NSMinY(picture) - NSMinY(frame)),
        NSMakeRect(NSMinX(picture), NSMaxY(picture), picture.size.width, NSMaxY(frame) - NSMaxY(picture)),
    };
    BOOL any = NO;
    for (int i = 0; i < 4; i++) any = any || (sides[i].size.width >= 1 && sides[i].size.height >= 1);
    if (!any || NSIsEmptyRect(picture)) {
        scaledPictureBarsRemove(window);
        return;
    }
    NSArray<NSWindow *> *bars = objc_getAssociatedObject(window, &kBarsKey);
    BOOL made = NO;
    if (!bars) {
        bars = @[newBar(), newBar(), newBar(), newBar()];
        objc_setAssociatedObject(window, &kBarsKey, bars, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        made = YES;
    }
    for (int i = 0; i < 4; i++) {
        NSWindow *bar = bars[i];
        if (sides[i].size.width < 1 || sides[i].size.height < 1) {
            if (bar.parentWindow) [bar.parentWindow removeChildWindow:bar];
            if (bar.isVisible) [bar orderOut:nil];
            continue;
        }
        if (!NSEqualRects(bar.frame, sides[i])) [bar setFrame:sides[i] display:NO];
        if (bar.parentWindow != window) [window addChildWindow:bar ordered:NSWindowAbove];
        [bar.contentView.window invalidateCursorRectsForView:bar.contentView];
    }
    confineBarsLikeParent(window);
    if (made) {
        helperReport("ScaledPictureWindow", "notice", "in its Space: the bars beside the program's %.0fx%.0f picture are windows of their own",
                     picture.size.width, picture.size.height);
    }
}

__attribute__((constructor))
static void scaledPictureWindowInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "ScaledPictureWindow");
}
