//
//  basilisk_display.m
//  Shows the emulated Mac's screen in a window of the wrapp's own rather
//  than in Basilisk II's, so the window is the game's app's: its menu bar,
//  its Dock icon, its fullscreen (docs/modules.md#the-basilisk-modules-mac).
//
//  Armed by BASILISK_MAC_DISPLAY, the Unix socket the wrapp listens on
//  (BasiliskRuntime, MacScreenServer), from basilisk_mac.m's constructor.
//  It takes nothing from Basilisk II's source, only its imports of SDL2
//  (a framework of its own, so each call is an import that can be pointed
//  here) and the ADB functions its build exports:
//
//  - **The picture.** Basilisk II converts what changed on the Mac's screen
//    to 32-bit pixels and copies it into a streaming texture between
//    SDL_LockTexture and SDL_UnlockTexture. Both imports are pointed here,
//    and each locked area is copied, at its unlock, into shared memory the
//    wrapp maps (sent once, with the screen's size, as a file descriptor),
//    and at SDL_RenderPresent the wrapp is told what changed since the last
//    frame, and whether the Mac is covered (basilisk_mac.m's hiding). The
//    picture never depends on Basilisk II's window being seen, so a
//    background login's occluded window, which dropped frames, no longer
//    matters.
//  - **Basilisk II's window** is made hidden (SDL_CreateWindow's flags), and
//    never made fullscreen (SDL_SetWindowFullscreen does nothing), and
//    nothing is drawn into it: SDL_RenderCopy, SDL_RenderClear and
//    SDL_RenderPresent do nothing, so no drawing waits on a window nobody
//    sees, and its process is an accessory app, out of the Dock and
//    Cmd-Tab (SDL_MAC_BACKGROUND_APP, set here before SDL starts), kept from App
//    Nap, which a process with no window on screen is otherwise given.
//  - **The keys and the mouse** come from the wrapp's window over the same
//    socket, and go straight to the Mac's ADB (Basilisk II's ADBKeyDown,
//    ADBKeyUp, ADBMouseMoved, ADBMouseDown, ADBMouseUp, which its own event
//    loop calls), from one thread, as its event loop does: the Mac's
//    keyboard is a Mac keyboard, so a key is its Mac key code, and the
//    pointer is a position on the Mac's screen.
//  - **Puppet control** answers through this rather than through the
//    window (helperRemoteScreen): its pictures are the screen as the wrapp
//    shows it, and its clicks and keys go to the ADB as the wrapp's do.
//
//  Armed only when every piece is there (the wrapp's socket, the ADB
//  functions, the imports); otherwise it says so to the wrapp, which shows
//  Basilisk II's own window as before.

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import <sys/mman.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import "helper_common.h"

static const char *kHelper = "BasiliskDisplay";

// basilisk_mac.m's, which this works with.
BOOL basiliskMacCoverAtFrame(void);
void basiliskMacRedrawAll(const char *why);
void basiliskMacShutDown(const char *why);

#pragma mark - The wrapp's socket

/// One message each way, 24 bytes: a type and five numbers. The wrapp's
/// MacScreenMessage (BasiliskKit) is the other half; keep the two alike.
typedef struct {
    uint32_t type;
    int32_t values[5];
} DisplayMessage;

