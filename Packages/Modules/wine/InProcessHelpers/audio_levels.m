//
//  audio_levels.m
//  Measures how loud the game is, from the samples Wine hands Core Audio,
//  so a test can tell a game whose sound works from one that plays silence
//  -- without the System Audio Recording permission a tap from outside the
//  process needs.
//
//  Wine's Core Audio driver, winecoreaudio.so (x86_64-unix), plays each
//  stream through an output AudioUnit, giving it a render callback with
//  AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback): Core Audio
//  calls it on its render thread for each buffer, and Wine fills the buffer
//  from what the game (DirectSound, winmm, ...) has mixed. winecoreaudio.so
//  is loaded only when the game first opens sound, after this dylib's
//  constructors have run, so a dyld add-image notifier waits for it and then
//  points its import of AudioUnitSetProperty at a wrapper (replaceImageImport,
//  helper_common.h). The wrapper puts its own callback in front of Wine's:
//  it calls Wine's, then measures the samples Wine wrote. The stream's
//  format (float32 is Wine's mix format; int16, int24, int32, float64 and
//  unsigned 8-bit are read too) comes from the unit's
//  kAudioUnitProperty_StreamFormat, asked when the callback is set and kept
//  up to date as Wine sets it.
//
//  The render thread must never wait, or the sound glitches: it does no
//  allocation and takes no lock. Each buffer's peak and sum of squares go
//  into a ring of 0.1 s windows, by atomics alone, keyed by the window's
//  number since the process started. puppet control's `audio <seconds>`
//  (audioLevelsListen) waits that long and reads the windows back: a window
//  nothing rendered into reads as silence.
//
//  Armed only where puppet control is (SECOND_CHANCE_PUPPET_DIR and
//  PUPPET_CONTROL_EXE: WrappPuppeteer or `sc puppet` started the wrapp), never
//  for players. See docs/wine-in-process-helpers.md#audio-levels.
//
//  Built into in_process_helpers.dylib by build-in-process-helpers.sh.
//

#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <os/log.h>
#include <stdatomic.h>
#include <unistd.h>

#include "helper_common.h"

static os_log_t gLog;

#pragma mark - Levels, by atomics

/// A 0.1 s window's levels: which window it holds (its number + 1, so 0 is
/// none), its peak as a float's bits (a positive float's bits order as the
/// float does), and its sum of squares in fixed point.
typedef struct {
    _Atomic uint64_t window;
    _Atomic uint32_t peakBits;
    _Atomic uint64_t sumSquares;
    _Atomic uint64_t samples;
} LevelWindow;

/// 1024 windows: 102 s, more than any request may listen for.
#define kWindowCount 1024
static const double kWindowSeconds = 0.1;
/// A sample's square (0...1) is kept in units of 2^-24: a whole window's sum
/// fits in 64 bits many times over.
static const double kSquareUnit = 16777216.0;

static LevelWindow gWindows[kWindowCount];
static double gTicksPerSecond;
static uint64_t gStartTicks;

static uint64_t currentWindow(void) {
    return (uint64_t)((double)(mach_absolute_time() - gStartTicks) / gTicksPerSecond / kWindowSeconds);
}

/// Add one buffer's levels to the window it ends in. Two streams rendering
/// into a window just as it's reused can lose a buffer's levels to each
/// other; a 0.1 s window has several buffers, so the reading barely moves.
static void addLevels(float peak, double sumSquares, uint64_t samples) {
    uint64_t number = currentWindow() + 1;
    LevelWindow *slot = &gWindows[number % kWindowCount];
    uint64_t held = atomic_load_explicit(&slot->window, memory_order_acquire);
    if (held != number) {
        if (atomic_compare_exchange_strong(&slot->window, &held, number)) {
            atomic_store_explicit(&slot->peakBits, 0, memory_order_relaxed);
            atomic_store_explicit(&slot->sumSquares, 0, memory_order_relaxed);
            atomic_store_explicit(&slot->samples, 0, memory_order_relaxed);
        }
    }
    union { float f; uint32_t bits; } value = { .f = peak };
    uint32_t current = atomic_load_explicit(&slot->peakBits, memory_order_relaxed);
    while (value.bits > current &&
           !atomic_compare_exchange_weak_explicit(&slot->peakBits, &current, value.bits, memory_order_relaxed, memory_order_relaxed)) {
    }
    atomic_fetch_add_explicit(&slot->sumSquares, (uint64_t)(sumSquares * kSquareUnit), memory_order_relaxed);
    atomic_fetch_add_explicit(&slot->samples, samples, memory_order_relaxed);
}

