import SwiftUI

/// Finder-style "Get Info" sheet for custom databases
struct DatabaseInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let database: CustomDatabase
    var modelManager: ModelManager?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.md) {
                Image(systemName: "cylinder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(database.displayName)
                        .font(.headline)
                    Text("Custom Database")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(Spacing.lg)
            .background(.bar)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // General section
                    infoSection(title: "General") {
                        infoRow("Source File", value: database.csvPath)
                        infoRow("Date Added", value: formatDate(database.dateAdded))
                        infoRow("Items", value: database.itemCount.formatted())
                    }

                    // Embeddings section
                    infoSection(title: "Embeddings") {
                        let modelKeys = database.embeddedModelKeys
                        if modelKeys.isEmpty {
                            infoRow("Status", value: "Not embedded")
                        } else {
                            infoRow("Status", value: "\(modelKeys.count) model\(modelKeys.count == 1 ? "" : "s") embedded")
                            ForEach(modelKeys, id: \.self) { key in
                                HStack(alignment: .top) {
                                    Text(displayName(for: key))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 140, alignment: .leading)
                                    Text(formatBytes(database.cacheSize(for: key)))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.callout)
                            }
                        }
                        infoRow("Total Cache", value: formatBytes(database.totalCacheSize > 0 ? database.totalCacheSize : nil))
                    }

                    // Columns section
                    infoSection(title: "Columns") {
                        infoRow("Text Column", value: database.textColumn)
                        infoRow("ID Column", value: database.idColumn ?? "None")
                    }
                }
                .padding(Spacing.lg)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.lg)
        }
        .frame(width: 420, height: 500)
    }

    private func displayName(for modelKey: String) -> String {
        modelManager?.registeredModel(for: modelKey)?.displayName ?? modelKey
    }

    // MARK: - Components

    @ViewBuilder
    private func infoSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(spacing: Spacing.xs) {
                content()
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    // MARK: - Formatters

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "-" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration = duration else { return "-" }
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f seconds", duration)
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(duration / 3600)
            let minutes = Int(duration.truncatingRemainder(dividingBy: 3600) / 60)
            if minutes == 0 {
                return "\(hours)h 0m"
            }
            return "\(hours)h \(minutes)m"
        }
    }
}

#Preview("Database Info - Light") {
    DatabaseInfoSheet(database: PreviewHelpers.sampleCustomDB)
}

#Preview("Database Info - Dark") {
    DatabaseInfoSheet(database: PreviewHelpers.sampleCustomDB)
        .preferredColorScheme(.dark)
}