enum {
    /// To the wrapp: values[0] this process's pid, values[1] 1 when armed, 0
    /// when the wrapp is to show Basilisk II's own window instead.
    kMessageHello = 1,
    /// To the wrapp, with the screen's shared memory as a file descriptor:
    /// width, height, bytes per row, SDL pixel format.
    kMessageScreen = 2,
    /// To the wrapp: what changed since the last (x, y, width, height; a
    /// width of 0 when nothing did), and whether the Mac is covered (1/0).
    kMessageFrame = 3,
    /// To the wrapp: puppet control's `focus`, its window made key and the
    /// app active.
    kMessageFocus = 4,
    /// To the wrapp: puppet control's `yield`, activation handed to pid values[0].
    kMessageYield = 5,
    /// From the wrapp: the pointer at x, y on the Mac's screen.
    kMessageMouse = 10,
    /// From the wrapp: button values[0] (0 the Mac's, 1 another) down (1) or up (0).
    kMessageButton = 11,
    /// From the wrapp: a key, its Mac virtual key code (NSEvent's keyCode),
    /// down (1) or up (0).
    kMessageKey = 12,
    /// From the wrapp: its window fullscreen, key, the app active (1/0 each),
    /// and the window's size in points.
    kMessageWindowState = 13,
    /// From the wrapp: the whole screen again, as when its window is made.
    kMessageRedraw = 14,
};

static int gSocket = -1;
static os_unfair_lock gSendLock = OS_UNFAIR_LOCK_INIT;

/// A message to the wrapp, with `fd` passed alongside when not -1. A wrapp
/// that has gone (it quit, or was killed) leaves the Mac to shut down.
static BOOL sendMessage(uint32_t type, int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int fd) {
    if (gSocket < 0) return NO;
    DisplayMessage message = { type, { a, b, c, d, e } };
    struct iovec part = { &message, sizeof(message) };
    struct msghdr header = { .msg_iov = &part, .msg_iovlen = 1 };
    char control[CMSG_SPACE(sizeof(int))];
    if (fd >= 0) {
        memset(control, 0, sizeof(control));
        header.msg_control = control;
        header.msg_controllen = sizeof(control);
        struct cmsghdr *descriptor = CMSG_FIRSTHDR(&header);
        descriptor->cmsg_level = SOL_SOCKET;
        descriptor->cmsg_type = SCM_RIGHTS;
        descriptor->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(descriptor), &fd, sizeof(int));
    }
    os_unfair_lock_lock(&gSendLock);
    // MSG_NOSIGNAL: a wrapp that has gone fails the send rather than
    // raising SIGPIPE, which would end Basilisk II with the Mac's disk in use.
    ssize_t sent = sendmsg(gSocket, &header, MSG_NOSIGNAL);
    os_unfair_lock_unlock(&gSendLock);
    return sent == (ssize_t)sizeof(message);
}

/// The wrapp's socket, connected; -1 when it can't be.
static int connectToWrapp(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlcpy(address.sun_path, path, sizeof(address.sun_path)) >= sizeof(address.sun_path)
        || connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    // A wrapp that stops reading holds up Basilisk II's drawing for a second
    // at most: then the frame is told with the next.
    struct timeval wait = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, sizeof(wait));
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    return fd;
}

#pragma mark - The Mac's keyboard and mouse

typedef void (*ADBCodeFunction)(int);
typedef void (*ADBMovedFunction)(int, int);
static ADBCodeFunction gKeyDown, gKeyUp, gMouseDown, gMouseUp;
static ADBMovedFunction gMouseMoved;

/// Basilisk II's ADB functions, as its build exports them (C++ names).
static BOOL findADB(void) {
    gKeyDown = (ADBCodeFunction)dlsym(RTLD_DEFAULT, "_Z10ADBKeyDowni");
    gKeyUp = (ADBCodeFunction)dlsym(RTLD_DEFAULT, "_Z8ADBKeyUpi");
    gMouseDown = (ADBCodeFunction)dlsym(RTLD_DEFAULT, "_Z12ADBMouseDowni");
    gMouseUp = (ADBCodeFunction)dlsym(RTLD_DEFAULT, "_Z10ADBMouseUpi");
    gMouseMoved = (ADBMovedFunction)dlsym(RTLD_DEFAULT, "_Z13ADBMouseMovedii");
    return gKeyDown && gKeyUp && gMouseDown && gMouseUp && gMouseMoved;
}

