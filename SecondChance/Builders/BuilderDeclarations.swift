//
//  BuilderDeclarations.swift
//  SecondChance
//
//  What today's builders carry out of each module's declared instructions,
//  until each module's executor does (docs/modules.md#what-a-module-declares).

import Foundation

/// The instructions the builders carry out, by module, with the options
/// each reads (or checks and refuses). A unit test holds the modules'
/// `build:` declarations to it: every instruction declared is carried out,
/// none is carried out that isn't declared, and every option an
/// instruction declares is read, so none is accepted and ignored.
nonisolated enum BuilderDeclarations {
    static let handled: [String: [String: Set<String>]] = [
        // ModuleSteps, and DiskWrappBuilder's discs (`checkKeptDiscs`).
        "wine": [
            "WINETRICKS": [],
            "DRIVES": ["only"],
            "REGISTRY": ["set", "remove"],
            "KEEP-DISCS": ["into", "combined"],
            // The wine module's executor.
            "MOUNT": ["cdrom"],
            "HELPERS": [],
            "PREFIX": [],
            "KEEP-THREAD-HANDLES": [],
        ],
        // The nancy-drew module's executor.
        "nancy-drew": ["CONFIGURE-INI": []],
        // The scummvm module's executor.
        "scummvm": ["KEEP-DATA": []],
        // The basilisk module's executor.
        "basilisk": ["SETUP": [], "CDROM": [], "RUN": ["automation", "screen", "limit"], "STARTUP": []],
        // GameInstallerRunner, and its patch steps.
        "installer": ["RUN": ["from", "into", "answer-file", "automation", "creates", "patch", "mount"]],
        // HerDownloadWrappBuilder.
        "her-download": ["INSTALL": ["into", "answer-file", "automation", "creates"]],
        // SteamWrappBuilder's executor, which takes its stores.
        "steam": ["CLIENT": ["client-store"], "INSTALL": ["into", "sign-in-store", "client-store"], "SIGN-OUT": [], "REMOVE": []],
        // BigFishWrappBuilder.
        "big-fish": ["MANAGER": ["mount"], "INSTALL": ["into", "decline-directx", "sign-in-store"], "SIGN-OUT": []],
    ]
}
