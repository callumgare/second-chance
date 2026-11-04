//
//  InputProvider.swift
//  WrappModuleKit
//
//  How a build gets its inputs: a disc, a download, an installer.

import Foundation

/// Gives a build its inputs by name, each when a step first needs it: a
/// disc's module mounts an image and asks for disc 2 then, a download's has
/// fetched and unpacked it. A source uses one, and so does
/// `wrapp-builder build --input`.
public nonisolated protocol InputProvider: Sendable {
    /// The input's folder or file.
    func input(_ name: String) async throws -> URL

    /// The input, or nil when the build has none of that name to give: a
    /// one-disc game's disc 2.
    func inputIfGiven(_ name: String) async throws -> URL?
}

nonisolated extension InputProvider {
    public func inputIfGiven(_ name: String) async throws -> URL? { try await input(name) }
}

/// Inputs already where they are, by name.
public nonisolated struct GivenInputs: InputProvider {
    public let inputs: [String: URL]

    public init(_ inputs: [String: URL]) { self.inputs = inputs }

    public func input(_ name: String) async throws -> URL {
        guard let url = inputs[name] else { throw StepFailure.recipe("the build was given no input called \(name)") }
        return url
    }

    public func inputIfGiven(_ name: String) async throws -> URL? { inputs[name] }
}
