//
//  FailureReportCallout.swift
//  Shared
//
//  Under an error: what became of its failure report (sent, or the choice
//  of what to send when reports are set to ask), the first-failure question
//  of how detailed reports should be, a comment to add, and a GitHub issue
//  filled in with what the report says.

import SwiftUI

struct FailureReportCallout: View {
    @ObservedObject var model: FailureReportModel
    @State private var isCommenting = false
    @State private var comment = ""
    @State private var email = ""

    var body: some View {
        VStack(spacing: 10) {
            reportStatus

            if model.asksAboutDetail {
                Divider()
                detailQuestion
            }

            if isCommenting {
                commentForm
            }

            VStack(spacing: 4) {
                if let url = model.issueURL {
                    Link("Open an issue on GitHub →", destination: url)
                        .font(.callout)
                }
                Text("Attach the saved log file to help diagnose the problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("failure-report")
    }

    @ViewBuilder
    private var reportStatus: some View {
        switch model.outcome {
        case nil where model.report != nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending a failure report…")
                    .font(.callout)
            }
        case .sent(_, let detail):
            VStack(spacing: 4) {
                Label("A \(detail.rawValue) failure report was sent", systemImage: "checkmark.circle")
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isCommenting {
                    Button("Add a Comment…") { isCommenting = true }
                        .controlSize(.small)
                }
            }
        case .awaitingChoice:
            VStack(spacing: 6) {
                Text("Send a report about this, so it can be fixed?")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(Self.levelExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Don't Send") { model.send(nil) }
                    Button("Send Basic") { model.send(.basic) }
                    Button("Send Detailed") { model.send(.detailed) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        case .declined:
            Text("No failure report was sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .disabled, nil:
            Text("Believe this is a bug in Second Chance?")
                .font(.callout)
                .fontWeight(.medium)
        }
    }

    private var detailQuestion: some View {
        VStack(spacing: 6) {
            Text("Send detailed reports from now on?")
                .font(.callout)
                .fontWeight(.medium)
            Text("This report only said which game and what failed. \(Self.levelExplanation) You can change this later in Second Chance's Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Ask Each Time") { model.choose(.manual) }
                Button("Keep Basic") { model.choose(.basic) }
                Button("Send Detailed") { model.choose(.detailed) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .accessibilityIdentifier("failure-report-detail-question")
    }

    private var commentForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What were you doing when it went wrong?")
                .font(.caption)
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

    /// What a basic and a detailed report each say, in a sentence.
    static let levelExplanation = "A basic report says which game and what failed. A detailed one adds the log and diagnostics, with your name and folders taken out."
}
