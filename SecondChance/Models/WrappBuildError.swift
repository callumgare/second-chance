//
//  WrappBuildError.swift
//  SecondChance
//
//  Errors thrown while building a wrapp.
//
//  Two texts for each: `playerMessage` is what the error screen shows, in
//  plain words with nothing technical in it, and `errorDescription` is what
//  the log, `sc` and a headless run print, which may say more. Any error at
//  all becomes one of these through `WrappBuildError(_:)`, so nothing reaches
//  the error screen without a plain message.

import Foundation
import GameCatalog
import SecondChanceKit

enum WrappBuildError: LocalizedError, Equatable {
    case unsupportedEngine
    /// The game's bundle can't be planned, or its plan has a step this
    /// builder can't run; the detail is for the log.
    case buildRecipeProblem(String)
    /// The signed-in Steam account doesn't own the game.
    case steamGameNotOwned(title: String)
    /// The signed-in Steam account owns none of the games on Steam.
    case steamNoGamesOwned
    /// Steam needs someone to sign in, and nobody can: a headless build
    /// with no saved session.
    case steamSignInRequired
    /// Nobody signed in to the window Steam showed, in time.
    case steamSignInTimedOut
    /// Steam neither signed in nor asked for credentials: it went quiet
    /// again after being started again (and, from the app, after signing in
    /// afresh), or kept at it for too long without getting anywhere.
    case steamStoppedResponding
    /// Steam exited before it signed in, twice: once is started again.
    case steamExited
    /// Steam exited while it was installing the game.
    case steamExitedWhileInstalling
    /// Steam's download of the game got nowhere for too long.
    case steamDownloadStalled
    /// Steam's own install of the game failed, for `reason` (in Steam's words).
    case steamInstallFailed(reason: String)
    /// Another wrapp, or another build, is running Steam. The error screen
    /// offers to quit it, as a fallback.
    case steamInUse(SteamLockHolder)
    /// Big Fish's Game Manager couldn't be downloaded or installed.
    case bigFishGameManagerInstallFailed
    /// The Game Manager needs someone to sign in, and nobody can: a headless
    /// build without the test harness's sign-in.
    case bigFishSignInRequired
    /// Nobody signed in to the Game Manager's window in time.
    case bigFishSignInTimedOut
    /// The Game Manager quit partway through the build.
    case bigFishGameManagerQuit
    /// The signed-in Big Fish account owns none of the games.
    case bigFishNoGamesOwned
    /// The signed-in Big Fish account doesn't own the game.
    case bigFishGameNotOwned(title: String)
    /// The Game Manager couldn't download the game.
    case bigFishDownloadFailed
    /// The Game Manager couldn't install the game it downloaded.
    case bigFishInstallFailed
    /// The Game Manager installed the game, but couldn't activate it (Big
    /// Fish's DRM unlocking it for this computer).
    case bigFishActivationFailed
    case installerNotFound
    /// The folder chosen holds a game that's already installed, with no
    /// installer beside it (`GameDetector.isInstalledGame`).
    case installedGameNotInstaller
    /// A game's app was chosen to be updated, and it can only be built
    /// afresh from its `source`, for `reason` (for the log).
    case updateNeedsSource(reason: String, source: WrappSource = .disk)
    /// None of the places a free game's bundle names had its file, or
    /// none answered (each is in the log and reported).
    case downloadUnavailable(title: String)
    /// What the game runs in (Wine, ScummVM) couldn't be fetched from any
    /// of the places its module names (each is in the log).
    case engineUnavailable
    case gameExecutableNotFound
    case userCancelled
    case userCancelledBeforeStart
    case diskNotFound
    case autoItNotAvailable
    case autoItScriptNotFound
    /// A headless run left out a setting it needs (an environment variable).
    case missingRequiredParameter(String)
    case invalidPath(String)
    /// Something that shouldn't happen, or an error of a kind with no plain
    /// explanation: `detail` is for the log only.
    case internalError(String)
    /// The installer exited cleanly but its own record of finishing is
    /// missing (`InstallCompletion`), so the install was cut short.
    case installIncomplete(reason: String)
    /// An unattended install stopped showing any sign of progress, in a
    /// build that can't hand the person the installer's wizard instead
    /// (`InstallStallWatch`).
    case installStalled
    /// The finished wrapp couldn't be moved to where it was meant to go.
    case saveFailed(destination: String, reason: String)
    /// The disc is a different game from the one asked for (game slugs).
    case wrongGame(expected: String, detected: String)
    /// A Her Interactive Mac download Second Chance can't take the game
    /// from: not a Cider installer, or one that isn't laid out as expected.
    case unsupportedMacDownload(reason: String)
    /// This Mac can't run Wine because Rosetta isn't installed, in a build
    /// with nobody to offer it to (`WrappBuildInput.ensureRosetta`).
    case rosettaMissing
    /// The person agreed to install Rosetta, but it didn't install.
    case rosettaInstallFailed
    /// A disc image that wouldn't mount, and why (`ISOMounter.diagnoseImage`).
    case discImage(DiscImageError)
    /// The Mac ran out of space, or would have: `needed` and `available`
    /// in bytes when the build checked beforehand (`FreeSpace`).
    case notEnoughSpace(needed: Int64?, available: Int64?)
    /// Part of Second Chance itself, the game app template, is missing or
    /// damaged: `detail` says what, for the log.
    case templateDamaged(String)
    /// Files in the template have lost the code signatures they keep in
    /// extended attributes (`verifyTemplateSignatures`).
    case templateSignaturesLost(String)
    /// Copying files into the game's app failed; `detail` holds the command
    /// and its output, for the log.
    case copyFailed(String)
    /// Signing the finished app failed, with codesign's output.
    case signingFailed(String)
    /// A cached build (a developer aid) is of a different game.
    case cachedGameMismatch

