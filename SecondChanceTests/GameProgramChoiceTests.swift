//
//  GameProgramChoiceTests.swift
//  SecondChanceTests
//
//  Which program is the game, when an install leaves several and none is
//  where the game's details say: ranked the same way every time, and asked
//  about unless no one is there to ask.

import Foundation
import Testing
@testable import SecondChance

@Suite("Choosing the game's program")
struct GameProgramChoiceTests {
    @Test("Uninstallers and the like go last; otherwise the shallowest first, then by name, whatever order they were found in")
    func ranking() {
        let base = "/w/drive_c/Program Files (x86)/Game"
        let found: Set = [
            "\(base)/Redist/DirectX/dxsetup.exe",
            "\(base)/uninst.exe",
            "\(base)/Tools/Config.exe",
            "\(base)/Play.exe",
        ]
        #expect(GameInstallerRunner.rankedGamePrograms(found).map(\.lastPathComponent)
            == ["Play.exe", "Config.exe", "uninst.exe", "dxsetup.exe"])
    }

    @Test("At the same depth the largest program comes first, as a game's program dwarfs its helpers")
    func largestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GameProgramChoiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sizes = ["unins000.exe": 900_000, "Setup.exe": 800_000, "Game.exe": 500_000, "Helper.exe": 10_000]
        for (name, size) in sizes {
            try Data(repeating: 0, count: size).write(to: root.appendingPathComponent(name))
        }
        let ranked = GameInstallerRunner.rankedGamePrograms(Set(sizes.keys.map { root.appendingPathComponent($0).path }))
        #expect(ranked.map(\.lastPathComponent) == ["Game.exe", "Helper.exe", "unins000.exe", "Setup.exe"])
        #expect(ranked.filter { !GameInstallerRunner.isNotTheGame($0) }.count == 2)
    }

    @Test("Names with numbers sort as a person would read them")
    func naturalOrder() {
        let found: Set = ["/c/Game10.exe", "/c/Game2.exe"]
        #expect(GameInstallerRunner.rankedGamePrograms(found).map(\.lastPathComponent) == ["Game2.exe", "Game10.exe"])
    }

    @Test("A headless run takes the likeliest program without asking")
    @MainActor
    func headlessTakesFirst() async throws {
        let input = WrappBuildInput(environment: ["NON_INTERACTIVE": "true"], viewModel: nil)
        #expect(try await input.chooseGameProgram(among: ["C:\\Game\\Play.exe", "C:\\Game\\uninst.exe"]) == "C:\\Game\\Play.exe")
    }
}
