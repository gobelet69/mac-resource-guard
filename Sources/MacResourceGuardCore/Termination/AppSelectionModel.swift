import Foundation

/// Manages single and multi-selection of eligible applications for safe batch termination.
/// Automatically prevents protected system applications from being selected.
public struct AppSelectionModel: Equatable, Sendable {
    public private(set) var selectedPIDs: Set<pid_t> = []

    public init(selectedPIDs: Set<pid_t> = []) {
        self.selectedPIDs = selectedPIDs
    }

    public func isSelected(_ pid: pid_t) -> Bool {
        selectedPIDs.contains(pid)
    }

    public mutating func setSelected(_ selected: Bool, for app: AggregatedAppProcess) {
        guard app.canSafelyClose else {
            selectedPIDs.remove(app.id)
            return
        }
        if selected {
            selectedPIDs.insert(app.id)
        } else {
            selectedPIDs.remove(app.id)
        }
    }

    public mutating func toggle(for app: AggregatedAppProcess) {
        setSelected(!isSelected(app.id), for: app)
    }

    /// Selects all eligible (non-protected) applications in the provided list.
    public mutating func selectAllEligible(in apps: [AggregatedAppProcess]) {
        for app in apps where app.canSafelyClose {
            selectedPIDs.insert(app.id)
        }
    }

    public mutating func clearAll() {
        selectedPIDs.removeAll()
    }

    /// Removes any selected PIDs that are no longer present or no longer eligible in the visible list.
    public mutating func reconcile(with visibleApps: [AggregatedAppProcess]) {
        let eligibleVisiblePIDs = Set(visibleApps.filter { $0.canSafelyClose }.map { $0.id })
        selectedPIDs.formIntersection(eligibleVisiblePIDs)
    }

    /// Returns true if every eligible application in `visibleApps` is currently selected (and at least one is eligible).
    public func areAllEligibleSelected(in visibleApps: [AggregatedAppProcess]) -> Bool {
        let eligible = visibleApps.filter { $0.canSafelyClose }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { selectedPIDs.contains($0.id) }
    }

    /// Returns the selected `AggregatedAppProcess` objects in their display order.
    public func selectedApplications(in visibleApps: [AggregatedAppProcess]) -> [AggregatedAppProcess] {
        visibleApps.filter { $0.canSafelyClose && selectedPIDs.contains($0.id) }
    }
}
