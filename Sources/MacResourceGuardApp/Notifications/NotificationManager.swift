import Foundation
import AppKit
import UserNotifications
#if canImport(MacResourceGuardCore)
import MacResourceGuardCore
#endif

/// Delivers native, non-intrusive macOS user notifications when sustained CPU or memory pressure occurs.
/// Gracefully handles running both inside a signed `.app` bundle and unbundled CLI test contexts.
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()

    private static let categoryIdentifier = "MAC_RESOURCE_GUARD_ALERT"
    private static let openPopoverActionIdentifier = "OPEN_POPOVER_ACTION"

    public var onUserClickedNotification: (() -> Void)?
    private var isAuthorized: Bool = false

    private var hasValidAppBundle: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    private override init() {
        super.init()
    }

    public func configureIfPossible() {
        guard hasValidAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let inspectAction = UNNotificationAction(
            identifier: Self.openPopoverActionIdentifier,
            title: "Inspect Top Apps",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [inspectAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.isAuthorized = true
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    self?.isAuthorized = granted
                }
            default:
                self?.isAuthorized = false
            }
        }
    }

    public func postAlertNotification(_ alert: ResourceAlertEvent) {
        let settings = AppSettingsStore.shared
        guard settings.notificationsEnabled,
              !settings.doNotDisturbEnabled,
              !settings.isCurrentlyPaused(),
              hasValidAppBundle else {
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] notifSettings in
            guard let self = self else { return }
            if notifSettings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    self.isAuthorized = granted
                    if granted {
                        self.enqueueNotification(alert, on: center)
                    }
                }
            } else if notifSettings.authorizationStatus == .authorized || notifSettings.authorizationStatus == .provisional {
                self.enqueueNotification(alert, on: center)
            }
        }
    }

    private func enqueueNotification(_ alert: ResourceAlertEvent, on center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "MacResourceGuard.\(alert.kind.rawValue)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onUserClickedNotification?()
        }
        completionHandler()
    }
}
