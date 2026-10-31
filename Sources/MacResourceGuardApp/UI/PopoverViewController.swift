import AppKit
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

/// Lightweight, static progress bar view that draws using CoreAnimation layers without software rasterization.
final class StaticLevelBarView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    var fraction: Double = 0.0 {
        didSet {
            updateFillFrame()
        }
    }

    var fillColor: NSColor = .systemGreen {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.backgroundColor = fillColor.cgColor
            CATransaction.commit()
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 3

        trackLayer.masksToBounds = true
        trackLayer.cornerRadius = 3
        layer?.addSublayer(trackLayer)

        fillLayer.masksToBounds = true
        fillLayer.cornerRadius = 3
        fillLayer.backgroundColor = fillColor.cgColor
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = bounds.height / 2.0
        layer?.cornerRadius = r
        trackLayer.frame = bounds
        trackLayer.cornerRadius = r
        trackLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        updateFillFrame()
        CATransaction.commit()
    }

    private func updateFillFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = bounds.height / 2.0
        fillLayer.cornerRadius = r
        if fraction > 0.005 {
            let fillWidth = max(bounds.height, bounds.width * CGFloat(min(1.0, max(0.0, fraction))))
            fillLayer.frame = NSRect(x: 0, y: 0, width: min(bounds.width, fillWidth), height: bounds.height)
            fillLayer.isHidden = false
        } else {
            fillLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Adaptive root view for the popover that provides a clean material surface in both Light and Dark appearances.
final class PopoverSurfaceView: NSView {
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 0.96)
            : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 0.96)
        bgColor.setFill()
        dirtyRect.fill()
    }
}

/// Native AppKit card container that adapts automatically to Light and Dark appearances with zero dirty-rect artifacts.
final class AdaptiveCardView: NSView {
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
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
        layer?.cornerRadius = 10
    }
}

/// Compact native macOS menu bar popover controller.
public final class PopoverViewController: NSViewController {
    private let coordinator: AdaptiveMonitorCoordinator
    private let settings: AppSettingsStore
    private let terminator: SafeAppTerminator

    // Header
    private let statusIconView = NSImageView()
    private let statusTitleLabel = NSTextField(labelWithString: "Mac Resource Guard")
    private let statusBadgeLabel = NSTextField(labelWithString: "Normal")
    private let statusBadgeContainer = NSView()
    private let statusSubtitleLabel = NSTextField(wrappingLabelWithString: "Monitoring system resources…")

    // CPU Overview Card
    private let cpuValueLabel = NSTextField(labelWithString: "0.0%")
    private let cpuBarView = StaticLevelBarView()
    private let cpuDetailLabel = NSTextField(labelWithString: "User 0% • Sys 0%")
    private let cpuSecondaryDetailLabel = NSTextField(labelWithString: "Cores: -- • Idle: --")

    // Memory Pressure Overview Card
    private let memValueLabel = NSTextField(labelWithString: "Healthy")
    private let memBarView = StaticLevelBarView()
    private let memDetailPrimaryLabel = NSTextField(labelWithString: "Avail: -- • Comp: --")
    private let memDetailSecondaryLabel = NSTextField(labelWithString: "Cache: -- • Swap: --")

    // Top 3 Applications / Background Section
    private let categorySegmentedControl = NSSegmentedControl(labels: ["Top 3 Apps", "Top 3 Background"], trackingMode: .selectOne, target: nil, action: nil)
    private let sortSegmentedControl = NSSegmentedControl(labels: ["By CPU", "By Memory"], trackingMode: .selectOne, target: nil, action: nil)
    private var showBackgroundProcesses: Bool = false
    private var userManuallyChoseSort: Bool = false
    private var sortByMemory: Bool = false

    private let rowViews: [AppRowView] = [AppRowView(), AppRowView(), AppRowView()]
    private let emptyStateLabel = NSTextField(labelWithString: "Sampling active applications…")

    // Multi-selection & Batch Quit Bar
    private let selectAllCheckbox = NSButton(checkboxWithTitle: "Select All", target: nil, action: nil)
    private let hideSystemCheckbox = NSButton(checkboxWithTitle: "Hide macOS / System", target: nil, action: nil)
    private let actionFeedbackLabel = NSTextField(labelWithString: "")
    private let quitSelectedButton = NSButton(title: "Quit Selected", target: nil, action: nil)

