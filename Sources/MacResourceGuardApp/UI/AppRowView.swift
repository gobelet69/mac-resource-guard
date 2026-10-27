import AppKit
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

/// Reusable, zero-allocation-update row view representing one of the Top 3 resource-consuming applications.
public final class AppRowView: NSView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let primaryMetricLabel = NSTextField(labelWithString: "")
    private let secondaryMetricLabel = NSTextField(labelWithString: "")
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    public private(set) var currentApp: AggregatedAppProcess?
    private var isAwaitingForceQuit: Bool = false

    public var onToggleSelection: ((AggregatedAppProcess, Bool) -> Void)?
    public var onRequestQuit: ((AggregatedAppProcess, Bool) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var allowsVibrancy: Bool { false }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill = isDark
            ? NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.23, alpha: 0.90).cgColor
            : NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.92).cgColor
        let stroke = isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor
            : NSColor(calibratedWhite: 0.0, alpha: 0.08).cgColor

        layer?.backgroundColor = fill
        layer?.borderColor = stroke
        layer?.borderWidth = 1.0
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.target = self
        checkbox.action = #selector(handleCheckboxClicked)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [nameLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        primaryMetricLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        primaryMetricLabel.textColor = .labelColor
        primaryMetricLabel.alignment = .right
        primaryMetricLabel.setContentHuggingPriority(.required, for: .horizontal)
        primaryMetricLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        secondaryMetricLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        secondaryMetricLabel.textColor = .secondaryLabelColor
        secondaryMetricLabel.alignment = .right
        secondaryMetricLabel.setContentHuggingPriority(.required, for: .horizontal)
        secondaryMetricLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let metricsStack = NSStackView(views: [primaryMetricLabel, secondaryMetricLabel])
        metricsStack.orientation = .vertical
        metricsStack.alignment = .trailing
        metricsStack.spacing = 2
        metricsStack.translatesAutoresizingMaskIntoConstraints = false

        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        quitButton.target = self
        quitButton.action = #selector(handleQuitClicked)
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.setContentHuggingPriority(.required, for: .horizontal)
        quitButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(textStack)
        addSubview(metricsStack)
        addSubview(quitButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),

            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: metricsStack.leadingAnchor, constant: -8),

            metricsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            metricsStack.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -10),
            metricsStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),

            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
    }

    public func configure(
        with app: AggregatedAppProcess,
        sortByMemory: Bool,
        isSelected: Bool,
        awaitingForceQuit: Bool
    ) {
        self.currentApp = app
        self.isAwaitingForceQuit = awaitingForceQuit
        needsDisplay = true

        nameLabel.stringValue = app.displayName
        let helperBadge = app.helperProcessCount > 0
            ? "\(app.totalProcessCount) processes"
            : "1 process"

        let safetyBadge: String
        if app.isProtectedSystemApp {
            safetyBadge = "Protected"
            subtitleLabel.textColor = .systemOrange
        } else if awaitingForceQuit {
            safetyBadge = "Not responding / Save dialog open"
            subtitleLabel.textColor = .systemOrange
        } else if app.isBackgroundProcess {
            safetyBadge = "Safe to close"
            subtitleLabel.textColor = .secondaryLabelColor
        } else if app.hasIncompleteMetrics {
            safetyBadge = "Safe to close • Partial metrics"
            subtitleLabel.textColor = .secondaryLabelColor
        } else {
            safetyBadge = "Safe to close"
            subtitleLabel.textColor = .secondaryLabelColor
        }

        subtitleLabel.stringValue = "\(helperBadge) • \(safetyBadge)"

        var tooltipLines = [
            "\(app.displayName) (PID \(app.id))",
            "CPU Share: \(ByteFormatter.formatPercent(app.cpuPercentMachine)) of Mac (\(String(format: "%.0f%%", app.cpuPercentSingleCoreEquivalent)) single-core equiv.)",
            "Memory Footprint: \(ByteFormatter.formatBytes(app.memoryFootprintBytes))",
            "Processes Grouped: \(app.totalProcessCount)"
        ]
        if let path = app.executablePath {
            tooltipLines.append("Path: \(path)")
        }
        if let reason = app.protectionReason {
            tooltipLines.append("Protection: \(reason)")
        }
        self.toolTip = tooltipLines.joined(separator: "\n")

        let cpuStr = ByteFormatter.formatPercent(app.cpuPercentMachine)
        let memStr = ByteFormatter.formatBytes(app.memoryFootprintBytes)

        if sortByMemory {
            primaryMetricLabel.stringValue = memStr
            secondaryMetricLabel.stringValue = "\(cpuStr) CPU"
        } else {
            primaryMetricLabel.stringValue = "\(cpuStr)"
            secondaryMetricLabel.stringValue = memStr
        }

        if let icon = app.icon {
            iconView.image = icon
        } else if let path = ProcessAggregator.outermostAppBundlePath(for: app.executablePath) {
            iconView.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            iconView.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: app.displayName)
        }

        checkbox.isEnabled = app.canSafelyClose
        checkbox.state = (app.canSafelyClose && isSelected) ? .on : .off
        checkbox.setAccessibilityLabel("Select \(app.displayName)")

        if app.isProtectedSystemApp {
            quitButton.title = "Locked"
            quitButton.isEnabled = false
            quitButton.bezelColor = nil
        } else if awaitingForceQuit {
            quitButton.title = "Force…"
            quitButton.isEnabled = true
            quitButton.bezelColor = .systemRed
        } else {
            quitButton.title = "Quit"
            quitButton.isEnabled = true
            quitButton.bezelColor = nil
        }
    }

    @objc private func handleCheckboxClicked() {
        guard let app = currentApp, app.canSafelyClose else {
            checkbox.state = .off
            return
        }
        onToggleSelection?(app, checkbox.state == .on)
    }

    @objc private func handleQuitClicked() {
        guard let app = currentApp, app.canSafelyClose else { return }
        onRequestQuit?(app, isAwaitingForceQuit)
    }
}
