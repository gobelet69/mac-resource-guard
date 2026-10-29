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
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
