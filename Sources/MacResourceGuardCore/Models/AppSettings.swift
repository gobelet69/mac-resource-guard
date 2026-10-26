import Foundation
import ServiceManagement

/// Sensitivity presets for quick adjustment of alert thresholds and sustained durations.
public enum AlertSensitivityPreset: String, CaseIterable, Codable, Sendable {
    case low
    case balanced
    case high
    case custom

    public var displayName: String {
        switch self {
        case .low: return "Low (Conservative — 90% for 35s)"
        case .balanced: return "Balanced (Default — 85% for 25s)"
        case .high: return "High (Sensitive — 75% for 15s)"
        case .custom: return "Custom"
        }
    }

    public var defaultCPUThreshold: Double {
        switch self {
        case .low: return 90.0
        case .balanced: return 85.0
        case .high: return 75.0
        case .custom: return 85.0
        }
    }

    public var defaultSustainedSeconds: TimeInterval {
        switch self {
        case .low: return 35.0
        case .balanced: return 25.0
        case .high: return 15.0
        case .custom: return 25.0
        }
    }
}

/// Lightweight local preference store backed by UserDefaults with safe clamping and change notifications.
public final class AppSettingsStore {
    public static let shared = AppSettingsStore()
    public static let didChangeNotification = Notification.Name("MacResourceGuard.AppSettingsDidChange")

    private let defaults: UserDefaults

