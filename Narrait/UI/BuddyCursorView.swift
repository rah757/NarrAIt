//
//  BuddyCursorView.swift
//  Narrait
//
//  SwiftUI view rendered inside BuddyOverlayWindow.
//  Replicates farzaa/clicky's BlueCursorView with the full feature set:
//
//  • Cursor following  — 60fps Timer, offset (+35, +25), spring animation
//  • Element navigation — bezier arc flight when AI points to a screen element
//  • Pointing mode     — speech bubble with character-stream entrance
//  • Low-vision trail  — smooth Canvas gradient line during AI navigation
//
//  Listening waveform and processing spinner are rendered inside the response
//  bubble (ResponseOverlay), not on the cursor — see ResponseOverlay.leadingIndicator.
//
//  Driven by ActivationCoordinator.State (idle/recording/transcribing/streaming/playing).
//

import AppKit
import SwiftUI

// MARK: - Buddy Navigation Mode

/// Controls whether the buddy follows the cursor, is mid-flight to a target,
/// or is pointing at and labelling a target element.
enum BuddyNavigationMode: Equatable, Sendable {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

// MARK: - Triangle Shape

/// A cursor-like equilateral triangle. Default rotation (-35°) looks like a
/// macOS pointer. Rotation changes to face direction of travel during flight.
struct BuddyTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let h = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - h / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + h / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + h / 3))
        path.closeSubpath()
        return path
    }
}

// MARK: - PreferenceKeys

private struct BuddyBubbleSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Buddy Cursor View

/// Placed inside a full-screen BuddyOverlayWindow. Each screen gets its own
/// BuddyCursorView instance; the buddy is only rendered on the screen where
/// the cursor currently lives (or on the screen that owns a navigation target).
struct BuddyCursorView: View {

    let screenFrame: CGRect
    @ObservedObject var coordinator: ActivationCoordinator

    // MARK: - Cursor tracking

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    @State private var trackingTimer: Timer?
    @State private var cursorOpacity: Double = 1.0

    // MARK: - Navigation state

    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor
    @State private var triangleRotationDegrees: Double = -35.0
    @State private var buddyFlightScale: CGFloat = 1.0
    @State private var isReturningToCursor: Bool = false
    @State private var navigationAnimationTimer: Timer?
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    // MARK: - Navigation bubble

    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero
    @State private var navigationBubbleScale: CGFloat = 1.0

    // MARK: - Low-vision trail (Canvas path)

    /// All 60fps positions sampled during the current AI-driven flight.
    /// Rendered as a single smooth Canvas stroke — zero per-view overhead.
    @State private var flightPath: [CGPoint] = []
    /// Drives the trail fade-out via SwiftUI animation after landing.
    @State private var trailOpacity: Double = 0.0

