import AppKit
import SwiftUI

/// Holds only the current startup attempt. It does not read application
/// settings or construct application services before storage is available.
@MainActor
final class FoodMapperStartupCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case failed
        case ready
    }

    @Published private(set) var state: State = .checking
    private let bootstrapStorage: () throws -> Void

    init(bootstrapStorage: @escaping () throws -> Void = FoodMapperStorage.bootstrap) {
        self.bootstrapStorage = bootstrapStorage
    }

    func start() {
        state = .checking
        do {
            try bootstrapStorage()
            state = .ready
        } catch {
            state = .failed
        }
    }

    func retry() {
        start()
    }
}

struct FoodMapperStorageStartupView: View {
    let state: FoodMapperStartupCoordinator.State
    let retry: () -> Void

    var body: some View {
        switch state {
        case .checking:
            ProgressView("Opening FoodMapper")
                .controlSize(.regular)
                .frame(width: 360, height: 220)

        case .failed:
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("FoodMapper could not open its storage")
                    .font(.title3)

                Text("Review the FoodMapper folder in Application Support, then try again. FoodMapper did not remove or replace storage entries.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    Button("Try Again", action: retry)
                        .keyboardShortcut(.defaultAction)

                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, Spacing.xs)
            }
            .frame(width: 420, alignment: .leading)
            .padding(Spacing.xxl)

        case .ready:
            EmptyView()
        }
    }
}
