//
//  basilisk_mac.m
//  What the wrapp needs of Basilisk II's own process, the emulated classic
//  Mac's window (docs/modules.md#the-basilisk-modules-mac).
//
//  Armed by BASILISK_MAC_EXE (set by the wrapp's BasiliskRuntime on every
//  launch), in the process running the executable it names:
//
//  - **Its picture.** Basilisk II presents a frame only when the Mac's screen
//    changes, and macOS drops what a window presents while it counts the
//    window as occluded, which it does from the start for a window on a
//    screen nobody is watching (a test user's background login, where the
//    window counted as occluded though it was frontmost and on screen). So
//    the Mac boots to the Finder behind a stale "Welcome to Macintosh" until
//    something both marks the window visible and makes Basilisk present
//    again. A picture of the window taken in-process (ScreenCaptureKit, as
//    puppet control's `capture`, needing no permission) marks it visible;
//    then an SDL "exposed" event, which Basilisk II answers with a full
//    redraw, puts the Mac's current screen in it. The exposed event goes
//    again whenever the window becomes visible or changes size. It isn't
//    pictured again after that: each picture stalls Basilisk II for most of
//    a second, which a picture twice a second made the game's sound and
//    video stutter.
//  - **The Mac's first pointer position.** The Finder doesn't draw its
//    desktop until the Mac has one, which it gets only when the pointer
//    moves over the window. So it's given one as an SDL event, where the
//    person's pointer is if it's over the window, else in the middle; never
//    once the person has moved the pointer there, and the person's pointer
//    itself is never moved.
//  - **The green button.** Basilisk II's window is a fixed size, which macOS
//    gives no fullscreen button: it's made fullscreen-capable and resizable
//    (keeping the screen's shape), and in fullscreen Basilisk II's pointer
//    grab and hidden menu bar are undone, so the title bar can be reached to
//    leave it. It starts windowed.
//  - **Shutting the Mac down.** SIGUSR2 (the wrapp's, when it quits), and
//    the app's own Quit (⌘Q, which SDL would turn into the power key alone,
//    leaving the Mac asking "shut down now?"), raise
//    the Mac's power key, as Basilisk II does for SIGTERM, then presses
//    Return, Shut Down being the dialog's default, until the Mac has shut
//    down and Basilisk II exits: its disk is left clean, the person's files
//    on it safe. The wrapp ends it only if this hasn't in its time.
//  - **A build's automation.** With BASILISK_MAC_AUTOMATION naming a script
//    (the basilisk module's BASILISK.RUN), the Mac is driven by it once its
//    window is up, a line at a time: puppet control's requests (`click 440
//    418`, `key cmd+down`), `type <text>`, `wait <seconds>`, and `wait-for
//    <seconds> <text>`, which waits for the text to be on the Mac's screen
//    (read from a picture of the window by Vision), `wait-gone <seconds>
//    <text>`, for it to go, and `wait-restart <seconds>`, for the Mac to
//    restart (its startup disk marked unmounted cleanly, then mounted again).
//    A request the window
//    can't take yet, as while the Mac restarts, is tried again for a while.
//    Then the Mac is shut down. How it went is a report line,
//    `automation finished` or `automation failed at line <n>`, and a
//    failure leaves a picture of the screen in BASILISK_MAC_AUTOMATION_PICTURES.

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Vision/Vision.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>
#import "helper_common.h"

static const char *kHelper = "BasiliskMac";

static void quitShutsDown(void);
static void giveGreenButton(NSWindow *window);

/// Basilisk II's window: its one titled, visible window.
static NSWindow *macWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if (window.visible && (window.styleMask & NSWindowStyleMaskTitled)) return window;
    }
    return nil;
}

