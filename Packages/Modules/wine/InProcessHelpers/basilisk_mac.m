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
//    leaving the Mac asking "shut down now?"), shut the Mac down as its
//    Special ▸ Shut Down does, asking nothing: a few bytes of 68k put in
//    the Mac's GetNextEvent filter (jGNEFilter) have the Mac send its
//    Finder the Shut Down Apple event at the next event an application asks
//    for, so its applications are asked to quit, its disk is left clean,
//    the person's files on it safe, and it powers off, which Basilisk II
//    answers by exiting. Where that can't be set up or sent, or the Mac
//    asks for no event, it's the power key instead, as Basilisk II makes
//    SIGTERM, and Return on the dialog's Shut Down. The wrapp ends Basilisk II only if this hasn't in its time.
//  - **Shutting down with the program.** With
//    BASILISK_MAC_SHUT_DOWN_WITH_PROGRAM=1 (`LAUNCH
//    --basilisk.shut-down=with-program`), once the program the Mac opened
//    has quit, leaving the Finder alone, the Mac is shut down the same way,
//    so the app closes with the game; never while it's open, even behind
//    the Finder. Told from the Mac's memory (the applications open, as the
//    Process Manager's Application menu lists them), never from pictures.
//  - **Hiding the Mac.** With BASILISK_MAC_HIDDEN=1 (`LAUNCH
//    --basilisk.mac=hidden`), the Mac's own screens (its boot, the Finder and
//    its windows) are kept from the window: every frame Basilisk II presents
//    is cleared to black first (its import of SDL_RenderPresent is pointed
//    here) until the program the Mac opened is in front and has drawn over
//    the Finder's screen (its frame buffer, sampled), and again once the
//    program shows the menu bar it hid or quits, or the Mac shuts down. Never
//    in a build's automation, which reads the screen.
//  - **A build's automation.** With BASILISK_MAC_AUTOMATION naming a script
//    (the basilisk module's BASILISK.RUN), the Mac is driven by it once its
//    window is up, a line at a time: puppet control's requests (`click 440
//    418`, `key cmd+down`), `type <text>`, `wait <seconds>`, and `wait-for
//    <seconds> <text>`, which waits for the text to be on the Mac's screen
//    (read from a picture of the window by Vision), `wait-gone <seconds>
//    <text>`, for it to go, `click-until-gone <seconds> <x> <y> <text>`,
//    which clicks again while the text stays (a busy Mac can lose a click),
//    and `wait-restart <seconds>`, for the Mac to
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
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <signal.h>
#import <unistd.h>
#import "helper_common.h"

static const char *kHelper = "BasiliskMac";

static void quitShutsDown(void);
static void giveGreenButton(NSWindow *window);
static void coverForGood(const char *why);

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

/// The fallback: the Mac's power key, as Basilisk II makes SIGTERM, which
/// asks "shut down now?" (with a beep), Shut Down being its default; then
/// Return once the dialog may be up, again every two seconds, while the
/// process lasts. The wrapp ends it if the Mac never shuts down.
static void shutDownByPowerKey(void) {
    kill(getpid(), SIGTERM);
    for (int i = 0; i < 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 + 2 * i) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSWindow *window = macWindow();
            if (window) pressReturn(window);
        });
    }
}

static const volatile uint8_t *macMemory(uint32_t *size);

