import SwiftUI

/// Full-page database management view shown when "Databases" is selected in the sidebar.
struct DatabaseManagementView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingAddDatabase = false
    @State private var showingDatabaseInfo: CustomDatabase?
    @State private var showingBuiltInAbout: BuiltInDatabase?
    @State private var databaseToDelete: CustomDatabase?
    @State private var hoveredDatabase: String?
    @State private var reembedTarget: CustomDatabase?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("Databases")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    showingAddDatabase = true
                } label: {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.title)
                        .symbolRenderingMode(.multicolor)
                        .fontWeight(.light)
                }
                .buttonStyle(HeaderIconButtonStyle())
                .help("Add a custom database")
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)

            Divider()

            // Database list
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Built-in section header
                    sectionHeader("Built-in")

                    ForEach(BuiltInDatabase.allCases) { db in
                        let builtInModelKeys = AnyDatabase.builtIn(db).embeddedModelKeys
                        DatabaseManagementRow(
                            name: db.displayName,
                            itemCount: db.itemCount,
                            description: db.description,
                            isCustom: false,
                            isHovered: hoveredDatabase == db.id,
                            embeddingStatus: builtInEmbeddingStatusText(for: builtInModelKeys),
                            embeddedModelKeys: builtInModelKeys,
                            registeredModels: appState.modelManager.registeredModels
                        )
                        .onHover { hoveredDatabase = $0 ? db.id : nil }
                        .contextMenu {
                            Button {
                                showingBuiltInAbout = db
                            } label: {
                                Label("About \(db.displayName)", systemImage: "info.circle")
                            }
                        }
                        .onTapGesture {
                            showingBuiltInAbout = db
                        }

                        if db != BuiltInDatabase.allCases.last {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }

                    // Custom section
                    if !appState.customDatabases.isEmpty {
                        Divider()
                            .padding(.top, Spacing.sm)

                        sectionHeader("Custom")

                        ForEach(appState.customDatabases) { db in
                            DatabaseManagementRow(
                                name: db.displayName,
                                itemCount: db.itemCount,
                                description: formatCustomDescription(db),
                                isCustom: true,
                                isHovered: hoveredDatabase == db.id,
                                embeddingStatus: embeddingStatusText(for: db),
                                embeddedModelKeys: db.embeddedModelKeys,
                                registeredModels: appState.modelManager.registeredModels
                            )
                            .onHover { hoveredDatabase = $0 ? db.id : nil }
                            .contextMenu {
                                Button {
                                    showingDatabaseInfo = db
                                } label: {
                                    Label("Get Info", systemImage: "info.circle")
                                }

                                Divider()

                                // Re-embed option (only when not currently embedding)
                                if !appState.databaseEmbeddingStatus.isEmbedding {
                                    Button {
                                        reembedTarget = db
                                    } label: {
                                        Label("Re-embed with Current Model", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                }

                                Divider()

                                Button(role: .destructive) {
                                    databaseToDelete = db
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .onTapGesture {
                                showingDatabaseInfo = db
                            }

                            if db.id != appState.customDatabases.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }

                    // Empty custom state
                    if appState.customDatabases.isEmpty {
                        Divider()
                            .padding(.top, Spacing.sm)

                        sectionHeader("Custom")

                        Button {
                            showingAddDatabase = true
                        } label: {
                            VStack(spacing: Spacing.sm) {
                                Image(systemName: "plus.circle.dashed")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)

                                Text("No custom databases")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text("Add your own CSV or TSV database for matching.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xxl)
                            .padding(.horizontal, Spacing.lg)
                            .premiumMaterialStyle(cornerRadius: 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Spacing.lg)
                    }
                }
                .padding(.vertical, Spacing.sm)
            }
        }
        .sheet(isPresented: $showingAddDatabase) {
            AddDatabaseSheet { database in
                appState.addCustomDatabase(database)
            }
        }
        .sheet(item: $showingDatabaseInfo) { database in
            DatabaseInfoSheet(database: database, modelManager: appState.modelManager)
        }
        .sheet(item: $showingBuiltInAbout) { database in
            BuiltInDatabaseAboutView(database: database)
        }
        .confirmationDialog(
            "Remove Database?",
            isPresented: Binding(
                get: { databaseToDelete != nil },
                set: { if !$0 { databaseToDelete = nil } }
            ),
            presenting: databaseToDelete
        ) { database in
            Button("Remove", role: .destructive) {
                appState.deleteCustomDatabase(database)
                databaseToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                databaseToDelete = nil
            }
        } message: { database in
            Text("Remove \"\(database.displayName)\"? The cached embeddings will be deleted. You'll need to re-embed if you add this database again.")
        }
        .confirmationDialog(
            "Re-embed Database?",
            isPresented: Binding(
                get: { reembedTarget != nil },
                set: { if !$0 { reembedTarget = nil } }
            ),
            presenting: reembedTarget
        ) { database in
            Button("Re-embed") {
                appState.reembedCustomDatabase(database)
                reembedTarget = nil
            }
            Button("Cancel", role: .cancel) {
                reembedTarget = nil
            }
        } message: { database in
            let modelName = currentEmbeddingModelDisplayName
            Text("Re-embed \"\(database.displayName)\" using \(modelName)? This will generate new embeddings alongside any existing ones.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddDatabaseSheet)) { _ in
            showingAddDatabase = true
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .technicalLabel()

            Spacer()
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xs)
    }

    private func formatCustomDescription(_ db: CustomDatabase) -> String {
        var parts: [String] = []
        parts.append("Text column: \(db.textColumn)")
        if db.totalCacheSize > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: db.totalCacheSize, countStyle: .file)
            parts.append("Cache: \(formatted)")
        }
        return parts.joined(separator: " | ")
    }

    private func embeddingStatusText(for db: CustomDatabase) -> String {
        let keys = db.embeddedModelKeys
        if keys.isEmpty { return "Not embedded" }
        if keys.count == 1 { return "1 model" }
        return "\(keys.count) models"
    }

    private func builtInEmbeddingStatusText(for modelKeys: [String]) -> String {
        if modelKeys.isEmpty { return "Embeds on first use" }
        if modelKeys.count == 1 { return "1 model" }
        return "\(modelKeys.count) models"
    }

    private var currentEmbeddingModelDisplayName: String {
        if let key = appState.selectedPipelineType.embeddingModelKey,
           let reg = appState.modelManager.registeredModel(for: key) {
            return reg.displayName
        }
        return "current model"
    }
}

/// Row for a database in the management view
struct DatabaseManagementRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let name: String
    let itemCount: Int
    let description: String
    let isCustom: Bool
    let isHovered: Bool
    let embeddingStatus: String
    var embeddedModelKeys: [String] = []
    var registeredModels: [RegisteredModel] = []

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Icon
            Image(systemName: isCustom ? "externaldrive.badge.person.crop" : "internaldrive")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            // Info
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                HStack(spacing: Spacing.sm) {
                    Text("\(itemCount.formatted()) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Model embedding tags
                if !embeddedModelKeys.isEmpty {
                    HStack(spacing: Spacing.xxs) {
                        ForEach(embeddedModelKeys, id: \.self) { key in
                            Text(displayName(for: key))
                                .font(.caption2)
                                .padding(.horizontal, Spacing.xxs)
                                .padding(.vertical, 2)
                                .polishedBadge(tone: .accentStrong, cornerRadius: 4)
                        }
                    }
                }
            }

            Spacer()

            // Embedding status badge
            let badgeTone: AppBadgeTone = {
                if embeddingStatus == "Not embedded" { return .warning }
                if embeddingStatus == "Embeds on first use" { return .neutral }
                return .success
            }()

            Text(embeddingStatus)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .polishedBadge(tone: badgeTone, cornerRadius: 4)

            // Type badge
            Text(isCustom ? "Custom" : "Built-in")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .polishedBadge(tone: isCustom ? .accent : .neutral, cornerRadius: 4)
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

    private func displayName(for modelKey: String) -> String {
        registeredModels.first(where: { $0.key == modelKey })?.displayName ?? modelKey
    }
}

#Preview("Databases - Light") {
    DatabaseManagementView()
        .environmentObject(PreviewHelpers.databasesState())
        .frame(width: 800, height: 550)
}

#Preview("Databases - Dark") {
    DatabaseManagementView()
        .environmentObject(PreviewHelpers.databasesState())
        .frame(width: 800, height: 550)
        .preferredColorScheme(.dark)
}

#Preview("Databases - No Custom") {
    DatabaseManagementView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 800, height: 550)
}
