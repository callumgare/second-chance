// sc-audio-tap: the sound some processes make, measured from a Core Audio
// process tap, for `sc puppet audio` (docs/dev-cli.md#puppet-sessions).
//
// Not part of the sc package: sc compiles this file with swiftc into a small
// app of its own (PuppetAudio.swift), because a process tap needs the "System
// Audio Recording" permission, which macOS gives an app with an
// NSAudioCaptureUsageDescription, not a bare command-line tool, and keeps for
// as long as the app's signature stays the same. sc only rebuilds it when
// this file changes.
//
//   sc-audio-tap check                       -> permission authorized|denied|unknown
//   sc-audio-tap request                     -> asks macOS (a prompt on the screen), then as check
//   sc-audio-tap tap <pid,...> <seconds> [<window seconds>]
//       -> process pid=<n> object=<id> output=0|1   for each pid that's an audio client
//          format rate=<hz> channels=<n>
//          level t=<s> peak=<0-1> rms=<0-1>         every window (0.1 s), from the samples
//          done
//
// Denied, a tap delivers silence rather than an error, which would read as a
// silent program. So `tap` checks the permission first and refuses (exit 2)
// unless it's given. The check is TCC's private SPI, as macOS has no public
// one for this permission; fine in a developer tool, never in what ships.

import AudioToolbox
import CoreAudio
import Foundation

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    say("error \(message)")
    exit(code)
}

// MARK: Permission

enum Permission: String {
    case authorized, denied, unknown

    static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    static var tcc: UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }

    static func check() -> Permission {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Asks, which puts macOS's prompt on this session's screen, and waits
    /// up to `timeout` for an answer.
    static func request(timeout: TimeInterval) -> Permission {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return check() }
        let answered = DispatchSemaphore(value: 0)
        unsafeBitCast(symbol, to: Request.self)(service, nil) { _ in answered.signal() }
        _ = answered.wait(timeout: .now() + timeout)
        return check()
    }
}

// MARK: Core Audio

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: pid_t? = nil, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
        guard var qualifier else { return AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) }
        return AudioObjectGetPropertyData(object, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, pointer)
    }
    return status == noErr ? value : nil
}

func processObject(_ pid: pid_t) -> AudioObjectID? {
    let object = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject,
                          qualifier: pid, AudioObjectID(kAudioObjectUnknown))
    return object == AudioObjectID(kAudioObjectUnknown) ? nil : object
}

func defaultOutputUID() -> String? {
    guard let device = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                                AudioObjectID(kAudioObjectUnknown)), device != kAudioObjectUnknown,
          let uid = property(device, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none) ?? nil else { return nil }
    return uid.takeRetainedValue() as String
}

/// Levels over windows of the tapped sound, kept on the IO proc's queue.
final class Meter: @unchecked Sendable {
    let windowFrames: Int
    let rate: Double
    var frames = 0
    var windowSeen = 0
    var peak: Float = 0
    var squares: Double = 0
    var samples = 0

    init(rate: Double, window: Double) {
        self.rate = rate
        windowFrames = max(1, Int(rate * window))
    }

    /// One buffer list from the tap: Float32, interleaved or not.
    func take(_ list: UnsafeMutableAudioBufferListPointer, isFloat: Bool, channelsPerFrame: Int) {
        guard isFloat else { return }
        var framesHere = 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let values = data.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count {
                let value = values[index]
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                squares += Double(value) * Double(value)
            }
            samples += count
            framesHere = max(framesHere, count / max(1, Int(buffer.mNumberChannels)))
        }
        frames += framesHere
        windowSeen += framesHere
        if windowSeen >= windowFrames {
            let rms = samples > 0 ? (squares / Double(samples)).squareRoot() : 0
            say(String(format: "level t=%.2f peak=%.6f rms=%.6f", Double(frames) / rate, peak, rms))
            windowSeen = 0
            peak = 0
            squares = 0
            samples = 0
        }
    }
}

func tap(pids: [pid_t], seconds: Double, window: Double) -> Never {
    let permission = Permission.check()
    guard permission == .authorized else {
        say("permission \(permission.rawValue)")
        exit(2)
    }
    var objects: [AudioObjectID] = []
    for pid in pids {
        guard let object = processObject(pid) else { continue }
        let output = property(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
        say("process pid=\(pid) object=\(object) output=\(output)")
        objects.append(object)
    }
    guard !objects.isEmpty else {
        say("none of its processes has opened sound")
        exit(3)
    }

    let description = CATapDescription(stereoMixdownOfProcesses: objects)
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else { fail("couldn't create the tap (\(status))") }

    guard let format = property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else { fail("the tap has no format") }
    say(String(format: "format rate=%.0f channels=%d", format.mSampleRate, format.mChannelsPerFrame))
    let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32

    var aggregate: [String: Any] = [
        kAudioAggregateDeviceNameKey: "sc-audio-tap",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
    ]
    if let output = defaultOutputUID() {
        aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
        aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
    }
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
    guard status == noErr else { fail("couldn't create the aggregate device (\(status))") }

    let meter = Meter(rate: format.mSampleRate, window: window)
    let queue = DispatchQueue(label: "sc-audio-tap")
    var procID: AudioDeviceIOProcID?
    let channels = Int(format.mChannelsPerFrame)
    status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
        meter.take(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), isFloat: isFloat, channelsPerFrame: channels)
    }
    guard status == noErr, let procID else { fail("couldn't read from the tap (\(status))") }
    status = AudioDeviceStart(deviceID, procID)
    guard status == noErr else { fail("couldn't start the tap (\(status))") }
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(deviceID, procID)
    AudioDeviceDestroyIOProcID(deviceID, procID)
    AudioHardwareDestroyAggregateDevice(deviceID)
    queue.sync {}
    say("done")
    AudioHardwareDestroyProcessTap(tapID)
    exit(0)
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "check":
    say("permission \(Permission.check().rawValue)")
case "request":
    say("permission \(Permission.request(timeout: 60).rawValue)")
case "tap" where arguments.count >= 3:
    let pids = arguments[1].split(separator: ",").compactMap { pid_t($0) }
    guard let seconds = Double(arguments[2]), seconds > 0 else { fail("tap <pid,...> <seconds> [<window seconds>]") }
    tap(pids: pids, seconds: seconds, window: arguments.count > 3 ? Double(arguments[3]) ?? 0.1 : 0.1)
default:
    fail("usage: sc-audio-tap check | request | tap <pid,...> <seconds> [<window seconds>]")
}