/// A big-endian long of the Mac's, read or written in place in host memory.
static uint32_t readMacLong(const volatile uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/// Written as one host store (jGNEFilter is read by the Mac's CPU, on
/// Basilisk II's own thread, as one load: half an address must never be
/// seen). 0x29A isn't 4-aligned; arm64 (LSE2, every Apple silicon Mac) and
/// x86_64 store a long within 16 bytes in one go.
static void writeMacLong(volatile uint8_t *p, uint32_t value) {
    uint32_t big = CFSwapInt32HostToBig(value);
    __atomic_store((uint32_t *)(uintptr_t)p, &big, __ATOMIC_SEQ_CST);
}

/// Low memory's jGNEFilter: the routine GetNextEvent and WaitNextEvent call
/// with each event they return, in the application asking, at task time.
static const uint32_t kJGNEFilter = 0x29A;

/// Where the shut-down filter goes: the end of the ROM's own .Sony driver
/// (the ROM resource 'DRVR' 4), whose start Basilisk II overwrites with
/// its own drivers, icons and patches (rom_patches.cpp, sony_offset up to
/// +0xd00 and a little), so nothing ever runs the rest, and no Mac program
/// writes to ROM. Found as Basilisk II finds it (find_rom_resource: the
/// ROM's resource list from its header's 0x1a), and believed only if the
/// driver there is Basilisk II's (its header's Open at 0x18, ".Sony" at
/// 0x12) and long enough. 0 when not.
static uint32_t filterPlaceInROM(const uint8_t *rom, uint32_t romSize, uint32_t length) {
    if (romSize < 0x40000) return 0;
    uint32_t mapEntry = readMacLong(rom + 0x1a);
    if (mapEntry > romSize - 4) return 0;
    uint32_t entry = readMacLong(rom + mapEntry);
    for (int n = 0; entry != 0 && n < 4096; n++) {
        if (entry > romSize - 22) return 0;
        uint32_t data = readMacLong(rom + entry + 12);
        BOOL isSony = memcmp(rom + entry + 16, "DRVR", 4) == 0 && rom[entry + 20] == 0 && rom[entry + 21] == 4;
        if (isSony) {
            if (data < 8 || data > romSize - 0x20) return 0;
            uint32_t size = readMacLong(rom + data - 8);   // the resource's length, in its header
            BOOL basilisks = rom[data + 8] == 0x00 && rom[data + 9] == 0x18 && memcmp(rom + data + 0x12, "\005.Sony", 6) == 0;
            if (!basilisks || size < 0x2000 || size > 0x20000 || data + size > romSize) return 0;
            return (data + size - 0x80 - length) & ~1u;
        }
        entry = readMacLong(rom + entry + 8);
    }
    return 0;
}

/// 68k code, a word at a time, big-endian.
typedef struct {
    uint16_t words[128];
    int count;
} M68kCode;

static void op(M68kCode *code, uint16_t word) {
    if (code->count < 128) code->words[code->count++] = word;
}

static void op32(M68kCode *code, uint32_t value) {
    op(code, (uint16_t)(value >> 16));
    op(code, (uint16_t)value);
}

/// A Pascal call into the Apple Event Manager (_Pack8, A816, with its
/// selector in D0, whose high byte is the parameters' size in words), its
/// OSErr left in D0.
static void callPack8(M68kCode *code, uint16_t selector) {
    op(code, 0x303C); op(code, selector);           // move.w #selector,d0
    op(code, 0xA816);                               // _Pack8
    op(code, 0x301F);                               // move.w (sp)+,d0
}

/// Where the filter keeps its status, a word ahead of its code: what AESend
/// said (an OSErr), or kFilterNotRun until the filter has run.
static const uint16_t kFilterNotRun = 0x5555;

/// The 68k filter, chained in front of `previous`: it puts `previous` back
/// in jGNEFilter, so it runs once, then sends the Finder its Shut Down
/// Apple event ('FNDR' 'shut', the Finder's own suite, which is what its
/// Special ▸ Shut Down does: each application asked to quit, then the Mac
/// shut down), with no reply waited for, and leaves AESend's result (or
/// the error that stopped it before) in the status word at `status`, all
/// with every register it changes saved; then it goes on to `previous` as
/// if it had never been there. In Pascal's calling convention: a result
/// word, then the parameters in order.
static void shutDownFilter(M68kCode *code, uint32_t previous, uint32_t status) {
    op(code, 0x21FC); op32(code, previous); op(code, (uint16_t)kJGNEFilter);   // move.l #previous,(jGNEFilter).w
    op(code, 0x48E7); op(code, 0xE0E0);             // movem.l d0-d2/a0-a2,-(sp)
    // -4(a6) the Finder's signature, -12(a6) the target's AEAddressDesc,
    // -20(a6) the Apple event, -28(a6) the (empty) reply.
    op(code, 0x4E56); op(code, 0xFFE4);             // link a6,#-28
    op(code, 0x2D7C); op32(code, 0x4D414353); op(code, 0xFFFC);   // move.l #'MACS',-4(a6)
    // AECreateDesc(typeApplSignature, &signature, 4, &target)
    op(code, 0x4267);                               // clr.w -(sp)
    op(code, 0x2F3C); op32(code, 0x7369676E);           // move.l #'sign',-(sp)
    op(code, 0x486E); op(code, 0xFFFC);             // pea -4(a6)
    op(code, 0x2F3C); op32(code, 4);                // move.l #4,-(sp)
    op(code, 0x486E); op(code, 0xFFF4);             // pea -12(a6)
    callPack8(code, 0x0825);
    op(code, 0x6600); int failed1 = code->count; op(code, 0);   // bne.w done
    // AECreateAppleEvent('FNDR', 'shut', &target, kAutoGenerateReturnID,
    // kAnyTransactionID, &event)
    op(code, 0x4267);                               // clr.w -(sp)
    op(code, 0x2F3C); op32(code, 0x464E4452);           // move.l #'FNDR',-(sp)
    op(code, 0x2F3C); op32(code, 0x73687574);           // move.l #'shut',-(sp)
    op(code, 0x486E); op(code, 0xFFF4);             // pea -12(a6)
    op(code, 0x3F3C); op(code, 0xFFFF);             // move.w #-1,-(sp)
    op(code, 0x42A7);                               // clr.l -(sp)
    op(code, 0x486E); op(code, 0xFFEC);             // pea -20(a6)
    callPack8(code, 0x0B14);
    op(code, 0x6600); int failed2 = code->count; op(code, 0);   // bne.w done
    // AESend(&event, &reply, kAENoReply, kAENormalPriority,
    // kAEDefaultTimeout, no idle proc, no filter proc)
    op(code, 0x4267);                               // clr.w -(sp)
    op(code, 0x486E); op(code, 0xFFEC);             // pea -20(a6)
    op(code, 0x486E); op(code, 0xFFE4);             // pea -28(a6)
    op(code, 0x2F3C); op32(code, 1);                // move.l #kAENoReply,-(sp)
    op(code, 0x4267);                               // clr.w -(sp)
    op(code, 0x2F3C); op32(code, 0xFFFFFFFF);       // move.l #kAEDefaultTimeout,-(sp)
    op(code, 0x42A7); op(code, 0x42A7);             // clr.l -(sp) twice
    callPack8(code, 0x0D17);
    int done = code->count;                         // done:
    code->words[failed1] = (uint16_t)(2 * (done - failed1));
    code->words[failed2] = (uint16_t)(2 * (done - failed2));
    op(code, 0x33C0); op32(code, status);           // move.w d0,(status).l
    op(code, 0x4E5E);                               // unlk a6
    op(code, 0x4CDF); op(code, 0x0707);             // movem.l (sp)+,d0-d2/a0-a2
    if (previous) {
        op(code, 0x2F3C); op32(code, previous);     // move.l #previous,-(sp)
    }
    op(code, 0x4E75);                               // rts (on to previous)
}

/// Room for the status word and the filter.
static const uint32_t kFilterRoom = 0x100;

/// Shut the Mac down as its Special ▸ Shut Down does, asking nothing first:
/// the Mac's Finder is sent its Shut Down event, so the applications are
/// asked to quit (one with unsaved work asks the person, and may stop it),
/// the disks are put away marked clean, and the Mac powers off, which
/// Basilisk II answers by exiting. Sent by the shut-down filter (above)
/// put in the Mac's jGNEFilter, so it happens at the next event any
/// application asks for, at task time, where the Apple Event Manager may be
/// called; never from Basilisk II's interrupt handling, or from a thread of
/// the host, where no trap may run. (ShutDwnPower itself, called from
/// there, powered off at once without asking the applications to quit:
/// SimpleText's unsaved document was lost without a word.) NO if it can't
/// be set up (no memory or ROM of the Mac's to put it in, or the Mac in
/// 24-bit mode).
static BOOL shutDownDirectly(void) {
    uint32_t size = 0;
    volatile uint8_t *memory = (volatile uint8_t *)macMemory(&size);
    uint8_t **romHost = (uint8_t **)dlsym(RTLD_DEFAULT, "ROMBaseHost");
    uint32_t *romMac = (uint32_t *)dlsym(RTLD_DEFAULT, "ROMBaseMac");
    uint32_t *romSize = (uint32_t *)dlsym(RTLD_DEFAULT, "ROMSize");
    if (!memory || !romHost || !romMac || !romSize || !*romHost) {
        helperReport(kHelper, "warning", "can't shut the Mac down directly: its memory or ROM can't be found");
        return NO;
    }
    if (memory[0xCB2] == 0) {   // MMU32Bit: in 24-bit mode the ROM isn't at ROMBaseMac
        helperReport(kHelper, "warning", "can't shut the Mac down directly: it runs in 24-bit mode");
        return NO;
    }
    uint32_t place = filterPlaceInROM(*romHost, *romSize, kFilterRoom);
    if (!place) {
        helperReport(kHelper, "warning", "can't shut the Mac down directly: no room for it in the ROM's .Sony driver");
        return NO;
    }
    uint32_t previous = readMacLong(memory + kJGNEFilter);
    uint32_t status = *romMac + place;
    uint32_t filter = status + 4;
    M68kCode code = { .count = 0 };
    shutDownFilter(&code, previous, status);
    if ((uint32_t)code.count * 2 + 4 > kFilterRoom) {
        helperReport(kHelper, "warning", "can't shut the Mac down directly: the filter doesn't fit");
        return NO;
    }
    volatile uint8_t *statusHost = *romHost + place;
    statusHost[0] = (uint8_t)(kFilterNotRun >> 8);
    statusHost[1] = (uint8_t)kFilterNotRun;
    for (int i = 0; i < code.count; i++) {
        statusHost[4 + 2 * i] = (uint8_t)(code.words[i] >> 8);
        statusHost[4 + 2 * i + 1] = (uint8_t)code.words[i];
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    writeMacLong(memory + kJGNEFilter, filter);
    helperReport(kHelper, "notice", "shutting the Mac down directly: its Finder to be sent Shut Down at its next event"
                 " (filter at 0x%08x, before it 0x%08x)", filter, previous);
    // The Mac takes it within a tick or so: the filter puts the old one back
    // as it runs, and says how AESend went. If it couldn't send, or no
    // application asks for an event for a while, it's the power key instead.
    __block int checks = 0;
    __block void (^check)(void);
    void (^checkOnce)(void) = ^{
        uint16_t said = (uint16_t)(statusHost[0] << 8 | statusHost[1]);
        uint32_t now = readMacLong(memory + kJGNEFilter);
        if (said != kFilterNotRun) {
            if (said == 0) {
                helperReport(kHelper, "notice", "the Mac's Finder was sent Shut Down (%.2f s)", checks * 0.05);
            } else {
                helperReport(kHelper, "warning", "the Finder couldn't be sent Shut Down (error %d): shutting the Mac down by its power key",
                             (int16_t)said);
                shutDownByPowerKey();
            }
            check = nil;
            return;
        }
        if (++checks < 100) {   // 5 s for the Mac to run it and AESend to return
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), check);
            return;
        }
        if (now == filter) {
            writeMacLong(memory + kJGNEFilter, previous);
            helperReport(kHelper, "warning", "the Mac asked for no event in 5 s: shutting it down by its power key");
        } else {
            helperReport(kHelper, "warning", "the shut-down filter ran but left no word (jGNEFilter 0x%08x): shutting the Mac down by its power key", now);
        }
        check = nil;
        shutDownByPowerKey();
    };
    check = checkOnce;
    dispatch_async(dispatch_get_main_queue(), check);
    return YES;
}