    // Footer Toolbar
    private let alertsToggleButton = NSButton(title: "Enable Alerts", target: nil, action: nil)

    private var selectionModel = AppSelectionModel()
    private var awaitingForceQuitPIDs = Set<pid_t>()
    private var currentDisplayedApps: [AggregatedAppProcess] = []

    public var onOpenSettings: (() -> Void)?
    public var onPreferredContentSizeChanged: ((NSSize) -> Void)?

    public init(
        coordinator: AdaptiveMonitorCoordinator,
        settings: AppSettingsStore = .shared,
        terminator: SafeAppTerminator = .shared
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.terminator = terminator
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let rootView = PopoverSurfaceView(frame: NSRect(x: 0, y: 0, width: 424, height: 448))
        self.view = rootView
        buildLayout(in: rootView)
        updatePreferredContentSize()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        userManuallyChoseSort = false
        setActionFeedback("")
        hideSystemCheckbox.state = settings.hideMacOSSystemProcesses ? .on : .off
        updateAlertsToggleButton()
        if let snapshot = coordinator.latestSnapshot {
            applySnapshot(snapshot)
        }
        updatePreferredContentSize()
        // Prevent automatic blue focus ring on the first control when popover opens
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
    }

    public func updatePreferredContentSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        if fitting.height > 0 {
            let targetSize = NSSize(width: 424, height: ceil(fitting.height))
            if preferredContentSize != targetSize {
                preferredContentSize = targetSize
                onPreferredContentSizeChanged?(targetSize)
            }
        }
    }

    // MARK: - UI Construction

    private func buildLayout(in rootView: NSView) {
        // 1. Header Section
        statusIconView.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Status")
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        statusIconView.contentTintColor = .systemGreen
        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        statusTitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        statusTitleLabel.textColor = .labelColor

        statusBadgeContainer.wantsLayer = true
        statusBadgeContainer.layer?.cornerRadius = 6
        statusBadgeContainer.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        statusBadgeContainer.translatesAutoresizingMaskIntoConstraints = false

        statusBadgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        statusBadgeLabel.textColor = .systemGreen
        statusBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeContainer.addSubview(statusBadgeLabel)

        NSLayoutConstraint.activate([
            statusBadgeLabel.leadingAnchor.constraint(equalTo: statusBadgeContainer.leadingAnchor, constant: 8),
            statusBadgeLabel.trailingAnchor.constraint(equalTo: statusBadgeContainer.trailingAnchor, constant: -8),
            statusBadgeLabel.topAnchor.constraint(equalTo: statusBadgeContainer.topAnchor, constant: 2),
            statusBadgeLabel.bottomAnchor.constraint(equalTo: statusBadgeContainer.bottomAnchor, constant: -2)
        ])

        let headerTopRow = NSStackView(views: [statusIconView, statusTitleLabel, NSView(), statusBadgeContainer])
        headerTopRow.orientation = .horizontal
        headerTopRow.alignment = .centerY
        headerTopRow.spacing = 8

        statusSubtitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        statusSubtitleLabel.textColor = .secondaryLabelColor
        statusSubtitleLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [headerTopRow, statusSubtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerTopRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true

        // 2. Overview Cards (CPU & Memory Pressure side-by-side with equal height)
        let cpuCard = buildCPUCard()
        let memCard = buildMemoryCard()

        let cardsRow = NSStackView(views: [cpuCard, memCard])
        cardsRow.orientation = .horizontal
        cardsRow.distribution = .fillEqually
        cardsRow.alignment = .centerY
        cardsRow.spacing = 10
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        cpuCard.heightAnchor.constraint(equalTo: memCard.heightAnchor).isActive = true

        // 3. Top 3 Applications / Background Header + Sort Control
        categorySegmentedControl.selectedSegment = showBackgroundProcesses ? 1 : 0
        categorySegmentedControl.controlSize = .small
        categorySegmentedControl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        categorySegmentedControl.refusesFirstResponder = true
        categorySegmentedControl.target = self
        categorySegmentedControl.action = #selector(handleCategoryChanged)

        sortSegmentedControl.selectedSegment = 0
        sortSegmentedControl.controlSize = .small
        sortSegmentedControl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sortSegmentedControl.refusesFirstResponder = true
        sortSegmentedControl.target = self
        sortSegmentedControl.action = #selector(handleSortChanged)

        let topAppsHeaderRow = NSStackView(views: [categorySegmentedControl, NSView(), sortSegmentedControl])
        topAppsHeaderRow.orientation = .horizontal
        topAppsHeaderRow.alignment = .centerY

        // 4. Rows Stack
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        for row in rowViews {
            row.onToggleSelection = { [weak self] app, isSelected in
                self?.handleRowSelectionToggled(app: app, isSelected: isSelected)
            }
            row.onRequestQuit = { [weak self] app, isForce in
                self?.handleRowQuitRequested(app: app, isForce: isForce)
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        emptyStateLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        rowsStack.addArrangedSubview(emptyStateLabel)

        // 5. Batch Selection, Hide System Checkbox & Quit Bar
        selectAllCheckbox.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        selectAllCheckbox.refusesFirstResponder = true
        selectAllCheckbox.setAccessibilityLabel("Select all eligible applications")
        selectAllCheckbox.target = self
        selectAllCheckbox.action = #selector(handleSelectAllClicked)

        hideSystemCheckbox.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        hideSystemCheckbox.refusesFirstResponder = true
        hideSystemCheckbox.state = settings.hideMacOSSystemProcesses ? .on : .off
        hideSystemCheckbox.toolTip = "Hide macOS system apps, services, and background daemons from Top 3 Apps and Top 3 Background."
        hideSystemCheckbox.setAccessibilityLabel("Hide macOS system processes and components")
        hideSystemCheckbox.target = self
        hideSystemCheckbox.action = #selector(handleHideSystemToggled)

        actionFeedbackLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        actionFeedbackLabel.textColor = .systemBlue
        actionFeedbackLabel.lineBreakMode = .byTruncatingTail
        actionFeedbackLabel.isHidden = true

        quitSelectedButton.bezelStyle = .rounded
        quitSelectedButton.controlSize = .small
        quitSelectedButton.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        quitSelectedButton.isEnabled = false
        quitSelectedButton.setAccessibilityLabel("Quit all selected applications")
        quitSelectedButton.target = self
        quitSelectedButton.action = #selector(handleQuitSelectedClicked)

        let batchBar = NSStackView(views: [selectAllCheckbox, hideSystemCheckbox, NSView(), quitSelectedButton])
        batchBar.orientation = .horizontal
        batchBar.alignment = .centerY
        batchBar.spacing = 10

        // 6. Divider + Footer Actions
        let divider = NSBox()
        divider.boxType = .separator

        let activityMonitorBtn = NSButton(title: "Activity Monitor", target: self, action: #selector(handleOpenActivityMonitor))
        activityMonitorBtn.bezelStyle = .rounded
        activityMonitorBtn.controlSize = .small
        activityMonitorBtn.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        activityMonitorBtn.setAccessibilityLabel("Open Activity Monitor utility")

        alertsToggleButton.bezelStyle = .rounded
        alertsToggleButton.controlSize = .small
        alertsToggleButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        alertsToggleButton.refusesFirstResponder = true
        alertsToggleButton.setAccessibilityLabel("Toggle system resource alerts")
        alertsToggleButton.target = self
        alertsToggleButton.action = #selector(handleToggleAlertsClicked)
        updateAlertsToggleButton()

        let settingsBtn = NSButton(title: "Settings…", target: self, action: #selector(handleOpenSettings))
        settingsBtn.bezelStyle = .rounded
        settingsBtn.controlSize = .small
        settingsBtn.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        settingsBtn.setAccessibilityLabel("Open Mac Resource Guard Settings")

        let quitAppBtn = NSButton(title: "Quit Guard", target: self, action: #selector(handleQuitGuardApp))
        quitAppBtn.bezelStyle = .rounded
        quitAppBtn.controlSize = .small
        quitAppBtn.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        quitAppBtn.setAccessibilityLabel("Quit Mac Resource Guard utility")

        let footerBar = NSStackView(views: [activityMonitorBtn, alertsToggleButton, NSView(), settingsBtn, quitAppBtn])
        footerBar.orientation = .horizontal
        footerBar.alignment = .centerY
        footerBar.spacing = 6

        // Main Vertical Stack
        let mainStack = NSStackView(views: [
            headerStack,
            cardsRow,
            topAppsHeaderRow,
            rowsStack,
            batchBar,
            actionFeedbackLabel,
            divider,
            footerBar
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(mainStack)

        for sub in [headerStack, cardsRow, topAppsHeaderRow, rowsStack, batchBar, actionFeedbackLabel, divider, footerBar] {
            sub.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }

        let safeArea = rootView.safeAreaLayoutGuide
        let safeTop = mainStack.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 18)
        safeTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            safeTop,
            mainStack.topAnchor.constraint(greaterThanOrEqualTo: rootView.topAnchor, constant: 18),
            mainStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -14),
            rootView.widthAnchor.constraint(equalToConstant: 424)
        ])
    }

    private func buildCPUCard() -> NSView {
        let card = AdaptiveCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "CPU LOAD")
        title.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        title.textColor = .secondaryLabelColor
        title.refusesFirstResponder = true

        cpuValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        cpuValueLabel.textColor = .labelColor
        cpuValueLabel.refusesFirstResponder = true

        cpuBarView.translatesAutoresizingMaskIntoConstraints = false
        cpuBarView.heightAnchor.constraint(equalToConstant: 6).isActive = true

        cpuDetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        cpuDetailLabel.textColor = .secondaryLabelColor
        cpuDetailLabel.lineBreakMode = .byTruncatingTail
        cpuDetailLabel.refusesFirstResponder = true

        cpuSecondaryDetailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        cpuSecondaryDetailLabel.textColor = .secondaryLabelColor
        cpuSecondaryDetailLabel.lineBreakMode = .byTruncatingTail
        cpuSecondaryDetailLabel.refusesFirstResponder = true

        let stack = NSStackView(views: [title, cpuValueLabel, cpuBarView, cpuDetailLabel, cpuSecondaryDetailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        cpuBarView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }

    private func buildMemoryCard() -> NSView {
        let card = AdaptiveCardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "MEMORY PRESSURE")
        title.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        title.textColor = .secondaryLabelColor
        title.refusesFirstResponder = true

        memValueLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        memValueLabel.textColor = .labelColor
        memValueLabel.lineBreakMode = .byTruncatingTail
        memValueLabel.refusesFirstResponder = true

        memBarView.translatesAutoresizingMaskIntoConstraints = false
        memBarView.heightAnchor.constraint(equalToConstant: 6).isActive = true

        memDetailPrimaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        memDetailPrimaryLabel.textColor = .secondaryLabelColor
        memDetailPrimaryLabel.lineBreakMode = .byTruncatingTail
        memDetailPrimaryLabel.refusesFirstResponder = true

        memDetailSecondaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        memDetailSecondaryLabel.textColor = .secondaryLabelColor
        memDetailSecondaryLabel.lineBreakMode = .byTruncatingTail
        memDetailSecondaryLabel.refusesFirstResponder = true

        let stack = NSStackView(views: [title, memValueLabel, memBarView, memDetailPrimaryLabel, memDetailSecondaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        memBarView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }

    // MARK: - Applying Live Snapshots

    public func applySnapshot(_ snapshot: SystemSnapshot) {
        guard isViewLoaded else { return }

        // 1. Update Header Status
        let statusColor: NSColor
        let symbolName: String
        switch snapshot.severity {
        case .normal:
            statusColor = .systemGreen
            symbolName = "checkmark.shield.fill"
        case .elevated:
            statusColor = .systemOrange
            symbolName = "exclamationmark.triangle.fill"
        case .critical:
            statusColor = .systemRed
            symbolName = "exclamationmark.octagon.fill"
        }

        statusIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: snapshot.severity.badgeText)
        statusIconView.contentTintColor = statusColor
        statusTitleLabel.stringValue = snapshot.primaryPressureKind.displayName
        statusBadgeLabel.stringValue = snapshot.severity.badgeText
        statusBadgeLabel.textColor = statusColor
        statusBadgeContainer.layer?.backgroundColor = statusColor.withAlphaComponent(0.16).cgColor

        if !settings.notificationsEnabled {
            statusSubtitleLabel.stringValue = "\(snapshot.statusSummary) • Alerts disabled"
        } else if settings.isCurrentlyPaused() {
            statusSubtitleLabel.stringValue = "Alerts paused temporarily. \(snapshot.statusSummary)"
        } else if settings.doNotDisturbEnabled {
            statusSubtitleLabel.stringValue = "Do Not Disturb active. \(snapshot.statusSummary)"
        } else if snapshot.hasIncompleteProcessMetrics {
            statusSubtitleLabel.stringValue = "\(snapshot.statusSummary) (Some OS process metrics restricted)"
        } else {
            statusSubtitleLabel.stringValue = snapshot.statusSummary
        }
        updateAlertsToggleButton()

        // 2. Update CPU Card
        cpuValueLabel.stringValue = ByteFormatter.formatPercent(snapshot.cpuTotalPercent)
        cpuBarView.fraction = snapshot.cpuTotalPercent / 100.0
        if snapshot.cpuTotalPercent >= settings.cpuWarningThresholdPercent {
            cpuBarView.fillColor = .systemRed
        } else if snapshot.cpuTotalPercent >= settings.cpuWarningThresholdPercent - 15.0 {
            cpuBarView.fillColor = .systemOrange
        } else {
            cpuBarView.fillColor = .systemGreen
        }
        cpuDetailLabel.stringValue = String(
            format: "User %.0f%% • Sys %.0f%%",
            snapshot.cpuUserPercent,
            snapshot.cpuSystemPercent
        )
        let idlePercent = max(0.0, 100.0 - snapshot.cpuTotalPercent)
        cpuSecondaryDetailLabel.stringValue = String(
            format: "Idle %.0f%% • %d Logical Cores",
            idlePercent,
            snapshot.coreCount
        )

        // 3. Update Memory Pressure Card
        let mem = snapshot.memory
        memValueLabel.stringValue = mem.pressureLevel.title
        switch mem.pressureLevel {
        case .normal:
            memBarView.fillColor = .systemGreen
            let usedPressureRatio = 1.0 - (Double(mem.availableBytes) / Double(max(1, mem.totalPhysicalBytes)))
            memBarView.fraction = max(0.12, min(0.65, usedPressureRatio * 0.7))
        case .elevated:
            memBarView.fillColor = .systemOrange
            memBarView.fraction = 0.78
        case .critical:
            memBarView.fillColor = .systemRed
            memBarView.fraction = 0.96
        }

        memDetailPrimaryLabel.stringValue = "Avail: \(ByteFormatter.formatBytes(mem.availableBytes)) • Comp: \(ByteFormatter.formatBytes(mem.compressedBytes))"
        memDetailSecondaryLabel.stringValue = "Cache: \(ByteFormatter.formatBytes(mem.cachedFilesBytes)) • Swap: \(ByteFormatter.formatBytes(mem.swapUsedBytes))"

        // 4. Auto-select sort order if user hasn't manually overridden it during this popover session
        if !userManuallyChoseSort {
            let shouldSortByMemory = (snapshot.primaryPressureKind == .memory)
            if sortByMemory != shouldSortByMemory {
                sortByMemory = shouldSortByMemory
                sortSegmentedControl.selectedSegment = shouldSortByMemory ? 1 : 0
            }
        }

        updateDisplayedApplications(from: snapshot)
    }

    private func updateDisplayedApplications(from snapshot: SystemSnapshot) {
        let rawApps: [AggregatedAppProcess]
        if showBackgroundProcesses {
            rawApps = sortByMemory ? snapshot.topBackgroundByMemory : snapshot.topBackgroundByCPU
        } else {
            rawApps = sortByMemory ? snapshot.topAppsByMemory : snapshot.topAppsByCPU
        }

        let filteredApps: [AggregatedAppProcess]
        if settings.hideMacOSSystemProcesses {
            filteredApps = rawApps.filter { !$0.isMacOSSystemRelated }
        } else {
            filteredApps = rawApps
        }
        let apps = Array(filteredApps.prefix(3))

        self.currentDisplayedApps = apps
        selectionModel.reconcile(with: apps)

        let livePIDs = Set(apps.map { $0.id })
        awaitingForceQuitPIDs.formIntersection(livePIDs)

        if apps.isEmpty {
            for row in rowViews { row.isHidden = true }
            emptyStateLabel.isHidden = false
            if settings.hideMacOSSystemProcesses {
                emptyStateLabel.stringValue = showBackgroundProcesses
                    ? "No non-macOS background processes detected."
                    : "No non-macOS user applications detected."
            } else {
                emptyStateLabel.stringValue = showBackgroundProcesses
                    ? "No heavy background processes detected."
                    : "No active user applications detected."
            }
        } else {
            emptyStateLabel.isHidden = true
            for (index, row) in rowViews.enumerated() {
                if index < apps.count {
                    let app = apps[index]
                    row.isHidden = false
                    row.configure(
                        with: app,
                        sortByMemory: sortByMemory,
                        isSelected: selectionModel.isSelected(app.id),
                        awaitingForceQuit: awaitingForceQuitPIDs.contains(app.id)
                    )
                } else {
                    row.isHidden = true
                }
            }
        }

        syncSelectionControls()
    }

    private func syncSelectionControls() {
        let eligibleCount = currentDisplayedApps.filter { $0.canSafelyClose }.count
        selectAllCheckbox.isEnabled = eligibleCount > 0
        selectAllCheckbox.state = selectionModel.areAllEligibleSelected(in: currentDisplayedApps) ? .on : .off

        let selectedApps = selectionModel.selectedApplications(in: currentDisplayedApps)
        if selectedApps.isEmpty {
            quitSelectedButton.title = "Quit Selected"
            quitSelectedButton.isEnabled = false
        } else {
            quitSelectedButton.title = "Quit Selected (\(selectedApps.count))"
            quitSelectedButton.isEnabled = true
        }
    }

    // MARK: - User Actions

    public func setShowBackgroundProcesses(_ showBackground: Bool) {
        showBackgroundProcesses = showBackground
        if isViewLoaded {
            categorySegmentedControl.selectedSegment = showBackground ? 1 : 0
            if let snapshot = coordinator.latestSnapshot {
                updateDisplayedApplications(from: snapshot)
            }
        }
    }

    @objc private func handleCategoryChanged() {
        showBackgroundProcesses = (categorySegmentedControl.selectedSegment == 1)
        selectionModel.clearAll()
        if let snapshot = coordinator.latestSnapshot {
            updateDisplayedApplications(from: snapshot)
        }
    }

    @objc private func handleSortChanged() {
        userManuallyChoseSort = true
        sortByMemory = (sortSegmentedControl.selectedSegment == 1)
        if let snapshot = coordinator.latestSnapshot {
            updateDisplayedApplications(from: snapshot)
        }
    }

    private func handleRowSelectionToggled(app: AggregatedAppProcess, isSelected: Bool) {
        selectionModel.setSelected(isSelected, for: app)
        if let snapshot = coordinator.latestSnapshot {
            updateDisplayedApplications(from: snapshot)
        }
    }

    @objc private func handleSelectAllClicked() {
        if selectAllCheckbox.state == .on {
            selectionModel.selectAllEligible(in: currentDisplayedApps)
        } else {
            selectionModel.clearAll()
        }
        if let snapshot = coordinator.latestSnapshot {
            updateDisplayedApplications(from: snapshot)
        }
    }

    @objc private func handleHideSystemToggled() {
        settings.hideMacOSSystemProcesses = (hideSystemCheckbox.state == .on)
        selectionModel.clearAll()
        if let snapshot = coordinator.latestSnapshot {
            updateDisplayedApplications(from: snapshot)
        }
    }

    private func setActionFeedback(_ message: String) {
        actionFeedbackLabel.stringValue = message
        actionFeedbackLabel.isHidden = message.isEmpty
        updatePreferredContentSize()
    }

    private func handleRowQuitRequested(app: AggregatedAppProcess, isForce: Bool) {
        if isForce {
            confirmAndForceQuit(app: app)
            return
        }

        setActionFeedback("Requesting \(app.displayName) to quit…")
        terminator.requestGracefulQuit(for: app) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .terminatedSmoothly, .alreadyExited:
                self.setActionFeedback("Closed \(app.displayName).")
                self.awaitingForceQuitPIDs.remove(app.id)
                self.selectionModel.setSelected(false, for: app)
                self.coordinator.requestImmediateRefresh(detailed: true)
            case .awaitingUserOrUnresponsive:
                self.setActionFeedback("\(app.displayName) is still open (save prompt or busy).")
                self.awaitingForceQuitPIDs.insert(app.id)
                if let snap = self.coordinator.latestSnapshot {
                    self.updateDisplayedApplications(from: snap)
                }
            case .deniedProtectedProcess(let reason):
                self.setActionFeedback("Protected: \(reason)")
            case .abortedPIDReuseDetected:
                self.setActionFeedback("Process changed; refreshing list…")
                self.coordinator.requestImmediateRefresh(detailed: true)
            case .forceTerminated:
                self.setActionFeedback("Force quit \(app.displayName).")
                self.coordinator.requestImmediateRefresh(detailed: true)
            case .failed(let reason):
                self.setActionFeedback("Could not quit: \(reason)")
            }
        }
    }

    private func confirmAndForceQuit(app: AggregatedAppProcess) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force Quit \(app.displayName)?"
        alert.informativeText = "If \(app.displayName) has unsaved changes, forcing it to quit will lose those changes. Prefer closing any open Save dialogs in the app first."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let outcome = terminator.forceQuitAfterConfirmation(for: app)
        switch outcome {
        case .forceTerminated, .alreadyExited:
            awaitingForceQuitPIDs.remove(app.id)
            selectionModel.setSelected(false, for: app)
            setActionFeedback("Force quit \(app.displayName).")
            coordinator.requestImmediateRefresh(detailed: true)
        case .deniedProtectedProcess(let reason):
            setActionFeedback("Protected: \(reason)")
        case .abortedPIDReuseDetected:
            setActionFeedback("PID changed; refreshing…")
            coordinator.requestImmediateRefresh(detailed: true)
        default:
            setActionFeedback("Force quit failed.")
        }
    }

    @objc private func handleQuitSelectedClicked() {
        let selected = selectionModel.selectedApplications(in: currentDisplayedApps)
        guard !selected.isEmpty else { return }

        setActionFeedback("Quitting \(selected.count) selected app(s)…")
        let group = DispatchGroup()
        var closedCount = 0
        var stillOpenCount = 0

        for app in selected {
            group.enter()
            terminator.requestGracefulQuit(for: app) { [weak self] result in
                switch result {
                case .terminatedSmoothly, .alreadyExited:
                    closedCount += 1
                    self?.selectionModel.setSelected(false, for: app)
                    self?.awaitingForceQuitPIDs.remove(app.id)
                case .awaitingUserOrUnresponsive:
                    stillOpenCount += 1
                    self?.awaitingForceQuitPIDs.insert(app.id)
                default:
                    break
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if stillOpenCount > 0 {
                self.setActionFeedback("Closed \(closedCount); \(stillOpenCount) awaiting save/response.")
            } else {
                self.setActionFeedback("Closed \(closedCount) application(s).")
            }
            self.coordinator.requestImmediateRefresh(detailed: true)
        }
    }

    @objc private func handleOpenActivityMonitor() {
        let activityMonitorURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: activityMonitorURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func updateAlertsToggleButton() {
        let alertsActive = settings.notificationsEnabled && !settings.doNotDisturbEnabled && !settings.isCurrentlyPaused()
        if alertsActive {
            alertsToggleButton.title = "Disable Alerts"
            alertsToggleButton.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "Alerts Active")
            alertsToggleButton.imagePosition = .imageLeading
            alertsToggleButton.contentTintColor = .systemGreen
        } else {
            alertsToggleButton.title = "Enable Alerts"
            alertsToggleButton.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Alerts Disabled")
            alertsToggleButton.imagePosition = .imageLeading
            alertsToggleButton.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func handleToggleAlertsClicked() {
        let currentlyActive = settings.notificationsEnabled && !settings.doNotDisturbEnabled && !settings.isCurrentlyPaused()
        if currentlyActive {
            settings.notificationsEnabled = false
            setActionFeedback("Alerts disabled.")
        } else {
            settings.notificationsEnabled = true
            settings.doNotDisturbEnabled = false
            settings.resumeMonitoring()
            setActionFeedback("Alerts enabled.")
        }
        updateAlertsToggleButton()
        if let snap = coordinator.latestSnapshot {
            applySnapshot(snap)
        }
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleQuitGuardApp() {
        NSApplication.shared.terminate(nil)
    }
}
