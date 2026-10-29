import XCTest
#if canImport(MacResourceGuardCore)
@testable import MacResourceGuardCore
#else
@testable import MacResourceGuard
#endif

final class ResourceStatusPaletteTests: XCTestCase {
    func testEverySmallBadgeMeetsContrastInLightAndDarkAppearances() {
        let surfaces: [(ResourceStatusAppearance, ResourceRGB)] = [
            (.light, ResourceRGB(red: 0.95, green: 0.95, blue: 0.97)),
            (.dark, ResourceRGB(red: 0.15, green: 0.15, blue: 0.17))
        ]

        for (appearance, surface) in surfaces {
            for severity in [ResourceSeverity.normal, .elevated, .critical] {
                let pair = ResourceStatusPalette.colors(for: severity, appearance: appearance)
                let resolvedBackground = pair.backgroundTint.composited(over: surface, opacity: pair.backgroundOpacity)
                XCTAssertGreaterThanOrEqual(
                    pair.foreground.contrastRatio(with: resolvedBackground),
                    4.5,
                    "\(appearance) \(severity)"
                )
            }
        }
    }
}
