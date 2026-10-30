import AppKit

public enum ForceQuitAlertFactory {
    public static func makeAlert(displayName: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force Quit \(displayName)?"
        alert.informativeText = "If \(displayName) has unsaved changes, forcing it to quit will lose those changes. Prefer closing any open Save dialogs in the app first."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}