    /// `error` as a build error: itself if it is one, or what it means.
    init(_ error: Error) {
        switch error {
        case let buildError as WrappBuildError:
            self = buildError
        case is CancellationError:
            self = .userCancelled
        case let discImage as DiscImageError:
            self = .discImage(discImage)
        default:
            self = ErrorChain.isOutOfSpace(error)
                ? .notEnoughSpace(needed: nil, available: nil)
                : .internalError(ErrorChain.describe(error))
        }
    }

    private static var tryAgain: String {
        String(localized: "Something went wrong while installing the game. Try again, and if it happens again, the failure report helps get it fixed.")
    }
    private static var damaged: String {
        String(localized: "Part of Second Chance is damaged. Download Second Chance again and try once more.")
    }

    /// What the error screen says: plain words, nothing technical.
    var playerMessage: String {
        switch self {
        case .internalError, .missingRequiredParameter, .copyFailed, .signingFailed, .cachedGameMismatch:
            return Self.tryAgain
        case .invalidPath:
            return String(localized: "Second Chance can't install the game from that. Choose the game's disc, or the file you downloaded from Her Interactive.")
        case .installIncomplete:
            return String(localized: "The game didn't install completely. Try again.")
        case .steamInstallFailed:
            return String(localized: "Steam couldn't install the game. Try again.")
        case .bigFishSignInRequired:
            return Self.tryAgain
        case .unsupportedMacDownload:
            return String(localized: """
                Second Chance can't use this Mac download. It may not have finished downloading: download it again, \
                or download the Windows version from Her Interactive instead.
                """)
        case .saveFailed(let destination, _):
            let folder = URL(fileURLWithPath: destination).deletingLastPathComponent().lastPathComponent
            return String(localized: "Couldn't save the game's app in \(folder). Try again, and choose another folder, such as Applications.")
        case .wrongGame(let expected, let detected):
            let provider = GameInfoProvider.shared
            let disc = provider.gameInfo(for: detected).title, wanted = provider.gameInfo(for: expected).title
            return String(localized: "This disc is \(disc), not \(wanted).")
        case .templateDamaged, .templateSignaturesLost:
            return Self.damaged
        default:
            return errorDescription ?? Self.tryAgain
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedEngine:
            return String(localized: "Second Chance doesn't know how to run this game yet.")
        case .buildRecipeProblem:
            return String(localized: "Second Chance's instructions for building this game have a problem. Updating Second Chance may fix it.")
        case .steamGameNotOwned(let title):
            return String(localized: "Your Steam account doesn't own \(title)")
        case .steamNoGamesOwned:
            return String(localized: "Your Steam account doesn't own any of the Nancy Drew games on Steam")
        case .steamSignInRequired:
            // Only a headless build (sc) says this, so it needn't be plain.
            return "Steam needs you to sign in, which a headless build can't do. Build once from the app to sign in."
        case .steamSignInTimedOut:
            return String(localized: "Steam waited for you to sign in, but nobody did. Try again when you're ready, and sign in when Steam's window appears.")
        case .steamStoppedResponding:
            return String(localized: """
                Steam kept getting stuck while it was signing in. Check that this Mac is connected to the internet.

                Trying again signs you out of Steam to start afresh: you'll need to sign in once more, \
                and your other Nancy Drew games from Steam will ask you to sign in again once too.
                """)
        case .steamExited:
            return String(localized: "Steam closed unexpectedly while it was starting up. Try again.")
        case .steamExitedWhileInstalling:
            return String(localized: "Steam closed unexpectedly while it was downloading the game. Try again.")
        case .steamDownloadStalled:
            return String(localized: "Steam stopped downloading the game. Check that this Mac is connected to the internet, then try again.")
        case .steamInstallFailed(let reason):
            return "Steam couldn't install the game: \(reason)"
        case .steamInUse(let holder):
            if holder.isBuild {
                return String(localized: "Second Chance is already adding a game from Steam, and only one game can use Steam at a time. Wait for it to finish and try again.")
            }
            guard let name = holder.name.map(SteamLockHolder.quoted) else {
                return String(localized: "Another game is using Steam, and only one game can use it at a time. Quit it and try again.")
            }
            return String(localized: "\(name) is using Steam, and only one game can use it at a time. Save your game in \(name) and quit it, then click Try Again.")
        case .bigFishGameManagerInstallFailed:
            return String(localized: """
                Big Fish's Game Manager, which downloads the game, couldn't be set up. \
                Check that this Mac is connected to the internet, then try again.
                """)
        case .bigFishSignInRequired:
            // Only a headless build (sc) says this, so it needn't be plain.
            return "Big Fish's Game Manager needs you to sign in, which a headless build can't do. "
                + "Build from the app, or set BIG_FISH_TEST_SIGN_IN=1 with BIG_FISH_EMAIL and BIG_FISH_PASSWORD."
        case .bigFishSignInTimedOut:
            return String(localized: """
                Big Fish's Game Manager waited for you to sign in, but nobody did. \
                Try again when you're ready, and sign in when its window appears.
                """)
        case .bigFishGameManagerQuit:
            return String(localized: "Big Fish's Game Manager closed unexpectedly. Try again.")
        case .bigFishNoGamesOwned:
            return String(localized: "Your Big Fish Games account doesn't have any of the Nancy Drew games that Second Chance can install.")
        case .bigFishGameNotOwned(let title):
            return String(localized: "Your Big Fish Games account doesn't have \(title).")
        case .bigFishDownloadFailed:
            return String(localized: """
                Big Fish's Game Manager couldn't download the game. \
                Check that this Mac is connected to the internet, then try again.
                """)
        case .bigFishInstallFailed:
            return String(localized: "Big Fish's Game Manager couldn't install the game. Try again.")
        case .bigFishActivationFailed:
            return String(localized: """
                Big Fish's Game Manager installed the game, but couldn't unlock it to play on this Mac. \
                Check that this Mac is connected to the internet, then try again.
                """)
        case .installerNotFound:
            return String(localized: "Couldn't find the game's installer. Check that it's the first disc of a Nancy Drew game, or the file you downloaded from Her Interactive.")
        case .installedGameNotInstaller:
            return String(localized: """
                This is a game that's already installed, not its installer. Second Chance needs to install the game itself: \
                choose the game's disc, or the installer you downloaded from Her Interactive.
                """)
        case .updateNeedsSource(_, .disk):
            return String(localized: """
                This game's app can't be brought up to date without the game's disc. \
                Choose the game's first disc instead, and Second Chance will make the app again.
                """)
        case .updateNeedsSource(_, .herDownload):
            return String(localized: """
                This game's app can't be brought up to date by itself. Choose the file you downloaded \
                from Her Interactive instead, and Second Chance will make the app again.
                """)
        case .updateNeedsSource(_, .download):
            return String(localized: """
                This game's app can't be brought up to date by itself. Download the game again, \
                and Second Chance will make the app again.
                """)
        case .updateNeedsSource(_, .steam):
            return String(localized: """
                This game's app can't be brought up to date by itself. Add the game from Steam again, \
                and Second Chance will make the app again.
                """)
        case .updateNeedsSource(_, .bigFish):
            return String(localized: """
                This game's app can't be brought up to date by itself. Add the game from Big Fish Games again, \
                and Second Chance will make the app again.
                """)
        case .downloadUnavailable(let title):
            return String(localized: """
                \(title) can't be downloaded right now. The places that had it don't have it any more, \
                or aren't answering. Try again later.
                """)
        case .engineUnavailable:
            return String(localized: """
                Second Chance couldn't download what the game needs to run. Check that you're connected \
                to the internet, then try again.
                """)
        case .gameExecutableNotFound:
            return String(localized: "The installer finished, but the game wasn't installed. Try again, and if the installer asks you questions, choose the options it suggests.")
        case .userCancelled:
            return String(localized: "You cancelled installing the game.")
        case .userCancelledBeforeStart:
            return String(localized: "You cancelled before installing started.")
        case .diskNotFound:
            return String(localized: "Couldn't find the files copied from the game disc. Try again.")
        case .autoItNotAvailable, .autoItScriptNotFound:
            return String(localized: "Part of Second Chance is missing. Download Second Chance again and try once more.")
        case .missingRequiredParameter(let param):
            return "Missing required parameter: \(param)"
        case .invalidPath(let message):
            return "Second Chance can't install from that: \(message)"
        case .internalError(let detail):
            return detail
        case .saveFailed(let destination, let reason):
            return "Couldn't save the game's app to \(destination): \(reason)"
        case .wrongGame(let expected, let detected):
            return "This disc is \(detected), not \(expected)"
        case .installIncomplete(let reason):
            return "The game didn't install completely: \(reason)"
        case .installStalled:
            return String(localized: "The game's installer stopped responding, so installing was stopped. Try again.")
        case .unsupportedMacDownload(let reason):
            return "Second Chance can't use this Mac download: \(reason). Download the Windows version from Her Interactive instead."
        case .rosettaMissing:
            return String(localized: "This Mac doesn't have Rosetta, which the games need. Install it with: softwareupdate --install-rosetta --agree-to-license")
        case .rosettaInstallFailed:
            return String(localized: "Rosetta, which the games need, couldn't be installed. Check that your Mac is connected to the internet, then try again.")
        case .discImage(let error):
            return error.errorDescription
        case .notEnoughSpace(let needed, let available):
            guard let needed, let available else {
                return String(localized: "Your Mac ran out of space while installing the game. Free up some space, then try again.")
            }
            let neededText = FreeSpace.describe(needed), availableText = FreeSpace.describe(available)
            return String(localized: """
                There isn't enough free space on your Mac to install the game. It needs about \(neededText), \
                and \(availableText) is free. Free up some space, then try again.
                """)
        case .templateDamaged(let detail):
            return "Part of Second Chance (the game app template) is damaged: \(detail)"
        case .templateSignaturesLost:
            return "Second Chance's copy of the game template is damaged: some of its files have lost their code signatures, "
                + "so no game could be signed. This happens when Second Chance is copied with a tool that leaves out "
                + "extended attributes. Download Second Chance again, or copy it with Finder."
        case .copyFailed(let detail):
            return "Copying files into the game's app failed: \(detail)"
        case .signingFailed(let output):
            return "Code signing failed: \(output)"
        case .cachedGameMismatch:
            return "Cached wrapp belongs to a different game"
        }
    }

    var isIncompleteInstall: Bool {
        if case .installIncomplete = self { return true }
        return false
    }
}
