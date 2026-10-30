import AppKit
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

/// Manages the macOS menu bar `NSStatusItem` and `NSPopover`, avoiding redundant redraws.
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverViewController: PopoverViewController
    private let coordinator: AdaptiveMonitorCoordinator
    private let settings: AppSettingsStore
    private let safetyPolicy: VisualQASafetyPolicy

    private var lastDisplayedSeverity: ResourceSeverity?
    private var lastDisplayedTitle: String?
    private var eventMonitor: Any?

    public var onOpenSettings: (() -> Void)? {
        didSet {
            popoverViewController.onOpenSettings = { [weak self] in
                self?.closePopover()
                self?.onOpenSettings?()
            }
        }
    }

    public init(
        coordinator: AdaptiveMonitorCoordinator,
        settings: AppSettingsStore = .shared,
        safetyPolicy: VisualQASafetyPolicy = .production
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.safetyPolicy = safetyPolicy
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popoverViewController = PopoverViewController(
            coordinator: coordinator,
            settings: settings,
            safetyPolicy: safetyPolicy
        )
        super.init()

        popover.contentViewController = popoverViewController
        popover.behavior = .transient
        popover.animates = (safetyPolicy == .production)
        popover.delegate = self

        configureStatusButton()
        updateStatusBarDisplay(cpuPercent: 0.0, severity: .normal, force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: AppSettingsStore.didChangeNotification,
            object: settings
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopOutsideClickMonitor()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "Mac Resource Guard — Click to inspect CPU & Memory pressure"
    }

    public func handleSnapshot(_ snapshot: SystemSnapshot) {
        updateStatusBarDisplay(
            cpuPercent: snapshot.cpuTotalPercent,
            severity: snapshot.severity,
            force: false
        )
        if popover.isShown {
            popoverViewController.applySnapshot(snapshot)
        }
    }

    public func applyVisualQAScenario(_ scenario: VisualQAScenario) {
        updateStatusBarDisplay(
            cpuPercent: scenario.snapshot.cpuTotalPercent,
            severity: scenario.snapshot.severity,
            force: true
        )
        popoverViewController.applyVisualQAScenario(scenario)
    }

    private func updateStatusBarDisplay(cpuPercent: Double, severity: ResourceSeverity, force: Bool) {
        let showPercent = settings.showCPUPercentageInMenuBar
        let roundedCPU = Int(cpuPercent.rounded())
        let newTitle = showPercent ? String(format: " %d%%", roundedCPU) : ""

        // Avoid touching AppKit NSStatusBarButton if neither severity nor displayed text changed
        if !force && lastDisplayedSeverity == severity && lastDisplayedTitle == newTitle {
            return
        }

        lastDisplayedSeverity = severity
        lastDisplayedTitle = newTitle

        guard let button = statusItem.button else { return }
        button.title = newTitle

        let symbolName: String
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)

        switch severity {
        case .normal:
            symbolName = "gauge.with.dots.needle.bottom.50percent"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "System Normal")?.withSymbolConfiguration(config) {
                img.isTemplate = true
                button.image = img
                button.contentTintColor = nil
            }
        case .elevated:
            symbolName = "exclamationmark.triangle.fill"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Elevated Resource Usage")?.withSymbolConfiguration(config) {
                img.isTemplate = true
                button.image = img
                button.contentTintColor = .systemOrange
            }
        case .critical:
            symbolName = "exclamationmark.octagon.fill"
            if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Critical Resource Pressure")?.withSymbolConfiguration(config) {
                img.isTemplate = true
                button.image = img
                button.contentTintColor = .systemRed
            }
        }
    }

    @objc private func handleSettingsChanged() {
        let cpu = coordinator.latestSnapshot?.cpuTotalPercent ?? 0.0
        let sev = coordinator.latestSnapshot?.severity ?? .normal
        updateStatusBarDisplay(cpuPercent: cpu, severity: sev, force: true)
    }

    @objc public func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            if let appAppearance = NSApp.appearance {
                popover.appearance = appAppearance
            }
            if safetyPolicy == .production {
                coordinator.setPopoverVisible(true)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if safetyPolicy == .production {
                startOutsideClickMonitor()
            }
        }
    }

    public func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if safetyPolicy == .production {
            coordinator.setPopoverVisible(false)
        }
        stopOutsideClickMonitor()
    }

    public var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    public var statusButtonForVisualQAIfAvailable: NSStatusBarButton? {
        statusItem.button
    }

    public func setShowBackgroundProcesses(_ showBackground: Bool) {
        popoverViewController.setShowBackgroundProcesses(showBackground)
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        if safetyPolicy == .production {
            coordinator.setPopoverVisible(false)
        }
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