/// A Mac's virtual key code (NSEvent's keyCode, Carbon's kVK_) as the ADB
/// key code the Mac's keyboard sends: the same for nearly every key, as
/// macOS's codes are ADB's, but for the modifiers' right-hand keys and
/// Control, and the arrows (as Basilisk II's own kc_decode gives them).
/// -1 for a key a Mac keyboard of the time didn't have (fn, volume).
int basiliskDisplayADBCode(int virtualKeyCode) {
    switch (virtualKeyCode) {
    case 0x36: return 0x37;   // right Command: Command
    case 0x3B: return 0x36;   // Control
    case 0x3C: return 0x38;   // right Shift: Shift
    case 0x3D: return 0x3A;   // right Option: Option
    case 0x3E: return 0x36;   // right Control: Control
    case 0x3F: return -1;     // fn
    case 0x48: case 0x49: case 0x4A: return -1;   // volume up, down, mute
    case 0x7B: return 0x3B;   // left arrow
    case 0x7C: return 0x3C;   // right arrow
    case 0x7D: return 0x3D;   // down arrow
    case 0x7E: return 0x3E;   // up arrow
    }
    return virtualKeyCode >= 0 && virtualKeyCode <= 0x7A ? virtualKeyCode : -1;
}

/// The one thread that tells the ADB anything, as Basilisk II's own event
/// loop is: its key and button buffers have one writer.
static dispatch_queue_t inputQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("BasiliskDisplay.input",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    });
    return queue;
}

static void macKey(int virtualKeyCode, BOOL down) {
    int code = basiliskDisplayADBCode(virtualKeyCode);
    if (code < 0) return;
    dispatch_async(inputQueue(), ^{ (down ? gKeyDown : gKeyUp)(code); });
}

/// A key pressed and let go on the Mac's ADB by its ADB code, for
/// basilisk_mac.m's fallback (the power key, 0x7F, then Return, 0x24,
/// which Mac keyboards' codes alone don't reach). On the input queue when
/// the wrapp shows the Mac, so the ADB keeps one writer; otherwise on the
/// calling thread, the main one, where Basilisk II reads its own events.
void basiliskDisplayPressADBKey(int code) {
    if (!gKeyDown && !findADB()) return;
    if (helperRemoteScreen) {
        dispatch_async(inputQueue(), ^{ gKeyDown(code); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), inputQueue(), ^{ gKeyUp(code); });
    } else {
        gKeyDown(code);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ gKeyUp(code); });
    }
}

static void macMouseMoved(int x, int y) {
    dispatch_async(inputQueue(), ^{ gMouseMoved(x, y); });
}

static void macButton(int button, BOOL down) {
    if (button < 0 || button > 2) return;
    dispatch_async(inputQueue(), ^{ (down ? gMouseDown : gMouseUp)(button); });
}

#pragma mark - The picture

typedef struct { int x, y, w, h; } SDLRect;
typedef int (*LockTextureFunction)(void *, const SDLRect *, void **, int *);
typedef void (*UnlockTextureFunction)(void *);
typedef int (*QueryTextureFunction)(void *, uint32_t *, int *, int *, int *);
static LockTextureFunction realLockTexture;
static UnlockTextureFunction realUnlockTexture;
static QueryTextureFunction queryTexture;

/// SDL's 32-bit formats, the two Basilisk II makes its texture in.
static const uint32_t kSDLPixelFormatARGB8888 = 0x16362004;
static const uint32_t kSDLPixelFormatBGRA8888 = 0x16862004;

/// The Mac's screen as the wrapp shows it: shared memory, a whole screen of
/// 32-bit pixels, kept up to date at each unlock. Taken by the video thread
/// as it copies and by puppet control as it pictures it.
static os_unfair_lock gScreenLock = OS_UNFAIR_LOCK_INIT;
static uint8_t *gScreen;
static size_t gScreenSize;
static int gWidth, gHeight, gRowBytes;
static uint32_t gFormat;
/// What changed since the last frame was told, as a box (empty: nothing).
static int gDirtyLeft, gDirtyTop, gDirtyRight, gDirtyBottom;
/// Whether the last frame told was covered, and whether one has been yet.
static BOOL gCoveredTold = NO, gFrameTold = NO;
static _Atomic BOOL gCovered = NO;