static BOOL countsAsVisible(NSWindow *window) {
    return (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

#pragma mark - Its picture

/// SDL2's SDL_WindowEvent, as it is laid out in the 56-byte SDL_Event union.
typedef struct {
    uint32_t type;       // SDL_WINDOWEVENT, 0x200
    uint32_t timestamp;
    uint32_t windowID;
    uint8_t event;       // SDL_WINDOWEVENT_EXPOSED, 3
    uint8_t padding[3];
    int32_t data1;
    int32_t data2;
    uint8_t rest[56 - 24];
} SDLWindowEvent;

/// Have Basilisk II redraw the whole Mac screen: an SDL "exposed" event,
/// which its event loop answers with force_complete_window_refresh(); said
/// in the log with `why`, unless it's NULL. SDL2
/// is Basilisk II's, found when needed, as this dylib goes into other
/// programs too.
static void redrawAll(const char *why) {
    typedef int (*PushEvent)(void *);
    static PushEvent push;
    if (!push) push = (PushEvent)dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    if (!push) {
        helperReport(kHelper, "warning", "can't redraw the Mac's screen: no SDL_PushEvent");
        return;
    }
    SDLWindowEvent event = { .type = 0x200, .windowID = 1, .event = 3 };
    if (push(&event) < 0) helperReport(kHelper, "warning", "can't redraw the Mac's screen: SDL_PushEvent failed");
    else if (why) helperReport(kHelper, "notice", "redrawing the Mac's screen (%s)", why);
}

/// Whether the person (or puppet control) has moved the pointer over the
/// window: then the Mac has its pointer, and nothing more is given it.
static BOOL pointerMoved = NO;

/// SDL2's SDL_MouseMotionEvent, as laid out in the 56-byte SDL_Event union.
typedef struct {
    uint32_t type;       // SDL_MOUSEMOTION, 0x400
    uint32_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t state;
    int32_t x, y, xrel, yrel;
    uint8_t rest[56 - 36];
} SDLMouseMotionEvent;

/// The Mac's first pointer position: the Mac waits for one before the
/// Finder draws its desktop, and gets none until the pointer moves over the
/// window. Given to Basilisk II as an SDL event, so the Mac's pointer goes
/// where the person's is if it's over the window, else to the middle of the
/// screen, and the person's pointer is never moved.
static void givePointer(NSWindow *window) {
    if (pointerMoved) return;
    typedef int (*PushEvent)(void *);
    typedef uint32_t (*GetMouseState)(int *, int *);
    typedef void *(*GetMouseFocus)(void);
    PushEvent push = (PushEvent)dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    GetMouseState mouseState = (GetMouseState)dlsym(RTLD_DEFAULT, "SDL_GetMouseState");
    GetMouseFocus mouseFocus = (GetMouseFocus)dlsym(RTLD_DEFAULT, "SDL_GetMouseFocus");
    if (!push) return;
    NSSize content = window.contentView.frame.size;
    int x = (int)(content.width / 2), y = (int)(content.height / 2);
    if (mouseState && mouseFocus && mouseFocus()) mouseState(&x, &y);
    SDLMouseMotionEvent event = { .type = 0x400, .windowID = 1, .x = x, .y = y };
    if (push(&event) >= 0) helperReport(kHelper, "notice", "gave the Mac its pointer at %d,%d", x, y);
}

/// Whether ScreenCaptureKit can picture this process's own windows (macOS
/// 14.4), asked of it rather than with @available, as puppet_control.m does.
static BOOL canPictureOwnWindows(void) {
    Class content = NSClassFromString(@"SCShareableContent");
    return [content respondsToSelector:@selector(getCurrentProcessShareableContentWithCompletionHandler:)];
}

/// Whether a picture has failed yet: said once, not twice a second.
static BOOL pictureFailed = NO;

/// A small picture of the window, taken only for macOS to count the window
/// as visible and put what it presented on the screen; the picture itself is
/// thrown away.
static void pictureWindow(CGWindowID windowID) {
    if (!canPictureOwnWindows()) {
        helperReport(kHelper, "warning", "the Mac's window counts as hidden, and this macOS can't picture it to show it");
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        SCWindow *found = nil;
        for (SCWindow *window in content.windows) {
            if (window.windowID == windowID) found = window;
        }
        if (!found) {
            if (!pictureFailed) helperReport(kHelper, "warning", "the Mac's window isn't among this process's windows (%s)",
                                             error.localizedDescription.UTF8String ?: "no error");
            pictureFailed = YES;
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:found];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = 64;
        config.height = 48;
        config.showsCursor = NO;
        [SCScreenshotManager captureImageWithFilter:filter configuration:config
                                  completionHandler:^(CGImageRef image, NSError *captureError) {
            if (!image && !pictureFailed) {
                pictureFailed = YES;
                helperReport(kHelper, "warning", "picturing the Mac's window failed: %s",
                             captureError.localizedDescription.UTF8String ?: "no error");
            }
        }];
    }];
#pragma clang diagnostic pop
}

/// Until macOS counts the window as visible: a picture of it now and then (a
/// few tries, a while apart), the exposed event following from the change.
static void showWindow(NSWindow *window, int tries) {
    if (countsAsVisible(window)) return;
    if (tries == 0) helperReport(kHelper, "notice", "the Mac's window counts as hidden: picturing it to show it");
    if (tries >= 6) {
        helperReport(kHelper, "warning", "the Mac's window still counts as hidden after %d pictures", tries);
        return;
    }
    pictureWindow((CGWindowID)window.windowNumber);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 + tries) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showWindow(window, tries + 1);
    });
}

