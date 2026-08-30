import XCTest
@testable import FoodMapper

final class HelpSectionTests: XCTestCase {
    func testExperimentalTopicIsHiddenInSimpleMode() {
        let sections = HelpSidebarGroup.settingsAdvanced.sections(isAdvancedMode: false)

        XCTAssertFalse(HelpSection.experimentalFeatures.isVisible(isAdvancedMode: false))
        XCTAssertFalse(sections.contains(.experimentalFeatures))
        XCTAssertEqual(HelpSidebarGroup.settingsAdvanced.title(isAdvancedMode: false), "SETTINGS")
        XCTAssertEqual(
            HelpSection.experimentalFeatures.resolved(isAdvancedMode: false),
            .gettingStarted
        )
    }

    func testExperimentalTopicIsAvailableInAdvancedMode() {
        let sections = HelpSidebarGroup.settingsAdvanced.sections(isAdvancedMode: true)

        XCTAssertTrue(HelpSection.experimentalFeatures.isVisible(isAdvancedMode: true))
        XCTAssertTrue(sections.contains(.experimentalFeatures))
        XCTAssertEqual(HelpSidebarGroup.settingsAdvanced.title(isAdvancedMode: true), "SETTINGS & ADVANCED")
        XCTAssertEqual(
            HelpSection.experimentalFeatures.resolved(isAdvancedMode: true),
            .experimentalFeatures
        )
    }

    func testDisablingAdvancedModeResetsHistoryAroundVisibleTopic() {
        var navigation = HelpNavigationState()

        XCTAssertEqual(
            navigation.select(.experimentalFeatures, isAdvancedMode: true),
            .experimentalFeatures
        )
        XCTAssertEqual(
            navigation.select(.pipelineModes, isAdvancedMode: true),
            .pipelineModes
        )
        XCTAssertEqual(navigation.goBack(), .experimentalFeatures)

        XCTAssertEqual(navigation.resetForSimpleMode(), .gettingStarted)
        XCTAssertEqual(navigation.history, [.gettingStarted])
        XCTAssertEqual(navigation.historyIndex, 0)
        XCTAssertFalse(navigation.canGoBack)
        XCTAssertFalse(navigation.canGoForward)
        XCTAssertNil(navigation.goBack())
        XCTAssertNil(navigation.goForward())
        XCTAssertEqual(navigation.currentSection, .gettingStarted)
    }

    func testExperimentalNotificationFallsBackToGettingStartedInSimpleMode() {
        var navigation = HelpNavigationState(initialSection: .research)

        XCTAssertEqual(
            navigation.select(.experimentalFeatures, isAdvancedMode: false),
            .gettingStarted
        )
        XCTAssertEqual(navigation.history, [.research, .gettingStarted])
        XCTAssertEqual(navigation.historyIndex, 1)
        XCTAssertEqual(navigation.goBack(), .research)
        XCTAssertEqual(navigation.goForward(), .gettingStarted)
    }

    @MainActor
    func testDeepLinkPostedBeforeHelpMountIsConsumedWhenRequested() async {
        let notificationCenter = NotificationCenter()
        let requests = HelpRequestCoordinator(notificationCenter: notificationCenter)

        notificationCenter.post(
            name: .showHelp,
            object: HelpSection.keyboardShortcuts.rawValue
        )
        await Task.yield()

        XCTAssertEqual(
            requests.consumePendingSection(isAdvancedMode: false),
            .keyboardShortcuts
        )
        XCTAssertNil(requests.consumePendingSection(isAdvancedMode: false))
    }

    @MainActor
    func testPendingExperimentalDeepLinkFallsBackInSimpleMode() {
        let requests = HelpRequestCoordinator()

        requests.request(rawValue: HelpSection.experimentalFeatures.rawValue)

        XCTAssertEqual(
            requests.consumePendingSection(isAdvancedMode: false),
            .gettingStarted
        )
    }
}