/// The texture locked now, and where its locked pixels are.
static void *gLockedTexture;
static SDLRect gLockedRect;
static uint8_t *gLockedPixels;
static int gLockedPitch;

static void markDirty(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return;
    if (gDirtyRight <= gDirtyLeft || gDirtyBottom <= gDirtyTop) {
        gDirtyLeft = x; gDirtyTop = y; gDirtyRight = x + w; gDirtyBottom = y + h;
        return;
    }
    gDirtyLeft = MIN(gDirtyLeft, x);
    gDirtyTop = MIN(gDirtyTop, y);
    gDirtyRight = MAX(gDirtyRight, x + w);
    gDirtyBottom = MAX(gDirtyBottom, y + h);
}

/// Shared memory for a screen of this size, sent to the wrapp; the old
/// screen given up. Under gScreenLock.
static BOOL newScreen(int width, int height, uint32_t format) {
    static int made = 0;
    char name[32];
    snprintf(name, sizeof(name), "/scbd-%d-%d", getpid(), ++made);
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        helperReport(kHelper, "error", "can't make memory for the Mac's screen: %s", strerror(errno));
        return NO;
    }
    shm_unlink(name);
    int rowBytes = width * 4;
    size_t size = (size_t)rowBytes * (size_t)height;
    void *memory = MAP_FAILED;
    if (ftruncate(fd, (off_t)size) == 0) memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (memory == MAP_FAILED) {
        helperReport(kHelper, "error", "can't map memory for the Mac's screen: %s", strerror(errno));
        close(fd);
        return NO;
    }
    BOOL told = sendMessage(kMessageScreen, width, height, rowBytes, (int32_t)format, 0, fd);
    close(fd);
    if (gScreen) munmap(gScreen, gScreenSize);
    gScreen = memory;
    gScreenSize = size;
    gWidth = width;
    gHeight = height;
    gRowBytes = rowBytes;
    gFormat = format;
    gDirtyLeft = gDirtyTop = gDirtyRight = gDirtyBottom = 0;
    helperReport(kHelper, "notice", "the Mac's screen is %dx%d%s", width, height, told ? "" : " (the wrapp wasn't told)");
    // A whole screen, as this one is empty: Basilisk II otherwise copies only
    // what changes.
    dispatch_async(dispatch_get_main_queue(), ^{ basiliskMacRedrawAll("a new screen for the wrapp"); });
    return YES;
}

/// What was locked, copied into the screen at its unlock.
static void copyLocked(void) {
    uint32_t format = 0;
    int access = 0, width = 0, height = 0;
    if (!queryTexture || queryTexture(gLockedTexture, &format, &access, &width, &height) != 0) return;
    if (format != kSDLPixelFormatARGB8888 && format != kSDLPixelFormatBGRA8888) {
        static BOOL said = NO;
        if (!said) helperReport(kHelper, "warning", "the Mac's screen is in an SDL format this doesn't know (0x%x)", format);
        said = YES;
        return;
    }
    os_unfair_lock_lock(&gScreenLock);
    if (!gScreen || width != gWidth || height != gHeight || format != gFormat) {
        if (!newScreen(width, height, format)) {
            os_unfair_lock_unlock(&gScreenLock);
            return;
        }
    }
    SDLRect rect = gLockedRect;
    if (rect.w <= 0 || rect.h <= 0) rect = (SDLRect){ 0, 0, width, height };
    rect.w = MIN(rect.w, width - rect.x);
    rect.h = MIN(rect.h, height - rect.y);
    if (rect.x >= 0 && rect.y >= 0 && rect.w > 0 && rect.h > 0) {
        for (int row = 0; row < rect.h; row++) {
            memcpy(gScreen + (size_t)(rect.y + row) * (size_t)gRowBytes + (size_t)rect.x * 4,
                   gLockedPixels + (size_t)row * (size_t)gLockedPitch, (size_t)rect.w * 4);
        }
        markDirty(rect.x, rect.y, rect.w, rect.h);
    }
    os_unfair_lock_unlock(&gScreenLock);
}

