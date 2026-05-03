import AppKit
import Combine
import CoreGraphics
import Foundation

// Events published to ActivationCoordinator
enum HotkeyEvent {
    case hoverStart       // Option key down
    case hoverEnd         // Option key up
    case voiceStart       // Cmd+Option down (push-to-talk)
    case voiceEnd         // Cmd+Option up
    case magnifierToggle  // Option double-tap (low vision profile only)
}

// Ported from Clicky's GlobalPushToTalkShortcutMonitor.
// Added second trigger: Option-alone for hover-explain.
// Cmd+Option is voice push-to-talk (Clicky's existing pattern).
// Uses AppKit local + global modifier monitors so it keeps working when focus
// moves between Xcode, Narrait panels, and other apps.
final class GlobalHotkeyMonitor {
    let eventPublisher = PassthroughSubject<HotkeyEvent, Never>()

    @Published private(set) var isHotkeyDown = false

    private enum Mode {
        case idle
        case hover
        case voice
        case suppressHoverUntilOptionUp
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var mode: Mode = .idle
    private var releasePoll: DispatchWorkItem?
    private var lastOptionUpTime: Date?
    private static let doubleTapWindow: TimeInterval = 0.35

    deinit { stop() }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(flags: event.modifierFlags) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
            return event
        }

        print("✅ GlobalHotkeyMonitor: started (AppKit local+global)")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        mode = .idle
        releasePoll?.cancel()
        releasePoll = nil
        isHotkeyDown = false
    }

    // MARK: - Private

    private func handle(flags: NSEvent.ModifierFlags) {
        reconcile(with: flags.intersection(.deviceIndependentFlagsMask))
    }

    private func publish(_ event: HotkeyEvent) {
        isHotkeyDown = event == .hoverStart || event == .voiceStart
        print("⌨️ GlobalHotkeyMonitor: \(event)")
        if Thread.isMainThread {
            eventPublisher.send(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.eventPublisher.send(event)
            }
        }
    }

    private func reconcile(with flags: NSEvent.ModifierFlags) {
        let optionDown = flags.contains(.option)
        let commandDown = flags.contains(.command)

        if !optionDown {
            switch mode {
            case .hover:
                publish(.hoverEnd)
                lastOptionUpTime = Date()
            case .voice:
                publish(.voiceEnd)
            case .idle, .suppressHoverUntilOptionUp:
                break
            }
            mode = .idle
            stopReleasePoll()
            isHotkeyDown = false
            return
        }

        if commandDown {
            if mode == .hover { publish(.hoverEnd) }
            if mode != .voice { publish(.voiceStart) }
            mode = .voice
            scheduleReleasePoll()
            return
        }

        switch mode {
        case .idle:
            if let last = lastOptionUpTime,
               Date().timeIntervalSince(last) < Self.doubleTapWindow {
                lastOptionUpTime = nil
                publish(.magnifierToggle)
                mode = .suppressHoverUntilOptionUp
                scheduleReleasePoll()
            } else {
                mode = .hover
                publish(.hoverStart)
                scheduleReleasePoll()
            }
        case .voice:
            publish(.voiceEnd)
            mode = .suppressHoverUntilOptionUp
            scheduleReleasePoll()
        case .hover, .suppressHoverUntilOptionUp:
            scheduleReleasePoll()
        }
    }

    private func scheduleReleasePoll() {
        releasePoll?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconcile(with: self.currentModifierFlags())
        }
        releasePoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func stopReleasePoll() {
        releasePoll?.cancel()
        releasePoll = nil
    }

    private func currentModifierFlags(fallbackRawValue: UInt64? = nil) -> NSEvent.ModifierFlags {
        let rawValue = fallbackRawValue ?? CGEventSource.flagsState(.hidSystemState).rawValue
        return NSEvent.ModifierFlags(rawValue: UInt(rawValue)).intersection(.deviceIndependentFlagsMask)
    }
}