    // Phrases the buddy says when it arrives at a pointed element
    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "here it is!",
        "found it!"
    ]

    // MARK: - Buddy color (Narrait brand: indigo instead of Clicky's blue)

    private let buddyColor = Color(red: 0.42, green: 0.44, blue: 1.0)   // #6B70FF — indigo

    // MARK: - Init

    init(screenFrame: CGRect, coordinator: ActivationCoordinator) {
        self.screenFrame = screenFrame
        self.coordinator = coordinator

        // Seed position from current mouse location so buddy doesn't flash at (0,0)
        let mouse = NSEvent.mouseLocation
        let localX = mouse.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouse.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouse))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Near-transparent fill helps compositing
            Color.black.opacity(0.001)

            // ── Low-vision trail (Canvas) ─────────────────────────────────────────
            // A single continuous stroke drawn through every 60fps sample point.
            // The gradient goes from fully transparent at the tail to indigo at the
            // head, giving a natural "comet tail" look with zero SwiftUI view overhead.
            // Only rendered in the low-vision profile during AI-driven navigation.
            if AccessProfile.current == .vision, flightPath.count >= 2 {
                Canvas { context, _ in
                    let points = flightPath
                    let count = points.count

                    // ── Glow pass (wider, lower opacity) ────────────────────────
                    // Drawn first so it sits behind the crisp stroke.
                    var glowPath = Path()
                    glowPath.move(to: points[0])
                    for i in 1..<count {
                        glowPath.addLine(to: points[i])
                    }
                    context.stroke(
                        glowPath,
                        with: .linearGradient(
                            Gradient(colors: [
                                buddyColor.opacity(0),
                                buddyColor.opacity(0.25)
                            ]),
                            startPoint: points.first!,
                            endPoint: points.last!
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )

                    // ── Core stroke pass (crisp, higher opacity) ─────────────
                    var corePath = Path()
                    corePath.move(to: points[0])
                    for i in 1..<count {
                        corePath.addLine(to: points[i])
                    }
                    context.stroke(
                        corePath,
                        with: .linearGradient(
                            Gradient(colors: [
                                buddyColor.opacity(0),
                                buddyColor.opacity(0.75)
                            ]),
                            startPoint: points.first!,
                            endPoint: points.last!
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }
                .frame(width: screenFrame.width, height: screenFrame.height)
                .opacity(trailOpacity)
                .allowsHitTesting(false)
            }

            // Navigation pointer bubble — pops in with scale bounce when buddy arrives
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(buddyColor)
                            .shadow(
                                color: buddyColor.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear.preference(key: BuddyBubbleSizeKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + navigationBubbleSize.width / 2,
                              y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0),
                               value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(BuddyBubbleSizeKey.self) { navigationBubbleSize = $0 }
            }

            if coordinator.state == .recording {
                OverlayWaveformIcon(powerLevel: coordinator.micPowerLevel)
                    .frame(width: 18, height: 18)
                    .scaleEffect(buddyFlightScale)
                    .opacity(shouldShowBuddyOnThisScreen ? cursorOpacity : 0)
                    .position(cursorPosition)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            } else if coordinator.state == .transcribing || coordinator.state == .capturing {
                OverlaySpinnerIcon()
                    .frame(width: 16, height: 16)
                    .scaleEffect(buddyFlightScale)
                    .opacity(shouldShowBuddyOnThisScreen ? cursorOpacity : 0)
                    .position(cursorPosition)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            } else {
                // Triangle cursor — visible whenever the buddy belongs on this screen
                // and we're not in an assessment lockout.
                BuddyTriangle()
                    .fill(buddyColor)
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(triangleRotationDegrees))
                    .shadow(color: buddyColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                    .scaleEffect(buddyFlightScale)
                    .opacity(shouldShowBuddyOnThisScreen && isTriangleVisible ? cursorOpacity : 0)
                    .position(cursorPosition)
                    .animation(
                        buddyNavigationMode == .followingCursor
                            ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                            : nil,
                        value: cursorPosition
                    )
                    .animation(.easeIn(duration: 0.25), value: coordinator.state)
                    .animation(
                        buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                        value: triangleRotationDegrees
                    )
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouse = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouse)
            let pos = convertToSwiftUI(mouse)
            cursorPosition = CGPoint(x: pos.x + 35, y: pos.y + 25)
            startTrackingCursor()
        }
        .onDisappear {
            trackingTimer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: coordinator.pointingTarget?.screenLocation) { _, newLocation in
            guard let target = coordinator.pointingTarget else {
                if buddyNavigationMode != .followingCursor {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }
            // Only navigate if the target lives on this screen
            guard screenFrame.contains(target.screenLocation) else { return }
            startNavigatingToElement(screenLocation: target.screenLocation, label: target.label)
        }
    }

    // MARK: - Visibility helpers

    /// Whether any part of the buddy should be drawn on this screen.
    private var shouldShowBuddyOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen is navigating, hide here so only one buddy is visible
            if coordinator.pointingTarget != nil { return false }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    private var isTriangleVisible: Bool {
        coordinator.state != .blocked
    }

    // MARK: - Cursor tracking (60fps)

    private func startTrackingCursor() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                let mouse = NSEvent.mouseLocation
                self.isCursorOnThisScreen = self.screenFrame.contains(mouse)

                // During return flight, allow cursor movement to cancel back to following
                if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                    let pos = self.convertToSwiftUI(mouse)
                    let dist = hypot(pos.x - self.cursorPositionWhenNavigationStarted.x,
                                     pos.y - self.cursorPositionWhenNavigationStarted.y)
                    if dist > 100 { self.cancelNavigationAndResumeFollowing() }
                    return
                }

                // During forward navigation or pointing, skip cursor tracking
                if self.buddyNavigationMode != .followingCursor { return }

                let pos = self.convertToSwiftUI(mouse)
                self.cursorPosition = CGPoint(x: pos.x + 35, y: pos.y + 25)
            }
        }
    }

    /// Converts AppKit screen coordinates (bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertToSwiftUI(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        )
    }

    // MARK: - Element Navigation

    private func startNavigatingToElement(screenLocation: CGPoint, label: String?) {
        let targetInSwiftUI = convertToSwiftUI(screenLocation)
        let offsetTarget = CGPoint(x: targetInSwiftUI.x + 8, y: targetInSwiftUI.y + 12)
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        let mouse = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertToSwiftUI(mouse)
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlight(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement(label: label)
        }
    }

    /// Animates the buddy along a quadratic bezier arc to the destination.
    /// The triangle rotates to face its direction of travel (tangent to curve),
    /// scales up at the arc's apex, and the glow intensifies during flight.
    /// In the low-vision profile every frame position is recorded into `flightPath`
    /// and rendered as a single smooth gradient stroke via Canvas.
    private func animateBezierFlight(to destination: CGPoint, onComplete: @escaping () -> Void) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let deltaX = destination.x - startPosition.x
        let deltaY = destination.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let flightDuration = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDuration / frameInterval)
        var currentFrame = 0

        // Quadratic bezier control point: arc height proportional to distance
        let midPoint = CGPoint(
            x: (startPosition.x + destination.x) / 2.0,
            y: (startPosition.y + destination.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        // Seed the path at the starting position so the gradient has an origin
        if AccessProfile.current == .vision {
            flightPath = [startPosition]
            trailOpacity = 1.0
        }

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            Task { @MainActor in
                currentFrame += 1

                if currentFrame > totalFrames {
                    self.navigationAnimationTimer?.invalidate()
                    self.navigationAnimationTimer = nil
                    self.cursorPosition = destination
                    self.buddyFlightScale = 1.0
                    onComplete()
                    return
                }

                let linearProgress = Double(currentFrame) / Double(totalFrames)
                // Smoothstep easeInOut: 3t² - 2t³
                let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)
                let oneMinusT = 1.0 - t

                // Quadratic bezier B(t) = (1-t)²P0 + 2(1-t)tP1 + t²P2
                let bx = oneMinusT * oneMinusT * startPosition.x
                       + 2.0 * oneMinusT * t * controlPoint.x
                       + t * t * destination.x
                let by = oneMinusT * oneMinusT * startPosition.y
                       + 2.0 * oneMinusT * t * controlPoint.y
                       + t * t * destination.y
                self.cursorPosition = CGPoint(x: bx, y: by)

                // Tangent-based rotation: B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
                let tx = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                       + 2.0 * t * (destination.x - controlPoint.x)
                let ty = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                       + 2.0 * t * (destination.y - controlPoint.y)
                self.triangleRotationDegrees = atan2(ty, tx) * (180.0 / .pi) + 90.0

                // Scale pulse: peaks at arc midpoint (sin curve)
                let scalePulse = sin(linearProgress * .pi)
                self.buddyFlightScale = 1.0 + scalePulse * 0.3

                // ── Low-vision trail: append every frame for maximum smoothness ──
                if AccessProfile.current == .vision {
                    self.flightPath.append(CGPoint(x: bx, y: by))
                }
            }
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with
    /// scale-bounce entrance and character-by-character streaming.
    private func startPointingAtElement(label: String?) {
        buddyNavigationMode = .pointingAtTarget
        triangleRotationDegrees = -35.0

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        let useRandom = (label == nil || label == "target")
        let phrase = useRandom ? (navigationPointerPhrases.randomElement() ?? "right here!") : label!
        streamBubbleCharacter(phrase: phrase, index: 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    if !self.coordinator.pendingPlanSteps.isEmpty {
                        // Stay pointing at the target until user clicks to advance the plan
                    } else {
                        self.startFlyingBackToCursor()
                    }
                }
            }
        }
    }

    /// Streams the bubble text one character at a time (30–60ms per char).
    private func streamBubbleCharacter(phrase: String, index: Int, onComplete: @escaping () -> Void) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard index < phrase.count else { onComplete(); return }
        let charIndex = phrase.index(phrase.startIndex, offsetBy: index)
        navigationBubbleText.append(phrase[charIndex])
        if index == 0 { navigationBubbleScale = 1.0 }
        let delay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.streamBubbleCharacter(phrase: phrase, index: index + 1, onComplete: onComplete)
        }
    }

    private func startFlyingBackToCursor() {
        let mouse = NSEvent.mouseLocation
        let cursorInSwiftUI = convertToSwiftUI(mouse)
        let target = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)
        cursorPositionWhenNavigationStarted = cursorInSwiftUI
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true
        animateBezierFlight(to: target) { self.finishNavigation() }
    }

    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        fadeAndClearTrail()
        finishNavigation()
    }

    private func finishNavigation() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        fadeAndClearTrail()
        coordinator.clearPointingTarget()
    }

    // MARK: - Low-vision trail helpers

    /// Fades the trail out with a smooth SwiftUI animation, then clears the
    /// point buffer so the Canvas stops drawing. Called after every flight.
    private func fadeAndClearTrail() {
        guard AccessProfile.current == .vision, !flightPath.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.55)) {
            trailOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            self.flightPath = []
        }
    }
}
