import SwiftUI

/// Finder-style "About" sheet for built-in databases
struct BuiltInDatabaseAboutView: View {
    @Environment(\.dismiss) private var dismiss
    let database: BuiltInDatabase

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.md) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(database.displayName)
                        .font(.headline)
                    Text("\(database.itemCount.formatted()) items")
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
                    // About section
                    infoSection(title: "About") {
                        Text(database.aboutDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Technical details section
                    infoSection(title: "Technical Details") {
                        infoRow("Text Column", value: database.textColumn)
                        infoRow("ID Column", value: database.idColumn ?? "None")
                        infoRow("Embeddings", value: "Pre-computed (bundled with app)")
                    }

                    // Source section
                    infoSection(title: "Source") {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            switch database {
                            case .fooDB:
                                infoRow("Maintained by", value: "Wishart Research Group, University of Alberta")
                                infoRow("License", value: "CC BY-NC 4.0")
                                infoRow("Website", value: "foodb.ca")
                            case .dfg2:
                                infoRow("Authors", value: "Suarez C, Cheang SE, Larke JA, Jiang J, Weng CY, Stacy A, Couture G, Chen Y, Bacalzo NP Jr, Smilowitz JT, German JB, Mills DA, Lemay DG, Lebrilla CB")
                                infoRow("Journal", value: "Food Chemistry")
                                infoRow("Title", value: "Development of a comprehensive food glycomic database and its application")
                            }
                        }
                    }

                    // FoodMapper paper section
                    infoSection(title: "FoodMapper Research") {
                        Text("Included in FoodMapper as part of the study \"Evaluation of Large Language Models for Mapping Dietary Data to Food Databases.\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            infoRow("Authors", value: "Lemay DG, Strohmeier MP, Stoker RB, Larke JA, Wilson SMG")
                            infoRow("Status", value: "Publication forthcoming")
                        }
                        .padding(.top, Spacing.xs)
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
        .frame(width: 420, height: 480)
    }

    // MARK: - Components

    @ViewBuilder
    private func infoSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
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
}

#Preview("About FooDB - Light") {
    BuiltInDatabaseAboutView(database: .fooDB)
}

#Preview("About FooDB - Dark") {
    BuiltInDatabaseAboutView(database: .fooDB)
        .preferredColorScheme(.dark)
}

#Preview("About DFG2") {
    BuiltInDatabaseAboutView(database: .dfg2)
}
