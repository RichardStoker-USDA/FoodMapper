import SwiftUI
import UniformTypeIdentifiers
import AppKit
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "ui")

/// Shared drop delegate for handling CSV file drops throughout the app
struct CSVDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false

        let providers = info.itemProviders(for: [.fileURL])
        guard let provider = providers.first else {
            logger.debug("CSVDropDelegate: No providers found")
            return false
        }

        // Use loadObject which works better with Finder drops
        _ = provider.loadObject(ofClass: URL.self) { reading, error in
            if let error = error {
                logger.debug("CSVDropDelegate: Error loading URL: \(error)")
                return
            }

            guard let url = reading else {
                logger.debug("CSVDropDelegate: No URL in reading")
                return
            }

            logger.debug("CSVDropDelegate: Got URL: \(url)")

            // Check if it's a CSV or TSV
            guard ["csv", "tsv"].contains(url.pathExtension.lowercased()) else {
                logger.debug("CSVDropDelegate: Not a CSV/TSV file: \(url.pathExtension)")
                return
            }

            DispatchQueue.main.async {
                onDrop(url)
            }
        }

        return true
    }
}
