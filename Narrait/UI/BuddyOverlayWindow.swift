//
//  BuddyOverlayWindow.swift
//  Narrait
//
//  System-wide transparent overlay window for the buddy cursor.
//  One BuddyOverlayWindow is created per screen so the buddy
//  seamlessly follows the cursor across multiple monitors.
//
//  Architecture mirrors farzaa/clicky OverlayWindow.swift:
//  - NSWindow at .screenSaver level (above all menus and popups)
//  - ignoresMouseEvents = true (click-through)
//  - hidesOnDeactivate = false (stays visible when other apps are active)
//  - 60fps Timer polling NSEvent.mouseLocation, offset (+35, +25)
//

import AppKit
import SwiftUI

// MARK: - Overlay Window

/// A borderless, transparent, always-on-top, click-through NSWindow
/// that covers one full screen. Contains the buddy cursor SwiftUI view.
final class BuddyOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver          // Above submenus, notifications, everything.
        ignoresMouseEvents = true     // Click-through — user interacts with the real screen.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false     // Stay visible when a different app is frontmost.
        setFrame(screen.frame, display: true)
        if let s = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            setFrameOrigin(s.frame.origin)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay Window Manager

/// Creates and manages one BuddyOverlayWindow per connected screen.
/// Call `show(coordinator:)` to spin up overlays, `hide()` to tear them down.
@MainActor
final class BuddyOverlayManager {
    private var overlayWindows: [BuddyOverlayWindow] = []

    func show(coordinator: ActivationCoordinator) {
        hide()
        for screen in NSScreen.screens {
            let window = BuddyOverlayWindow(screen: screen)
            let view = BuddyCursorView(screenFrame: screen.frame, coordinator: coordinator)
            let host = NSHostingView(rootView: view)
            host.frame = screen.frame
            window.contentView = host
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        print("🎯 BuddyOverlayManager: showing overlay on \(overlayWindows.count) screen(s)")
    }

    func hide() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }
}