/// Until the window shows (a minute at most), then: shown if it counts as
/// hidden, and redrawn whenever it becomes visible or changes size.
static void watchForWindow(int tries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp ? macWindow() : nil;
        if (!window) {
            if (tries < 240) watchForWindow(tries + 1);
            else helperReport(kHelper, "warning", "no window to show after a minute");
            return;
        }
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:NSWindowDidChangeOcclusionStateNotification object:window queue:nil
                        usingBlock:^(NSNotification *note) {
            helperReport(kHelper, "notice", "the Mac's window counts as %s", countsAsVisible(window) ? "visible" : "hidden");
            // What it presented while hidden was dropped.
            if (countsAsVisible(window)) redrawAll("the window became visible");
        }];
        [center addObserverForName:NSWindowDidResizeNotification object:window queue:nil
                        usingBlock:^(NSNotification *note) { redrawAll("the window changed size"); }];
        // The person's own pointer over the window: the Mac has it from them.
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
            if (event.window == window) pointerMoved = YES;
            return event;
        }];
        showWindow(window, 0);
        givePointer(window);
        quitShutsDown();
        giveGreenButton(window);
    });
}

#pragma mark - The green button

/// The window made able to go fullscreen (its green button), and resizable,
/// keeping the Mac screen's shape when dragged. Basilisk II opens a fixed-size
/// window, which macOS gives no fullscreen button.
static void markFullscreenCapable(NSWindow *window) {
    if (!(window.styleMask & NSWindowStyleMaskTitled)) return;
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.styleMask |= NSWindowStyleMaskResizable;
    NSSize content = window.contentView.frame.size;
    if (content.width > 0 && content.height > 0 && !(window.styleMask & NSWindowStyleMaskFullScreen)) {
        window.contentAspectRatio = content;
    }
}

