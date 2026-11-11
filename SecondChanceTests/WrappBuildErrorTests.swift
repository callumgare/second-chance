import Testing
import Foundation
@testable import SecondChance
import WrappBuilder

/// Every error a build can end with reaches the error screen as plain words.
@Suite("Build errors")
struct WrappBuildErrorTests {
    private struct Unexpected: Error {}

    @Test("Any error becomes a build error that says what it means")
    func mapping() {
        #expect(WrappBuildError(WrappBuildError.installStalled) == .installStalled)
        #expect(WrappBuildError(CancellationError()) == .userCancelled)
        #expect(WrappBuildError(DiscImageError.rawCDImage) == .discImage(.rawCDImage))
        #expect(WrappBuildError(CocoaError(.fileWriteOutOfSpace)) == .notEnoughSpace(needed: nil, available: nil))
        #expect(WrappBuildError(POSIXError(.ENOSPC)) == .notEnoughSpace(needed: nil, available: nil))
        guard case .internalError = WrappBuildError(Unexpected()) else {
            Issue.record("An unexpected error should be an internal one")
            return
        }
    }

    @Test("A step that failed isn't called a problem with the instructions; one the instructions can't do is")
    func stepFailures() {
        let failed = WrappBuildError(StepFailure.failed("Wrappfile:12: the installer exited 1"))
        #expect(failed == .stepFailed("Wrappfile:12: the installer exited 1"))
        #expect(WrappBuildError(stepFailure: .recipe("Wrappfile:3: no stage")) == .buildRecipeProblem("Wrappfile:3: no stage"))
        #expect(failed.playerMessage != WrappBuildError.buildRecipeProblem("x").playerMessage)
        #expect(failed.errorDescription?.contains("the installer exited 1") == true)
    }

    @Test("Out of space is found beneath the error it caused")
    func underlyingOutOfSpace() {
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])
        #expect(WrappBuildError(wrapped) == .notEnoughSpace(needed: nil, available: nil))
    }

    @Test("What the screen shows carries none of the technical detail", arguments: [
        WrappBuildError.internalError("cp: /private/var/folders/x: Operation not permitted"),
        .copyFailed("/bin/cp -a /a /b: No such file"),
        .signingFailed("errSecInternalComponent"),
        .installIncomplete(reason: "InstallShield wrote no setup.ilg uninstall log"),
        .steamInstallFailed(reason: "state 0x602"),
        .unsupportedMacDownload(reason: "tar exited 1"),
        .macInstallerFromDiscs,
        .templateDamaged("WrappTemplate.app not found"),
        .saveFailed(destination: "/Volumes/Games/Nancy Drew - X.app", reason: "NSCocoaErrorDomain 513"),
        .stepFailed("Wrappfile:19: the Mac's automation failed: automation failed at line 7"),
    ])
    func plainMessages(error: WrappBuildError) {
        let message = error.playerMessage
        for jargon in ["cp", "/private", "tar", "exit", "setup.ilg", "0x", "errSec", "WrappTemplate", "NSCocoa", "Wine", "wrapp"] {
            #expect(!message.contains(jargon), "\(error) shows \"\(jargon)\": \(message)")
        }
    }

    @Test("A disc that's the wrong game is named by its title")
    func wrongGameTitles() {
        let message = WrappBuildError.wrongGame(expected: "stay-tuned", detected: "scarlet-hand").playerMessage
        #expect(message.contains("Stay Tuned for Danger"))
        #expect(message.contains("Secret of the Scarlet Hand"))
    }

    @Test("Free space is described as Finder would")
    func describesSpace() {
        let message = WrappBuildError.notEnoughSpace(needed: 5_000_000_000, available: 1_000_000_000).playerMessage
        #expect(message.contains("5 GB"))
        #expect(message.contains("1 GB"))
    }
}
