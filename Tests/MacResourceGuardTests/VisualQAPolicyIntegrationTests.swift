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
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
