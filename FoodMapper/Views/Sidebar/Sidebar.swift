import SwiftUI

/// Navigation sidebar -- main items always visible, Pipelines section in advanced mode.
struct Sidebar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            // Main navigation items
            ForEach(NavigationItem.mainItems) { item in
                sidebarLabel(for: item)
            }

            // Pipelines section (advanced mode only)
            if appState.isAdvancedMode {
                Section("Pipelines") {
                    ForEach(NavigationItem.pipelineItems) { item in
                        sidebarLabel(for: item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Size.sidebarMin, idealWidth: Size.sidebarIdeal, maxWidth: Size.sidebarMax)
    }

    private func sidebarLabel(for item: NavigationItem) -> some View {
        Label(item.label, systemImage: item.icon)
            .imageScale(.medium)
            .lineLimit(1)
            .tag(item)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

// MARK: - Section Header Component (kept for other views that may use it)

struct SectionHeader: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        Group {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
    }
}

#Preview("Sidebar - Standard Mode") {
    Sidebar()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 220, height: 400)
}

#Preview("Sidebar - Advanced Mode") {
    let state = PreviewHelpers.emptyState()
    state.isAdvancedMode = true
    return Sidebar()
        .environmentObject(state)
        .frame(width: 220, height: 400)
}

#Preview("Sidebar - Dark") {
    Sidebar()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 220, height: 400)
        .preferredColorScheme(.dark)
}
