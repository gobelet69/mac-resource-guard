import Foundation
import AppKit
import Darwin

/// Outcomes of a safe application termination attempt.
public enum TerminationResult: Equatable, Sendable {
    /// Normal quit request (`NSRunningApplication.terminate()`) succeeded immediately.
    case terminatedSmoothly
    /// Normal quit signal was delivered; application is still running (e.g., showing a Save dialog or unresponsive).
    case awaitingUserOrUnresponsive
    /// Force quit (`forceTerminate()`) succeeded after explicit user confirmation.
    case forceTerminated
    /// Blocked because the target is a protected macOS process or Mac Resource Guard itself.
    case deniedProtectedProcess(reason: String)
    /// Blocked because the PID no longer matches its recorded start timestamp or bundle identity (PID reuse guard).
    case abortedPIDReuseDetected
    /// The process already exited before termination was needed.
    case alreadyExited
    /// OS rejected the termination signal.
    case failed(reason: String)
}

/// Enforces process termination safety rules, protected system blocklists, and PID reuse verification.
public final class SafeAppTerminator {
    public static let shared = SafeAppTerminator()

    /// Protected macOS bundle identifiers that must never be terminated.
    public static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
        "com.apple.coreservices.uiagent",
        "com.apple.securityagent",
        "com.macresourceguard.app"
    ]

    /// Protected executable names that must never be terminated.
    public static let protectedProcessNames: Set<String> = [
        "Finder",
        "Dock",
        "WindowServer",
        "loginwindow",
        "kernel_task",
        "launchd",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "Spotlight",
        "WindowManager",
        "UserEventAgent",
        "coreservicesd",
        "MacResourceGuard",
        "agy"
    ]

    public init() {}

    // MARK: - Eligibility & Protection Evaluation

    /// Evaluates whether a process is protected and returns a human-readable reason if it cannot be closed.
    public static func evaluateProtection(
        pid: pid_t,
        uid: uid_t?,
        bundleIdentifier: String?,
        processName: String,
        executablePath: String?,
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) -> (isProtected: Bool, reason: String?) {
        if pid <= 1 {
            return (true, "Critical kernel/launchd process")
        }

        if pid == selfPID {
            return (true, "Mac Resource Guard (self)")
        }

        if let selfBundleID = selfBundleID, let bundleID = bundleIdentifier, bundleID == selfBundleID {
            return (true, "Mac Resource Guard (self)")
        }

        if let uid = uid, uid == 0 {
            return (true, "System root process")
        }

        if let bundleID = bundleIdentifier {
            if protectedBundleIdentifiers.contains(bundleID) {
                return (true, "Essential macOS system component (\(processName))")
            }
            if bundleID.hasPrefix("com.apple.CoreServices") {
                return (true, "Core macOS service")
            }
        }

        if protectedProcessNames.contains(processName) {
            return (true, "Essential macOS system process (\(processName))")
        }

        if let path = executablePath {
            if path.hasPrefix("/System/Library/CoreServices/") && bundleIdentifier != "com.apple.Safari" {
                // Finder, Dock, SystemUIServer, ControlCenter, loginwindow live in /System/Library/CoreServices
                return (true, "macOS CoreServices component")
            }
            if path.hasPrefix("/sbin/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/System/Library/PrivateFrameworks/") {
                return (true, "macOS background system daemon")
            }
        }

        return (false, nil)
    }

    // MARK: - PID Reuse Verification

    /// Reads current BSD process info for a PID to verify start time before sending any termination signal.
    public static func readBSDProcessIdentity(pid: pid_t) -> (startTimeSec: UInt64, startTimeUsec: UInt64, uid: uid_t, name: String)? {
        guard pid > 0 else { return nil }
        var bsdInfo = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytesRead = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, expectedSize)
        guard bytesRead == expectedSize else {
            return nil
        }

        let name: String = withUnsafePointer(to: bsdInfo.pbi_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                String(cString: cStr)
            }
        }

        let fallbackName: String
        if name.isEmpty {
            fallbackName = withUnsafePointer(to: bsdInfo.pbi_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                    String(cString: cStr)
                }
            }
        } else {
            fallbackName = name
        }

        return (
            startTimeSec: bsdInfo.pbi_start_tvsec,
            startTimeUsec: bsdInfo.pbi_start_tvusec,
            uid: bsdInfo.pbi_uid,
            name: fallbackName
        )
    }

    /// Validates that a live process still matches the exact start time and bundle identifier recorded in the snapshot.
    public static func verifyProcessIdentity(
        for app: AggregatedAppProcess,
        liveMetadataProvider: (pid_t) -> (startTimeSec: UInt64, startTimeUsec: UInt64, bundleID: String?)? = { pid in
            guard let bsd = SafeAppTerminator.readBSDProcessIdentity(pid: pid) else { return nil }
            let runningApp = NSRunningApplication(processIdentifier: pid)
            return (bsd.startTimeSec, bsd.startTimeUsec, runningApp?.bundleIdentifier)
        }
    ) -> (exists: Bool, isMatchingIdentity: Bool) {
        guard let live = liveMetadataProvider(app.id) else {
            return (exists: false, isMatchingIdentity: false)
        }

        let startTimesMatch = (live.startTimeSec == app.startTimeSec) && (live.startTimeUsec == app.startTimeUsec)
        let bundleMatches: Bool
        if let expectedBundle = app.bundleIdentifier, let actualBundle = live.bundleID {
            bundleMatches = (expectedBundle == actualBundle)
        } else {
            bundleMatches = true
        }

        return (exists: true, isMatchingIdentity: startTimesMatch && bundleMatches)
    }

    // MARK: - Graceful & Force Termination

    /// Initiates a normal, graceful quit (`NSRunningApplication.terminate()`) that respects unsaved document prompts.
    /// Never silently force-quits an application.
    public func requestGracefulQuit(
        for app: AggregatedAppProcess,
        completion: @escaping (TerminationResult) -> Void
    ) {
        if app.isProtectedSystemApp {
            completion(.deniedProtectedProcess(reason: app.protectionReason ?? "Protected system application"))
            return
        }

        let recheck = Self.evaluateProtection(
            pid: app.id,
            uid: nil,
            bundleIdentifier: app.bundleIdentifier,
            processName: app.displayName,
            executablePath: app.executablePath
        )
        if recheck.isProtected {
            completion(.deniedProtectedProcess(reason: recheck.reason ?? "Protected system application"))
            return
        }

        let verification = Self.verifyProcessIdentity(for: app)
        if !verification.exists {
            completion(.alreadyExited)
            return
        }
        if !verification.isMatchingIdentity {
            completion(.abortedPIDReuseDetected)
            return
        }

        guard let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            // If it is not an NSRunningApplication (e.g., background process/daemon), send SIGTERM if user-owned
            if let bsd = Self.readBSDProcessIdentity(pid: app.id), bsd.uid == getuid() {
                let rc = Darwin.kill(app.id, SIGTERM)
                if rc == 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                        let postCheck = Self.verifyProcessIdentity(for: app)
                        DispatchQueue.main.async {
                            if !postCheck.exists {
                                completion(.terminatedSmoothly)
                            } else {
                                completion(.awaitingUserOrUnresponsive)
                            }
                        }
                    }
                } else {
                    completion(.failed(reason: "SIGTERM failed with errno \(errno)"))
                }
            } else {
                completion(.alreadyExited)
            }
            return
        }

        if runningApp.isTerminated {
            completion(.alreadyExited)
            return
        }

        let accepted = runningApp.terminate()
        if !accepted {
            completion(.awaitingUserOrUnresponsive)
            return
        }

        // Wait up to 2.0 seconds off the main thread to see if the app exited cleanly
        // or if it is awaiting a Save dialog / unresponsive.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.8) {
            let postCheck = Self.verifyProcessIdentity(for: app)
            DispatchQueue.main.async {
                if !postCheck.exists || runningApp.isTerminated {
                    completion(.terminatedSmoothly)
                } else {
                    completion(.awaitingUserOrUnresponsive)
                }
            }
        }
    }

    /// Performs an explicit Force Quit ONLY after the user has confirmed via a modal alert.
    public func forceQuitAfterConfirmation(for app: AggregatedAppProcess) -> TerminationResult {
        if app.isProtectedSystemApp {
            return .deniedProtectedProcess(reason: app.protectionReason ?? "Protected system application")
        }

        let verification = Self.verifyProcessIdentity(for: app)
        if !verification.exists {
            return .alreadyExited
        }
        if !verification.isMatchingIdentity {
            return .abortedPIDReuseDetected
        }

        if let runningApp = NSRunningApplication(processIdentifier: app.id) {
            if runningApp.isTerminated {
                return .alreadyExited
            }
            let forced = runningApp.forceTerminate()
            return forced ? .forceTerminated : .failed(reason: "OS declined forceTerminate()")
        } else if let bsd = Self.readBSDProcessIdentity(pid: app.id), bsd.uid == getuid() {
            let rc = Darwin.kill(app.id, SIGKILL)
            return rc == 0 ? .forceTerminated : .failed(reason: "SIGKILL failed with errno \(errno)")
        }

        return .alreadyExited
    }
}
