//
//  FakeWine.swift
//  SecondChanceTests
//
//  A wrapp whose `wine` and `wineserver` are shell scripts, for testing what
//  Second Chance runs without running Wine. Each records its arguments, one
//  call per line with each argument in brackets, then runs the body it was
//  given.

import Foundation
@testable import SecondChance

struct FakeWine {
    let wrapp: URL
    private let calls: URL

    var wine: Wine { Wine(wrapp: wrapp) }

    /// `wine` and `wineserver` run these shell bodies after recording the call.
    init(wine wineBody: String = "exit 0", wineserver wineserverBody: String = "exit 0") throws {
        wrapp = FileManager.default.temporaryDirectory.appendingPathComponent("fake-wine-\(UUID().uuidString).app")
        calls = wrapp.appendingPathComponent("calls.txt")
        let bin = wrapp.appendingPathComponent("Contents/SharedSupport/wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: calls.path, contents: nil)
        for (tool, body) in [("wine", wineBody), ("wineserver", wineserverBody)] {
            let script = bin.appendingPathComponent(tool)
            try """
            #!/bin/sh
            { printf '%s' '\(tool)'; for argument in "$@"; do printf ' [%s]' "$argument"; done; echo; } >> '\(calls.path)'
            \(body)

            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    /// Every call so far, as `wine [reg] [query]`.
    func recorded() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The calls to `tool`, without its name.
    func recorded(_ tool: String) -> [String] {
        recorded().filter { $0.hasPrefix(tool + " ") || $0 == tool }.map { String($0.dropFirst(tool.count).drop { $0 == " " }) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: wrapp)
    }
}