/// SIGUSR2, the app's Quit, or the end of an automation: shut the Mac
/// down, as Special ▸ Shut Down does (shutDownDirectly), or, when that
/// can't be set up, by its power key and Return. Once.
static void startShutDown(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    coverForGood("the Mac is shutting down");
    helperReport(kHelper, "notice", "shutting the Mac down");
    if (shutDownDirectly()) return;
    helperReport(kHelper, "notice", "shutting the Mac down by its power key");
    shutDownByPowerKey();
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

#pragma mark - Shutting down with the program

/// The Mac's memory as Basilisk II keeps it in this process (its globals
/// RAMBaseHost, RAMBaseMac and RAMSize, which its build exports), from
/// address 0, and how much of it there is; NULL until the Mac has its
/// memory, or if it isn't laid out from 0 in one piece.
static const volatile uint8_t *macMemory(uint32_t *size) {
    static uint8_t **host;
    static uint32_t *mac;
    static uint32_t *ramSize;
    if (!host) host = (uint8_t **)dlsym(RTLD_DEFAULT, "RAMBaseHost");
    if (!mac) mac = (uint32_t *)dlsym(RTLD_DEFAULT, "RAMBaseMac");
    if (!ramSize) ramSize = (uint32_t *)dlsym(RTLD_DEFAULT, "RAMSize");
    if (!host || !mac || !ramSize || !*host || *mac != 0 || *ramSize < 0x10000) return NULL;
    *size = *ramSize;
    return *host;
}

/// The Mac's memory read a field at a time, big-endian, every read checked
/// against its size, since the addresses come from the Mac itself.
typedef struct {
    const volatile uint8_t *memory;
    uint32_t size;
    BOOL ok;
} MacReader;

static uint32_t macLong(MacReader *reader, uint32_t address) {
    if (address > reader->size - 4) { reader->ok = NO; return 0; }
    const volatile uint8_t *p = reader->memory + address;
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int16_t macWord(MacReader *reader, uint32_t address) {
    if (address > reader->size - 2) { reader->ok = NO; return 0; }
    const volatile uint8_t *p = reader->memory + address;
    return (int16_t)((uint16_t)p[0] << 8 | p[1]);
}

static uint8_t macByte(MacReader *reader, uint32_t address) {
    if (address >= reader->size) { reader->ok = NO; return 0; }
    return reader->memory[address];
}

/// A handle's block: the address its master pointer holds (only the low 24
/// bits while the Mac runs in 24-bit mode, low memory's MMU32Bit, 0xCB2, 0).
static uint32_t macDeref(MacReader *reader, uint32_t handle) {
    uint32_t pointer = macLong(reader, handle);
    return macByte(reader, 0xCB2) ? pointer : (pointer & 0x00FFFFFF);
}

/// The menu ID of the Application menu, the Process Manager's, at the right
/// of the menu bar (Inside Macintosh's kApplicationMenuID).
static const int16_t kApplicationMenuID = -16489;

/// The applications open on the Mac, as the Process Manager lists them in
/// its Application menu: the names after the menu's first "-" (above it are
/// Hide …, Hide Others and Show All). The Process Manager adds an
/// application's name as it opens and takes it out as it quits, whichever
/// application is in front and whether or not the menu bar shows (Ingenious
/// hides it), so it says what is open, where low memory's CurApName says
/// only which application has time at this moment: a program left open
/// behind the Finder reads "Finder" there for as long as it's left.
/// The menu is found from the system menu list (the handle at low memory's
/// 0x286; the Help menu and this one), not from MenuList, which is the
/// application in front's and is empty while Ingenious runs. nil when it
/// can't be read, as before the Process Manager has made the menu.
static NSArray<NSString *> *openApplications(const volatile uint8_t *memory, uint32_t size) {
    MacReader reader = { memory, size, YES };
    MacReader *r = &reader;
    uint32_t list = macDeref(r, macLong(r, 0x286));
    int16_t lastMenu = macWord(r, list);
    if (!reader.ok || list == 0 || lastMenu < 0 || lastMenu > 6 * 16) return nil;
    for (int16_t offset = 6; offset <= lastMenu; offset += 6) {
        uint32_t menu = macDeref(r, macLong(r, list + (uint32_t)offset));
        if (!reader.ok) return nil;
        if (menu == 0 || macWord(r, menu) != kApplicationMenuID) continue;
        // MenuInfo: menuID, menuWidth, menuHeight, menuProc, enableFlags,
        // then the title and the items, each a Pascal string and four bytes
        // (icon, key, mark, style), up to an empty one.
        uint32_t item = menu + 14;
        item += 1 + macByte(r, item);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        BOOL separated = NO;
        for (int i = 0; i < 64; i++) {
            uint8_t length = macByte(r, item);
            if (!reader.ok) return nil;
            if (length == 0) return separated ? names : nil;
            uint8_t text[256];
            for (int c = 0; c <= length; c++) text[c] = macByte(r, item + (uint32_t)c);
            if (!reader.ok) return nil;
            item += 1 + length + 4;
            CFStringRef name = CFStringCreateWithPascalString(NULL, text, kCFStringEncodingMacRoman);
            if (!name) return nil;
            NSString *string = (__bridge_transfer NSString *)name;
            if (!separated) separated = [string isEqualToString:@"-"];
            else [names addObject:string];
        }
        return nil;
    }
    return nil;
}

/// The Mac's low-memory Ticks (0x16A): sixtieths of a second since it
/// started, big-endian; it goes back to nothing when the Mac restarts.
static uint32_t macTicks(const volatile uint8_t *memory) {
    return (uint32_t)memory[0x16A] << 24 | (uint32_t)memory[0x16B] << 16 | (uint32_t)memory[0x16C] << 8 | memory[0x16D];
}

/// BASILISK_MAC_SHUT_DOWN_WITH_PROGRAM (`LAUNCH --basilisk.shut-down=with-program`):
/// once the program the Mac opened has quit, leaving only the Finder open,
/// the Mac is shut down, and with it the app; never while a program is open,
/// in front or not. Told from the Mac's own memory, its Application menu
/// (openApplications), four times a second, which costs Basilisk II
/// nothing (a picture of its window would stall it). The menu is read twice
/// in a row each time and believed only when both agree, since the Mac may
/// be changing it as it's read; nothing waits beyond that, as the menu says
/// what's open, not what ran last. A program must have been open since the
/// Mac last started (Ticks going back says it restarted): the Finder alone
/// at boot, before it opens its startup items, or after a restart, isn't a
/// quit.
static void watchProgram(void) {
    static dispatch_source_t timer;
    static BOOL seen = NO;
    static uint32_t lastTicks = 0;
    static NSArray<NSString *> *lastOpen = nil;
    static BOOL said = NO;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
    dispatch_source_set_event_handler(timer, ^{
        uint32_t size = 0;
        const volatile uint8_t *memory = macMemory(&size);
        if (!memory) {
            if (!said) helperReport(kHelper, "notice", "waiting for the Mac's memory to watch its program");
            said = YES;
            return;
        }
        uint32_t ticks = macTicks(memory);
        if (ticks < lastTicks && seen) {
            helperReport(kHelper, "notice", "the Mac restarted: waiting for its program again");
            seen = NO;
        }
        lastTicks = ticks;
        NSArray<NSString *> *open = openApplications(memory, size);
        if (!open || ![open isEqualToArray:openApplications(memory, size) ?: @[]]) return;
        if (![open isEqualToArray:lastOpen ?: @[]]) {
            helperReport(kHelper, "notice", "open on the Mac: %s", [open componentsJoinedByString:@", "].UTF8String);
            lastOpen = open;
        }
        NSArray<NSString *> *programs = [open filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != 'Finder'"]];
        if (programs.count > 0) {
            if (!seen) helperReport(kHelper, "notice", "the Mac has %s open: shutting it down once only the Finder is",
                                    [programs componentsJoinedByString:@", "].UTF8String);
            seen = YES;
            return;
        }
        if (!seen) return;
        helperReport(kHelper, "notice", "the Mac's program has quit: only the Finder is open");
        dispatch_source_cancel(timer);
        dispatch_async(dispatch_get_main_queue(), ^{ startShutDown(); });
    });
    dispatch_resume(timer);
    helperReport(kHelper, "notice", "the Mac shuts down when its program quits");
}

#pragma mark - Hiding the Mac

/// BASILISK_MAC_HIDDEN=1 (`LAUNCH --basilisk.mac=hidden`): the Mac's own
/// screens (its boot, the Finder) are kept from the window, which is black
/// until the program the Mac opens has drawn itself, and black again once it
/// quits or the Mac shuts down. Basilisk II's own import of
/// SDL_RenderPresent is pointed here, and while the Mac is covered each frame
/// is cleared to black before it's presented: nothing is put over the
/// window, so fullscreen, the green button, the pointer and the keys are
/// Basilisk II's as ever, and what puppet control pictures is what the window
/// shows. What the Mac shows is read from its memory, as the quit watch reads
/// it, at each frame and 60 times a second besides: a few hundred bytes,
/// never a picture of the window, which would stall Basilisk II.
static BOOL hideArmed = NO;

/// Over the Mac until its program has drawn itself, off while it plays, and
/// over it for good once it has quit or the Mac is shutting down; or off
/// for good when no program opened, so the person isn't left at a black
/// window with the Mac waiting behind it.
typedef enum { CoverUntilProgram, CoverOff, CoverForGood, CoverGaveUp } CoverState;

/// How long the Finder may be alone in front, no program having opened,
/// before the cover gives up: Ingenious opens 0.7 s after the Finder.
static const double kNoProgramSeconds = 30;
static _Atomic int coverState = CoverUntilProgram;

/// Taken by each frame and the timer while they read the Mac and move the cover.
static os_unfair_lock coverLock = OS_UNFAIR_LOCK_INIT;
static uint64_t hidingArmedAt;

static double secondsSinceHidingArmed(void) {
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - hidingArmedAt) / 1e9;
}

/// Low memory's CurApName (0x910): the application that has time now.
static NSString *currentApplication(MacReader *r) {
    uint8_t text[32];
    uint8_t length = macByte(r, 0x910);
    if (length > 31) return nil;
    for (int i = 0; i <= length; i++) text[i] = macByte(r, 0x910 + (uint32_t)i);
    if (!r->ok) return nil;
    CFStringRef name = CFStringCreateWithPascalString(NULL, text, kCFStringEncodingMacRoman);
    return name ? (__bridge_transfer NSString *)name : nil;
}

/// A rectangle of the Mac's, in its own order.
typedef struct { int16_t top, left, bottom, right; } MacRect;

static MacRect macRect(MacReader *r, uint32_t address) {
    return (MacRect){ macWord(r, address), macWord(r, address + 2), macWord(r, address + 4), macWord(r, address + 6) };
}

/// A region's bounding box (rgnBBox, after its size word).
static MacRect regionBox(MacReader *r, uint32_t handle) {
    uint32_t region = macDeref(r, handle);
    return region ? macRect(r, region + 2) : (MacRect){ 0 };
}

/// Whether the application with time has a visible window, going down its
/// window list (low memory's WindowList, 0x9D6, which the Process Manager
/// switches with CurApName): each WindowRecord's visible flag at 110, the
/// next window at 144.
static BOOL hasVisibleWindow(MacReader *r) {
    uint32_t window = macLong(r, 0x9D6);
    for (int i = 0; window != 0 && i < 64 && r->ok; i++) {
        if (macByte(r, window + 110)) return YES;
        window = macLong(r, window + 144);
    }
    return NO;
}

/// The sparse sample of the Mac's screen the cover compares: a 32x32 grid of
/// bytes of its frame buffer, and which of them the front window covers.
enum { kSampleSide = 32, kSamples = kSampleSide * kSampleSide };
typedef struct {
    BOOL ok;
    uint8_t bytes[kSamples];
    BOOL inWindow[kSamples];
} ScreenSample;

/// The Mac's frame buffer in this process: where low memory's ScrnBase
/// (0x824) is, past MEMBaseDiff (Basilisk II addresses the Mac's memory
/// directly), as big as ScreenRow (0x106) times the main screen's height
/// (MainDevice, 0x8A4, its gdRect at 34); NULL unless that much of this
/// process's memory is there to read, checked whenever the screen moves.
static const volatile uint8_t *frameBuffer(MacReader *r, MacRect *screen, uint32_t *rowBytes) {
    static uintptr_t *baseDiff;
    static uintptr_t checkedStart, checkedLength;
    static BOOL readable;
    if (!baseDiff) baseDiff = (uintptr_t *)dlsym(RTLD_DEFAULT, "MEMBaseDiff");
    uint32_t base = macLong(r, 0x824);
    *rowBytes = (uint32_t)(macWord(r, 0x106) & 0x3FFF);
    *screen = macRect(r, macDeref(r, macLong(r, 0x8A4)) + 34);
    int height = screen->bottom - screen->top, width = screen->right - screen->left;
    if (!r->ok || !baseDiff || !*baseDiff || !base || *rowBytes == 0 || height <= 0 || width <= 0) return NULL;
    uintptr_t start = *baseDiff + base, length = (uintptr_t)*rowBytes * (uintptr_t)height;
    if (start != checkedStart || length != checkedLength) {
        checkedStart = start;
        checkedLength = length;
        mach_vm_address_t address = start;
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        readable = mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                                  (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS
            && address <= start && start + length <= address + size && (info.protection & VM_PROT_READ);
        if (!readable) helperReport(kHelper, "warning", "the Mac's screen can't be read at 0x%lx: hiding the Mac waits for its program's window alone",
                                    (unsigned long)start);
    }
    return readable ? (const volatile uint8_t *)start : NULL;
}

/// The Mac's screen sampled, with which samples lie in `window` (a box in
/// the screen's own coordinates).
static ScreenSample sampleScreen(MacReader *r, MacRect window) {
    ScreenSample sample = { .ok = NO };
    MacRect screen;
    uint32_t rowBytes = 0;
    const volatile uint8_t *frame = frameBuffer(r, &screen, &rowBytes);
    if (!frame) return sample;
    int width = screen.right - screen.left, height = screen.bottom - screen.top;
    for (int row = 0; row < kSampleSide; row++) {
        for (int column = 0; column < kSampleSide; column++) {
            int x = width * (2 * column + 1) / (2 * kSampleSide), y = height * (2 * row + 1) / (2 * kSampleSide);
            int i = row * kSampleSide + column;
            // A pixel's first byte, whatever the depth.
            sample.bytes[i] = frame[(uint32_t)y * rowBytes + (uint32_t)((uint64_t)x * rowBytes / (uint32_t)width)];
            int h = screen.left + x, v = screen.top + y;
            sample.inWindow[i] = h >= window.left && h < window.right && v >= window.top && v < window.bottom;
        }
    }
    sample.ok = YES;
    return sample;
}

/// What the Mac shows, as far as the cover cares.
typedef struct {
    BOOL known;           // read twice alike
    BOOL programOpen;     // a program besides the Finder is in the Application menu
    BOOL programInFront;  // ...and has time (CurApName), so WindowList is its own
    BOOL windowShown;     // it has a visible window
    MacRect frontWindow;  // its front window's structure region's box, if visible
    int16_t menuBar;      // low memory's MBarHeight (0xBAA)
} MacScene;

static MacScene readSceneOnce(const volatile uint8_t *memory, uint32_t size) {
    MacScene scene = { 0 };
    MacReader reader = { memory, size, YES };
    MacReader *r = &reader;
    NSArray<NSString *> *open = openApplications(memory, size);
    NSString *front = currentApplication(r);
    if (!open || !front) return scene;
    NSArray<NSString *> *programs = [open filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != 'Finder'"]];
    scene.programOpen = programs.count > 0;
    scene.programInFront = [programs containsObject:front];
    scene.windowShown = hasVisibleWindow(r);
    uint32_t window = macLong(r, 0x9D6);
    if (window && macByte(r, window + 110)) scene.frontWindow = regionBox(r, macLong(r, window + 114));
    scene.menuBar = macWord(r, 0xBAA);
    scene.known = reader.ok;
    return scene;
}

/// The scene, believed when two reads in a row agree: the Mac may be
/// switching applications (CurApName and WindowList change one after the
/// other) or changing its menu as it's read.
static MacScene readScene(MacReader *reader) {
    MacScene first = readSceneOnce(reader->memory, reader->size), second = readSceneOnce(reader->memory, reader->size);
    BOOL same = first.programOpen == second.programOpen && first.programInFront == second.programInFront
        && first.windowShown == second.windowShown && first.menuBar == second.menuBar
        && memcmp(&first.frontWindow, &second.frontWindow, sizeof(MacRect)) == 0;
    if (!first.known || !second.known || !same) return (MacScene){ 0 };
    return first;
}

/// The Mac's screen as it was before the program came in front (the
/// Finder's), to tell when the program has drawn over it.
static ScreenSample before;
/// When the program in front first had a window up, while covered (0: not yet).
static double windowUpAt = 0;
/// When the Finder was first seen alone in front, no program open yet (0: not yet).
static double finderAloneAt = 0;
/// Whether the last frame saw the program showing: the cover comes off at
/// the frame after, whose picture of the Mac's screen was taken once it was.
/// (The timer only asks for that frame: one being made as it reads may have
/// pictured the screen a moment before.)
static BOOL showingAtLastFrame = NO;
/// Whether the last read, frame or timer, saw the program showing.
static BOOL showingNow = NO;
/// The menu bar's height when the cover came off: a program that hid it
/// (Ingenious) showing it again is quitting.
static int16_t menuBarWhenShown = -1;
static BOOL coverEverRemoved = NO;
/// Frames cleared to black, for the log.
static int framesCovered = 0;

/// Whether the program has drawn itself: of the samples its front window
/// covers, nine in ten differ from the screen before it came in front (a
/// window marked visible is drawn a while later: Ingenious's was marked
/// visible about 0.1 s before its first frame); or its window has been up
/// two seconds, so a program that draws little isn't left black.
static BOOL programHasDrawn(MacReader *r, MacScene scene, double now) {
    if (now - windowUpAt >= 2.0) return YES;
    if (!before.ok) return NO;
    ScreenSample after = sampleScreen(r, scene.frontWindow);
    if (!after.ok) return NO;
    int inside = 0, changed = 0;
    for (int i = 0; i < kSamples; i++) {
        if (!after.inWindow[i]) continue;
        inside++;
        if (after.bytes[i] != before.bytes[i]) changed++;
    }
    return inside >= 16 && changed * 10 >= inside * 9;
}

/// Moves the cover as the scene says; YES if it moved. Called before each
/// frame (`atFrame`) and from the timer, under coverLock.
static BOOL updateCover(BOOL atFrame) {
    int state = coverState;
    if (state == CoverForGood || state == CoverGaveUp) return NO;
    uint32_t size = 0;
    const volatile uint8_t *memory = macMemory(&size);
    if (!memory) return NO;
    MacReader reader = { memory, size, YES };
    MacScene scene = readScene(&reader);
    if (!scene.known) return NO;
    double now = secondsSinceHidingArmed();
    if (state == CoverOff) {
        showingAtLastFrame = showingNow = NO;
        if (!scene.programOpen) {
            coverState = CoverForGood;
            helperReport(kHelper, "notice", "the Mac's program has quit: the Mac covered (%.2f s)", now);
            return YES;
        }
        // Only while the program has time: the Finder's moments of it, now
        // and then as the program plays, show nothing.
        if (scene.programInFront && (!scene.windowShown || scene.menuBar != menuBarWhenShown)) {
            coverState = CoverUntilProgram;
            windowUpAt = 0;
            helperReport(kHelper, "notice", "the Mac's program %s: the Mac covered (%.2f s)",
                         scene.windowShown ? "showed the menu bar" : "has no window up", now);
            return YES;
        }
        return NO;
    }
    if (coverEverRemoved && !scene.programOpen) {
        coverState = CoverForGood;
        helperReport(kHelper, "notice", "the Mac's program has quit (%.2f s)", now);
        return YES;
    }
    if (!coverEverRemoved && !scene.programOpen) {
        if (finderAloneAt == 0) finderAloneAt = now;
        if (now - finderAloneAt >= kNoProgramSeconds) {
            coverState = CoverGaveUp;
            helperReport(kHelper, "warning", "no program opened on the Mac in %.0f s: the Mac uncovered (%.2f s)", kNoProgramSeconds, now);
            return YES;
        }
    }
    if (!scene.programInFront) {
        // The Finder's screen, kept to compare the program's with.
        before = sampleScreen(&reader, (MacRect){ 0 });
        windowUpAt = 0;
        showingAtLastFrame = showingNow = NO;
        return NO;
    }
    BOOL showing = NO;
    if (scene.windowShown && (!coverEverRemoved || scene.menuBar == menuBarWhenShown)) {
        if (windowUpAt == 0) windowUpAt = now;
        // Back after a moment covered while playing: its screen is its own.
        showing = coverEverRemoved || programHasDrawn(&reader, scene, now);
    }
    BOOL seenAtLastFrame = showingAtLastFrame;
    showingNow = showing;
    if (atFrame) showingAtLastFrame = showing;
    if (!(showing && seenAtLastFrame && atFrame)) return NO;
    coverState = CoverOff;
    helperReport(kHelper, "notice", "the Mac's program is showing%s: the Mac uncovered (%.2f s, its window up %.2f s, %d frames covered)",
                 coverEverRemoved ? " again" : "", now, now - windowUpAt, framesCovered);
    if (!coverEverRemoved) menuBarWhenShown = scene.menuBar;
    coverEverRemoved = YES;
    return YES;
}

typedef void (*RenderPresent)(void *);
static RenderPresent realPresent;

/// Basilisk II's call to put a frame on the screen, redirected: the cover
/// moved as the Mac says, and while it's on, the frame cleared to black first.
static void presentHidden(void *renderer) {
    os_unfair_lock_lock(&coverLock);
    updateCover(YES);
    os_unfair_lock_unlock(&coverLock);
    int state = coverState;
    if (state == CoverUntilProgram || state == CoverForGood) {
        typedef int (*GetColor)(void *, uint8_t *, uint8_t *, uint8_t *, uint8_t *);
        typedef int (*SetColor)(void *, uint8_t, uint8_t, uint8_t, uint8_t);
        typedef int (*Clear)(void *);
        static GetColor getColor;
        static SetColor setColor;
        static Clear clear;
        if (!getColor) getColor = (GetColor)dlsym(RTLD_DEFAULT, "SDL_GetRenderDrawColor");
        if (!setColor) setColor = (SetColor)dlsym(RTLD_DEFAULT, "SDL_SetRenderDrawColor");
        if (!clear) clear = (Clear)dlsym(RTLD_DEFAULT, "SDL_RenderClear");
        if (getColor && setColor && clear) {
            framesCovered++;
            uint8_t red = 0, green = 0, blue = 0, alpha = 255;
            getColor(renderer, &red, &green, &blue, &alpha);
            setColor(renderer, 0, 0, 0, 255);
            clear(renderer);
            setColor(renderer, red, green, blue, alpha);
        }
    }
    realPresent(renderer);
}

/// The Mac covered for good, as it shuts down (the app's Quit, the wrapp's
/// SIGUSR2): at once, with a frame asked for, as the window otherwise keeps
/// the last one it was given.
static void coverForGood(const char *why) {
    if (!hideArmed) return;
    if (atomic_exchange(&coverState, CoverForGood) == CoverForGood) return;
    helperReport(kHelper, "notice", "the Mac covered: %s (%.2f s)", why, secondsSinceHidingArmed());
    redrawAll(NULL);
}

/// The cover moved between frames too (Basilisk II presents only when the
/// Mac's screen changes), with a frame asked for when it moves or may come
/// off; until it's on for good.
static void watchCover(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_SEC / 200);
    dispatch_source_set_event_handler(timer, ^{
        if (coverState == CoverForGood || coverState == CoverGaveUp) {
            dispatch_source_cancel(timer);
            return;
        }
        os_unfair_lock_lock(&coverLock);
        BOOL wasShowing = showingNow;
        BOOL moved = updateCover(NO);
        BOOL mayComeOff = showingNow && !wasShowing && coverState == CoverUntilProgram;
        os_unfair_lock_unlock(&coverLock);
        if (moved || mayComeOff) redrawAll(NULL);
    });
    dispatch_resume(timer);
}

/// In the constructor, before Basilisk II presents its first frame.
static void armHiding(void) {
    hidingArmedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    realPresent = (RenderPresent)dlsym(RTLD_DEFAULT, "SDL_RenderPresent");
    int replaced = realPresent ? rebindMainImport("_SDL_RenderPresent", (void *)presentHidden) : 0;
    if (replaced == 0) {
        helperReport(kHelper, "warning", "can't hide the Mac: Basilisk II's SDL_RenderPresent can't be redirected");
        return;
    }
    hideArmed = YES;
    helperReport(kHelper, "notice", "the Mac is hidden until its program shows");
    watchCover();
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
        // Scaled to fit: Basilisk II's window has a 1x backing even on a
        // Retina display, and unscaled it filled only a quarter of the
        // picture, its text too small for Vision to read.
        config.width = (size_t)size.width * 2;
        config.height = (size_t)size.height * 2;
        config.scalesToFit = YES;
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

/// Whether `wanted` is in `text`, both `comparable`, allowing a letter in
/// every eight misread: Vision reads the Mac's bitmap fonts well but not
/// perfectly ("Quioktime 2.5 Installer"). Words under eight letters must be
/// read exactly. An approximate substring match (Sellers' edit distance).
static BOOL containsRoughly(NSString *text, NSString *wanted) {
    if ([text containsString:wanted]) return YES;
    NSUInteger m = wanted.length, n = text.length;
    NSUInteger allowed = m / 8;
    if (allowed == 0 || m == 0) return NO;
    NSUInteger *previous = calloc(m + 1, sizeof(NSUInteger)), *current = calloc(m + 1, sizeof(NSUInteger));
    if (!previous || !current) { free(previous); free(current); return NO; }
    BOOL found = NO;
    for (NSUInteger i = 0; i <= m; i++) previous[i] = i;
    for (NSUInteger j = 1; j <= n && !found; j++) {
        current[0] = 0;   // a match may start anywhere in the text
        unichar c = [text characterAtIndex:j - 1];
        for (NSUInteger i = 1; i <= m; i++) {
            NSUInteger cost = [wanted characterAtIndex:i - 1] == c ? 0 : 1;
            NSUInteger best = previous[i - 1] + cost;
            if (previous[i] + 1 < best) best = previous[i] + 1;
            if (current[i - 1] + 1 < best) best = current[i - 1] + 1;
            current[i] = best;
        }
        if (current[m] <= allowed) found = YES;
        NSUInteger *swap = previous; previous = current; current = swap;
    }
    free(previous);
    free(current);
    return found;
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
                if (containsRoughly(comparable(read), wanted) != gone) return nil;
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

/// `click-until-gone <seconds> <x> <y> <text>`: clicks, then clicks again
/// while the text is still on the screen. A click can be lost: a busy Mac
/// (seen under load, 2026-11-11) left the pointer on the QuickTime licence's
/// Agree with the licence still up. The text is the click's sign of having
/// landed, so the button is only clicked again while what it closes is
/// still there. nil when gone.
static NSString *clickUntilGone(double seconds, NSString *click, NSString *text) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    for (;;) {
        NSString *failed = request(click);
        if (failed) return failed;
        double left = [deadline timeIntervalSinceNow];
        // Long enough for the Mac to take the click and redraw; a picture
        // takes most of a second of that anyway.
        NSString *still = waitForText(text, MAX(1, MIN(10, left)), YES);
        if (!still) return nil;
        if ([deadline timeIntervalSinceNow] <= 0) return still;
        helperReport(kHelper, "notice", "\"%s\" is still on the screen after a click: clicking again", text.UTF8String);
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
    if ([command isEqualToString:@"click-until-gone"]) {
        NSArray<NSString *> *parts = [rest componentsSeparatedByString:@" "];
        double seconds = parts.count >= 4 ? parts[0].doubleValue : 0;
        if (seconds <= 0) return @"click-until-gone needs a number of seconds, x, y, then the text";
        return clickUntilGone(seconds, [NSString stringWithFormat:@"click %@ %@", parts[1], parts[2]],
                              [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@" "]);
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
    const char *withProgram = getenv("BASILISK_MAC_SHUT_DOWN_WITH_PROGRAM");
    if (withProgram && strcmp(withProgram, "1") == 0) watchProgram();
    const char *hidden = getenv("BASILISK_MAC_HIDDEN");
    if (hidden && strcmp(hidden, "1") == 0) armHiding();
    const char *automation = getenv("BASILISK_MAC_AUTOMATION");
    if (automation && *automation) {
        NSString *path = @(automation);
        // Once the window is up: the script's first request waits for it.
        runAutomation(path);
    }
}
