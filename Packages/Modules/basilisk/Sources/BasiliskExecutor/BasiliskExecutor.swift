//
//  BasiliskExecutor.swift
//  BasiliskExecutor
//
//  The basilisk module's executor: the Mac's startup disk and ROM in the app,
//  and the program's discs as the Mac's CD.

import CryptoKit
import Foundation
import Logging
import ProcessKit
import WrappModuleKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.BasiliskExecutor")

/// Carries out the basilisk module's instructions in a tree laid out as a
/// wrapp, where the engine is installed already (`USE basilisk`):
/// - `BASILISK.SETUP`, what `USE` plans: the engine's System 7.5.3 disk
///   copied to `SharedSupport/basilisk/boot.hfv`, which later steps change
///   and the app keeps, and the person's ROM (`module:basilisk:/rom`) to
///   `mac.rom` beside it.
/// - `BASILISK.CDROM <input>`: the disc's image to `cdrom-<n>.iso`, the
///   Mac's CD, numbered in the order the steps give them.
public nonisolated struct BasiliskExecutor: ModuleExecutor {
    public static let handles = ["SETUP", "CDROM"]

    /// The engine's System 7.5.3, as `BasiliskBuild.prepare` lays it in.
    static let systemDisk = "Contents/SharedSupport/basilisk/system.hfv"
    static let folder = "Contents/SharedSupport/basilisk"
    static let rom = "module:basilisk:/rom"

    public init() {}

    public func keyInputs(for step: PlannedStep, in context: any StepContext) async throws -> KeyInputs {
        switch step.instruction {
        case "SETUP":
            // Another ROM is another Mac: what the layer was made with.
            guard let rom = context.file(Self.rom) else { return KeyInputs() }
            return KeyInputs([KeyInput("rom", try await Blocking.run { try Self.hash(rom) })])
        case "CDROM":
            let image = try await Self.image(step, in: context)
            return KeyInputs([KeyInput("disc", try await Blocking.run { try Self.fingerprint(image) })])
        default:
            return KeyInputs()
        }
    }

    public func run(_ step: PlannedStep, in context: any StepContext) async throws {
        let folder = context.tree.appendingPathComponent(Self.folder)
        switch step.instruction {
        case "SETUP":
            let system = context.tree.appendingPathComponent(Self.systemDisk)
            guard FileManager.default.fileExists(atPath: system.path) else {
                throw StepFailure.recipe("\(step.origin): BASILISK.SETUP needs the basilisk engine in this stage")
            }
            guard let rom = context.file(Self.rom) else {
                throw StepFailure.failed("\(step.origin): no Mac ROM was given (module:basilisk:/rom)")
            }
            try await Blocking.run {
                try Self.replace(folder.appendingPathComponent("boot.hfv"), with: system)
                try Self.replace(folder.appendingPathComponent("mac.rom"), with: rom)
            }
            logger.notice("The Mac's startup disk and ROM are in the app")
        case "CDROM":
            let image = try await Self.image(step, in: context)
            let target = try await Blocking.run { () -> URL in
                let files = FileManager.default
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let taken = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
                let number = (1...).first { !taken.contains("cdrom-\($0).iso") } ?? 1
                let target = folder.appendingPathComponent("cdrom-\(number).iso")
                try Self.replace(target, with: image)
                return target
            }
            logger.notice("The disc is the Mac's CD: \(target.lastPathComponent)")
        default:
            throw StepFailure.recipe("\(step.origin): the basilisk module has no instruction \(step.instruction)")
        }
    }

    /// The image file of the disc `step` names: a disc built from an image
    /// has it as `<input>.image` beside its mounted folder; an input given
    /// as a file (a command-line build) is the image itself.
    static func image(_ step: PlannedStep, in context: any StepContext) async throws -> URL {
        guard let argument = step.arguments.first, let name = PlannedStep.input(in: argument) else {
            throw StepFailure.recipe("\(step.origin): BASILISK.CDROM names a disc input (${input.disc-1})")
        }
        if let image = try await context.inputIfGiven("\(name).image") { return image }
        let given = try await context.input(name)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: given.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw StepFailure.failed("\(step.origin): \(name) is a disc, not a disc image, and the Mac's CD has to be an image")
        }
        return given
    }

    /// `target` made a copy of `source`: a clone where the volume can.
    static func replace(_ target: URL, with source: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
        try files.copyItem(at: source, to: target)
    }

    static func hash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// What tells one disc image from another without reading it all: its
    /// size and the hash of its first megabyte (its partition map and volume
    /// headers).
    static func fingerprint(_ image: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 1 << 20) ?? Data()
        let size = try FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int ?? 0
        return "\(size)-" + SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
    }
}
