import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class ResponseOverlayViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var isVisible: Bool = false
    @Published var mode: OverlayMode = .response
    @Published var micPowerLevel: CGFloat = 0

    enum OverlayMode {
        case response
        case recording
        case transcribing
        case sidePanel
    }

    @Published var completedStepIndices: Set<Int> = []
}

// MARK: - Manager
//
// Cursor-tracking policy:
//   - .recording mode: panel follows the cursor at 60fps (user may still be aiming).
//   - .transcribing / .response: panel is frozen at the position it had when the
//     transition happened. Listening to TTS or reading streamed text shouldn't
//     drag the bubble around the screen.
//   - .sidePanel: anchored to top-right of the cursor screen — never tracks.
//   - During fade-out: tracking is off so the alpha tween isn't interrupted by
//     setFrameOrigin calls.

@MainActor
final class ResponseOverlayManager {
    private let viewModel = ResponseOverlayViewModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var trackingTimer: Timer?
    private var fadeWorkItem: DispatchWorkItem?
    private var resizeTask: Task<Void, Never>?
    private var lastKnownHeight: CGFloat = 0

    // Buddy triangle sits at mouse + (35, 25) and is 16pt wide (right edge ≈ +43).
    // Anchor the bubble to the right of that so the indigo triangle never bleeds
    // through the bubble's leading icon area.
    private let cursorOffsetX: CGFloat = 80
    private let cursorOffsetY: CGFloat = 6
    private let cursorMaxWidth: CGFloat = 340
    private let sidePanelMaxWidth: CGFloat = 460

    private var currentMaxWidth: CGFloat {
        viewModel.mode == .sidePanel ? sidePanelMaxWidth : cursorMaxWidth
    }

    func showAndBeginStreaming() {
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        viewModel.text = ""
        viewModel.mode = .response
        viewModel.isVisible = true
        makePanel()
        // Snap to current cursor once, then freeze. The user is about to read /
        // listen — they shouldn't have to chase the bubble.
        stopTracking()
        resizeToFit()
        repositionToCursor()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func showSidePanelAndBeginStreaming() {
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        viewModel.text = ""
        viewModel.mode = .sidePanel
        viewModel.isVisible = true
        viewModel.completedStepIndices = []
        makePanel()
        stopTracking()
        if let panel {
            var frame = panel.frame
            frame.size = CGSize(width: sidePanelMaxWidth, height: 72)
            panel.setFrame(frame, display: true, animate: false)
            hostingView?.frame = NSRect(origin: .zero, size: frame.size)
        }
        repositionToSidePanel()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func updateText(_ text: String) {
        viewModel.text = Self.sanitizeForDisplay(text, mode: viewModel.mode)
        scheduleResize()
    }

    func updateMicPowerLevel(_ level: CGFloat) {
        viewModel.micPowerLevel = level
    }
    
    func markStepCompleted(_ index: Int) {
        viewModel.completedStepIndices.insert(index)
    }
    
    func resetSteps() {
        viewModel.completedStepIndices.removeAll()
    }

    func showRecordingIndicator() {
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        viewModel.text = ""
        viewModel.mode = .recording
        viewModel.isVisible = false
        hide()
    }

    func showTranscribingIndicator() {
        viewModel.text = ""
        viewModel.mode = .transcribing
        viewModel.isVisible = false
        hide()
    }

    func scheduleFade(after seconds: Double) {
        fadeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fadeAndHide()
        }
        fadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        resizeTask?.cancel()
        resizeTask = nil
        stopTracking()
        viewModel.isVisible = false
        viewModel.text = ""
        lastKnownHeight = 0
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func makePanel() {
        if panel != nil { return }

        let frame = NSRect(x: 0, y: 0, width: cursorMaxWidth, height: 44)
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isExcludedFromWindowsMenu = true

        let host = NSHostingView(
            rootView: AnyView(ResponseOverlayView(viewModel: viewModel).frame(maxWidth: sidePanelMaxWidth))
        )
        host.frame = frame
        p.contentView = host
        hostingView = host
        panel = p
        lastKnownHeight = 0
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.repositionToCursor() }
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func repositionToCursor() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size

        var ox = mouse.x + cursorOffsetX
        var oy = mouse.y - cursorOffsetY - size.height

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let vf = screen.visibleFrame
            if ox + size.width > vf.maxX { ox = mouse.x - cursorOffsetX - size.width }
            if oy < vf.minY { oy = mouse.y + cursorOffsetY }
            ox = max(vf.minX, min(ox, vf.maxX - size.width))
            oy = max(vf.minY, min(oy, vf.maxY - size.height))
        }

        panel.setFrameOrigin(CGPoint(x: ox, y: oy))
    }

