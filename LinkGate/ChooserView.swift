import AppKit
import SwiftUI

struct ChooserView: View {
    @ObservedObject var coordinator: SelectionCoordinator

    @FocusState private var focusedCandidateID: URL?

    private let iconSize: CGFloat = 64
    private let gridColumnCount = 3
    private let gridSpacing: CGFloat = 12
    private let candidateCellHeight: CGFloat = 120

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle:
                EmptyView()
            case let .discovering(url):
                progressView(for: url)
            case let .choosing(context):
                choosingView(context)
                    .id(context.presentationID)
            case .openingDirectly:
                EmptyView()
            case let .noCandidates(url):
                noCandidatesView(for: url)
            }
        }
        .frame(width: 480)
    }

    private func progressView(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            urlContext(for: url)
            ProgressView("Finding applications…")
            Button("Cancel", action: coordinator.cancelActiveURL)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .onExitCommand(perform: coordinator.cancelActiveURL)
    }

    private func choosingView(_ context: SelectionCoordinator.SelectionContext) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            urlContext(for: context.url)

            if let errorMessage = context.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if context.isOpening {
                ProgressView("Opening link…")
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(minimum: 112), spacing: gridSpacing),
                            count: gridColumnCount
                        ),
                        spacing: gridSpacing
                    ) {
                        ForEach(Array(context.candidates.enumerated()), id: \.element.id) { index, candidate in
                            candidateButton(
                                candidate,
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                isOpening: context.isOpening
                            )
                            .id(candidate.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 280)
                .onChange(of: focusedCandidateID) { _, candidateID in
                    guard let candidateID else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo(candidateID, anchor: .center)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: coordinator.cancelActiveURL)
                    .keyboardShortcut(.cancelAction)
                    .disabled(context.isOpening)
            }
        }
        .padding(24)
        .onAppear {
            resetFocus(for: context.candidates)
        }
        .onChange(of: context.presentationID) { _, _ in
            resetFocus(for: context.candidates)
        }
        .onChange(of: context.candidates.map(\.id)) { _, candidateIDs in
            ensureValidFocus(in: candidateIDs)
        }
        .onChange(of: context.isOpening) { _, isOpening in
            if !isOpening {
                ensureValidFocus(in: context.candidates.map(\.id))
            }
        }
        .onMoveCommand { direction in
            guard !context.isOpening else {
                return
            }
            moveFocus(direction, among: context.candidates)
        }
        .onKeyPress(.return) {
            activateFocusedCandidate(in: context)
        }
        .onKeyPress(KeyEquivalent("\u{3}")) {
            activateFocusedCandidate(in: context)
        }
        .onExitCommand {
            guard !context.isOpening else {
                return
            }
            coordinator.cancelActiveURL()
        }
    }

    @ViewBuilder
    private func candidateButton(
        _ candidate: ApplicationCandidate,
        shortcutNumber: Int?,
        isOpening: Bool
    ) -> some View {
        let isFocused = focusedCandidateID == candidate.id

        let button = Button {
            coordinator.select(candidate)
        } label: {
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    Spacer()
                    if let shortcutNumber {
                        Text("\(shortcutNumber)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 14)

                Image(nsImage: candidate.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)

                Text(candidate.displayName)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: candidateCellHeight)
            .padding(8)
            .background(isFocused ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isFocused ? 3 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .focusable()
        .focused($focusedCandidateID, equals: candidate.id)
        .accessibilityLabel(candidate.displayName)
        .accessibilityHint(shortcutNumber.map { "Shortcut \($0)" } ?? "")

        if let shortcutNumber {
            button.keyboardShortcut(KeyEquivalent(Character("\(shortcutNumber)")), modifiers: [])
        } else {
            button
        }
    }

    private func noCandidatesView(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            urlContext(for: url)
            Text("No applications are available to open this link.")
            Text("Install or enable a web browser in Settings, then try this link again.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close", action: coordinator.cancelActiveURL)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .onExitCommand(perform: coordinator.cancelActiveURL)
    }

    private func urlContext(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.host(percentEncoded: false) ?? url.host ?? "Web link")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(url.absoluteString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func activateFocusedCandidate(in context: SelectionCoordinator.SelectionContext) -> KeyPress.Result {
        guard !context.isOpening,
              let focusedCandidateID,
              let candidate = context.candidates.first(where: { $0.id == focusedCandidateID })
        else {
            return .ignored
        }

        coordinator.select(candidate)
        return .handled
    }

    private func moveFocus(_ direction: MoveCommandDirection, among candidates: [ApplicationCandidate]) {
        guard !candidates.isEmpty else {
            return
        }

        let currentIndex = candidates.firstIndex(where: { $0.id == focusedCandidateID }) ?? 0
        let destinationIndex: Int

        switch direction {
        case .left:
            destinationIndex = max(0, currentIndex - 1)
        case .right:
            destinationIndex = min(candidates.count - 1, currentIndex + 1)
        case .up:
            destinationIndex = max(0, currentIndex - gridColumnCount)
        case .down:
            destinationIndex = min(candidates.count - 1, currentIndex + gridColumnCount)
        default:
            return
        }

        focusedCandidateID = candidates[destinationIndex].id
    }

    private func resetFocus(for candidates: [ApplicationCandidate]) {
        focusedCandidateID = candidates.first?.id
    }

    private func ensureValidFocus(in candidateIDs: [URL]) {
        if let focusedCandidateID, candidateIDs.contains(focusedCandidateID) {
            return
        }
        focusedCandidateID = candidateIDs.first
    }
}
