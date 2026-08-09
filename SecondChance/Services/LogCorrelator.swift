//
//  LogCorrelator.swift
//  SecondChance
//
//  Renders typed bus events and ContextualLogger text entries into a single
//  structured log stream via print(). LogManager's stdout pipe tee handles
//  fan-out — the same output reaches both the console and the log window
//  without LogCorrelator needing to know which destinations are active.
//
//  Rendering rules:
//    - A new progress step emits a bold section header
//    - Lines under a step are indented one level
//    - Subprocess lines carry a source tag (e.g. "[wine]")
//    - Warning/error entries get a visual prefix (⚠️ / ❌)

import Foundation

actor LogCorrelator {

    private var currentStep: InstallationState?
    private var eventSubscriptionToken: EventBus<AppEvent>.Token?

    static let shared = LogCorrelator()

    init() {}

    // MARK: - Configuration

    func subscribe(to bus: EventBus<AppEvent>) async {
        eventSubscriptionToken = await bus.subscribe { [weak self] event in
            await self?.handleBusEvent(event)
        }
    }

    func unsubscribe(from bus: EventBus<AppEvent>) async {
        if let token = eventSubscriptionToken {
            await bus.unsubscribe(token)
            eventSubscriptionToken = nil
        }
    }

    // MARK: - Sink

    /// Wire this as the `sink` when constructing a `ContextualLogger`.
    nonisolated var sink: @Sendable (LogEntry) -> Void {
        { [weak self] entry in
            Task { await self?.render(entry: entry) }
        }
    }

    // MARK: - Private

    private func handleBusEvent(_ event: AppEvent) {
        if case .installation(let installEvent) = event,
           case .progress(let state) = installEvent,
           currentStep != state {
            currentStep = state
            emit(header(for: state))
        }
    }

    func render(entry: LogEntry) {
        if let entryStep = entry.step, entryStep != currentStep {
            currentStep = entryStep
            emit(header(for: entryStep))
        }

        let levelPrefix: String
        switch entry.level {
        case .warning: levelPrefix = "⚠️  "
        case .error:   levelPrefix = "❌ "
        case .info:    levelPrefix = ""
        }

        let sourceTag = entry.source.map { "[\($0)] " } ?? ""
        let indent = currentStep != nil ? "  " : ""
        emit("\(indent)\(sourceTag)\(levelPrefix)\(entry.message)")
    }

    private func header(for state: InstallationState) -> String {
        "\n\u{1b}[1m=== \(state.displayText) ===\u{1b}[0m"
    }

    private func emit(_ line: String) {
        print(line)
    }
}

// MARK: - ContextualLogger convenience

extension ContextualLogger {
    /// Create a logger whose entries flow through `LogCorrelator.shared`.
    static func forCorrelator(_ correlator: LogCorrelator) -> ContextualLogger {
        ContextualLogger(sink: correlator.sink)
    }
}
