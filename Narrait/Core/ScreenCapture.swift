import AppKit
import ScreenCaptureKit

// Per-display capture result carrying JPEG data and coordinate metadata.
struct ScreenCaptureResult {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

// Captures the cursor screen + the active window under the cursor.
// For hover: sends window crop + cursor screen (full) so Gemini focuses on the right area.
// For voice: just the cursor screen.
@MainActor
enum ScreenCapture {
    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768, 1024.0 / 768.0),
        (1280, 800, 1280.0 / 800.0),
        (1366, 768, 1366.0 / 768.0)
    ]

    // Shared setup: returns content, ownWindows, nsScreenByID, and the cursor screen display.
    private static func setup() async throws -> (
        content: SCShareableContent,
        ownWindows: [SCWindow],
        nsScreenByID: [CGDirectDisplayID: NSScreen],
        cursorDisplay: SCDisplay,
        cursorFrame: CGRect
    ) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw NSError(domain: "ScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == ownBundleID
        }

        var nsScreenByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByID[id] = screen
            }
        }

        let mouse = NSEvent.mouseLocation
        // Find the display the cursor is on; fall back to first display.
        let cursorDisplay = content.displays.first { display in
            let frame = nsScreenByID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            return frame.contains(mouse)
        } ?? content.displays[0]

        let cursorFrame = nsScreenByID[cursorDisplay.displayID]?.frame
            ?? CGRect(x: cursorDisplay.frame.origin.x, y: cursorDisplay.frame.origin.y,
                      width: CGFloat(cursorDisplay.width), height: CGFloat(cursorDisplay.height))

        return (content, ownWindows, nsScreenByID, cursorDisplay, cursorFrame)
    }

    // Captures the cursor screen. Hover uses a capped image; voice uses native pixels for [POINT:] precision.
    static func captureCursorScreen(maxDimension: Int? = 1280, targetSize: CGSize? = nil) async throws -> ScreenCaptureResult {
        let (_, ownWindows, nsScreenByID, display, displayFrame) = try await setup()

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        if let targetSize {
            config.width = Int(targetSize.width)
            config.height = Int(targetSize.height)
        } else if let maxDimension {
            let aspect = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                config.width = maxDimension
                config.height = Int(CGFloat(maxDimension) / aspect)
            } else {
                config.height = maxDimension
                config.width = Int(CGFloat(maxDimension) * aspect)
            }
        } else {
            let screenScale = nsScreenByID[display.displayID]?.backingScaleFactor ?? 1
            let nativeWidth = Int(displayFrame.width * screenScale)
            let nativeHeight = Int(displayFrame.height * screenScale)
            config.width = max(display.width, nativeWidth)
            config.height = max(display.height, nativeHeight)
        }

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "ScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }

        return ScreenCaptureResult(
            imageData: jpeg,
            label: "full screen — use THESE pixel coordinates for [POINT:x,y]",
            isCursorScreen: true,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: cgImage.width,
            screenshotHeightInPixels: cgImage.height
        )
    }

    // Captures the topmost visible window under the cursor at up to 1200px wide.
    // Returns nil if no suitable window is found.
    static func captureWindowUnderCursor() async throws -> Data? {
        let (content, ownWindows, _, _, _) = try await setup()
        let mouse = NSEvent.mouseLocation

        // SCWindow.frame is in CG coords (top-left origin). Convert mouse to CG coords.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cgMouse = CGPoint(x: mouse.x, y: primaryH - mouse.y)

        let ownIDs = Set(ownWindows.compactMap { $0.windowID })

        // content.windows is ordered front-to-back; pick the first one containing the cursor.
        guard let window = content.windows.first(where: { w in
            !ownIDs.contains(w.windowID)
            && w.isOnScreen
            && w.frame.contains(cgMouse)
            && w.frame.width > 50 && w.frame.height > 50
        }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let maxW = 1200
        let aspect = window.frame.width / window.frame.height
        config.width = maxW
        config.height = max(1, Int(CGFloat(maxW) / aspect))

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // Voice path: use Anthropic Computer Use's recommended resolution closest to this display's aspect ratio.
    static func captureAllScreens() async throws -> [ScreenCaptureResult] {
        let (_, _, _, display, _) = try await setup()
        let target = closestComputerUseResolution(for: Double(display.width) / Double(display.height))
        let result = try await captureCursorScreen(maxDimension: nil, targetSize: CGSize(width: target.width, height: target.height))
        print("🖥️ ScreenCapture: Computer Use \(target.width)x\(target.height)")
        return [result]
    }

    private static func closestComputerUseResolution(for aspectRatio: Double) -> (width: Int, height: Int, aspectRatio: Double) {
        supportedComputerUseResolutions.min {
            abs($0.aspectRatio - aspectRatio) < abs($1.aspectRatio - aspectRatio)
        } ?? supportedComputerUseResolutions[0]
    }

    // Converts the current AppKit mouse location to screenshot pixel space (top-left origin).
    static func cursorPixelPosition(in screen: ScreenCaptureResult, mouse: CGPoint = NSEvent.mouseLocation) -> CGPoint {
        let frame = screen.displayFrame
        let sw = CGFloat(screen.screenshotWidthInPixels)
        let sh = CGFloat(screen.screenshotHeightInPixels)
        let dw = CGFloat(screen.displayWidthInPoints)
        let dh = CGFloat(screen.displayHeightInPoints)

        let relX = mouse.x - frame.origin.x
        let relY = frame.origin.y + dh - mouse.y
        return CGPoint(
            x: relX * (sw / dw),
            y: relY * (sh / dh)
        )
    }

    // Crops a ~700×500px region centered on the cursor from the cursor screen's screenshot.
    // Returns JPEG data for the crop, or nil if the cursor screen isn't in results.
    // Draws a red ring/crosshair on the exact hover point so the model doesn't guess.
    static func cropAroundCursor(from results: [ScreenCaptureResult], mouse: CGPoint = NSEvent.mouseLocation) -> Data? {
        guard let screen = results.first(where: { $0.isCursorScreen }) else { return nil }

        let sw = CGFloat(screen.screenshotWidthInPixels)
        let sh = CGFloat(screen.screenshotHeightInPixels)
        let cursorPx = cursorPixelPosition(in: screen, mouse: mouse)

        // Crop window: ~700×500px, clamped to image bounds
        let cropW: CGFloat = min(700, sw)
        let cropH: CGFloat = min(500, sh)
        let cropX = max(0, min(cursorPx.x - cropW / 2, sw - cropW))
        let cropY = max(0, min(cursorPx.y - cropH / 2, sh - cropH))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)

        // Decode JPEG → CGImage → crop → re-encode
        guard let source = CGImageSourceCreateWithData(screen.imageData as CFData, nil),
              let fullCG = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = fullCG.cropping(to: cropRect) else { return nil }

        let cursorInCrop = CGPoint(x: cursorPx.x - cropX, y: cursorPx.y - cropY)
        let marked = drawMarker(on: cropped, at: cursorInCrop) ?? cropped

        return NSBitmapImageRep(cgImage: marked)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func drawMarker(on image: CGImage, at point: CGPoint) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let y = CGFloat(height) - point.y
        let x = point.x
        let radius: CGFloat = 18
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(5)
        context.strokeEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        context.move(to: CGPoint(x: x - radius - 8, y: y))
        context.addLine(to: CGPoint(x: x + radius + 8, y: y))
        context.move(to: CGPoint(x: x, y: y - radius - 8))
        context.addLine(to: CGPoint(x: x, y: y + radius + 8))
        context.strokePath()

        return context.makeImage()
    }
}