/// In fullscreen Basilisk II grabs the pointer and hides the menu bar for
/// good (video_sdl2.cpp, utils_macosx.mm), so the pointer can't reach the top
/// edge where macOS shows the title bar again: the grab let go (SDL's own
/// calls, found in the process) and macOS's auto-hiding menu bar given back.
static void releaseFullscreenLocks(void) {
    typedef void *(*GetWindow)(void);
    typedef void (*SetGrab)(void *, int);
    typedef int (*GetRelative)(void);
    typedef int (*SetRelative)(int);
    GetWindow grabbed = (GetWindow)dlsym(RTLD_DEFAULT, "SDL_GetGrabbedWindow");
    GetWindow focus = (GetWindow)dlsym(RTLD_DEFAULT, "SDL_GetMouseFocus");
    SetGrab setGrab = (SetGrab)dlsym(RTLD_DEFAULT, "SDL_SetWindowGrab");
    GetRelative getRelative = (GetRelative)dlsym(RTLD_DEFAULT, "SDL_GetRelativeMouseMode");
    SetRelative setRelative = (SetRelative)dlsym(RTLD_DEFAULT, "SDL_SetRelativeMouseMode");
    void *held = grabbed ? grabbed() : NULL;
    void *focused = focus ? focus() : NULL;
    if (setGrab && held) setGrab(held, 0);
    if (setGrab && focused) setGrab(focused, 0);
    if (getRelative && setRelative && getRelative()) setRelative(0);
    [NSMenu setMenuBarVisible:YES];
    NSApp.presentationOptions = NSApplicationPresentationFullScreen | NSApplicationPresentationAutoHideMenuBar
        | NSApplicationPresentationAutoHideDock;
}

/// The green button on the window, and kept there: Basilisk II reacts to
/// fullscreen a little after AppKit says so, and leaving it SDL puts the
/// window's fixed size back, so each is answered a few times over a second.
static void giveGreenButton(NSWindow *window) {
    markFullscreenCapable(window);
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    void (^repeat)(void (^)(void)) = ^(void (^work)(void)) {
        for (int i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 250) * NSEC_PER_MSEC), dispatch_get_main_queue(), work);
        }
    };
    [center addObserverForName:NSWindowDidBecomeKeyNotification object:window queue:nil
                    usingBlock:^(NSNotification *note) { markFullscreenCapable(window); }];
    [center addObserverForName:NSWindowDidEnterFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification *note) {
        helperReport(kHelper, "notice", "the Mac's window is fullscreen");
        repeat(^{ releaseFullscreenLocks(); });
    }];
    [center addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:nil
                    usingBlock:^(NSNotification *note) {
        helperReport(kHelper, "notice", "the Mac's window left fullscreen");
        repeat(^{ markFullscreenCapable(window); });
    }];
    helperReport(kHelper, "notice", "the Mac's window has its green button");
}

#pragma mark - Shutting the Mac down

/// Return, pressed and let go, to the window.
static void pressReturn(NSWindow *window) {
    NSEventType types[2] = { NSEventTypeKeyDown, NSEventTypeKeyUp };
    for (int i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:types[i] location:NSZeroPoint modifierFlags:0
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:window.windowNumber context:nil characters:@"\r"
                       charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        if (event) [NSApp postEvent:event atStart:NO];
    }
}

/// SIGUSR2, the app's Quit, or the end of an automation: shut the Mac
/// down, as its power key and Return would. Once.
static void startShutDown(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    helperReport(kHelper, "notice", "shutting the Mac down");
    // Basilisk II turns SIGTERM into the Mac's power key, which asks "shut
    // down now?" with Shut Down as its default.
    kill(getpid(), SIGTERM);
    // Return once the dialog may be up, again every two seconds, while the
    // process lasts; the wrapp ends it if the Mac never shuts down.
    for (int i = 0; i < 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 + 2 * i) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSWindow *window = macWindow();
            if (window) pressReturn(window);
        });
    }
}

/// The app's Quit (⌘Q, the Dock's Quit, puppet control's `quit`) shuts the
/// Mac down as SIGUSR2 does, rather than asking the Mac "shut down now?"
/// and waiting there. SDL's own NSApplication subclass answers -terminate:
/// itself with SDL's quit event, which Basilisk II makes the power key alone,
/// so it's -terminate: on that class that's replaced (the app delegate's
/// -applicationShouldTerminate: is never asked).
static void shutDownForTerminate(id self, SEL _cmd, id sender) {
    startShutDown();
}

