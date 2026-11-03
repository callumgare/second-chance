//
//  BuildQuestionView.swift
//  SecondChance
//
//  A question the build asks part way through (`BuildQuestion`), as a page
//  of the main window in place of the build's progress.

import SwiftUI

struct BuildQuestionView: View {
    @Environment(WrappBuildViewModel.self) var viewModel
    let question: WrappBuildViewModel.BuildQuestion

    @State private var chosen: Int?

    var body: some View {
        InstallerPage(title: question.title) {
            Text(question.detail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let waiting = question.waiting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(waiting)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if question.choices.isEmpty {
                Spacer()
            } else {
                choices
            }
        } leading: {
            HStack {
                ForEach(actions(.other, .destructive), id: \.self) { button($0) }
            }
        } trailing: {
            HStack {
                ForEach(actions(.cancel, .primary), id: \.self) { button($0) }
            }
        }
        // A new question starts on its first choice, not the last one's.
        .onAppear { chosen = question.choices.isEmpty ? nil : 0 }
        .onChange(of: question.title) { chosen = question.choices.isEmpty ? nil : 0 }
        .accessibilityIdentifier("build-question")
    }

    /// Double-clicking a choice picks it, as the way on would.
    private var choices: some View {
        List(question.choices.indices, id: \.self, selection: $chosen) { index in
            let choice = question.choices[index]
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                if let detail = choice.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, choice.detail == nil ? 0 : 4)
        }
        .listStyle(.bordered)
        .contextMenu(forSelectionType: Int.self) { _ in
        } primaryAction: { selection in
            guard let index = selection.first,
                  let primary = question.actions.firstIndex(where: { $0.role == .primary }) else { return }
            viewModel.answerQuestion(.init(action: primary, choice: index))
        }
        .accessibilityLabel(question.choicesLabel)
    }

    /// The indices of the actions with these roles, in order.
    private func actions(_ roles: WrappBuildViewModel.BuildQuestion.Action.Role...) -> [Int] {
        question.actions.indices.filter { roles.contains(question.actions[$0].role) }
    }

    @ViewBuilder
    private func button(_ index: Int) -> some View {
        let action = question.actions[index]
        let answer = { viewModel.answerQuestion(.init(action: index, choice: chosen)) }
        switch action.role {
        case .primary:
            Button(action.title, action: answer)
                .keyboardShortcut(.defaultAction)
                // A list needs something picked to go on with.
                .disabled(!question.choices.isEmpty && chosen == nil)
        case .cancel:
            Button(action.title, action: answer)
                .keyboardShortcut(.cancelAction)
        case .destructive:
            // Red text marks it as losing work; `role: .destructive` alone
            // draws no colour on a macOS push button.
            Button(role: .destructive, action: answer) {
                Text(action.title).foregroundStyle(.red)
            }
        case .other:
            Button(action.title, action: answer)
        }
    }
}
