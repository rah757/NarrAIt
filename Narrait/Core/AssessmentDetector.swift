import AppKit
import Combine

// Polls every 2s for any sign that an assessment / proctoring context is on screen.
// Publishes `isAssessmentActive` so the coordinator can hard-cancel current work
// and the menu bar can gray its icon. This is the third demo beat.
//
// Detection sources (in order, any match → blocked):
//   1. Frontmost app's bundle ID matches a known proctoring vendor.
//   2. Any on-screen window title contains "quiz", "exam", "test", etc.
//
// Note: CGWindowListCopyWindowInfo requires Screen Recording permission to
// return real window titles. We already prompt for that at launch.
@MainActor
final class AssessmentDetector: ObservableObject {

    @Published private(set) var isAssessmentActive: Bool = false

    private static let blockedBundleIDPrefixes: [String] = [
        "com.respondus.lockdownbrowser",
        "com.honorlock.",
        "com.examsoft.examplify",
        "com.proctorio.",
    ]

    private static let blockedWindowTitleSubstrings: [String] = [
        "quiz", "exam", "test", "canvas quiz", "blackboard test",
    ]

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    func start() {
        stop()
        check() // immediate, so launch state is correct
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
        print("🛡️ AssessmentDetector: started (\(Int(pollInterval))s polling)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Private

    private func check() {
        let blocked = Self.detect()
        guard blocked != isAssessmentActive else { return }
        isAssessmentActive = blocked
        print(blocked
              ? "🔒 AssessmentDetector: assessment context detected — blocking"
              : "🔓 AssessmentDetector: assessment context cleared — unblocking")
    }

    private static func detect() -> Bool {
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            for prefix in blockedBundleIDPrefixes where bundleID.hasPrefix(prefix) {
                return true
            }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue } // skip menu bar, dock, status overlays

            guard let title = window[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            let lower = title.lowercased()
            for substr in blockedWindowTitleSubstrings where lower.contains(substr) {
                return true
            }
        }

        return false
    }
}