static void quitShutsDown(void) {
    Class app = object_getClass(NSApp);
    if (!app) {
        helperReport(kHelper, "warning", "the app's Quit can't shut the Mac down: there's no app yet");
        return;
    }
    class_replaceMethod(app, @selector(terminate:), (IMP)shutDownForTerminate, "v@:@");
    helperReport(kHelper, "notice", "the app's Quit shuts the Mac down (%s)", class_getName(app));
}

#pragma mark - A build's automation

/// puppet_control.m's requests, answered in this process.
NSString *puppetControlRequest(NSString *line);

/// A request the window can't take yet (the Mac restarting, its window
/// made again) is tried again for this long.
static const int kRetrySeconds = 90;

/// The window pictured at full size, or NULL (no window, or no picture yet).
/// Not on the main thread: it waits for ScreenCaptureKit.
static CGImageRef copyWindowPicture(void) {
    if (!canPictureOwnWindows()) return NULL;
    __block CGWindowID windowID = 0;
    __block NSSize size = NSZeroSize;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSWindow *window = macWindow();
        if (!window) return;
        windowID = (CGWindowID)window.windowNumber;
        size = window.frame.size;
    });
    if (!windowID) return NULL;
    __block CGImageRef picture = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        SCWindow *found = nil;
        for (SCWindow *window in content.windows) {
            if (window.windowID == windowID) found = window;
        }
        if (!found) {
            dispatch_semaphore_signal(done);
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:found];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        // Twice the Mac's pixels: the Mac's small bitmap fonts read better.
        config.width = (size_t)size.width * 2;
        config.height = (size_t)size.height * 2;
        config.showsCursor = NO;
        [SCScreenshotManager captureImageWithFilter:filter configuration:config
                                  completionHandler:^(CGImageRef image, NSError *captureError) {
            if (image) picture = CGImageRetain(image);
            dispatch_semaphore_signal(done);
        }];
    }];
#pragma clang diagnostic pop
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return picture;
}