static int displayLockTexture(void *texture, const SDLRect *rect, void **pixels, int *pitch) {
    int result = realLockTexture(texture, rect, pixels, pitch);
    if (result == 0 && pixels && pitch) {
        gLockedTexture = texture;
        gLockedRect = rect ? *rect : (SDLRect){ 0, 0, 0, 0 };
        gLockedPixels = *pixels;
        gLockedPitch = *pitch;
    }
    return result;
}

static void displayUnlockTexture(void *texture) {
    if (texture == gLockedTexture && gLockedPixels) copyLocked();
    gLockedPixels = NULL;
    realUnlockTexture(texture);
}

/// Basilisk II's frame, told to the wrapp: what changed, and whether the
/// Mac is covered. Nothing goes to Basilisk II's window. On the video thread.
static void displayPresent(void *renderer) {
    BOOL covered = basiliskMacCoverAtFrame();
    atomic_store(&gCovered, covered);
    os_unfair_lock_lock(&gScreenLock);
    BOOL changed = gDirtyRight > gDirtyLeft && gDirtyBottom > gDirtyTop;
    if (gScreen && (changed || covered != gCoveredTold || !gFrameTold)) {
        BOOL told = changed
            ? sendMessage(kMessageFrame, gDirtyLeft, gDirtyTop, gDirtyRight - gDirtyLeft, gDirtyBottom - gDirtyTop, covered, -1)
            : sendMessage(kMessageFrame, 0, 0, 0, 0, covered, -1);
        // Not told: kept for the next frame, which tells it all.
        if (told) {
            gDirtyLeft = gDirtyTop = gDirtyRight = gDirtyBottom = 0;
            gCoveredTold = covered;
            gFrameTold = YES;
        }
    }
    os_unfair_lock_unlock(&gScreenLock);
}

/// SDL_RenderCopy and SDL_RenderClear, doing nothing: with no present to
/// send it, SDL would only pile up what they ask for.
static int copyNothing(void *renderer, void *texture, const SDLRect *source, const SDLRect *destination) {
    return 0;
}

static int clearNothing(void *renderer) {
    return 0;
}

#pragma mark - Basilisk II's window

typedef void *(*CreateWindowFunction)(const char *, int, int, int, int, uint32_t);
static CreateWindowFunction realCreateWindow;

static const uint32_t kSDLWindowShown = 0x4, kSDLWindowHidden = 0x8, kSDLWindowFullscreenFlags = 0x1 | 0x1000;

/// The process an accessory app, out of the Dock and Cmd-Tab, and kept
/// from App Nap: with no window on the screen macOS would nap it, and the
/// Mac's sound and clock slow with it. Once there's an app, on the main
/// thread.
static void settleApp(void) {
    static id activity;
    if (activity) return;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                                            reason:@"The emulated Mac's screen is shown by the app"];
    helperReport(kHelper, "notice", "Basilisk II is an accessory app, its screen shown by the wrapp");
}

/// Basilisk II's window, made hidden, and never fullscreen.
static void *hiddenCreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags) {
    void *window = realCreateWindow(title, x, y, w, h, (flags & ~(kSDLWindowShown | kSDLWindowFullscreenFlags)) | kSDLWindowHidden);
    helperReport(kHelper, "notice", "Basilisk II's window made hidden (%dx%d)", w, h);
    if ([NSThread isMainThread]) settleApp();
    else dispatch_async(dispatch_get_main_queue(), ^{ settleApp(); });
    return window;
}

