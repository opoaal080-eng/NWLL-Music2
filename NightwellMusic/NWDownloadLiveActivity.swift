import ActivityKit
import Foundation
import UIKit

// ActivityKit runs out of process. Only a quantized snapshot is sent; no
// player timer, file scan, artwork request or SwiftUI root invalidation.
@MainActor final class NWDownloadLiveActivity {
    static let shared = NWDownloadLiveActivity()
    private typealias State = NWDownloadActivityAttributes.ContentState
    private var current: Activity<NWDownloadActivityAttributes>?
    private var pending: State?
    private var worker: Task<Void, Never>?
    private var lastSent: State?
    private var lastUpdate: TimeInterval = 0

    func receive(_ state: NWDownloadActivityAttributes.ContentState) {
        pending = state
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let state = self.pending {
                self.pending = nil
                if state == self.lastSent, self.current != nil { continue }
                if state.active, let last = self.lastSent, last.active,
                   state.completed == last.completed, state.total == last.total,
                   ProcessInfo.processInfo.systemUptime - self.lastUpdate < 1 {
                    // Coalesce byte-only updates. Counts and completion do not wait.
                    self.pending = state
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                await self.apply(state)
            }
            self.worker = nil
        }
    }

    func flush(_ state: NWDownloadActivityAttributes.ContentState) async {
        receive(state)
        if !state.active { await worker?.value }
    }

    private func apply(_ state: State) async {
        if current?.activityState == .ended || current?.activityState == .dismissed {
            current = nil; lastSent = nil
        }
        if current == nil {
            current = Activity<NWDownloadActivityAttributes>.activities.first
        }
        let content = ActivityContent(state: state, staleDate: nil)
        guard state.active, state.total > 0 else {
            // Close any recovered activity as well as our own; don't leave an
            // obsolete Island after the daemon finishes while the app is locked.
            let activities = Activity<NWDownloadActivityAttributes>.activities
            for activity in activities {
                await activity.end(state.total > 0 ? content : nil,
                                   dismissalPolicy: state.total > 0 ? .after(Date().addingTimeInterval(8)) : .immediate)
            }
            current = nil; lastSent = nil
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let activity = current {
            guard lastSent != state else { return }
            await activity.update(content)
        } else {
            // Local ActivityKit requests require a foreground app. Background
            // URLSession events may update an existing activity, not create one.
            guard UIApplication.shared.applicationState == .active else { return }
            do {
                current = try Activity.request(attributes: NWDownloadActivityAttributes(),
                                               content: content, pushType: nil)
            } catch { return }
        }
        lastSent = state
        lastUpdate = ProcessInfo.processInfo.systemUptime
    }
}