/// The text Vision reads in `picture`, lines joined by newlines; loaded
/// when first needed, so the dylib doesn't bring Vision into every program
/// it's inserted into.
static NSString *textIn(CGImageRef picture) {
    static Class requestClass, handlerClass;
    if (!requestClass) {
        dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
        requestClass = NSClassFromString(@"VNRecognizeTextRequest");
        handlerClass = NSClassFromString(@"VNImageRequestHandler");
    }
    if (!requestClass || !handlerClass) return nil;
    VNRecognizeTextRequest *request = [[requestClass alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;
    VNImageRequestHandler *handler = [[handlerClass alloc] initWithCGImage:picture options:@{}];
    if (![handler performRequests:@[request] error:nil]) return nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

/// Text compared as the Mac's screen reads: case, and the curly quotes,
/// dashes and ™ the Mac draws that Vision reads loosely, aside.
static NSString *comparable(NSString *text) {
    NSMutableString *plain = [[text lowercaseString] mutableCopy];
    NSDictionary *same = @{ @"’": @"'", @"‘": @"'", @"“": @"\"", @"”": @"\"",
                            @"…": @"...", @"™": @"", @"–": @"-", @"—": @"-" };
    for (NSString *from in same) [plain replaceOccurrencesOfString:from withString:same[from] options:0 range:NSMakeRange(0, plain.length)];
    return [[plain componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            componentsJoinedByString:@""];
}

/// A picture of the screen left where BASILISK_MAC_AUTOMATION_PICTURES says,
/// for whoever looks into a failure.
static void keepPicture(const char *name) {
    const char *folder = getenv("BASILISK_MAC_AUTOMATION_PICTURES");
    if (!folder || !*folder) return;
    CGImageRef picture = copyWindowPicture();
    if (!picture) return;
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/%s.png", folder, name]];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                        CFSTR("public.png"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, picture, NULL);
        if (CGImageDestinationFinalize(destination)) helperReport(kHelper, "notice", "pictured the Mac's screen: %s", url.path.UTF8String);
        CFRelease(destination);
    }
    CGImageRelease(picture);
}

/// `wait-for <seconds> <text>`: until the text is on the Mac's screen, or
/// with `gone` (`wait-gone`), until it isn't. nil when so; else what was
/// there instead.
static NSString *waitForText(NSString *text, double seconds, BOOL gone) {
    NSString *wanted = comparable(text);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSString *last = @"(no picture of the window)";
    do {
        @autoreleasepool {
            // A full redraw first: in a background login what the window
            // presented since the last picture may never have reached it, and
            // the picture would read a screen long gone.
            dispatch_sync(dispatch_get_main_queue(), ^{ redrawAll(NULL); });
            usleep(300 * 1000);
            CGImageRef picture = copyWindowPicture();
            if (picture) {
                NSString *read = textIn(picture) ?: @"";
                CGImageRelease(picture);
                if ([comparable(read) containsString:wanted] != gone) return nil;
                last = read.length ? [read stringByReplacingOccurrencesOfString:@"\n" withString:@" | "] : @"(no text)";
            }
        }
        // Looked at again almost at once: a screen that shows only for a
        // moment, as "Welcome to Macintosh" at a restart, is caught, and each
        // picture holds Basilisk II up for a while anyway.
        usleep(100 * 1000);
    } while ([deadline timeIntervalSinceNow] > 0);
    return [NSString stringWithFormat:gone ? @"\"%@\" was still on the screen after %.0f s; it read: %@"
                                           : @"\"%@\" wasn't on the screen in %.0f s; it read: %@", text, seconds, last];
}

/// The Mac's startup disk: the first `disk` of the prefs Basilisk II was
/// started with (`--config <file>`); nil when it can't be told.
static NSString *startupDisk(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger at = [arguments indexOfObject:@"--config"];
    if (at == NSNotFound || at + 1 >= arguments.count) return nil;
    NSString *prefs = [NSString stringWithContentsOfFile:arguments[at + 1] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [prefs componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"disk "]) return [line substringFromIndex:5];
    }
    return nil;
}

/// Whether the HFS volume in `disk` is marked unmounted cleanly (its Master
/// Directory Block's drAtrb bit 8): -1 when it can't be read.
static int markedClean(NSString *disk) {
    int fd = open(disk.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return -1;
    unsigned char header[12];
    ssize_t got = pread(fd, header, sizeof(header), 1024);
    close(fd);
    if (got != (ssize_t)sizeof(header) || header[0] != 0x42 || header[1] != 0x44) return -1;
    return (header[10] & 0x01) != 0;
}

/// `wait-restart <seconds>`: until the Mac has restarted. Basilisk II keeps
/// its window, and the screens between are gone in a moment, so it's told
/// by the startup disk: Mac OS marks it unmounted cleanly as it restarts, and
/// clears the mark when it mounts it again at boot. nil when so.
static NSString *waitForRestart(double seconds) {
    NSString *disk = startupDisk();
    if (!disk) return @"wait-restart can't tell which is the Mac's startup disk";
    BOOL unmounted = NO;
    int last = -2;
    NSDate *start = [NSDate date];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        int clean = markedClean(disk);
        if (clean < 0) return [NSString stringWithFormat:@"wait-restart can't read %@ as an HFS disk", disk];
        if (clean != last) {
            helperReport(kHelper, "notice", "the Mac's disk is marked %s (%.2f s)", clean ? "clean" : "in use",
                         -[start timeIntervalSinceNow]);
            last = clean;
        }
        if (clean) unmounted = YES;
        else if (unmounted) return nil;
        usleep(20 * 1000);
    }
    return [NSString stringWithFormat:unmounted ? @"the Mac shut its disk for a restart but didn't boot again in %.0f s"
                                                : @"the Mac didn't restart in %.0f s", seconds];
}

/// One request through puppet control, tried again while the window can't
/// take it. nil when done; else the error.
static NSString *request(NSString *line) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kRetrySeconds];
    for (;;) {
        NSString *reply = puppetControlRequest(line);
        if ([reply hasPrefix:@"ok"]) return nil;
        BOOL notYet = [reply hasPrefix:@"error no game window"] || [reply hasPrefix:@"error timed out"]
            || [reply hasPrefix:@"error the event would not land"];
        if (!notYet || [deadline timeIntervalSinceNow] <= 0) return reply;
        sleep(1);
    }
}

