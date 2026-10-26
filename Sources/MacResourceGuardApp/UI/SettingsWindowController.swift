import AppKit
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

/// Native AppKit Settings window with General, Monitoring, and Notifications tabs.
public final class SettingsWindowController: NSWindowController {
    private let settings: AppSettingsStore

    // General controls
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Mac Resource Guard at login", target: nil, action: nil)
    private let showCPUPercentCheckbox = NSButton(checkboxWithTitle: "Show compact CPU percentage in menu bar", target: nil, action: nil)
    private let autoStartMonitoringCheckbox = NSButton(checkboxWithTitle: "Start monitoring automatically on launch", target: nil, action: nil)

    // Monitoring controls
    private let sensitivityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cpuAlertsCheckbox = NSButton(checkboxWithTitle: "Enable sustained CPU usage alerts", target: nil, action: nil)
    private let cpuThresholdSlider = NSSlider(value: 85.0, minValue: 50.0, maxValue: 95.0, target: nil, action: nil)
    private let cpuThresholdValueLabel = NSTextField(labelWithString: "85%")
    private let cpuDurationSlider = NSSlider(value: 25.0, minValue: 10.0, maxValue: 60.0, target: nil, action: nil)
    private let cpuDurationValueLabel = NSTextField(labelWithString: "25s")
    private let memoryAlertsCheckbox = NSButton(checkboxWithTitle: "Enable intelligent memory-pressure alerts", target: nil, action: nil)
    private let frequencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Notifications controls
    private let enableNotificationsCheckbox = NSButton(checkboxWithTitle: "Enable macOS notifications", target: nil, action: nil)
    private let dndCheckbox = NSButton(checkboxWithTitle: "Do Not Disturb (suppress all alert banners)", target: nil, action: nil)
    private let cooldownPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pauseStatusLabel = NSTextField(labelWithString: "Alerts are currently active.")

    private let frequencyValues: [TimeInterval] = [5.0, 10.0, 15.0, 30.0, 60.0]
    private let cooldownValues: [TimeInterval] = [60.0, 180.0, 300.0, 600.0, 900.0, 1800.0]

