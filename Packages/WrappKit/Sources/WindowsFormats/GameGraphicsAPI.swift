//
//  GameGraphicsAPI.swift
//  WindowsFormats
//
//  What a Wine game draws with, read from the DLLs its .exe imports. It
//  decides whether the wrapp arms cursor lock: a DirectDraw game draws through
//  cnc-ddraw, which swallows the player's first click unless the cursor lock
//  gets it to take the mouse first, while a Direct3D game never goes near
//  cnc-ddraw, and the cursor lock's middle clicks only get in the way — each
//  one closes a menu the player has opened from the menu bar. When the .exe
//  can't say, as an Armadillo-wrapped Big Fish edition's can't, the game
//  catalog's `GameInfo.graphics` does.
//  See docs/wine-in-process-helpers.md#cursor-lock.

import Foundation
import GameCatalog

nonisolated public enum GameGraphicsAPI: Equatable, Sendable {
    /// Imports ddraw.dll, so it draws through cnc-ddraw.
    case directDraw
    /// Imports Direct3D (d3d8.dll, d3d9.dll …) and not ddraw.dll.
    case direct3D
    /// Imports neither, or the .exe couldn't be read: a game that loads its
    /// graphics DLL at run time, or a DRM wrapper that hides the imports.
    case unknown

    public init(exeAt url: URL) {
        guard let imports = WindowsExecutable(contentsOf: url)?.importedDLLs else {
            self = .unknown
            return
        }
        self.init(importedDLLs: imports)
    }

    /// From the .exe's imports, or, when they don't say, from what the
    /// catalog knows about `game`: Armadillo hides the imports of every Big
    /// Fish edition, which then went without native fullscreen's fit for a
    /// Direct3D game and got the cursor lock's middle clicks.
    public init(exeAt url: URL, game: GameInfo?) {
        self.init(exeAt: url)
        guard self == .unknown, let known = game?.graphics else { return }
        switch known {
        case .directDraw: self = .directDraw
        case .direct3D: self = .direct3D
        }
    }

    /// From the lower-cased names of the DLLs an .exe imports.
    public init(importedDLLs imports: Set<String>) {
        if imports.contains("ddraw.dll") {
            self = .directDraw
        } else if imports.contains(where: { $0.hasPrefix("d3d") && !$0.hasPrefix("d3dx") }) {
            self = .direct3D
        } else {
            self = .unknown
        }
    }

    /// Whether cnc-ddraw may be drawing the game, so it needs cursor lock.
    /// Only a game known to draw with Direct3D goes without.
    public var mayUseCncDdraw: Bool { self != .direct3D }

    /// Whether the game may draw with Direct3D, so its picture needs scaling
    /// up when Wine emulates the display mode it switches to. Only a game known
    /// to draw through cnc-ddraw, which never switches the real display, goes
    /// without.
    public var mayUseDirect3D: Bool { self != .directDraw }

    /// For a log line: "… draws with <this>".
    public var logDescription: String {
        switch self {
        case .directDraw: return "DirectDraw (through cnc-ddraw)"
        case .direct3D: return "Direct3D"
        case .unknown: return "an unknown graphics API (its .exe imports neither ddraw nor d3d)"
        }
    }
}
