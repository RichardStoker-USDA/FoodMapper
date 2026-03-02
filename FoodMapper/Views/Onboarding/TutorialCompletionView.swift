import SwiftUI

/// Modal shown when tutorial is completed, with staggered animation and auto-dismiss
struct TutorialCompletionView: View {
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = 0
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(phase >= 1 ? 0.3 : 0)
                .ignoresSafeArea()
                .animation(Animate.smooth, value: phase)

            // Modal content
            VStack(spacing: Spacing.xl) {
                // Success icon
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(phase >= 2 ? 1.0 : 0.3)
                    .opacity(phase >= 2 ? 1.0 : 0)

                // Title
                Text("You're All Set")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .opacity(phase >= 3 ? 1.0 : 0)
                    .offset(y: phase >= 3 ? 0 : 8)

                // Recap text
                Text("You've learned how to load data, run matches, review and refine results, and export. For more details, check the Help section in the menu bar. Need a refresher? Select \"Restart Tutorial\" from Help anytime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .opacity(phase >= 4 ? 1.0 : 0)
                    .offset(y: phase >= 4 ? 0 : 8)

                // Action button
                Button {
                    autoDismissTask?.cancel()
                    onDismiss()
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 240)
                .opacity(phase >= 5 ? 1.0 : 0)
                .offset(y: phase >= 5 ? 0 : 8)
                .accessibilityLabel("Close tutorial and start using FoodMapper")
            }
            .padding(Spacing.xxl)
            .frame(width: 380)
            .background {
                Group {
                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.regularMaterial)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12),
                    radius: 24,
                    y: 8
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.3 : 0.5),
                            lineWidth: 0.5
                        )
                }
            }
            .scaleEffect(phase >= 1 ? 1.0 : 0.9)
            .opacity(phase >= 1 ? 1.0 : 0)
        }
        .onAppear {
            // Staggered animation sequence (snappy, ~0.8s total build-up)
            withAnimation(Animate.smooth) { phase = 1 }
            withAnimation(Animate.bouncy.delay(0.1)) { phase = 2 }
            withAnimation(Animate.standard.delay(0.25)) { phase = 3 }
            withAnimation(Animate.standard.delay(0.4)) { phase = 4 }
            withAnimation(Animate.standard.delay(0.6)) { phase = 5 }

            // Auto-dismiss after 18 seconds (long enough to read recap)
            autoDismissTask = Task {
                try? await Task.sleep(for: .seconds(18))
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(Animate.smooth) {
                            onDismiss()
                        }
                    }
                }
            }
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You're All Set")
    }
}

#Preview("Tutorial Complete - Light") {
    TutorialCompletionView(onDismiss: {})
        .frame(width: 600, height: 500)
}

#Preview("Tutorial Complete - Dark") {
    TutorialCompletionView(onDismiss: {})
        .frame(width: 600, height: 500)
        .preferredColorScheme(.dark)
}