    public init(settings: AppSettingsStore = .shared) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Resource Guard Settings"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildTabs(in: window)
        refreshControlsFromSettings()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshControlsFromSettings),
            name: AppSettingsStore.didChangeNotification,
            object: settings
        )
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func showAndActivate() {
        if let appAppearance = NSApp.appearance {
            window?.appearance = appAppearance
        }
        refreshControlsFromSettings()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Tab View Construction

    private let tabSegmentedControl = NSSegmentedControl(labels: ["General", "Monitoring", "Notifications"], trackingMode: .selectOne, target: nil, action: nil)
    private let tabView = NSTabView(frame: .zero)

    private func buildTabs(in window: NSWindow) {
        if let appAppearance = NSApp.appearance {
            window.appearance = appAppearance
        }

        tabSegmentedControl.selectedSegment = 0
        tabSegmentedControl.controlSize = .regular
        tabSegmentedControl.target = self
        tabSegmentedControl.action = #selector(handleTabSegmentChanged)
        tabSegmentedControl.translatesAutoresizingMaskIntoConstraints = false

        tabView.tabViewType = .noTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "General"
        generalItem.view = buildGeneralTab()

        let monitoringItem = NSTabViewItem(identifier: "monitoring")
        monitoringItem.label = "Monitoring"
        monitoringItem.view = buildMonitoringTab()

        let notificationsItem = NSTabViewItem(identifier: "notifications")
        notificationsItem.label = "Notifications"
        notificationsItem.view = buildNotificationsTab()

        tabView.addTabViewItem(generalItem)
        tabView.addTabViewItem(monitoringItem)
        tabView.addTabViewItem(notificationsItem)

        let container = PopoverSurfaceView(frame: NSRect(x: 0, y: 0, width: 460, height: 350))
        container.addSubview(tabSegmentedControl)
        container.addSubview(tabView)
        window.contentView = container

        NSLayoutConstraint.activate([
            tabSegmentedControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            tabSegmentedControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            tabSegmentedControl.widthAnchor.constraint(equalToConstant: 300),

            tabView.topAnchor.constraint(equalTo: tabSegmentedControl.bottomAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
    }

    @objc private func handleTabSegmentChanged() {
        tabView.selectTabViewItem(at: tabSegmentedControl.selectedSegment)
    }

    public func selectTab(index: Int) {
        guard index >= 0 && index < tabSegmentedControl.segmentCount else { return }
        tabSegmentedControl.selectedSegment = index
        tabView.selectTabViewItem(at: index)
    }

    private func buildGeneralTab() -> NSView {
        let view = NSView()

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(handleGeneralChanged)

        showCPUPercentCheckbox.target = self
        showCPUPercentCheckbox.action = #selector(handleGeneralChanged)

        autoStartMonitoringCheckbox.target = self
        autoStartMonitoringCheckbox.action = #selector(handleGeneralChanged)

        let privacyNote = NSTextField(wrappingLabelWithString: "100% Local & Private: All monitoring occurs locally on your Mac using low-level Mach kernel APIs. Zero network requests, zero analytics, and zero telemetry.")
        privacyNote.font = NSFont.systemFont(ofSize: 11.5)
        privacyNote.textColor = .secondaryLabelColor

        let quitBtn = NSButton(title: "Quit Mac Resource Guard", target: self, action: #selector(handleQuitApp))
        quitBtn.bezelStyle = .rounded

        let stack = NSStackView(views: [
            launchAtLoginCheckbox,
            showCPUPercentCheckbox,
            autoStartMonitoringCheckbox,
            privacyNote,
            quitBtn
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        return view
    }

    private func buildMonitoringTab() -> NSView {
        let view = NSView()

        for preset in AlertSensitivityPreset.allCases {
            sensitivityPopup.addItem(withTitle: preset.displayName)
        }
        sensitivityPopup.target = self
        sensitivityPopup.action = #selector(handleSensitivityPresetChanged)

        let presetRow = labeledRow(label: "Alert Sensitivity:", control: sensitivityPopup)

        cpuAlertsCheckbox.target = self
        cpuAlertsCheckbox.action = #selector(handleMonitoringChanged)

        cpuThresholdSlider.target = self
        cpuThresholdSlider.action = #selector(handleCPUSlidersChanged)
        cpuThresholdValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        cpuThresholdValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let threshControlRow = NSStackView(views: [cpuThresholdSlider, cpuThresholdValueLabel])
        threshControlRow.orientation = .horizontal
        threshControlRow.spacing = 8
        let threshRow = labeledRow(label: "CPU Warning Threshold:", control: threshControlRow)

        cpuDurationSlider.target = self
        cpuDurationSlider.action = #selector(handleCPUSlidersChanged)
        cpuDurationValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        cpuDurationValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let durControlRow = NSStackView(views: [cpuDurationSlider, cpuDurationValueLabel])
        durControlRow.orientation = .horizontal
        durControlRow.spacing = 8
        let durRow = labeledRow(label: "Sustained Duration:", control: durControlRow)

        memoryAlertsCheckbox.target = self
        memoryAlertsCheckbox.action = #selector(handleMonitoringChanged)

        frequencyPopup.addItems(withTitles: [
            "Every 5 seconds (Fast)",
            "Every 10 seconds (Recommended)",
            "Every 15 seconds",
            "Every 30 seconds (Ultra-Low Power)",
            "Every 60 seconds"
        ])
        frequencyPopup.target = self
        frequencyPopup.action = #selector(handleFrequencyChanged)
        let freqRow = labeledRow(label: "Background Interval:", control: frequencyPopup)

        let stack = NSStackView(views: [
            presetRow,
            cpuAlertsCheckbox,
            threshRow,
            durRow,
            memoryAlertsCheckbox,
            freqRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
        ])
        return view
    }

    private func buildNotificationsTab() -> NSView {
        let view = NSView()

        enableNotificationsCheckbox.target = self
        enableNotificationsCheckbox.action = #selector(handleNotificationsChanged)

        dndCheckbox.target = self
        dndCheckbox.action = #selector(handleNotificationsChanged)

        cooldownPopup.addItems(withTitles: [
            "1 minute",
            "3 minutes",
            "5 minutes (Default)",
            "10 minutes",
            "15 minutes",
            "30 minutes"
        ])
        cooldownPopup.target = self
        cooldownPopup.action = #selector(handleCooldownChanged)
        let cooldownRow = labeledRow(label: "Alert Cooldown:", control: cooldownPopup)

        let pause15Btn = NSButton(title: "Pause 15m", target: self, action: #selector(handlePause15m))
        pause15Btn.bezelStyle = .rounded
        let pause1hBtn = NSButton(title: "Pause 1h", target: self, action: #selector(handlePause1h))
        pause1hBtn.bezelStyle = .rounded
        let resumeBtn = NSButton(title: "Resume Now", target: self, action: #selector(handleResumeNow))
        resumeBtn.bezelStyle = .rounded

        let pauseButtonsRow = NSStackView(views: [pause15Btn, pause1hBtn, resumeBtn])
        pauseButtonsRow.orientation = .horizontal
        pauseButtonsRow.spacing = 8
        let pauseRow = labeledRow(label: "Temporary Pause:", control: pauseButtonsRow)

        pauseStatusLabel.font = NSFont.systemFont(ofSize: 11.5)
        pauseStatusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            enableNotificationsCheckbox,
            dndCheckbox,
            cooldownRow,
            pauseRow,
            pauseStatusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        return view
    }

    private func labeledRow(label: String, control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    // MARK: - Syncing State

    @objc private func refreshControlsFromSettings() {
        launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        showCPUPercentCheckbox.state = settings.showCPUPercentageInMenuBar ? .on : .off
        autoStartMonitoringCheckbox.state = settings.startMonitoringAutomatically ? .on : .off

        if let presetIdx = AlertSensitivityPreset.allCases.firstIndex(of: settings.sensitivityPreset) {
            sensitivityPopup.selectItem(at: presetIdx)
        }

        cpuAlertsCheckbox.state = settings.cpuAlertsEnabled ? .on : .off
        cpuThresholdSlider.doubleValue = settings.cpuWarningThresholdPercent
        cpuThresholdValueLabel.stringValue = "\(Int(settings.cpuWarningThresholdPercent.rounded()))%"

        cpuDurationSlider.doubleValue = settings.cpuSustainedDurationSeconds
        cpuDurationValueLabel.stringValue = "\(Int(settings.cpuSustainedDurationSeconds.rounded()))s"

        memoryAlertsCheckbox.state = settings.memoryAlertsEnabled ? .on : .off

        let currentFreq = settings.monitoringIntervalSeconds
        if let idx = frequencyValues.enumerated().min(by: { abs($0.element - currentFreq) < abs($1.element - currentFreq) })?.offset {
            frequencyPopup.selectItem(at: idx)
        }

        enableNotificationsCheckbox.state = settings.notificationsEnabled ? .on : .off
        dndCheckbox.state = settings.doNotDisturbEnabled ? .on : .off

        let currentCooldown = settings.notificationCooldownSeconds
        if let idx = cooldownValues.enumerated().min(by: { abs($0.element - currentCooldown) < abs($1.element - currentCooldown) })?.offset {
            cooldownPopup.selectItem(at: idx)
        }

        if let until = settings.pausedUntilDate {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            pauseStatusLabel.stringValue = "Monitoring alerts paused until \(formatter.string(from: until))."
        } else if settings.doNotDisturbEnabled {
            pauseStatusLabel.stringValue = "Do Not Disturb is enabled."
        } else {
            pauseStatusLabel.stringValue = "Alerts are currently active."
        }
    }

    // MARK: - Handlers

    @objc private func handleGeneralChanged() {
        let desiredLaunchAtLogin = (launchAtLoginCheckbox.state == .on)
        if desiredLaunchAtLogin != settings.launchAtLoginEnabled {
            settings.launchAtLoginEnabled = desiredLaunchAtLogin
        }
        settings.showCPUPercentageInMenuBar = (showCPUPercentCheckbox.state == .on)
        settings.startMonitoringAutomatically = (autoStartMonitoringCheckbox.state == .on)
    }

    @objc private func handleSensitivityPresetChanged() {
        let index = sensitivityPopup.indexOfSelectedItem
        guard index >= 0 && index < AlertSensitivityPreset.allCases.count else { return }
        settings.sensitivityPreset = AlertSensitivityPreset.allCases[index]
        refreshControlsFromSettings()
    }

    @objc private func handleCPUSlidersChanged() {
        let roundedThresh = cpuThresholdSlider.doubleValue.rounded()
        let roundedDur = (cpuDurationSlider.doubleValue / 5.0).rounded() * 5.0
        settings.cpuWarningThresholdPercent = roundedThresh
        settings.cpuSustainedDurationSeconds = max(10.0, roundedDur)
        refreshControlsFromSettings()
    }

    @objc private func handleMonitoringChanged() {
        settings.cpuAlertsEnabled = (cpuAlertsCheckbox.state == .on)
        settings.memoryAlertsEnabled = (memoryAlertsCheckbox.state == .on)
    }

    @objc private func handleFrequencyChanged() {
        let idx = frequencyPopup.indexOfSelectedItem
        guard idx >= 0 && idx < frequencyValues.count else { return }
        settings.monitoringIntervalSeconds = frequencyValues[idx]
    }

    @objc private func handleNotificationsChanged() {
        settings.notificationsEnabled = (enableNotificationsCheckbox.state == .on)
        settings.doNotDisturbEnabled = (dndCheckbox.state == .on)
        refreshControlsFromSettings()
    }

    @objc private func handleCooldownChanged() {
        let idx = cooldownPopup.indexOfSelectedItem
        guard idx >= 0 && idx < cooldownValues.count else { return }
        settings.notificationCooldownSeconds = cooldownValues[idx]
    }

    @objc private func handlePause15m() {
        settings.pauseFor(seconds: 15 * 60)
        refreshControlsFromSettings()
    }

    @objc private func handlePause1h() {
        settings.pauseFor(seconds: 60 * 60)
        refreshControlsFromSettings()
    }

    @objc private func handleResumeNow() {
        settings.resumeMonitoring()
        settings.doNotDisturbEnabled = false
        refreshControlsFromSettings()
    }

    @objc private func handleQuitApp() {
        NSApplication.shared.terminate(nil)
    }
}
