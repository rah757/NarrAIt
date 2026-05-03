import AppKit
import SwiftUI

// Floating circular magnifier loupe.
// Follows the cursor while active, capturing a live zoomed crop via CGWindowListCreateImage.
// Activated by double-tap Option when the Low Vision profile is selected.
@MainActor
final class MagnifierPanel {
    private var panel: NSPanel?
    private var magnifierHost: NSHostingView<MagnifierView>?
    private var captureTimer: DispatchSourceTimer?
    private let captureQueue = DispatchQueue(label: "narrait.magnifier", qos: .userInteractive)
    private var isRunning = false

    var isActive: Bool { isRunning }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        captureTimer?.cancel()
        captureTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func start() {
        isRunning = true
        makePanelIfNeeded()
        panel?.orderFrontRegardless()
        startCaptureTimer()
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }

        let size: CGFloat = 200
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isExcludedFromWindowsMenu = true

        let host = NSHostingView(rootView: MagnifierView())
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        p.contentView = host

        self.panel = p
        self.magnifierHost = host
    }

    private func startCaptureTimer() {
        captureTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        // 20fps — smooth enough for a loupe, light enough not to block main thread.
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.captureFrame() }
        timer.resume()
        captureTimer = timer
    }

    private func captureFrame() {
        // Run entirely off main thread. Only the final UI update goes to main.
        let mouse = NSEvent.mouseLocation  // safe to call off main on macOS
        let cropSize: CGFloat = 100

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return }

        let sh = screen.frame.height
        let quartzRect = CGRect(
            x: mouse.x - cropSize / 2,
            y: sh - (mouse.y + cropSize / 2),
            width: cropSize,
            height: cropSize
        )

        guard let cgImage = CGWindowListCreateImage(
            quartzRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else { return }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
        let offset: CGFloat = 20
        let origin = CGPoint(x: mouse.x + offset, y: mouse.y + offset)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.panel?.setFrameOrigin(origin)
            self.magnifierHost?.rootView = MagnifierView(image: image)
        }
    }

    deinit {
        captureTimer?.cancel()
    }
}

// MARK: - SwiftUI loupe

private struct MagnifierView: View {
    var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
            } else {
                Circle().fill(Color.black.opacity(0.4))
            }

            // Border ring
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)

            // Crosshair
            Path { p in
                p.move(to: CGPoint(x: 100, y: 85))
                p.addLine(to: CGPoint(x: 100, y: 115))
                p.move(to: CGPoint(x: 85, y: 100))
                p.addLine(to: CGPoint(x: 115, y: 100))
            }
            .stroke(Color.white.opacity(0.7), lineWidth: 1.5)
        }
        .frame(width: 200, height: 200)
    }
}

