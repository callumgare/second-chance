//
//  FailureReportCallout.swift
//  Shared
//
//  Under an error: what became of its failure report — the first failure's
//  question of how detailed to send it, the choice of what to send when
//  reports are set to ask, or that it was sent — and a comment to add. When
//  reports are off in this build it shows nothing.

import SwiftUI

struct FailureReportCallout: View {
    @ObservedObject var model: FailureReportModel
    @State private var isCommenting = false
    @State private var comment = ""
    @State private var email = ""

    var body: some View {
        if model.report != nil, model.outcome != .disabled {
            callout
        }
    }

    private var callout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Not beside the spinner while it is sending: one symbol at a time.
            if model.outcome != nil {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 10) {
                reportStatus

                if isCommenting {
                    commentForm
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityIdentifier("failure-report")
    }

    @ViewBuilder
    private var reportStatus: some View {
        switch model.outcome {
        case nil where model.report != nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.sendingBeforeQuit ? "Sending a basic failure report before quitting…" : "Sending a failure report…")
                    .font(.callout)
            }
        case .sent(_, let detail):
            VStack(alignment: .leading, spacing: 4) {
                Text("A \(detail.rawValue) failure report was sent.")
                    .font(.callout)
                    .fontWeight(.medium)
                if let id = model.outcome?.shortID {
                    Text("Report \(id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if model.commentSent {
                    Text("Thanks — your comment was sent with it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !isCommenting {
                    HStack {
                        Spacer()
                        Button("Add a Comment…") { isCommenting = true }
                            .controlSize(.small)
                    }
                }
            }
        case .askingHowDetailed:
            detailQuestion
        case .awaitingChoice:
            VStack(alignment: .leading, spacing: 6) {
                Text("Send a report about this, so it can be fixed?")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(Self.levelExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    // None filled: the screen's own way on is its default.
                    Button("Don't Send") { model.send(nil) }
                    Button("Send Basic Report") { model.send(.basic) }
                    Button("Send Detailed Report") { model.send(.detailed) }
                }
                .controlSize(.small)
            }
        case .declined:
            Text("No failure report was sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .disabled, nil:
            EmptyView()
        }
    }

    /// The first failure: how detailed a report to send. The error screen's
    /// way out stays hidden until it is answered (`HiddenUntilReportAnswered`).
    private var detailQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How much should the failure report include?")
                .font(.callout)
                .fontWeight(.medium)
            Text(Self.detailedIsWhatHelps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Later reports are sent the same way. You can change that in Second Chance's Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Send Basic Report") { model.choose(.basic) }
                // The default while the question holds the screen's way out back.
                Button("Send Detailed Report") { model.choose(.detailed) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .accessibilityIdentifier("failure-report-detail-question")
    }

    private var commentForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What were you doing when it went wrong?")
                .font(.callout)
            TextEditor(text: $comment)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            TextField("Email, if you'd like a reply (optional)", text: $email)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { isCommenting = false }
                Button("Send Comment") {
                    model.sendComment(comment, email: email)
                    isCommenting = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    /// The first-failure question's case for a detailed report.
    static let detailedIsWhatHelps = "A report about this is sent to the developer so it can be fixed. "
        + "A detailed one includes the log of what was happening, which is usually what it takes to track the problem down and fix it. "
        + "Your name and folders are taken out. A basic one says only which game it was and what failed."

    /// What a basic and a detailed report each say, in a sentence.
    static let levelExplanation = "A basic report says which game and what failed. A detailed one adds the log and diagnostics, with your name and folders taken out."
}

/// An error screen's way out — Quit, Start Over — kept back while the
/// failure's report is asking how detailed to send it, so the question is
/// answered rather than skipped. Leaving anyway (Cmd-Q) sends it basic.
struct HiddenUntilReportAnswered<Content: View>: View {
    @ObservedObject var model: FailureReportModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        if !model.holdsBackWayOut {
            content()
        }
    }
}