static int stayWindowed(void *window, uint32_t flags) {
    return 0;
}

#pragma mark - The wrapp's window, for puppet control

static _Atomic int gWindowFullscreen, gWindowKey, gAppActive, gWindowWidth, gWindowHeight;

static BOOL remoteSize(int *width, int *height) {
    os_unfair_lock_lock(&gScreenLock);
    *width = gWidth;
    *height = gHeight;
    BOOL ok = gScreen != NULL;
    os_unfair_lock_unlock(&gScreenLock);
    return ok;
}

/// The screen as the wrapp's window shows it: black while the Mac is covered.
static CGImageRef remoteCopyPicture(void) {
    os_unfair_lock_lock(&gScreenLock);
    if (!gScreen) {
        os_unfair_lock_unlock(&gScreenLock);
        return NULL;
    }
    size_t size = gScreenSize;
    int width = gWidth, height = gHeight, rowBytes = gRowBytes;
    uint32_t format = gFormat;
    CFMutableDataRef data = CFDataCreateMutable(NULL, (CFIndex)size);
    CFDataSetLength(data, (CFIndex)size);
    if (atomic_load(&gCovered)) memset(CFDataGetMutableBytePtr(data), 0, size);
    else memcpy(CFDataGetMutableBytePtr(data), gScreen, size);
    os_unfair_lock_unlock(&gScreenLock);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // ARGB8888 is a 32-bit ARGB number, BGRA8888 a BGRA one; in memory, as
    // this Mac is little-endian, B G R A and A R G B.
    CGBitmapInfo info = format == kSDLPixelFormatARGB8888
        ? (CGBitmapInfo)kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst
        : (CGBitmapInfo)kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)rowBytes, space, info, provider,
                                     NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

static void remoteWindowState(BOOL *fullscreen, BOOL *key, BOOL *active, double *width, double *height) {
    *fullscreen = atomic_load(&gWindowFullscreen) != 0;
    *key = atomic_load(&gWindowKey) != 0;
    *active = atomic_load(&gAppActive) != 0;
    *width = atomic_load(&gWindowWidth);
    *height = atomic_load(&gWindowHeight);
}

static void remoteFocus(void) {
    sendMessage(kMessageFocus, 0, 0, 0, 0, 0, -1);
}

static void remoteYield(pid_t pid) {
    sendMessage(kMessageYield, pid, 0, 0, 0, 0, -1);
}

static const HelperRemoteScreen kRemoteScreen = {
    .size = remoteSize,
    .copyPicture = remoteCopyPicture,
    .mouseMoved = macMouseMoved,
    .button = macButton,
    .key = macKey,
    .windowState = remoteWindowState,
    .focus = remoteFocus,
    .yield = remoteYield,
};

#pragma mark - Reading the wrapp

/// The wrapp's messages, for as long as it's there: once it's gone, nothing
/// shows the Mac, so it's shut down rather than left running unseen.
static void *readWrapp(void *arg) {
    for (;;) {
        DisplayMessage message;
        ssize_t got = recv(gSocket, &message, sizeof(message), MSG_WAITALL);
        if (got != (ssize_t)sizeof(message)) break;
        int32_t *v = message.values;
        switch (message.type) {
        case kMessageMouse: macMouseMoved(v[0], v[1]); break;
        case kMessageButton: macButton(v[0], v[1] != 0); break;
        case kMessageKey: macKey(v[0], v[1] != 0); break;
        case kMessageWindowState:
            atomic_store(&gWindowFullscreen, v[0]);
            atomic_store(&gWindowKey, v[1]);
            atomic_store(&gAppActive, v[2]);
            atomic_store(&gWindowWidth, v[3]);
            atomic_store(&gWindowHeight, v[4]);
            break;
        case kMessageRedraw:
            dispatch_async(dispatch_get_main_queue(), ^{ basiliskMacRedrawAll("the wrapp asked"); });
            break;
        default:
            helperReport(kHelper, "warning", "a message from the wrapp this doesn't know (%u)", message.type);
        }
    }
    helperReport(kHelper, "notice", "the wrapp's window has gone");
    dispatch_async(dispatch_get_main_queue(), ^{ basiliskMacShutDown("the wrapp that showed it has gone"); });
    return NULL;
}

