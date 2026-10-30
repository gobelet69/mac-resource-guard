import AppKit
import XCTest
#if canImport(MacResourceGuardApp)
@testable import MacResourceGuardApp
@testable import MacResourceGuardCore
#else
@testable import MacResourceGuard
#endif

@MainActor
final class VisualQAPolicyIntegrationTests: XCTestCase {
    func testMultipleSelectionKeepsEveryQuitCommandDisabledInVisualQAMode() {
        let controller = PopoverViewController(
            coordinator: AdaptiveMonitorCoordinator(),
            safetyPolicy: .visualQAMode
        )

        controller.applyVisualQAScenario(.multipleSelection)
        controller.view.layoutSubtreeIfNeeded()

        let quitButtons = controller.view.allDescendants
            .compactMap { $0 as? NSButton }
            .filter { $0.title.hasPrefix("Quit") || $0.title.hasPrefix("Force") }

        XCTAssertFalse(quitButtons.isEmpty)
        XCTAssertTrue(quitButtons.allSatisfy { !$0.isEnabled })
    }

    func testSelectedRowExposesStateAndUsesDistinctStaticCardStyling() {
        let app = VisualQAScenario.normal.snapshot.topAppsByCPU[0]
        let row = AppRowView()
        row.appearance = NSAppearance(named: .aqua)

        row.configure(with: app, sortByMemory: false, isSelected: false, awaitingForceQuit: false)
        row.updateLayer()
        let neutralBorder = row.layer?.borderColor
        let neutralFill = row.layer?.backgroundColor
        XCTAssertEqual(row.accessibilityValue() as? String, "Not selected")

        row.configure(with: app, sortByMemory: false, isSelected: true, awaitingForceQuit: false)
        row.updateLayer()
        XCTAssertEqual(row.accessibilityValue() as? String, "Selected")
        XCTAssertNotEqual(row.layer?.borderColor, neutralBorder)
        XCTAssertNotEqual(row.layer?.backgroundColor, neutralFill)
        XCTAssertEqual(row.layer?.borderWidth, 1.0)
    }

    func testForceQuitAlertFactoryBuildsWarningWithoutProcessIdentity() {
        let alert = ForceQuitAlertFactory.makeAlert(displayName: "Synthetic Application")

        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.messageText, "Force Quit Synthetic Application?")
        XCTAssertTrue(alert.informativeText.contains("unsaved changes"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Force Quit", "Cancel"])
    }

    func testStatusItemExposesTheRealButtonSafelyForVisualQAExport() throws {
        let controller = StatusBarController(
            coordinator: AdaptiveMonitorCoordinator(),
            safetyPolicy: .visualQAMode
        )
        controller.applyVisualQAScenario(.highCPU)

        let button = try XCTUnwrap(controller.statusButtonForVisualQAIfAvailable)
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.image?.accessibilityDescription, "Elevated Resource Usage")
    }

    func testNotificationScenarioControlsFooterStateWithoutUsingUserSettings() throws {
        let suiteName = "VisualQAPolicyIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let controller = PopoverViewController(
            coordinator: AdaptiveMonitorCoordinator(settings: settings),
            settings: settings,
            safetyPolicy: .visualQAMode
        )

        controller.applyVisualQAScenario(.notificationsEnabled)
        let enabledButton = try XCTUnwrap(controller.view.alertsButton)
        XCTAssertEqual(enabledButton.title, "Disable Alerts")
        XCTAssertEqual(enabledButton.image?.accessibilityDescription, "Alerts Active")

        controller.applyVisualQAScenario(.notificationsPaused)
        let pausedButton = try XCTUnwrap(controller.view.alertsButton)
        XCTAssertEqual(pausedButton.title, "Enable Alerts")
        XCTAssertEqual(pausedButton.image?.accessibilityDescription, "Alerts Disabled")
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }

    var alertsButton: NSButton? {
        allDescendants
            .compactMap { $0 as? NSButton }
            .first { $0.title.hasSuffix("Alerts") }
    }
}