#pragma mark - Samples

typedef enum { FormatUnknown = 0, FormatFloat32, FormatFloat64, FormatInt16, FormatInt24, FormatInt32, FormatUInt8 } SampleFormat;

static const char *formatName(SampleFormat format) {
    switch (format) {
    case FormatFloat32: return "float32";
    case FormatFloat64: return "float64";
    case FormatInt16: return "int16";
    case FormatInt24: return "int24";
    case FormatInt32: return "int32";
    case FormatUInt8: return "uint8";
    default: return "unknown";
    }
}

static SampleFormat sampleFormat(const AudioStreamBasicDescription *description) {
    if (description->mFormatID != kAudioFormatLinearPCM) return FormatUnknown;
    if (description->mFormatFlags & kAudioFormatFlagIsBigEndian) return FormatUnknown;
    UInt32 bits = description->mBitsPerChannel;
    if (description->mFormatFlags & kAudioFormatFlagIsFloat) {
        return bits == 32 ? FormatFloat32 : bits == 64 ? FormatFloat64 : FormatUnknown;
    }
    if (description->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        // 24-bit samples packed in 3 bytes; in 4 they're read as int32.
        UInt32 bytes = description->mChannelsPerFrame ? description->mBytesPerFrame /
            ((description->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : description->mChannelsPerFrame) : 0;
        if (bits == 16) return FormatInt16;
        if (bits == 24) return bytes == 3 ? FormatInt24 : FormatInt32;
        if (bits == 32) return FormatInt32;
        return FormatUnknown;
    }
    return bits == 8 ? FormatUInt8 : FormatUnknown;
}

/// One sample, -1...1.
static inline float sampleAt(const uint8_t *data, size_t index, SampleFormat format) {
    switch (format) {
    case FormatFloat32: return ((const float *)data)[index];
    case FormatFloat64: return (float)((const double *)data)[index];
    case FormatInt16: return ((const int16_t *)data)[index] / 32768.0f;
    case FormatInt32: return ((const int32_t *)data)[index] / 2147483648.0f;
    case FormatInt24: {
        const uint8_t *p = data + index * 3;
        int32_t value = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
        return value / 8388608.0f;
    }
    case FormatUInt8: return (data[index] - 128) / 128.0f;
    default: return 0;
    }
}

static size_t bytesPerSample(SampleFormat format) {
    switch (format) {
    case FormatFloat64: return 8;
    case FormatFloat32: case FormatInt32: return 4;
    case FormatInt24: return 3;
    case FormatInt16: return 2;
    case FormatUInt8: return 1;
    default: return 0;
    }
}

#pragma mark - Wrapping Wine's streams

/// One stream Wine set a render callback on: the unit, Wine's callback, and
/// its format. Made on the thread that set it up, never on the render thread.
typedef struct {
    AudioUnit unit;
    AURenderCallback callback;
    void *refCon;
    _Atomic int format;
} Stream;

#define kMaxStreams 64
static Stream *gStreams[kMaxStreams];
static _Atomic int gStreamCount;
static _Atomic uint64_t gBuffers;

typedef OSStatus (*SetPropertyFunction)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static SetPropertyFunction gSetProperty;

static OSStatus measuringRender(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                UInt32 bus, UInt32 frames, AudioBufferList *data) {
    Stream *stream = refCon;
    OSStatus status = stream->callback(stream->refCon, flags, time, bus, frames, data);
    if (status != noErr || !data) return status;
    atomic_fetch_add_explicit(&gBuffers, 1, memory_order_relaxed);
    SampleFormat format = (SampleFormat)atomic_load_explicit(&stream->format, memory_order_relaxed);
    size_t size = bytesPerSample(format);
    float peak = 0;
    double sumSquares = 0;
    uint64_t samples = 0;
    BOOL silent = flags && (*flags & kAudioUnitRenderAction_OutputIsSilence);
    for (UInt32 b = 0; size && b < data->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &data->mBuffers[b];
        size_t count = buffer->mDataByteSize / size;
        samples += count;
        if (silent || !buffer->mData) continue;
        for (size_t i = 0; i < count; i++) {
            float value = sampleAt(buffer->mData, i, format);
            float magnitude = fabsf(value);
            if (magnitude > peak) peak = magnitude;
            sumSquares += (double)value * value;
        }
    }
    // NaN or worse from a bad format would poison the window.
    if (!(peak >= 0) || peak > 1000) peak = 0;
    addLevels(peak, sumSquares, samples);
    return status;
}

static Stream *streamFor(AudioUnit unit) {
    int count = atomic_load(&gStreamCount);
    if (count > kMaxStreams) count = kMaxStreams;
    for (int i = count - 1; i >= 0; i--) {
        if (gStreams[i] && gStreams[i]->unit == unit) return gStreams[i];
    }
    return NULL;
}

static void noteFormat(Stream *stream) {
    AudioStreamBasicDescription description = {0};
    UInt32 size = sizeof(description);
    if (AudioUnitGetProperty(stream->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &description, &size) == noErr) {
        SampleFormat format = sampleFormat(&description);
        atomic_store(&stream->format, format);
        os_log(gLog, "[AudioLevels] stream %p: %{public}s, %u channels, %.0f Hz", stream->unit, formatName(format),
               (unsigned)description.mChannelsPerFrame, description.mSampleRate);
    }
}

static OSStatus measuringSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope,
                                     AudioUnitElement element, const void *value, UInt32 size) {
    if (property == kAudioUnitProperty_SetRenderCallback && value && size >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *wine = value;
        Stream *stream = wine->inputProc ? calloc(1, sizeof(Stream)) : NULL;
        if (stream) {
            stream->unit = unit;
            stream->callback = wine->inputProc;
            stream->refCon = wine->inputProcRefCon;
            AURenderCallbackStruct ours = { .inputProc = measuringRender, .inputProcRefCon = stream };
            OSStatus status = gSetProperty(unit, property, scope, element, &ours, sizeof(ours));
            if (status == noErr) {
                // Kept for the life of the process: the render thread may
                // still be in it after Wine disposes of the unit. Past
                // kMaxStreams it still measures, but isn't listed.
                int index = atomic_fetch_add(&gStreamCount, 1);
                if (index < kMaxStreams) gStreams[index] = stream;
                noteFormat(stream);
                return status;
            }
            free(stream);
        }
    }
    OSStatus status = gSetProperty(unit, property, scope, element, value, size);
    if (status == noErr && property == kAudioUnitProperty_StreamFormat && scope == kAudioUnitScope_Input) {
        Stream *stream = streamFor(unit);
        if (stream) noteFormat(stream);
    }
    return status;
}

