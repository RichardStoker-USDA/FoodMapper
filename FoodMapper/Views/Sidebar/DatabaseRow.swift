import SwiftUI

/// Row for selecting a database in the sidebar.
/// Uses neutral gray row background for selection with accent-colored text/icon
/// (Finder sidebar pattern), and a leading icon to distinguish built-in from custom.
struct DatabaseRow: View {
    let name: String
    let subtitle: String
    let isSelected: Bool
    let isCustom: Bool
    let onSelect: () -> Void

    private var leadingIcon: String {
        isCustom ? "person.crop.circle" : "cylinder.split.1x2"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: leadingIcon)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)

                Text(name)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)

                Spacer()

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.7) : .secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Spacing.xxs)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
                : nil
        )
        .accessibilityLabel("\(name), \(subtitle)\(isSelected ? ", selected" : "")")
    }
}

#Preview("Database Rows - Light") {
    VStack(alignment: .leading, spacing: 8) {
        DatabaseRow(name: "FooDB", subtitle: "9,913 items", isSelected: true, isCustom: false) {}
        DatabaseRow(name: "DFG2", subtitle: "256 items", isSelected: false, isCustom: false) {}
        DatabaseRow(name: "My Custom DB", subtitle: "1,234 items", isSelected: false, isCustom: true) {}
    }
    .padding()
    .frame(width: 250)
}

#Preview("Database Rows - Dark") {
    VStack(alignment: .leading, spacing: 8) {
        DatabaseRow(name: "FooDB", subtitle: "9,913 items", isSelected: true, isCustom: false) {}
        DatabaseRow(name: "DFG2", subtitle: "256 items", isSelected: false, isCustom: false) {}
        DatabaseRow(name: "My Custom DB", subtitle: "1,234 items", isSelected: false, isCustom: true) {}
    }
    .padding()
    .frame(width: 250)
    .preferredColorScheme(.dark)
}
