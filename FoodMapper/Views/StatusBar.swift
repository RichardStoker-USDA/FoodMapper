import SwiftUI

/// Bottom status bar
struct StatusBar: View {
    let statusMessage: String
    let isProcessing: Bool
    let modelStatus: ModelStatus
    let hardwareConfig: HardwareConfig
    var showDebugInfo: Bool = false
    var effectiveEmbeddingBatchSize: Int = 0
    var effectiveMatchingBatchSize: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            // Status
            StatusBarSegment {
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(isProcessing ? .orange : .green)
                        .frame(width: Size.statusDot, height: Size.statusDot)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isProcessing)

                    Text(statusMessage)
                }
            }

            Spacer()

            // Debug info (when enabled)
            if showDebugInfo {
                StatusBarSegment {
                    Text("Batch: \(effectiveEmbeddingBatchSize)/\(effectiveMatchingBatchSize)")
                        .foregroundStyle(.secondary)
                }
                StatusBarDivider()
            }

            // Hardware info with model status
            StatusBarSegment {
                HStack(spacing: Spacing.xxs) {
                    if modelStatus.isReady {
                        // GPU active indicator
                        Image(systemName: "bolt")
                            .foregroundStyle(.green)
                            .font(.caption2)
                    } else {
                        Circle()
                            .fill(.orange)
                            .frame(width: Size.statusDot, height: Size.statusDot)
                    }

                    // Show device name and memory when model is ready
                    if modelStatus.isReady {
                        Text("\(hardwareConfig.shortDeviceName) (\(hardwareConfig.detectedMemoryGB)GB)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(modelStatus.shortText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .frame(height: Size.statusBarHeight)
        .overlay(alignment: .top) { Divider() }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StatusBarSegment<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Spacing.md)
    }
}

struct StatusBarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 14)
    }
}

#Preview("Ready - Light") {
    StatusBar(
        statusMessage: "Ready",
        isProcessing: false,
        modelStatus: .ready(executionProvider: "MLX (GPU)"),
        hardwareConfig: HardwareConfig(memoryGB: 32, deviceName: "Apple M2 Pro"),
        effectiveEmbeddingBatchSize: 48,
        effectiveMatchingBatchSize: 256
    )
    .frame(width: 900)
}

#Preview("Ready - Dark") {
    StatusBar(
        statusMessage: "Ready",
        isProcessing: false,
        modelStatus: .ready(executionProvider: "MLX (GPU)"),
        hardwareConfig: HardwareConfig(memoryGB: 32, deviceName: "Apple M2 Pro"),
        effectiveEmbeddingBatchSize: 48,
        effectiveMatchingBatchSize: 256
    )
    .frame(width: 900)
    .preferredColorScheme(.dark)
}

#Preview("Complete") {
    StatusBar(
        statusMessage: "Complete",
        isProcessing: false,
        modelStatus: .ready(executionProvider: "MLX (GPU)"),
        hardwareConfig: HardwareConfig(memoryGB: 32, deviceName: "Apple M2 Pro"),
        effectiveEmbeddingBatchSize: 48,
        effectiveMatchingBatchSize: 256
    )
    .frame(width: 900)
}

#Preview("Processing") {
    StatusBar(
        statusMessage: "Embedding inputs...",
        isProcessing: true,
        modelStatus: .ready(executionProvider: "MLX (GPU)"),
        hardwareConfig: HardwareConfig(memoryGB: 32, deviceName: "Apple M2 Pro"),
        showDebugInfo: true,
        effectiveEmbeddingBatchSize: 48,
        effectiveMatchingBatchSize: 256
    )
    .frame(width: 900)
}
