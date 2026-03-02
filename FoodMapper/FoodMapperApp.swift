import SwiftUI
import Sparkle

/// Overrides the macOS showHelp: responder chain action (Cmd+?).
/// Without this, CommandGroup(replacing: .help) breaks because macOS
/// routes Cmd+? through the responder chain. This override prevents
/// the default Help Viewer from opening; the Help menu dropdown
/// handles everything via its own menu items.
class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showHelp(_ sender: Any?) {
        // Intentionally empty. Prevents macOS from opening the default
        // Help Viewer. The Help menu items handle navigation to our
        // custom help window via .showHelp notifications.
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window minimum size is enforced by .windowResizability(.contentSize)
        // which propagates .frame(minWidth:minHeight:) from MainContent
        // to the NSWindow level. No AppKit-level enforcement needed.
    }
}

@main
struct FoodMapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("appearance") private var appearance = "system"
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    private var nsAppearance: NSAppearance? {
        switch appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil  // follow system
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    NSApp.appearance = nsAppearance
                }
                .onChange(of: appearance) { _, _ in
                    NSApp.appearance = nsAppearance
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .defaultSize(width: 1340, height: 750)
        .commands {
            // Inspector toggle (Cmd+Ctrl+I) for review panel
            InspectorCommands()

            // About panel (FoodMapper > About FoodMapper)
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }

            // Check for Updates (FoodMapper menu, below About)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Input File...") {
                    appState.ensureSidebarVisible()
                    appState.openFilePicker()
                }
                .keyboardShortcut("o")

                Button("Open Target Database...") {
                    appState.ensureSidebarVisible()
                    NotificationCenter.default.post(name: .showAddDatabaseSheet, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Export as CSV...") {
                    appState.exportResults()
                }
                .keyboardShortcut("e")
                .disabled(
                    !appState.viewingResults
                    || appState.results.isEmpty
                    || appState.isProcessing
                    || appState.sidebarSelection != .home
                    || appState.showMatchSetup
                )

                Button("Export as TSV...") {
                    appState.exportResults(format: .tsv)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(
                    !appState.viewingResults
                    || appState.results.isEmpty
                    || appState.isProcessing
                    || appState.sidebarSelection != .home
                    || appState.showMatchSetup
                )
            }

            // View menu
            CommandGroup(after: .sidebar) {
                Button("Back") {
                    appState.goBack()
                }
                .keyboardShortcut("[")
                .disabled(!appState.canGoBack)

                Button("Forward") {
                    appState.goForward()
                }
                .keyboardShortcut("]")
                .disabled(!appState.canGoForward)

                Divider()

                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)

                Divider()

                Button("Show All") {
                    appState.resultsFilter = .all
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Matches") {
                    appState.resultsFilter = .match
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Needs Review") {
                    appState.resultsFilter = .needsReview
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("No Matches") {
                    appState.resultsFilter = .noMatch
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("Find...") {
                    appState.focusSearch()
                }
                .keyboardShortcut("f")
                .disabled(appState.results.isEmpty)

                Divider()

                Button("Previous Page") {
                    if appState.currentPage > 0 {
                        appState.currentPage -= 1
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(appState.currentPage == 0 || appState.results.isEmpty)

                Button("Next Page") {
                    if appState.currentPage < appState.totalPages - 1 {
                        appState.currentPage += 1
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(appState.currentPage >= appState.totalPages - 1 || appState.results.isEmpty)

                Divider()

                Button("First Page") {
                    appState.currentPage = 0
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(appState.currentPage == 0 || appState.results.isEmpty)

                Button("Last Page") {
                    appState.currentPage = appState.totalPages - 1
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(appState.currentPage >= appState.totalPages - 1 || appState.results.isEmpty)
            }

            // Matching menu
            CommandMenu("Matching") {
                if appState.isProcessing {
                    Button("Cancel") {
                        appState.cancelMatching()
                    }
                    .keyboardShortcut(".")
                } else {
                    Button("Run Matching") {
                        appState.runMatching()
                    }
                    .keyboardShortcut("r")
                    .disabled(!appState.canRun)
                }
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("FoodMapper Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }

                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .showHelp, object: HelpSection.keyboardShortcuts.rawValue)
                }

                Divider()

                Button("Restart Tutorial") {
                    appState.restartTutorial()
                }
            }

            // Window menu
            CommandGroup(before: .windowList) {
                Button("Welcome to FoodMapper") {
                    appState.showSplashScreen = true
                }

                Divider()
            }

            // History menu
            CommandMenu("History") {
                Button("Show History") {
                    appState.sidebarSelection = .history
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(appState.sessions.isEmpty)

                Button("Return to Welcome") {
                    appState.returnToWelcome()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.sidebarSelection == .home && !appState.showMatchSetup)

                Divider()

                if !appState.sessions.isEmpty {
                    ForEach(appState.sessions.prefix(5)) { session in
                        Button(session.inputFileName) {
                            appState.loadSession(session)
                        }
                    }

                    Divider()

                    Button("Clear All History", role: .destructive) {
                        appState.clearAllHistory()
                    }
                } else {
                    Text("No history")
                        .foregroundStyle(.secondary)
                }
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(appState)
        }

        Window("FoodMapper Help", id: "help") {
            HelpView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 620)
        .defaultPosition(.center)

        Window("About FoodMapper", id: "about") {
            AboutPanelView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - About Panel (Xcode-style: icon left, text right)

/// Menu item that captures @Environment(\.openWindow) for the About window.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About FoodMapper") {
            openWindow(id: "about")
        }
    }
}

/// Custom About panel: icon left, name + version + credits right.
private struct AboutPanelView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.lg) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                }

                VStack(spacing: Spacing.lg) {
                    VStack(spacing: Spacing.xxxs) {
                        Text("FoodMapper")
                            .font(.system(size: 30, weight: .regular))

                        Text("Version \(version) (\(build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: Spacing.sm) {
                        VStack(spacing: Spacing.xxxs) {
                            Text("Western Human Nutrition Research Center").fontWeight(.medium)
                            + Text("  |  Davis, CA")
                            Text("Diet, Microbiome and Immunity Research Unit")
                        }

                        Text("United States Department of Agriculture  |  Agricultural Research Service")

                        Text("CC0 1.0 Universal - Public Domain")
                    }
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.65))
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: Spacing.md) {
                Button("Research Paper") {
                    // Placeholder: will open paper DOI link when published
                }
                .frame(width: 140)

                Button("GitHub Repository") {
                    // Placeholder: will open GitHub repo URL
                }
                .frame(width: 140)
            }
            .padding(.leading, 144)
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
        .padding(.horizontal, Spacing.xxl)
        .frame(width: 560)
        .onExitCommand {
            NSApp.keyWindow?.close()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showAddDatabaseSheet = Notification.Name("showAddDatabaseSheet")
    static let addInputFile = Notification.Name("addInputFile")
    static let showHelp = Notification.Name("showHelp")
}