    private enum Keys {
        static let showCPUPercentageInMenuBar = "showCPUPercentageInMenuBar"
        static let startMonitoringAutomatically = "startMonitoringAutomatically"
        static let sensitivityPreset = "sensitivityPreset"
        static let cpuWarningThresholdPercent = "cpuWarningThresholdPercent"
        static let cpuSustainedDurationSeconds = "cpuSustainedDurationSeconds"
        static let cpuHysteresisMarginPercent = "cpuHysteresisMarginPercent"
        static let cpuAlertsEnabled = "cpuAlertsEnabled"
        static let memoryAlertsEnabled = "memoryAlertsEnabled"
        static let monitoringIntervalSeconds = "monitoringIntervalSeconds"
        static let notificationsEnabled = "alertsMasterEnabled_v2"
        static let notificationCooldownSeconds = "notificationCooldownSeconds"
        static let doNotDisturbEnabled = "doNotDisturbEnabled"
        static let pausedUntilTimestamp = "pausedUntilTimestamp"
        static let hideMacOSSystemProcesses = "hideMacOSSystemProcesses"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.showCPUPercentageInMenuBar: true,
            Keys.startMonitoringAutomatically: true,
            Keys.sensitivityPreset: AlertSensitivityPreset.balanced.rawValue,
            Keys.cpuWarningThresholdPercent: 85.0,
            Keys.cpuSustainedDurationSeconds: 25.0,
            Keys.cpuHysteresisMarginPercent: 10.0,
            Keys.cpuAlertsEnabled: true,
            Keys.memoryAlertsEnabled: true,
            Keys.monitoringIntervalSeconds: 10.0,
            Keys.notificationsEnabled: false,
            Keys.notificationCooldownSeconds: 300.0,
            Keys.doNotDisturbEnabled: false,
            Keys.hideMacOSSystemProcesses: false
        ])
    }

    // MARK: - General

    public var showCPUPercentageInMenuBar: Bool {
        get { defaults.bool(forKey: Keys.showCPUPercentageInMenuBar) }
        set {
            defaults.set(newValue, forKey: Keys.showCPUPercentageInMenuBar)
            notifyChange()
        }
    }

    public var startMonitoringAutomatically: Bool {
        get { defaults.bool(forKey: Keys.startMonitoringAutomatically) }
        set {
            defaults.set(newValue, forKey: Keys.startMonitoringAutomatically)
            notifyChange()
        }
    }

    /// Whether macOS system processes and Apple built-in services should be hidden from Top 3 Apps and Top 3 Background.
    public var hideMacOSSystemProcesses: Bool {
        get { defaults.bool(forKey: Keys.hideMacOSSystemProcesses) }
        set {
            defaults.set(newValue, forKey: Keys.hideMacOSSystemProcesses)
            notifyChange()
        }
    }

    /// Queries SMAppService for current Launch at Login status.
    public var launchAtLoginEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                // In unsigned/adhoc local development builds outside /Applications,
                // SMAppService registration may fail softly; handle gracefully without crashing.
            }
            notifyChange()
        }
    }

    // MARK: - Monitoring

    public var sensitivityPreset: AlertSensitivityPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.sensitivityPreset),
                  let preset = AlertSensitivityPreset(rawValue: raw) else {
                return .balanced
            }
            return preset
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.sensitivityPreset)
            if newValue != .custom {
                defaults.set(newValue.defaultCPUThreshold, forKey: Keys.cpuWarningThresholdPercent)
                defaults.set(newValue.defaultSustainedSeconds, forKey: Keys.cpuSustainedDurationSeconds)
            }
            notifyChange()
        }
    }

    /// CPU warning threshold percentage (clamped to safe bounds 50%...98%).
    public var cpuWarningThresholdPercent: Double {
        get {
            let val = defaults.double(forKey: Keys.cpuWarningThresholdPercent)
            return Self.clamp(val == 0 ? 85.0 : val, min: 50.0, max: 98.0)
        }
        set {
            let clamped = Self.clamp(newValue, min: 50.0, max: 98.0)
            defaults.set(clamped, forKey: Keys.cpuWarningThresholdPercent)
            updatePresetToCustomIfNeeded()
            notifyChange()
        }
    }

    /// Sustained CPU duration before firing an alert (clamped to 10s...120s).
    public var cpuSustainedDurationSeconds: TimeInterval {
        get {
            let val = defaults.double(forKey: Keys.cpuSustainedDurationSeconds)
            return Self.clamp(val == 0 ? 25.0 : val, min: 10.0, max: 120.0)
        }
        set {
            let clamped = Self.clamp(newValue, min: 10.0, max: 120.0)
            defaults.set(clamped, forKey: Keys.cpuSustainedDurationSeconds)
            updatePresetToCustomIfNeeded()
            notifyChange()
        }
    }

    /// Hysteresis recovery margin below the CPU warning threshold (clamped to 5%...25%).
    public var cpuHysteresisMarginPercent: Double {
        get {
            let val = defaults.double(forKey: Keys.cpuHysteresisMarginPercent)
            return Self.clamp(val == 0 ? 10.0 : val, min: 5.0, max: 25.0)
        }
        set {
            let clamped = Self.clamp(newValue, min: 5.0, max: 25.0)
            defaults.set(clamped, forKey: Keys.cpuHysteresisMarginPercent)
            notifyChange()
        }
    }

    public var cpuAlertsEnabled: Bool {
        get { defaults.bool(forKey: Keys.cpuAlertsEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.cpuAlertsEnabled)
            notifyChange()
        }
    }

    public var memoryAlertsEnabled: Bool {
        get { defaults.bool(forKey: Keys.memoryAlertsEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.memoryAlertsEnabled)
            notifyChange()
        }
    }

    /// Low-frequency background monitoring interval in seconds (clamped to safe bounds 5s...60s).
    public var monitoringIntervalSeconds: TimeInterval {
        get {
            let val = defaults.double(forKey: Keys.monitoringIntervalSeconds)
            return Self.clamp(val == 0 ? 10.0 : val, min: 5.0, max: 60.0)
        }
        set {
            let clamped = Self.clamp(newValue, min: 5.0, max: 60.0)
            defaults.set(clamped, forKey: Keys.monitoringIntervalSeconds)
            notifyChange()
        }
    }

    // MARK: - Notifications & Pause / DND

    public var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Keys.notificationsEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.notificationsEnabled)
            notifyChange()
        }
    }

    /// Cooldown between alerts in seconds (clamped to 30s...3600s).
    public var notificationCooldownSeconds: TimeInterval {
        get {
            let val = defaults.double(forKey: Keys.notificationCooldownSeconds)
            return Self.clamp(val == 0 ? 300.0 : val, min: 30.0, max: 3600.0)
        }
        set {
            let clamped = Self.clamp(newValue, min: 30.0, max: 3600.0)
            defaults.set(clamped, forKey: Keys.notificationCooldownSeconds)
            notifyChange()
        }
    }

    public var doNotDisturbEnabled: Bool {
        get { defaults.bool(forKey: Keys.doNotDisturbEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.doNotDisturbEnabled)
            notifyChange()
        }
    }

    public var pausedUntilDate: Date? {
        get {
            let ts = defaults.double(forKey: Keys.pausedUntilTimestamp)
            guard ts > 0 else { return nil }
            let date = Date(timeIntervalSince1970: ts)
            if date <= Date() {
                defaults.removeObject(forKey: Keys.pausedUntilTimestamp)
                return nil
            }
            return date
        }
        set {
            if let date = newValue, date > Date() {
                defaults.set(date.timeIntervalSince1970, forKey: Keys.pausedUntilTimestamp)
            } else {
                defaults.removeObject(forKey: Keys.pausedUntilTimestamp)
            }
            notifyChange()
        }
    }

    public func isCurrentlyPaused(at now: Date = Date()) -> Bool {
        guard let until = pausedUntilDate else { return false }
        return until > now
    }

    public func pauseFor(seconds: TimeInterval, from now: Date = Date()) {
        pausedUntilDate = now.addingTimeInterval(seconds)
    }

    public func resumeMonitoring() {
        pausedUntilDate = nil
    }

    private func updatePresetToCustomIfNeeded() {
        let current = sensitivityPreset
        if current != .custom {
            let threshMatches = abs(cpuWarningThresholdPercent - current.defaultCPUThreshold) < 0.01
            let durMatches = abs(cpuSustainedDurationSeconds - current.defaultSustainedSeconds) < 0.01
            if !threshMatches || !durMatches {
                defaults.set(AlertSensitivityPreset.custom.rawValue, forKey: Keys.sensitivityPreset)
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}
