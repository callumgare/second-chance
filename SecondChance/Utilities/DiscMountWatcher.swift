//
//  DiscMountWatcher.swift
//  SecondChance
//
//  Says when a disc has been put in and mounted, even while a modal alert is
//  up: Disk Arbitration's callbacks are scheduled in the main run loop's
//  common modes, which include the modal one, where NSWorkspace's mount
//  notifications aren't reliably delivered.

import DiskArbitration
import Foundation

@MainActor
final class DiscMountWatcher {
    private let session: DASession?
    private let onMount: (URL) -> Void

    /// Calls `onMount` on the main thread with each volume that is mounted
    /// from now until `stop()`.
    init(onMount: @escaping (URL) -> Void) {
        self.onMount = onMount
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // A disc's volume path appears in its description once it mounts.
        let keys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, keys, { disk, _, context in
            guard let context,
                  let description = DADiskCopyDescription(disk) as? [CFString: Any],
                  let path = description[kDADiskDescriptionVolumePathKey] as? URL else { return }
            let watcher = Unmanaged<DiscMountWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onMount(path.standardizedFileURL) }
        }, context)
    }

    /// No more callbacks: an unscheduled session delivers none. Call before
    /// letting the watcher go, since the session holds it unretained.
    func stop() {
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
}