#pragma mark - Arming

/// From basilisk_mac.m's constructor, before Basilisk II makes its window:
/// YES when the screen is the wrapp's to show. When NO, Basilisk II's own
/// window shows it, as it would without this.
BOOL basiliskDisplayArm(void) {
    const char *path = getenv("BASILISK_MAC_DISPLAY");
    if (!path || !*path) return NO;
    gSocket = connectToWrapp(path);
    if (gSocket < 0) {
        helperReport(kHelper, "error", "can't reach the wrapp's window at %s: %s; Basilisk II's own window shows the Mac",
                     path, strerror(errno));
        return NO;
    }
    NSString *missing = nil;
    if (!findADB()) missing = @"Basilisk II's ADB functions aren't there";
    realLockTexture = (LockTextureFunction)dlsym(RTLD_DEFAULT, "SDL_LockTexture");
    realUnlockTexture = (UnlockTextureFunction)dlsym(RTLD_DEFAULT, "SDL_UnlockTexture");
    queryTexture = (QueryTextureFunction)dlsym(RTLD_DEFAULT, "SDL_QueryTexture");
    realCreateWindow = (CreateWindowFunction)dlsym(RTLD_DEFAULT, "SDL_CreateWindow");
    if (!missing && !(realLockTexture && realUnlockTexture && queryTexture && realCreateWindow)) missing = @"SDL2's functions aren't there";
    // The picture first, the window last: a window is hidden only once
    // everything that shows the Mac elsewhere is in place. A redirect that
    // fails after another has taken leaves both pointed here, harmlessly:
    // each still calls SDL's own.
    if (!missing && (rebindMainImport("_SDL_LockTexture", (void *)displayLockTexture) == 0
                     || rebindMainImport("_SDL_UnlockTexture", (void *)displayUnlockTexture) == 0
                     || rebindMainImport("_SDL_RenderPresent", (void *)displayPresent) == 0)) {
        missing = @"Basilisk II's SDL calls can't be redirected";
    }
    if (!missing) {
        rebindMainImport("_SDL_RenderCopy", (void *)copyNothing);
        rebindMainImport("_SDL_RenderClear", (void *)clearNothing);
        rebindMainImport("_SDL_SetWindowFullscreen", (void *)stayWindowed);
        if (rebindMainImport("_SDL_CreateWindow", (void *)hiddenCreateWindow) == 0) missing = @"Basilisk II's window can't be hidden";
    }
    if (missing) {
        helperReport(kHelper, "warning", "%s: Basilisk II's own window shows the Mac", missing.UTF8String);
        sendMessage(kMessageHello, getpid(), 0, 0, 0, 0, -1);
        close(gSocket);
        gSocket = -1;
        return NO;
    }
    // SDL reads its hints from the environment when Basilisk II starts it,
    // after this constructor: as a background app it never makes itself a
    // regular one, with a Dock icon, nor takes activation from the wrapp.
    setenv("SDL_MAC_BACKGROUND_APP", "1", 1);
    helperRemoteScreen = &kRemoteScreen;
    sendMessage(kMessageHello, getpid(), 1, 0, 0, 0, -1);
    pthread_t thread;
    if (pthread_create(&thread, NULL, readWrapp, NULL) == 0) pthread_detach(thread);
    helperReport(kHelper, "notice", "armed: the Mac's screen is shown in the wrapp's window (%s)", path);
    return YES;
}
