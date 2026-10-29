import Foundation

public enum ResourceStatusAppearance: Sendable {
    case light
    case dark
}

public struct ResourceRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func composited(over background: ResourceRGB, opacity: Double) -> ResourceRGB {
        let alpha = min(1.0, max(0.0, opacity))
        return ResourceRGB(
            red: red * alpha + background.red * (1.0 - alpha),
            green: green * alpha + background.green * (1.0 - alpha),
            blue: blue * alpha + background.blue * (1.0 - alpha)
        )
    }

    public func contrastRatio(with other: ResourceRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}

public struct ResourceStatusColorPair: Equatable, Sendable {
    public let foreground: ResourceRGB
    public let backgroundTint: ResourceRGB
    public let backgroundOpacity: Double

    public init(foreground: ResourceRGB, backgroundTint: ResourceRGB, backgroundOpacity: Double = 0.16) {
        self.foreground = foreground
        self.backgroundTint = backgroundTint
        self.backgroundOpacity = backgroundOpacity
    }
}

public enum ResourceStatusPalette {
    public static func colors(
        for severity: ResourceSeverity,
        appearance: ResourceStatusAppearance
    ) -> ResourceStatusColorPair {
        switch (appearance, severity) {
        case (.light, .normal):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 11.0 / 255.0, green: 110.0 / 255.0, blue: 46.0 / 255.0),
                backgroundTint: ResourceRGB(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0)
            )
        case (.light, .elevated):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 138.0 / 255.0, green: 59.0 / 255.0, blue: 0.0),
                backgroundTint: ResourceRGB(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
            )
        case (.light, .critical):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 164.0 / 255.0, green: 17.0 / 255.0, blue: 30.0 / 255.0),
                backgroundTint: ResourceRGB(red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)
            )
        case (.dark, .normal):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0),
                backgroundTint: ResourceRGB(red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0)
            )
        case (.dark, .elevated):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0),
                backgroundTint: ResourceRGB(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
            )
        case (.dark, .critical):
            return ResourceStatusColorPair(
                foreground: ResourceRGB(red: 1.0, green: 116.0 / 255.0, blue: 108.0 / 255.0),
                backgroundTint: ResourceRGB(red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)
            )
        }
    }
}
