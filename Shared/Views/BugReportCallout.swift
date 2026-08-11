//
//  BugReportCallout.swift
//  Shared
//
//  Reusable callout prompting users to file a GitHub issue with logs attached.

import SwiftUI

public struct BugReportCallout: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Text("Believe this is a bug in Second Chance?")
                .font(.callout)
                .fontWeight(.medium)
            Link(
                "Open an issue on GitHub →",
                destination: URL(string: "https://github.com/callumgare/second-chance/issues/new")!
            )
            .font(.callout)
            Text("Attach the saved log file to help diagnose the problem.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