/// One line of the script: nil when done, else what went wrong.
static NSString *runLine(NSString *line) {
    NSRange space = [line rangeOfString:@" "];
    NSString *command = space.location == NSNotFound ? line : [line substringToIndex:space.location];
    NSString *rest = space.location == NSNotFound ? @"" :
        [[line substringFromIndex:space.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([command isEqualToString:@"wait"]) {
        double seconds = rest.doubleValue;
        if (seconds <= 0) return @"wait needs a number of seconds";
        usleep((useconds_t)(seconds * 1e6));
        return nil;
    }
    if ([command isEqualToString:@"wait-for"] || [command isEqualToString:@"wait-gone"]) {
        NSRange gap = [rest rangeOfString:@" "];
        double seconds = rest.doubleValue;
        if (gap.location == NSNotFound || seconds <= 0) return [command stringByAppendingString:@" needs a number of seconds, then the text"];
        return waitForText([rest substringFromIndex:gap.location + 1], seconds, [command isEqualToString:@"wait-gone"]);
    }
    if ([command isEqualToString:@"wait-restart"]) {
        double seconds = rest.doubleValue;
        if (seconds <= 0) return @"wait-restart needs a number of seconds";
        return waitForRestart(seconds);
    }
    if ([command isEqualToString:@"type"]) {
        NSString *encoded = [rest stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
        return request([@"type " stringByAppendingString:encoded]);
    }
    return request(line);
}

/// The script, line by line, once the window is up; then the Mac shut down.
static void runAutomation(NSString *path) {
    NSError *error = nil;
    NSString *script = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!script) {
        helperReport(kHelper, "error", "automation failed at line 0: can't read %s: %s", path.UTF8String,
                     error.localizedDescription.UTF8String ?: "no error");
        dispatch_async(dispatch_get_main_queue(), ^{ startShutDown(); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *lines = [script componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        int number = 0;
        for (NSString *raw in lines) {
            number++;
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length == 0 || [line hasPrefix:@"#"]) continue;
            helperReport(kHelper, "notice", "automation line %d: %s", number, line.UTF8String);
            NSString *problem = runLine(line);
            if (problem) {
                helperReport(kHelper, "error", "automation failed at line %d (%s): %s", number, line.UTF8String, problem.UTF8String);
                keepPicture("automation-failed");
                dispatch_async(dispatch_get_main_queue(), ^{ startShutDown(); });
                return;
            }
        }
        helperReport(kHelper, "notice", "automation finished");
        dispatch_async(dispatch_get_main_queue(), ^{ startShutDown(); });
    });
}

__attribute__((constructor))
static void armBasiliskMac(void) {
    if (!processRunsExeNamedBy("BASILISK_MAC_EXE")) return;
    signal(SIGUSR2, SIG_IGN);
    static dispatch_source_t shutDown;
    shutDown = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(shutDown, ^{ startShutDown(); });
    dispatch_resume(shutDown);
    dispatch_async(dispatch_get_main_queue(), ^{ watchForWindow(0); });
    helperReport(kHelper, "notice", "armed in %s", getenv("BASILISK_MAC_EXE"));
    const char *automation = getenv("BASILISK_MAC_AUTOMATION");
    if (automation && *automation) {
        NSString *path = @(automation);
        // Once the window is up: the script's first request waits for it.
        runAutomation(path);
    }
}
