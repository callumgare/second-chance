//
//  SavesLink.swift
//  Shared
//
//  The Wine prefix's Documents folder, where the games keep their saves, is
//  a link to the player's saves folder in Application Support, made again on
//  every launch: the prefix may be a fresh copy, and the saves must outlive
//  it.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.SavesLink")

nonisolated public enum SavesLink {
    /// Makes `documents` a link to `saves`.
    ///
    /// A real folder there may hold saves a game wrote before the link
    /// existed, so it is moved aside beside it, never deleted. An old link is
    /// replaced. A link that can't be removed (a prefix that is read-only)
    /// is followed instead, and a link made where it points, unless
    /// something is there already.
    ///
    /// - Returns: where a real folder was moved to, if one was.
    @discardableResult
    public static func link(_ documents: URL, to saves: URL, now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        // Of the item itself, so a link whose target has gone still counts.
        let attributes = try? fileManager.attributesOfItem(atPath: documents.path)
        guard let type = attributes?[.type] as? FileAttributeType else {
            logger.debug("No Documents in the prefix yet: linking it to the saves")
            try fileManager.createSymbolicLink(at: documents, withDestinationURL: saves)
            return nil
        }

        if type == .typeDirectory {
            let aside = documents.deletingLastPathComponent()
                .appendingPathComponent("Documents (kept \(Int(now.timeIntervalSince1970)))")
            logger.warning("Documents in the prefix is a folder, not a link to the saves: moving it to \(aside.lastPathComponent)")
            try fileManager.moveItem(at: documents, to: aside)
            try fileManager.createSymbolicLink(at: documents, withDestinationURL: saves)
            return aside
        }

        do {
            try fileManager.removeItem(at: documents)
        } catch {
            logger.warning("Couldn't replace Documents in the prefix (\(error.localizedDescription)): linking where it points instead")
            let destination = try fileManager.destinationOfSymbolicLink(atPath: documents.path)
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : documents.deletingLastPathComponent().appendingPathComponent(destination).standardized
            if fileManager.fileExists(atPath: target.path) {
                logger.notice("Documents points to \(target.path), which is already there")
            } else {
                try fileManager.createSymbolicLink(at: target, withDestinationURL: saves)
            }
            return nil
        }
        try fileManager.createSymbolicLink(at: documents, withDestinationURL: saves)
        return nil
    }
}
