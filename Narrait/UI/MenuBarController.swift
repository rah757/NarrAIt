import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let narraitDismissPanel = Notification.Name("narraitDismissPanel")
}

// Manages the NSStatusItem (menu bar icon) and the SwiftUI popover surface.
// Icon shows as gray when Narrait is blocked (assessment context detected).
// The popover replaces the legacy NSMenu — see MenuBarPopover.swift.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var howToUseController: HowToUseWindowController?
    private weak var coordinator: ActivationCoordinator?
    private var blockSubscription: AnyCancellable?

    init(coordinator: ActivationCoordinator) {
        self.coordinator = coordinator
        super.init()
        createStatusItem()
        createPopover()

        blockSubscription = coordinator.$isBlocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocked in
                self?.setBlocked(blocked)
            }
    }

    func setBlocked(_ blocked: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = makeIcon(grayed: blocked)
        button.image?.isTemplate = !blocked
        button.toolTip = blocked
            ? "Narrait — disabled in assessment context"
            : "Narrait"
    }

    // MARK: - Setup

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = makeIcon(grayed: false)
        button.image?.isTemplate = true
        button.toolTip = "Narrait"
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func createPopover() {
        guard let coordinator else { return }
        let view = MenuBarPopoverView(
            coordinator: coordinator,
            onSettings: { [weak self] in self?.openKeysWindow() },
            onHelp: { [weak self] in self?.showHelp() },
            onQuit: { NSApp.terminate(nil) }
        )
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: view)
        p.delegate = self
        popover = p
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Actions

    @objc private func openKeysWindow() {
        // Dismiss the popover first so the alert sheet is layered correctly.
        popover?.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "API Keys"
        alert.informativeText = "Add a .env file to the app bundle with ANTHROPIC_API_KEY, GEMINI_API_KEY, and GROQ_API_KEY.\n\nOr set them now:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 92)

        func field(placeholder: String, current: String) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            f.placeholderString = placeholder
            f.stringValue = current
            return f
        }

        let anthropicField = field(placeholder: "Anthropic API Key (sk-ant-...)", current: APIKeyStore.anthropicKey)
        let geminiField = field(placeholder: "Gemini API Key (AIza...)", current: APIKeyStore.geminiKey)
        let groqField = field(placeholder: "Groq API Key (gsk_...)", current: APIKeyStore.groqKey)

        stack.addArrangedSubview(anthropicField)
        stack.addArrangedSubview(geminiField)
        stack.addArrangedSubview(groqField)
        alert.accessoryView = stack

        if alert.runModal() == .alertFirstButtonReturn {
            let a = anthropicField.stringValue.trimmingCharacters(in: .whitespaces)
            let g = geminiField.stringValue.trimmingCharacters(in: .whitespaces)
            let gr = groqField.stringValue.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty { APIKeyStore.anthropicKey = a }
            if !g.isEmpty { APIKeyStore.geminiKey = g }
            if !gr.isEmpty { APIKeyStore.groqKey = gr }
            print("✅ API keys updated")
        }
    }

    @objc private func showHelp() {
        popover?.performClose(nil)
        if howToUseController == nil {
            howToUseController = HowToUseWindowController()
        }
        howToUseController?.show()
    }

    // MARK: - Icon

    // Active: filled play triangle pointing right (template-rendered, adapts to dark/light bar).
    // Blocked: gray oval, not template-rendered.
    private func makeIcon(grayed: Bool) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        if grayed {
            NSColor.systemGray.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
        } else {
            let cx = size / 2, cy = size / 2
            let r: CGFloat = 6
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cx - r * 0.4, y: cy - r * 0.6))
            path.line(to: NSPoint(x: cx - r * 0.4, y: cy + r * 0.6))
            path.line(to: NSPoint(x: cx + r * 0.6, y: cy))
            path.close()
            NSColor.black.setFill()
            path.fill()
        }

        image.unlockFocus()
        return image
    }
}
