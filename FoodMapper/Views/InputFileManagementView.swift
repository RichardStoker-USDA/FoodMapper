import SwiftUI
import UniformTypeIdentifiers

/// Full-page input file management view shown when "Input Files" is selected in the sidebar.
struct InputFileManagementView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredFile: UUID?
    @State private var fileToDelete: StoredInputFile?
    @State private var renamingFile: StoredInputFile?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("Input Files")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    addFile()
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.title)
                        .symbolRenderingMode(.multicolor)
                        .fontWeight(.light)
                }
                .buttonStyle(HeaderIconButtonStyle())
                .help("Add an input file")
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)

            Divider()

            // File list
            if appState.storedInputFiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.storedInputFiles) { file in
                            InputFileRow(
                                file: file,
                                isHovered: hoveredFile == file.id
                            )
                            .onHover { hoveredFile = $0 ? file.id : nil }
                            .contextMenu {
                                Button {
                                    loadFileForMatching(file)
                                } label: {
                                    Label("Use for Matching", systemImage: "play")
                                }

                                Button {
                                    renameText = file.displayName
                                    renamingFile = file
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.csvURL])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }

                                Button {
                                    NSWorkspace.shared.open(file.csvURL)
                                } label: {
                                    Label("Open in Default App", systemImage: "arrow.up.forward.app")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    fileToDelete = file
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .onTapGesture {
                                loadFileForMatching(file)
                            }

                            if file.id != appState.storedInputFiles.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.sm)
                }
            }
        }
        .alert("Rename File", isPresented: Binding(
            get: { renamingFile != nil },
            set: { if !$0 { renamingFile = nil } }
        )) {
            TextField("File name", text: $renameText)
            Button("Rename") {
                if let file = renamingFile, !renameText.isEmpty {
                    appState.renameStoredInputFile(file.id, to: renameText)
                }
                renamingFile = nil
            }
            Button("Cancel", role: .cancel) {
                renamingFile = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addInputFile)) { _ in
            addFile()
        }
        .confirmationDialog(
            "Remove File?",
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { file in
            Button("Remove", role: .destructive) {
                appState.removeStoredInputFile(file.id)
                fileToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
        } message: { file in
            Text("Remove \"\(file.displayName)\"? The stored copy will be deleted.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: Size.iconHero))
                .foregroundStyle(.tertiary)

            Text("No stored files")
                .font(.headline)

            Text("Files you load for matching are stored here for easy reuse. Click Add File or start a New Match to add one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                addFile()
            } label: {
                Label("Add File", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, Spacing.sm)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let file = try await CSVParser.parse(url: url)
                    appState.storeInputFile(file)
                } catch {
                    appState.error = AppError.fileLoadFailed(error.localizedDescription)
                }
            }
        }
    }

    private func loadFileForMatching(_ stored: StoredInputFile) {
        Task { @MainActor in
            do {
                var file = try await CSVParser.parse(url: stored.csvURL)
                file.displayNameOverride = stored.displayName
                appState.inputFile = file
                appState.handleFileLoaded(file)
                appState.touchStoredInputFile(stored.id)
                appState.sidebarSelection = .home
                appState.showMatchSetup = true
            } catch {
                appState.error = AppError.fileLoadFailed(error.localizedDescription)
            }
        }
    }
}

/// Row for a stored input file
struct InputFileRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let file: StoredInputFile
    let isHovered: Bool

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
    }

    private var dateText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: file.lastUsed, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "doc.text")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(file.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: Spacing.sm) {
                    Text("\(file.rowCount.formatted()) rows, \(file.columnNames.count) columns")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(fileSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.cardBorder(for: colorScheme) : Color.clear)
                .padding(.horizontal, Spacing.sm)
        )
        .animation(Animate.quick, value: isHovered)
    }
}

#Preview("Input Files - With Files") {
    InputFileManagementView()
        .environmentObject(PreviewHelpers.inputFilesState())
        .frame(width: 800, height: 550)
}

#Preview("Input Files - Dark") {
    InputFileManagementView()
        .environmentObject(PreviewHelpers.inputFilesState())
        .frame(width: 800, height: 550)
        .preferredColorScheme(.dark)
}

#Preview("Input Files - Empty") {
    let state = PreviewHelpers.inputFilesState()
    state.storedInputFiles = []
    return InputFileManagementView()
        .environmentObject(state)
        .frame(width: 800, height: 550)
}
