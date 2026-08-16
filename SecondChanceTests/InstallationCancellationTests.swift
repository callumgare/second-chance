//
//  InstallationCancellationTests.swift
//  SecondChanceTests
//
//  Cancelling the initial disk-selection dialog is not an error from the
//  user's perspective — nothing has happened yet, so the app quietly returns
//  to the welcome screen. Cancelling a later prompt (disk 2, save location)
//  abandons work already done and must surface on the error screen.
//

import Testing
import Combine
@testable import SecondChance

@MainActor
@Suite("Installation cancellation routing")
struct InstallationCancellationTests {

    @Test("Cancelling the initial disk dialog returns to the welcome screen")
    func initialDialogCancelResetsToIdle() async {
        let viewModel = InstallationViewModel()

        await viewModel.handleBusEvent(.installation(.failed(.userCancelledBeforeStart)))

        #expect(viewModel.currentState == .idle)
    }

    @Test("Cancelling a later dialog (disk 2, save location) shows the error screen")
    func laterDialogCancelShowsError() async {
        let viewModel = InstallationViewModel()

        await viewModel.handleBusEvent(.installation(.failed(.userCancelled)))

        guard case .error(let message) = viewModel.currentState else {
            Issue.record("Expected error state after late cancellation, got \(viewModel.currentState)")
            return
        }
        #expect(message == "Installation cancelled by user")
    }

    @Test("Other failures still show the error screen")
    func internalFailureShowsError() async {
        let viewModel = InstallationViewModel()

        await viewModel.handleBusEvent(.installation(.failed(.internalError("boom"))))

        guard case .error(let message) = viewModel.currentState else {
            Issue.record("Expected error state after failure, got \(viewModel.currentState)")
            return
        }
        #expect(message == "boom")
    }

    @Test("The initial-dialog cancel is a distinct error from later cancels")
    func earlyCancelIsDistinctCase() {
        #expect(InstallationError.userCancelledBeforeStart != InstallationError.userCancelled)
    }

    @Test("No error-screen flash between the error-progress event and the failure event")
    func earlyCancelDoesNotFlashErrorScreen() async {
        let viewModel = InstallationViewModel()

        // Observe every state SwiftUI would render.
        var observed: [InstallationState] = []
        var cancellables = Set<AnyCancellable>()
        viewModel.$currentState.sink { observed.append($0) }.store(in: &cancellables)

        // Mirror the exact event order performInstallation's catch publishes on
        // cancellation: an error progress state followed by the typed failure.
        await viewModel.handleBusEvent(.installation(.progress(.error("Installation cancelled before it started"))))
        await viewModel.handleBusEvent(.installation(.failed(.userCancelledBeforeStart)))

        #expect(observed.allSatisfy { state in
            if case .error = state { return false }
            return true
        }, "Error state should never be rendered — observed: \(observed)")
        #expect(viewModel.currentState == .idle)
    }
}
