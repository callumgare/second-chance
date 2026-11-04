//
//  PlannedStep.swift
//  WrappModuleKit
//
//  One step of a plan, as an executor is given it.

import Foundation

/// One step, ready to run: every value substituted.
public nonisolated struct PlannedStep: Sendable, Equatable, CustomStringConvertible, Codable {
    /// `RUN`, `COPY`, … for a core instruction, or `MOUNT` for `WINE.MOUNT`.
    public let instruction: String
    /// The module whose instruction it is, by id; nil for the core's.
    public let module: String?
    /// Each option's values, in order (`--mount` may be given many times);
    /// a flag has one empty value.
    public let options: [String: [String]]
    public let arguments: [String]
    /// `--name`, when the step was given one.
    public let name: String?
    /// Where it was written: `Wrappfile:12`, or `nancy-drew/functions/patch:20`
    /// from `Wrappfile:16`.
    public let origin: String

    public init(instruction: String, module: String?, options: [String: [String]], arguments: [String], name: String?, origin: String) {
        self.instruction = instruction
        self.module = module
        self.options = options
        self.arguments = arguments
        self.name = name
        self.origin = origin
    }

    public func option(_ name: String) -> String? { options[name]?.first }
    public func has(_ name: String) -> Bool { options[name] != nil }

    /// As `sc bundle plan` shows it, and as install layers are keyed:
    /// `WINE.KEEP-DISCS --into=wine:C:/…`.
    public var description: String {
        let keyword = module.map { "\($0.uppercased()).\(instruction)" } ?? instruction
        let rendered = options.keys.sorted().flatMap { key in
            options[key, default: []].map { $0.isEmpty ? "--\(key)" : "--\(key)=\($0)" }
        }
        return ([keyword] + rendered + arguments).joined(separator: " ")
    }

    /// How a whole input is written in a planned step (`input:disc-1`), so a
    /// builder tells an input from text that looks like one.
    public static func inputToken(_ name: String) -> String { "input:\(name)" }

    /// The input a word names, if it's an input's token.
    public static func input(in word: String?) -> String? {
        guard let word, word.hasPrefix("input:") else { return nil }
        return String(word.dropFirst("input:".count))
    }
}

nonisolated extension PlannedStep {
    /// A `--mount=` value's fields: `type=bind,source=…,target=C:/x` as
    /// `type`, `source` and `target`; a field with no `=` (`snapshot`) has
    /// an empty value.
    public static func fields(ofMount mount: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in mount.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            fields[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
        }
        return fields
    }

    /// Its mounts' fields, in order.
    public var mounts: [[String: String]] { (options["mount"] ?? []).map(Self.fields(ofMount:)) }

    /// `--keyword` as the plan writes it: `WINE.KEEP-DISCS`, `COPY`.
    public var keyword: String { module.map { "\($0.uppercased()).\(instruction)" } ?? instruction }
}