static _Atomic int gHooked;

static void imageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (atomic_load(&gHooked)) return;
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    if (strcmp(processIdentityBasename(info.dli_fname), "winecoreaudio.so") != 0) return;
    int replaced = replaceImageImport((const struct mach_header_64 *)header, (void *)AudioUnitSetProperty, (void *)measuringSetProperty);
    if (replaced > 0) {
        atomic_store(&gHooked, 1);
        helperReport("AudioLevels", "notice", "measuring the game's sound in winecoreaudio.so");
    } else {
        helperReport("AudioLevels", "warning", "couldn't redirect winecoreaudio.so's AudioUnitSetProperty; the game's sound can't be measured");
    }
}

#pragma mark - Reading them back

int audioLevelsArmed(void) {
    return gTicksPerSecond > 0;
}

NSString *audioLevelsListen(double seconds) {
    if (!audioLevelsArmed()) return @"error no audio measure here: it's armed only in a Wine game under puppet control";
    if (!(seconds > 0) || seconds > 60) return @"error listen for more than 0 and at most 60 seconds";
    uint64_t first = currentWindow() + 1;
    uint64_t buffersBefore = atomic_load(&gBuffers);
    usleep((useconds_t)(seconds * 1e6));
    uint64_t end = currentWindow() + 1;
    // The window still filling is left out: it isn't whole.
    uint64_t count = end > first ? end - first : 0;
    if (count > kWindowCount - 8) count = kWindowCount - 8;
    NSMutableString *lines = [NSMutableString string];
    float loudest = 0;
    double loudestRMS = 0;
    uint64_t sounding = 0, clipped = 0;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t number = first + i;
        LevelWindow *slot = &gWindows[number % kWindowCount];
        float peak = 0;
        double rms = 0;
        if (atomic_load(&slot->window) == number) {
            union { float f; uint32_t bits; } value = { .bits = atomic_load(&slot->peakBits) };
            uint64_t samples = atomic_load(&slot->samples);
            peak = value.f;
            rms = samples ? sqrt((double)atomic_load(&slot->sumSquares) / kSquareUnit / (double)samples) : 0;
        }
        if (peak >= 0.001f) sounding++;
        if (peak >= 0.999f) clipped++;
        if (peak > loudest) loudest = peak;
        if (rms > loudestRMS) loudestRMS = rms;
        [lines appendFormat:@"\nlevel t=%.1f peak=%.6f rms=%.6f", (double)(i + 1) * kWindowSeconds, peak, rms];
    }
    int streams = atomic_load(&gStreamCount);
    Stream *latest = streams > 0 ? gStreams[MIN(streams, kMaxStreams) - 1] : NULL;
    SampleFormat format = latest ? (SampleFormat)atomic_load(&latest->format) : FormatUnknown;
    const char *verdict = sounding == 0 ? "silent" : clipped > 0 ? "clipping" : "sound";
    return [NSString stringWithFormat:@"ok %s windows=%llu sounding=%llu clipped=%llu peak=%.6f rms=%.6f streams=%d buffers=%llu format=%s hooked=%d%@",
            verdict, count, sounding, clipped, loudest, loudestRMS, streams, atomic_load(&gBuffers) - buffersBefore,
            formatName(format), atomic_load(&gHooked), lines];
}

__attribute__((constructor))
static void audioLevelsInit(void) {
    gLog = os_log_create("com.secondchance.gamewrapper", "AudioLevels");
    // Armed as puppet_control.m is: `*` arms it in every process.
    const char *directory = getenv("SECOND_CHANCE_PUPPET_DIR");
    const char *exe = getenv("PUPPET_CONTROL_EXE");
    BOOL everywhere = exe && strcmp(exe, "*") == 0;
    if (!directory || !*directory || !(everywhere || processRunsExeNamedBy("PUPPET_CONTROL_EXE"))) return;
    // A ScummVM wrapp loads this dylib into scummvm, which plays through SDL,
    // not winecoreaudio.so: nothing to wrap there (the docs say what would
    // be). In Wine, winemac.so is what loaded this dylib.
    if (!loadedImageNamed("winemac.so", NULL, NULL)) return;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gTicksPerSecond = 1e9 * (double)timebase.denom / (double)timebase.numer;
    gStartTicks = mach_absolute_time();
    gSetProperty = AudioUnitSetProperty;
    _dyld_register_func_for_add_image(imageAdded);
}
