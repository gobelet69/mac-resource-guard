import XCTest
#if canImport(MacResourceGuardCore)
@testable import MacResourceGuardCore
#else
@testable import MacResourceGuard
#endif

final class VisualQAScenarioTests: XCTestCase {
    func testScenarioNamesResolveOnlyTheSupportedVisualStates() {
        let supported = [
            "normal",
            "highCPU",
            "memoryPressure",
            "singleSelection",
            "multipleSelection",
            "notificationsEnabled",
            "notificationsPaused",
            "doNotDisturb",
            "forceQuitConfirmation"
        ]

        XCTAssertEqual(supported.compactMap(VisualQAScenario.init(rawValue:)), VisualQAScenario.allCases)
        XCTAssertNil(VisualQAScenario(rawValue: "live"))
        XCTAssertNil(VisualQAScenario(rawValue: ""))
    }

    func testLaunchArgumentParserAcceptsOnlyOneExactSupportedScenario() {
        XCTAssertEqual(
            VisualQAScenario.launchScenario(in: ["MacResourceGuard", "--visual-qa-scenario=highCPU"]),
            .highCPU
        )
        XCTAssertNil(VisualQAScenario.launchScenario(in: ["MacResourceGuard", "--visual-qa-scenario=live"]))
        XCTAssertNil(VisualQAScenario.launchScenario(in: ["MacResourceGuard", "--visual-qa-scenario=highCPU", "--visual-qa-scenario=normal"]))
        XCTAssertNil(VisualQAScenario.launchScenario(in: ["MacResourceGuard", "visual-qa-scenario=normal"]))
    }

    func testAppearanceParserSupportsLightDarkAndHighContrastVariants() {
        XCTAssertEqual(VisualQAAppearance.launchAppearance(in: ["app", "--appearance=light"]), .light)
        XCTAssertEqual(VisualQAAppearance.launchAppearance(in: ["app", "--appearance=dark"]), .dark)
        XCTAssertEqual(VisualQAAppearance.launchAppearance(in: ["app", "--appearance=highContrastLight"]), .highContrastLight)
        XCTAssertEqual(VisualQAAppearance.launchAppearance(in: ["app", "--appearance=highContrastDark"]), .highContrastDark)
        XCTAssertNil(VisualQAAppearance.launchAppearance(in: ["app", "--appearance=unknown"]))
    }

    func testEveryScenarioUsesOnlySanitizedNonRoutableApplications() {
        let expectedNames = ["Aurora Editor", "Northstar Browser", "Canvas Studio"]

        for scenario in VisualQAScenario.allCases {
            let apps = scenario.snapshot.topAppsByCPU
            XCTAssertEqual(apps.map(\.displayName), expectedNames, scenario.rawValue)
            XCTAssertTrue(apps.allSatisfy { $0.id < 0 }, scenario.rawValue)
            XCTAssertTrue(apps.allSatisfy { $0.groupedPIDs.allSatisfy { $0 < 0 } }, scenario.rawValue)
            XCTAssertTrue(apps.allSatisfy {
                SafeAppTerminator.evaluateProtection(
                    pid: $0.id,
                    uid: nil,
                    bundleIdentifier: $0.bundleIdentifier,
                    processName: $0.displayName,
                    executablePath: $0.executablePath
                ).isProtected
            }, scenario.rawValue)
        }
    }

    func testResourceScenariosExposeExactSemanticStates() {
        XCTAssertEqual(VisualQAScenario.normal.snapshot.severity, .normal)
        XCTAssertEqual(VisualQAScenario.normal.snapshot.primaryPressureKind, .none)
        XCTAssertEqual(VisualQAScenario.normal.snapshot.memory.pressureLevel, .normal)

        XCTAssertEqual(VisualQAScenario.highCPU.snapshot.severity, .elevated)
        XCTAssertEqual(VisualQAScenario.highCPU.snapshot.primaryPressureKind, .cpu)
        XCTAssertEqual(VisualQAScenario.highCPU.snapshot.cpuTotalPercent, 88.0)

        XCTAssertEqual(VisualQAScenario.memoryPressure.snapshot.severity, .critical)
        XCTAssertEqual(VisualQAScenario.memoryPressure.snapshot.primaryPressureKind, .memory)
        XCTAssertEqual(VisualQAScenario.memoryPressure.snapshot.memory.pressureLevel, .critical)
    }

    func testSelectionScenariosSelectOnlyRequestedSyntheticRows() {
        XCTAssertEqual(VisualQAScenario.singleSelection.selectedProcessIDs, [-101])
        XCTAssertEqual(VisualQAScenario.multipleSelection.selectedProcessIDs, [-101, -102])
        XCTAssertTrue(VisualQAScenario.normal.selectedProcessIDs.isEmpty)
    }

    func testNotificationScenariosHaveDeterministicPresentationCopy() {
        XCTAssertEqual(VisualQAScenario.normal.notificationPresentation, .disabled)
        XCTAssertEqual(VisualQAScenario.normal.notificationPresentation.subtitlePrefix, "Alerts disabled.")

        XCTAssertEqual(VisualQAScenario.notificationsEnabled.notificationPresentation, .enabled)
        XCTAssertEqual(VisualQAScenario.notificationsEnabled.notificationPresentation.subtitlePrefix, nil)

        XCTAssertEqual(VisualQAScenario.notificationsPaused.notificationPresentation, .paused)
        XCTAssertEqual(VisualQAScenario.notificationsPaused.notificationPresentation.subtitlePrefix, "Alerts paused temporarily.")

        XCTAssertEqual(VisualQAScenario.doNotDisturb.notificationPresentation, .doNotDisturb)
        XCTAssertEqual(VisualQAScenario.doNotDisturb.notificationPresentation.subtitlePrefix, "Do Not Disturb active.")
    }

    func testVisualQAModeAlwaysDisablesDestructiveActions() {
        XCTAssertFalse(VisualQASafetyPolicy.visualQAMode.allowsDestructiveActions)
        XCTAssertTrue(VisualQASafetyPolicy.production.allowsDestructiveActions)
    }
}
