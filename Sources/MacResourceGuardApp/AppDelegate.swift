import AppKit
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettingsStore.shared
    private var coordinator: AdaptiveMonitorCoordinator!
    private var statusBarController: StatusBarController!
    private var settingsWindowController: SettingsWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure no permanent Dock icon is shown
        NSApp.setActivationPolicy(.accessory)

        applyAppearanceOverrideIfRequested()
        let visualQAScenario = VisualQAScenario.launchScenario(in: CommandLine.arguments)
        let safetyPolicy: VisualQASafetyPolicy = visualQAScenario == nil ? .production : .visualQAMode

        let monitor = AdaptiveMonitorCoordinator(settings: settings)
        self.coordinator = monitor

        let barController = StatusBarController(
            coordinator: monitor,
            settings: settings,
            safetyPolicy: safetyPolicy
        )
        barController.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        self.statusBarController = barController

        if let scenario = visualQAScenario {
            barController.applyVisualQAScenario(scenario)
        } else {
            NotificationManager.shared.configureIfPossible()
            NotificationManager.shared.onUserClickedNotification = { [weak self] in
                self?.statusBarController.showPopover()
            }

            monitor.onSnapshotUpdate = { [weak self] snapshot in
                self?.statusBarController.handleSnapshot(snapshot)
            }

            monitor.onAlertTriggered = { [weak self] alert, snapshot in
                self?.statusBarController.handleSnapshot(snapshot)
                NotificationManager.shared.postAlertNotification(alert)
            }

            if settings.startMonitoringAutomatically {
                monitor.start()
            }
        }

        handleQALaunchArgumentsIfPresent(scenario: visualQAScenario)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings)
        }
        settingsWindowController?.showAndActivate()
    }

    // MARK: - Optional Visual QA Automation Hooks

    private func applyAppearanceOverrideIfRequested() {
        switch VisualQAAppearance.launchAppearance(in: CommandLine.arguments) {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .highContrastLight:
            NSApp.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        case .highContrastDark:
            NSApp.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        case nil:
            break
        }
    }

    private func handleQALaunchArgumentsIfPresent(scenario: VisualQAScenario?) {
        let args = CommandLine.arguments
        if scenario != nil || args.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if scenario != nil {
                    NSApp.activate(ignoringOtherApps: true)
                }
                self?.statusBarController.showPopover()
            }
        }
        if args.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSettingsWindow()
            }
        }

        // Optional automated view snapshot export for visual QA verification
        for arg in args {
            if arg.hasPrefix("--export-popover-png=") {
                let outputPath = String(arg.dropFirst("--export-popover-png=".count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    if let scenario {
                        self?.statusBarController.applyVisualQAScenario(scenario)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    self?.statusBarController.showPopover()
                    if args.contains("--show-background") {
                        self?.statusBarController.setShowBackgroundProcesses(true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self = self,
                              let contentView = self.statusBarController.popoverWindow?.contentView else { return }
                        Self.saveViewPNG(view: contentView, to: outputPath)
                        if args.contains("--quit-after-export") {
                            NSApp.terminate(nil)
                        }
                    }
                }
            } else if arg.hasPrefix("--export-settings-png=") {
                let outputPath = String(arg.dropFirst("--export-settings-png=".count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.showSettingsWindow()
                    if args.contains("--settings-tab=1") {
                        self?.settingsWindowController?.selectTab(index: 1)
                    } else if args.contains("--settings-tab=2") {
                        self?.settingsWindowController?.selectTab(index: 2)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self = self,
                              let contentView = self.settingsWindowController?.window?.contentView else { return }
                        Self.saveViewPNG(view: contentView, to: outputPath)
                        if args.contains("--quit-after-export") {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    private static func saveViewPNG(view: NSView, to path: String) {
        if let appAppearance = NSApp.appearance {
            view.window?.appearance = appAppearance
            view.appearance = appAppearance
        }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }

        // Render adaptive background behind translucent popover/window views for crisp offscreen capture
        let composed = NSImage(size: bounds.size)
        composed.lockFocus()
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1.0)
            : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        bgColor.setFill()
        bounds.fill()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        rep.draw(in: bounds)
        composed.unlockFocus()

        guard let tiff = composed.tiffRepresentation,
              let finalRep = NSBitmapImageRep(data: tiff),
              let pngData = finalRep.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: URL(fileURLWithPath: path))
    }
}
