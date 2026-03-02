import SwiftUI
import UniformTypeIdentifiers

/// Row for selecting input CSV file
struct FilePickerRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var file: InputFile?
    var onFileLoaded: ((InputFile) -> Void)?
    var onFileError: ((String) -> Void)?
    @State private var isDropTargeted = false
    @State private var isLoading = false

    private var borderColor: Color {
        if isDropTargeted {
            return Color.accentColor
        }
        return colorScheme == .dark
            ? Color.secondary.opacity(0.3)
            : Color.secondary.opacity(0.5)
    }

    private var backgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.05)
        }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let file = file {
                // File loaded state
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "doc")
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text("\(file.rowCount) rows, \(file.columns.count) columns")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        self.file = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Drop target state
                VStack(spacing: Spacing.sm) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 24))
                            .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                    }

                    Text(isLoading ? "Loading..." : "Drop file or click to select")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                )
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            borderColor,
                            style: StrokeStyle(lineWidth: 2, dash: [6, 3])
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isLoading else { return }
                    openFilePicker()
                }
                .onDrop(of: [.fileURL], delegate: CSVDropDelegate(
                    isTargeted: $isDropTargeted,
                    onDrop: loadFile
                ))
                .help("Drop a CSV or TSV file or click to browse")
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadFile(from: url)
        }
    }

    private func loadFile(from url: URL) {
        isLoading = true
        Task { @MainActor in
            do {
                let loadedFile = try await CSVParser.parse(url: url)
                self.file = loadedFile
                onFileLoaded?(loadedFile)
                isLoading = false
            } catch {
                isLoading = false
                onFileError?(error.localizedDescription)
            }
        }
    }
}

#Preview("File Picker - Empty - Light") {
    FilePickerRow(file: .constant(nil))
        .padding()
        .frame(width: 280)
}

#Preview("File Picker - Empty - Dark") {
    FilePickerRow(file: .constant(nil))
        .padding()
        .frame(width: 280)
        .preferredColorScheme(.dark)
}

#Preview("File Picker - File Loaded") {
    FilePickerRow(file: .constant(PreviewHelpers.mockInputFile()))
        .padding()
        .frame(width: 280)
}
