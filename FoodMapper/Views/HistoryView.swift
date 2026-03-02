import SwiftUI

/// History view showing past sessions -- displayed when "History" is selected in sidebar
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredSession: MatchingSession.ID?
    @State private var showingClearConfirmation = false
    @State private var showingExportOptions = false
    @State private var sessionToDelete: MatchingSession?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("Session History")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !appState.sessions.isEmpty {
                    HStack(spacing: Spacing.md) {
                        Button {
                            showingExportOptions = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title)
                                .fontWeight(.light)
                                .foregroundStyle(Color(nsColor: .controlAccentColor))
                        }
                        .buttonStyle(HeaderIconButtonStyle())
                        .help("Export all sessions")

                        Button {
                            showingClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.title)
                                .fontWeight(.light)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(HeaderIconButtonStyle())
                        .help("Clear all history")
                    }
                }
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)

            Divider()

            // Content
            if appState.sessions.isEmpty {
                EmptyStateContent(
                    icon: "clock.arrow.circlepath",
                    title: "No History",
                    message: "Your matching sessions will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.sessions) { session in
                            SessionRow(
                                session: session,
                                isHovered: hoveredSession == session.id,
                                onSelect: { appState.loadSession(session) },
                                onExport: { appState.exportSession(session) }
                            )
                            .onHover { hoveredSession = $0 ? session.id : nil }
                            .contextMenu {
                                Button {
                                    appState.loadSession(session)
                                } label: {
                                    Label("Load Session", systemImage: "arrow.uturn.backward")
                                }

                                Button {
                                    appState.exportSession(session)
                                } label: {
                                    Label("Export...", systemImage: "doc.text")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    sessionToDelete = session
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            }

                            if session.id != appState.sessions.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.sm)
                }

                // Footer
                HStack {
                    Text("\(appState.sessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.sm)
            }
        }
        .confirmationDialog(
            "Export All Sessions",
            isPresented: $showingExportOptions,
            titleVisibility: .visible
        ) {
            Button("Export as Zip") {
                appState.exportAllSessions()
            }
            Button("Export to Folder") {
                appState.exportAllSessionsToFolder()
            }
            Button("Cancel", role: .cancel) {}
        }
        .tint(.accentColor)
        .confirmationDialog(
            "Clear All History?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Sessions", role: .destructive) {
                appState.clearAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all past matching sessions. Any results that were never exported will be lost.")
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            presenting: sessionToDelete
        ) { session in
            Button("Delete", role: .destructive) {
                appState.deleteSession(session)
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
        } message: { session in
            Text("Delete the session for \"\(session.inputFileName)\"? The results will be permanently removed.")
        }
    }
}

/// Row for a session in history
struct SessionRow: View {
    let session: MatchingSession
    let isHovered: Bool
    let onSelect: () -> Void
    let onExport: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.md) {
                // Icon
                Image(systemName: "doc.text")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                // Info
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(session.inputFileName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    HStack(spacing: Spacing.sm) {
                        // Database badge
                        Text(session.databaseName)
                            .font(.caption)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 2)
                            .lineLimit(1)
                            .polishedBadge(tone: .accentStrong, cornerRadius: 4)

                        Text("\(session.totalCount) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Pipeline badge
                        Text(session.pipelineName)
                            .font(.caption2)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 2)
                            .lineLimit(1)
                            .polishedBadge(tone: .neutral, cornerRadius: 4)

                        Text(session.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Match rate + threshold
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.matchRate, format: .percent.precision(.fractionLength(0)))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.scoreColor(session.matchRate))

                    HStack(spacing: Spacing.xxs) {
                        Text("\(session.matchedCount) matched")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("@ \(session.threshold, format: .percent.precision(.fractionLength(0)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Export on hover
                if isHovered {
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.down")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export session results")
                } else {
                    Color.clear
                        .frame(width: 20)
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.3))
                    .padding(.horizontal, Spacing.sm)
            }
        }
    }
}

#Preview("History - With Sessions") {
    HistoryView()
        .environmentObject(PreviewHelpers.historyState())
        .frame(width: 800, height: 550)
}

#Preview("History - Dark") {
    HistoryView()
        .environmentObject(PreviewHelpers.historyState())
        .frame(width: 800, height: 550)
        .preferredColorScheme(.dark)
}

#Preview("History - Empty") {
    let state = PreviewHelpers.historyState()
    state.sessions = []
    return HistoryView()
        .environmentObject(state)
        .frame(width: 800, height: 550)
}