    private func repositionToSidePanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }

        let vf = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 24
        let topInset: CGFloat = 72
        let origin = CGPoint(
            x: max(vf.minX + margin, vf.maxX - size.width - margin),
            y: max(vf.minY + margin, vf.maxY - topInset - size.height)
        )
        panel.setFrameOrigin(origin)
    }

    // Debounce: coalesce rapid streaming updates into one resize per 80ms.
    private func scheduleResize() {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            resizeToFit()
        }
    }

    private func resizeToFit() {
        guard let panel, let host = hostingView else { return }
        let measured = measuredBubbleSize(for: viewModel.text, maxWidth: currentMaxWidth)
        let minWidth: CGFloat = viewModel.mode == .sidePanel ? 360 : 120
        let newW = min(max(measured.width, minWidth), currentMaxWidth)
        let newH = max(measured.height, 40)
        guard abs(newH - lastKnownHeight) > 1 || abs(panel.frame.width - newW) > 1 else { return }
        var frame = panel.frame
        let delta = newH - frame.height
        frame.size = CGSize(width: newW, height: newH)
        panel.setFrame(frame, display: true, animate: false)
        host.frame = NSRect(origin: .zero, size: frame.size)
        if viewModel.mode == .sidePanel {
            repositionToSidePanel()
        } else {
            // Anchor top edge — text expands downward.
            panel.setFrameOrigin(CGPoint(x: frame.origin.x, y: frame.origin.y - delta))
        }
        lastKnownHeight = newH
    }

    private func measuredBubbleSize(for text: String, maxWidth: CGFloat) -> CGSize {
        let displayText = text.isEmpty ? "..." : text
        let sidePanel = viewModel.mode == .sidePanel
        let horizontalPadding: CGFloat = sidePanel ? 40 : 28
        let verticalPadding: CGFloat = sidePanel ? 30 : 20
        let textWidth: CGFloat = maxWidth - horizontalPadding

        if sidePanel {
            let rows = displayText
                .components(separatedBy: .newlines)
                .map { line in
                    line.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: #"^[☐□\-\*\d\.\)\s]+"#, with: "", options: .regularExpression)
                }
                .filter { !$0.isEmpty }
            let rowTextWidth = textWidth - 26
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium)
            ]
            let rowHeights = (rows.isEmpty ? ["thinking..."] : rows).map { row in
                let rect = (row as NSString).boundingRect(
                    with: CGSize(width: rowTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes
                )
                return max(20, ceil(rect.height))
            }
            let spacing = CGFloat(max(0, rowHeights.count - 1)) * 10
            return CGSize(
                width: maxWidth,
                height: rowHeights.reduce(0, +) + spacing + verticalPadding
            )
        }

        let iconReservation: CGFloat = {
            switch viewModel.mode {
            case .recording: return 18 + 8     // waveform + spacing
            case .transcribing: return 16 + 8  // spinner + spacing
            default: return 0
            }
        }()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: paragraph
        ]
        let rect = (displayText as NSString).boundingRect(
            with: CGSize(width: textWidth - iconReservation, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        return CGSize(
            width: ceil(rect.width) + horizontalPadding + iconReservation,
            height: ceil(rect.height) + verticalPadding
        )
    }

    private func fadeAndHide() {
        guard let panel else { return }
        // Stop tracking BEFORE animating so setFrameOrigin doesn't fight the alpha tween.
        stopTracking()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.hide()
            }
        })
    }

    /// Bubble text: one readable line, no coordinate tags, no multi-paragraph dumps.
    /// Side-panel mode keeps newlines so each row renders as its own checklist item.
    private static func sanitizeForDisplay(_ s: String, mode: ResponseOverlayViewModel.OverlayMode) -> String {
        var t = stripAllPointTags(s)
        t = stripTrailingPartialPointTag(t)
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        if mode == .sidePanel {
            // Preserve line breaks for checklist rows; collapse only horizontal whitespace.
            while t.contains("  ") {
                t = t.replacingOccurrences(of: "  ", with: " ")
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while t.contains("\n\n") {
            t = t.replacingOccurrences(of: "\n\n", with: "\n")
        }
        t = t.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove complete `[POINT:…]` / `[BOX:…]` anywhere (models sometimes embed mid-sentence).
    private static func stripAllPointTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s*\[(?:POINT|BOX):[^\]]+\]"#, options: [.caseInsensitive]) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
    }

    // The model emits "[POINT:x,y:label]" or "[BOX:x1,y1,x2,y2:label]" at the very end of its response.
    // During streaming we strip it (and any partial match like "[POIN") so the
    // user never sees the tag flash in the bubble.
    private static func stripTrailingPartialPointTag(_ s: String) -> String {
        // Strip a complete tag at the end.
        if let r = s.range(of: #"\s*\[(POINT|BOX):[^\]]*\]\s*$"#, options: .regularExpression) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a partial trailing tag while it's still being generated.
        if let r = s.range(of: #"\s*\[(?:P(?:O(?:I(?:N(?:T(?::[0-9,\s:]*[a-zA-Z]*)?)?)?)?)?|B(?:O(?:X(?::[0-9,\s:]*[a-zA-Z]*)?)?)?)?$"#,
                           options: .regularExpression) {
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a lone "[" at the very end (earliest partial state).
        if s.hasSuffix(" [") || s.hasSuffix("\n[") {
            return String(s.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}

// MARK: - SwiftUI View

private struct ResponseOverlayView: View {
    @ObservedObject var viewModel: ResponseOverlayViewModel

    var body: some View {
        if viewModel.isVisible {
            content
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(background)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.mode == .sidePanel {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(planRows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        if viewModel.completedStepIndices.contains(index) {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundColor(Color(hex: "#15B8FF"))
                                .font(.system(size: 16))
                                .padding(.top, 2)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color(hex: "#B8C7FF").opacity(0.85), lineWidth: 1.4)
                                .frame(width: 16, height: 16)
                                .padding(.top, 2)
                        }
                        Text(row)
                            .font(.system(size: fontSize, weight: fontWeight))
                            .foregroundColor(Color(hex: "#F3F6FF"))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                Text(displayText)
                    .font(.system(size: fontSize, weight: fontWeight))
                    .foregroundColor(Color(hex: "#ECEEED"))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }



    @ViewBuilder
    private var background: some View {
        if viewModel.mode == .sidePanel {
            SiriBluePanelBackground(cornerRadius: cornerRadius)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(hex: "#171918").opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(hex: "#373B39").opacity(0.5), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
        }
    }

    private var displayText: String {
        if viewModel.text.isEmpty {
            switch viewModel.mode {
            case .recording: return "listening..."
            case .transcribing: return "thinking..."
            case .response, .sidePanel: return "..."
            }
        }
        return viewModel.text
    }

    private var planRows: [String] {
        let rows = displayText
            .components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^[☐□\-\*\d\.\)\s]+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
        return rows.isEmpty ? ["thinking..."] : rows
    }

    private var contentWidth: CGFloat {
        viewModel.mode == .sidePanel ? 400 : 300
    }

    private var fontSize: CGFloat {
        viewModel.mode == .sidePanel ? 15 : 13
    }

    private var fontWeight: Font.Weight {
        viewModel.mode == .sidePanel ? .medium : .regular
    }

    private var horizontalPadding: CGFloat {
        viewModel.mode == .sidePanel ? 18 : 14
    }

    private var verticalPadding: CGFloat {
        viewModel.mode == .sidePanel ? 16 : 10
    }

    private var cornerRadius: CGFloat {
        viewModel.mode == .sidePanel ? 18 : 10
    }
}

private struct TransparentGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        view.alphaValue = 0.25
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SiriBluePanelBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            // 1. Frosted glass base
            TransparentGlassView()

            // 2. Siri-blue gradient tint
            LinearGradient(
                colors: [
                    Color(hex: "#1A3AFF").opacity(0.18),
                    Color(hex: "#0A8FFF").opacity(0.12),
                    Color(hex: "#00C2FF").opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 3. Specular border
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: Color(hex: "#1A3AFF").opacity(0.2), radius: 16, x: 0, y: 8)
    }
}

// MARK: - Leading indicator icons

struct OverlayWaveformIcon: View {
    let powerLevel: CGFloat
    private let buddyColor = Color(red: 0.42, green: 0.44, blue: 1.0)
    private let barCount = 5
    private let barProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { ctx in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(buddyColor)
                        .frame(width: 1.6, height: barHeight(for: i, date: ctx.date))
                }
            }
            .animation(.linear(duration: 0.08), value: powerLevel)
        }
    }

    private func barHeight(for index: Int, date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(index) * 0.35
        let normalised = max(powerLevel - 0.008, 0)
        let eased = pow(min(normalised * 2.85, 1), 0.76)
        let reactive = eased * 9 * barProfile[index]
        let idle = (sin(phase) + 1) / 2 * 1.5
        return 3 + reactive + idle
    }
}

struct OverlaySpinnerIcon: View {
    @State private var isSpinning = false
    private let buddyColor = Color(red: 0.42, green: 0.44, blue: 1.0)

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [buddyColor.opacity(0.0), buddyColor],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
            )
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Minimal hex color extension used by the overlay view
private extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255,
            green: Double((rgb & 0x00FF00) >> 8) / 255,
            blue: Double(rgb & 0x0000FF) / 255
        )
    }
}
