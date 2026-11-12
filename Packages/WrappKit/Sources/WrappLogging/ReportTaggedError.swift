//
//  ReportTaggedError.swift
//  WrappLogging
//

/// An error that can say more about itself in a failure report than its
/// type and case: tags whose values are fixed words, never a path or a
/// message, so a basic report can carry them (a file was in the way, which
/// step failed). A host that reports failures adds them to the report's
/// tags, as Second Chance's `FailureReport` does. The keys are the error's
/// to choose; keep them few and stable, as a dashboard searches by them.
nonisolated public protocol ReportTaggedError: Error {
    var reportTags: [String: String] { get }
}
