import AppKit
import SwiftUI

// Handles the red hover marker only. AI click targets are rendered by
// BuddyOverlayManager/BuddyCursorView, not by this class.
@MainActor
final class CursorPointer {
    private var hoverMarkerPanel: NSPanel?

    func showHoverMarker(at location: CGPoint) {
        makeHoverMarkerIfNeeded()
        guard let panel = hoverMarkerPanel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideHoverMarker() {
        hoverMarkerPanel?.orderOut(nil)
    }

    // Kept as a no-op compatibility hook for older coordinator paths.
    func point(to location: CGPoint, in displayFrame: CGRect) {}

    func hide() {
        hoverMarkerPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func makeHoverMarkerIfNeeded() {
        if hoverMarkerPanel != nil { return }

        let size: CGFloat = 36
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let host = NSHostingView(rootView: HoverMarkerView())
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = host
        hoverMarkerPanel = panel
    }
}

private struct HoverMarkerView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Color.red.opacity(0.6), lineWidth: 2)
                .frame(width: 30, height: 30)
        }
        .frame(width: 36, height: 36)
        .shadow(color: Color.black.opacity(0.5), radius: 4, x: 0, y: 1)
    }
}
