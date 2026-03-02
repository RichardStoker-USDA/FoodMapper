import SwiftUI

/// Horizontal summary bar shown above the results table.
/// Always visible when results are displayed. Shows match rate and counts,
/// plus pagination controls on the right side.
struct ResultsSummaryBanner: View {
    @EnvironmentObject var appState: AppState
    @Binding var currentPage: Int
    let totalPages: Int

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.lg) {
                // Total results count + pipeline name
                HStack(spacing: Spacing.xs) {
                    Text("\(appState.results.count)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .monospacedDigit()

                    Text("results")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("via \(appState.selectedPipelineType.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Inline page size selector
                Menu {
                    ForEach([200, 500, 1000, 2000], id: \.self) { size in
                        Button {
                            UserDefaults.standard.set(size, forKey: "pageSize")
                        } label: {
                            if appState.pageSize == size {
                                Label("\(size)", systemImage: "checkmark")
                            } else {
                                Text("\(size)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xxxs) {
                        Text("\(appState.pageSize)")
                            .font(.caption)
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Items per page")

                // Pagination controls (Preview.app style)
                if totalPages > 1 {
                    PaginationControls(
                        currentPage: $currentPage,
                        totalPages: totalPages
                    )
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(height: 36)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
        }
    }
}

// MARK: - Previews

#Preview("Banner - Results Only - Light") {
    ResultsSummaryBanner(
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(PreviewHelpers.resultsState())
    .preferredColorScheme(.light)
}

#Preview("Banner - Results Only - Dark") {
    ResultsSummaryBanner(
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(PreviewHelpers.resultsState())
    .preferredColorScheme(.dark)
}

#Preview("Banner - With Pagination - Light") {
    ResultsSummaryBanner(
        currentPage: .constant(2),
        totalPages: 5
    )
    .environmentObject(PreviewHelpers.reviewBannerState())
    .preferredColorScheme(.light)
}

#Preview("Banner - With Pagination - Dark") {
    ResultsSummaryBanner(
        currentPage: .constant(2),
        totalPages: 5
    )
    .environmentObject(PreviewHelpers.reviewBannerState())
    .preferredColorScheme(.dark)
}
