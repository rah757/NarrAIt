import AppKit
import Combine
import Foundation

// The single orchestrator. Owns the activation state machine.
// All API clients and UI components are called from here; they never call each other.
//
// State machine (ARCHITECTURE.md §2):
//   idle → capturing → streaming → playing → idle
//   idle → recording → transcribing → streaming (voice path)
//   any → blocked (AssessmentDetector) → idle
@MainActor
final class ActivationCoordinator: ObservableObject {

    enum State {
        case idle
        case capturing
        case streaming
        case playing
        case recording
        case transcribing
        case blocked
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isBlocked: Bool = false

    // MARK: - Buddy cursor published state

    @Published private(set) var pendingPlanSteps: [String] = []
    @Published private(set) var currentPlanStepIndex: Int = 0

    /// Set when the AI returns a [POINT:] coordinate. BuddyCursorView observes this
    /// to fly the buddy to the element; call clearPointingTarget() on arrival.
    @Published private(set) var pointingTarget: BuddyPointingTarget?

    /// Forwarded from MicRecorder so BuddyCursorView can animate the waveform.
    @Published private(set) var micPowerLevel: CGFloat = 0

    // Voice request fans out into two downstream paths.
    // Sonnet decides at generation time whether it points or returns a checklist;
    // the UI watches the stream and switches between bubble and side panel.
    enum VoiceIntent: Equatable {
        case explain   // pure description/answer → Gemini Flash → bubble
        case action    // do something → Sonnet → bubble (point) OR side panel (plan)
    }

    // Injected dependencies
    let overlay: ResponseOverlayManager
    let cursorPointer: CursorPointer
    let ttsClient: GeminiTTSClient
    let claudeClient: GeminiClient
    let micRecorder: MicRecorder
    let groqClient: GroqWhisperClient
    let conversationStore: ConversationStore

    private let hotkeyMonitor: GlobalHotkeyMonitor
    private let assessmentDetector: AssessmentDetector
    private let routerClient = GeminiFlashRouterClient()
    private let magnifier = MagnifierPanel()
    private var hotkeySubscription: AnyCancellable?
    private var assessmentSubscription: AnyCancellable?
    private var micPowerSubscription: AnyCancellable?
    private var globalMouseSubscription: Any?
    private var localMouseSubscription: Any?
    private var currentTask: Task<Void, Never>?

    init(
        overlay: ResponseOverlayManager,
        cursorPointer: CursorPointer,
        ttsClient: GeminiTTSClient,
        claudeClient: GeminiClient,
        micRecorder: MicRecorder,
        groqClient: GroqWhisperClient,
        conversationStore: ConversationStore,
        hotkeyMonitor: GlobalHotkeyMonitor,
        assessmentDetector: AssessmentDetector
    ) {
        self.overlay = overlay
        self.cursorPointer = cursorPointer
        self.ttsClient = ttsClient
        self.claudeClient = claudeClient
        self.micRecorder = micRecorder
        self.groqClient = groqClient
        self.conversationStore = conversationStore
        self.hotkeyMonitor = hotkeyMonitor
        self.assessmentDetector = assessmentDetector
    }

    func start() {
        hotkeyMonitor.start()
        hotkeySubscription = hotkeyMonitor.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleHotkey(event)
            }

        assessmentDetector.start()
        assessmentSubscription = assessmentDetector.$isAssessmentActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                if active { self?.block() } else { self?.unblock() }
            }

        // Forward mic power level to the published property so BuddyCursorView
        // can animate the waveform without needing a direct reference to MicRecorder.
        micPowerSubscription = micRecorder.$currentPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.micPowerLevel = level
                self?.overlay.updateMicPowerLevel(level)
            }
            
        globalMouseSubscription = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in self?.handleMouseClick() }
        }
        localMouseSubscription = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in self?.handleMouseClick() }
            return event
        }
    }

    func stop() {
        hotkeyMonitor.stop()
        hotkeySubscription?.cancel()
        assessmentDetector.stop()
        assessmentSubscription?.cancel()
        micPowerSubscription?.cancel()
        if let g = globalMouseSubscription { NSEvent.removeMonitor(g) }
        if let l = localMouseSubscription { NSEvent.removeMonitor(l) }
        cancelCurrentTask()
    }

    /// Called by BuddyCursorView after it finishes pointing at an element
    /// and has flown back to the cursor position.
    func clearPointingTarget() {
        pointingTarget = nil
    }

    func block() {
        guard state != .blocked else { return }
        cancelCurrentTask()
        ttsClient.cancel()
        overlay.hide()
        magnifier.stop()
        pointingTarget = nil
        pendingPlanSteps = []
        overlay.resetSteps()
        conversationStore.clear()
        state = .blocked
        isBlocked = true
        print("🔒 ActivationCoordinator: blocked (assessment context)")
    }

    func unblock() {
        guard state == .blocked else { return }
        state = .idle
        isBlocked = false
        print("🔓 ActivationCoordinator: unblocked")
    }

    // MARK: - Plan Execution

    private func handleMouseClick() {
        guard state == .idle, !pendingPlanSteps.isEmpty, currentPlanStepIndex < pendingPlanSteps.count else { return }
        print("🖱️ Mouse clicked during plan execution. Advancing step.")
        
        // Mark current step completed
        overlay.markStepCompleted(currentPlanStepIndex)
        currentPlanStepIndex += 1
        
        clearPointingTarget()
        
        // Cancel any pending pointing from a previous step
        currentTask?.cancel()
        
        if currentPlanStepIndex >= pendingPlanSteps.count {
            pendingPlanSteps = []
            overlay.scheduleFade(after: 3)
            return
        }

        let nextStep = pendingPlanSteps[currentPlanStepIndex]
        currentTask = Task {
            do {
                try await ttsClient.speak(nextStep, speed: AccessProfile.current.ttsSpeed)
                try await executeNextPlanStep()
            } catch {
                print("⚠️ Plan step execution failed: \(error)")
            }
        }
    }

    private func executeNextPlanStep() async throws {
        guard currentPlanStepIndex < pendingPlanSteps.count else { return }
        
        let stepText = pendingPlanSteps[currentPlanStepIndex]
        print("🗂️ Executing plan step \(currentPlanStepIndex + 1): \(stepText)")
        
        // Wait for UI transitions to settle after a click before capturing the screen
        try await Task.sleep(nanoseconds: 1_200_000_000)
        guard !Task.isCancelled else { return }
        
        let screens = try await ScreenCapture.captureAllScreens()
        guard !Task.isCancelled else { return }
        
        let labeledImages = screens.map { s -> (data: Data, label: String) in
            let dim = " (image dimensions: \(s.screenshotWidthInPixels)x\(s.screenshotHeightInPixels) pixels)"
            return (data: s.imageData, label: s.label + dim)
        }
        
        let systemPrompt = """
        You are an expert at locating UI elements on a screen.
        You have access to the `computer` tool. You MUST use it (action: "mouse_move") to point to the exact UI element the user needs to click.
        Do not use the give_plan tool. Do not write any prose.
        """
        
        let userPrompt = """
        Find the UI element for this step: "\(stepText)".
        Use the computer tool to point to it. If it is not visible, do nothing.
        """
        
        // Silent background call
        let response = try await claudeClient.stream(
            systemPrompt: systemPrompt,
            images: labeledImages,
            conversationHistory: [],
            userPrompt: userPrompt,
            onTextChunk: { _ in } // Silently consume chunks
        )
        guard !Task.isCancelled else { return }
        
        let result = GeminiClient.parsePointing(from: response)
        if result.coordinate != nil {
            let polishedResult = GeminiClient.PointingResult(
                spokenText: result.spokenText,
                coordinate: result.coordinate,
                boundingBox: result.boundingBox,
                elementLabel: result.elementLabel,
                screenNumber: result.screenNumber
            )
            handlePointTo(result: polishedResult, screens: screens)
        }
    }

    // MARK: - Hotkey handling

    private func handleHotkey(_ event: HotkeyEvent) {
        print("🎯 Coordinator: handleHotkey \(event) (state=\(state))")
        guard state != .blocked else { return }

        switch event {
        case .hoverStart:
            startHoverExplain()
        case .hoverEnd:
            if state != .recording && state != .transcribing {
                cancelCurrentTask()
                overlay.scheduleFade(after: 0.2)
            }
        case .voiceStart:
            startVoiceRecording()
        case .voiceEnd:
            stopVoiceRecording()
        case .magnifierToggle:
            guard AccessProfile.current == .vision else { return }
            magnifier.toggle()
        }
    }

    // MARK: - Hover-explain (3-level fallback)
    //
    // Level 1 — cursor-centered crop with visible marker, plus selected text if present
    // Level 3 — full screen only, enabling [POINT:] coordinates
    //
    // Screenshot captures start in parallel at Level 1 so they're ready if needed.

    private func startHoverExplain() {
        print("🎬 Coordinator: startHoverExplain (state=\(state))")
        cancelCurrentTask()
        pendingPlanSteps = []
        overlay.resetSteps()

        currentTask = Task {
            do {
                state = .capturing

                let mousePos  = NSEvent.mouseLocation
                let selectedText = AccessibilityReader.selectedText()
                let history   = conversationStore.recentTurns()
                let sysPrompt = SystemPrompts.fullPrompt(for: .current)

                // Kick off screenshot captures immediately in parallel.
                async let windowDataTask = ScreenCapture.captureWindowUnderCursor()
                async let screenTask     = ScreenCapture.captureCursorScreen()

                // ── Level 1: cursor-centered crop (1 image, exact hover target) ───────
                let (windowData, screen) = try await (windowDataTask, screenTask)
                guard !Task.isCancelled else { return }

                let cursorPx = ScreenCapture.cursorPixelPosition(in: screen, mouse: mousePos)
                var prompt2 = "The center of the image marks exactly what the user is pointing at. Answer from a 'what am i pointing to?' perspective: identify the item and explain what it is or why it matters in this app/workflow. Use recent history only to infer intent. Do not describe its screen location unless location is the useful answer. One short spoken sentence."
                if let text = selectedText, text.count > 0 {
                    prompt2 += " The user also selected this text: \"\(text)\". Use it as exact text context, but still answer about the hovered target."
                }

                var images2: [(data: Data, label: String)] = []
                if let crop = ScreenCapture.cropAroundCursor(from: [screen], mouse: mousePos) {
                    images2.append((crop, "CURSOR CROP — the center of the image is the exact hovered point"))
                } else if let wd = windowData {
                    images2.append((wd, "ACTIVE WINDOW under cursor — answer only about the cursor location if identifiable"))
                } else {
                    // No window captured — use full screen directly as Level 2.
                    images2.append((screen.imageData,
                        "FULL CURSOR SCREEN (\(screen.screenshotWidthInPixels)×\(screen.screenshotHeightInPixels)px) — use THESE pixel coordinates for [POINT:y,x]"))
                }

                state = .streaming
                overlay.showAndBeginStreaming()

                let response2 = try await routerClient.answer(
                    systemPrompt: sysPrompt, images: images2,
                    conversationHistory: history, userPrompt: prompt2,
                    onTextChunk: { [weak self] c in self?.overlay.updateText(c) }
                )
                guard !Task.isCancelled else { return }

                if !response2.contains("[NEED_MORE_CONTEXT]"), !Self.looksIncomplete(response2) {
                    // No full screen at Level 2 — skip pointing (no coordinate ref image).
                    try await finishHover(response2, historyUserText: "hovered the marked screen item", screen: nil, screens: [])
                    return
                }

                // ── Level 3: full screen (enables [POINT:] coordinate tagging) ────────
                overlay.updateText("getting full screen context…")
                state = .streaming
                overlay.showAndBeginStreaming()

                let prompt3 = "Cursor at screenshot pixel (\(Int(cursorPx.x)), \(Int(cursorPx.y))). Display \(screen.screenshotWidthInPixels)×\(screen.screenshotHeightInPixels)px. The user is pointing at that exact item. Identify it and explain what it is or why it matters in this app/workflow in one short spoken sentence. Do not describe its screen location unless location is the useful answer. If you include a point tag, use [POINT:y,x:label] with these full-screen pixel coordinates."
                let response3 = try await routerClient.answer(
                    systemPrompt: sysPrompt,
                    images: [(screen.imageData, "FULL CURSOR SCREEN (\(screen.screenshotWidthInPixels)×\(screen.screenshotHeightInPixels)px) — use THESE pixel coordinates for [POINT:y,x]")],
                    conversationHistory: history, userPrompt: prompt3,
                    onTextChunk: { [weak self] c in self?.overlay.updateText(c) }
                )
                guard !Task.isCancelled else { return }
                try await finishHover(response3, historyUserText: "hovered the marked screen item", screen: screen, screens: [screen])

            } catch is CancellationError {
            } catch let e as NSError where e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled {
            } catch {
                print("⚠️ ActivationCoordinator hover error: \(error)")
                overlay.updateText(Self.friendlyError(error))
                overlay.scheduleFade(after: 4)
                state = .idle
            }
        }
    }

    // Shared completion step: parse pointing, update store, speak, fade.
    private func finishHover(_ text: String, historyUserText: String, screen: ScreenCaptureResult?, screens: [ScreenCaptureResult]) async throws {
        let result = GeminiClient.parsePointing(from: text)
        let spokenText = Self.polishSpokenText(result.spokenText, fallback: "that's the marked item.")
        let polishedResult = GeminiClient.PointingResult(
            spokenText: spokenText,
            coordinate: result.coordinate,
            boundingBox: result.boundingBox,
            elementLabel: result.elementLabel,
            screenNumber: result.screenNumber
        )
        print("🔊 Final spoken output: \"\(spokenText)\"")
        overlay.updateText(spokenText)
        conversationStore.append(userText: historyUserText, assistantText: spokenText)
        if let s = screen { handlePointTo(result: result, screens: [s]) }
        state = .playing
        try await ttsClient.speak(polishedResult.spokenText, speed: AccessProfile.current.ttsSpeed)
        guard !Task.isCancelled else { return }
        state = .idle
        overlay.scheduleFade(after: 3)
    }

    // MARK: - Voice loop

    private func startVoiceRecording() {
        // Allow starting voice from idle, mid-hover, or while audio is still playing —
        // user wants to interrupt with a follow-up question.
        guard state != .blocked, state != .recording, state != .transcribing else { return }
        print("🎬 Coordinator: startVoiceRecording (state=\(state))")
        cancelCurrentTask()
        pendingPlanSteps = []
        overlay.resetSteps()

        // Set state synchronously so a fast voiceEnd doesn't race past it.
        state = .recording
        overlay.showRecordingIndicator()

        currentTask = Task {
            do {
                try await micRecorder.start()
            } catch {
                print("⚠️ ActivationCoordinator: mic start failed: \(error)")
                state = .idle
                overlay.hide()
            }
        }
    }

    private func stopVoiceRecording() {
        print("🛑 Coordinator: stopVoiceRecording (state=\(state))")

        // Always stop the mic. macOS sometimes drops modifier-up events and we never
        // want the engine left running.
        let wasRecording = state == .recording
        if !wasRecording {
            Task { await micRecorder.stop() }
            if state != .blocked {
                overlay.hide()
                state = .idle
            }
            return
        }

        currentTask = Task {
            do {
                state = .transcribing
                overlay.showTranscribingIndicator()

                let pcmData = await micRecorder.stop()
                guard let audio = pcmData, !Task.isCancelled else {
                    state = .idle
                    overlay.hide()
                    return
                }

                let transcript = try await groqClient.transcribe(audioData: audio)
                guard !Task.isCancelled, !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
                    state = .idle
                    overlay.hide()
                    return
                }
                print("🎙️ Voice input: \"\(transcript)\"")

                let screens = try await ScreenCapture.captureAllScreens()
                guard !Task.isCancelled else { return }

                let labeledImages = screens.map { s -> (data: Data, label: String) in
                    let dim = " (image dimensions: \(s.screenshotWidthInPixels)x\(s.screenshotHeightInPixels) pixels)"
                    return (data: s.imageData, label: s.label + dim)
                }

                let history = conversationStore.recentTurns()
                let systemPrompt = SystemPrompts.fullPrompt(for: .current)

                // ── Binary route: Gemini Flash → fallback keyword classifier → default .action ──
                let intent = await resolveVoiceIntent(
                    transcript: transcript,
                    firstImage: labeledImages.first,
                    history: history
                )
                print("🧭 Voice intent: \(intent)")

                state = .streaming

                // ── .explain → Gemini Flash answers directly (no Sonnet, no Computer Use) ──
                if intent == .explain {
                    overlay.showAndBeginStreaming()
                    let answerPrompt = """
                    \(transcript)

                    Answer style: be concise and practical. If this is a broad screen question, name the current app/window and the main useful thing visible. Do not list every panel, log line, sidebar, or dock icon unless the user explicitly asks for detail. End with [POINT:none].
                    """
                    let answer = try await routerClient.answer(
                        systemPrompt: systemPrompt,
                        images: labeledImages,
                        conversationHistory: history,
                        userPrompt: answerPrompt,
                        onTextChunk: { [weak self] accumulated in
                            self?.overlay.updateText(accumulated)
                        }
                    )
                    guard !Task.isCancelled else { return }

                    let spokenAnswer = Self.polishSpokenText(answer, fallback: "you're looking at the current app screen.")
                    print("🔊 Final spoken output: \"\(spokenAnswer)\"")
                    overlay.updateText(spokenAnswer)
                    conversationStore.append(userText: transcript, assistantText: spokenAnswer)
                    state = .playing
                    try await ttsClient.speak(spokenAnswer, speed: AccessProfile.current.ttsSpeed)
                    guard !Task.isCancelled else { return }
                    state = .idle
                    overlay.scheduleFade(after: 3)
                    return
                }

                // ── .action → Sonnet decides at generation time: point OR plan ──
                let userPrompt = Self.actionPrompt(for: transcript, screens: screens)

                // Start in bubble mode; if Sonnet emits ☐ in its stream, we flip to side panel.
                overlay.showAndBeginStreaming()
                var hasShownSidePanel = false

                let actionHistory = Self.isFollowUp(transcript) ? Array(history.suffix(2)) : []
                let fullText = try await claudeClient.stream(
                    systemPrompt: systemPrompt,
                    images: labeledImages,
                    conversationHistory: actionHistory,
                    userPrompt: userPrompt,
                    onTextChunk: { [weak self] accumulated in
                        guard let self else { return }
                        if !hasShownSidePanel && Self.looksLikeChecklist(accumulated) {
                            hasShownSidePanel = true
                            self.overlay.showSidePanelAndBeginStreaming()
                        }
                        let display = hasShownSidePanel
                            ? Self.normalizedPlanChecklist(accumulated)
                            : GeminiClient.parsePointing(from: accumulated).spokenText
                        self.overlay.updateText(display)
                    }
                )
                guard !Task.isCancelled else { return }

                let result = GeminiClient.parsePointing(from: fullText)
                let isPlan = Self.looksLikeChecklist(fullText)

                if isPlan {
                    let checklist = Self.normalizedPlanChecklist(result.spokenText)
                    // Empty-checklist guard: degrade to bubble explain rather than empty side panel.
                    if checklist.isEmpty {
                        let fallback = Self.polishSpokenText(result.spokenText, fallback: "couldn't draft a plan for that.")
                        overlay.showAndBeginStreaming()
                        overlay.updateText(fallback)
                        conversationStore.append(userText: transcript, assistantText: fallback)
                        state = .playing
                        try await ttsClient.speak(fallback, speed: AccessProfile.current.ttsSpeed)
                        guard !Task.isCancelled else { return }
                        state = .idle
                        overlay.scheduleFade(after: 3)
                        return
                    }
                    if !hasShownSidePanel {
                        // Sonnet decided plan late — switch UI now before final render.
                        overlay.showSidePanelAndBeginStreaming()
                    }
                    overlay.updateText(checklist)
                    conversationStore.append(userText: transcript, assistantText: checklist)
                    self.pendingPlanSteps = Self.extractPlanSteps(from: result.spokenText)
                    self.currentPlanStepIndex = 0
                    self.overlay.resetSteps()

                    // Speak only step 1 — each subsequent step is spoken after the user checks it off.
                    let firstStep = self.pendingPlanSteps.first ?? ""
                    print("🔊 Final spoken output: \"\(firstStep)\"")
                    state = .playing
                    try await ttsClient.speak(firstStep, speed: AccessProfile.current.ttsSpeed)
                    guard !Task.isCancelled else { return }
                    state = .idle

                    try await self.executeNextPlanStep()
                    return
                }

                // Point or plain-speech path — Sonnet may or may not have used Computer Use.
                logPointingResult(result, screens: screens)
                let spokenText = Self.polishSpokenText(result.spokenText, fallback: "i marked it on your screen.")
                let polishedResult = GeminiClient.PointingResult(
                    spokenText: spokenText,
                    coordinate: result.coordinate,
                    boundingBox: result.boundingBox,
                    elementLabel: result.elementLabel,
                    screenNumber: result.screenNumber
                )
                print("🔊 Final spoken output: \"\(spokenText)\"")
                overlay.updateText(spokenText)
                conversationStore.append(userText: transcript, assistantText: spokenText)

                state = .playing
                try await playWithDelayedPointing(result: polishedResult, screens: screens)
                guard !Task.isCancelled else { return }

                state = .idle
                overlay.scheduleFade(after: 3)

            } catch is CancellationError {
                state = .idle
            } catch let e as NSError where e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled {
                state = .idle
            } catch {
                print("⚠️ ActivationCoordinator voice error: \(error)")
                let msg = Self.friendlyError(error)
                overlay.updateText(msg)
                overlay.scheduleFade(after: 4)
                state = .idle
            }
        }
    }

    // MARK: - TTS + cursor pointing
    //
    // Order matters: previously the cursor warped BEFORE TTS started, so the user
    // saw their cursor jump with no audio context. Now we kick off TTS first and
    // schedule the warp ~250ms in so the user is already hearing the explanation
    // when their attention is redirected.
    private func playWithDelayedPointing(
        result: GeminiClient.PointingResult,
        screens: [ScreenCaptureResult]
    ) async throws {
        handlePointTo(result: result, screens: screens)
        try await ttsClient.speak(result.spokenText, speed: AccessProfile.current.ttsSpeed)
    }

    private func handlePointTo(result: GeminiClient.PointingResult, screens: [ScreenCaptureResult]) {
        guard let coord = result.coordinate else { return }

        let targetScreen: ScreenCaptureResult? = {
            if let num = result.screenNumber, num >= 1, num <= screens.count {
                return screens[num - 1]
            }
            return screens.first(where: { $0.isCursorScreen })
        }()

        guard let screen = targetScreen else { return }

        let sw = CGFloat(screen.screenshotWidthInPixels)
        let sh = CGFloat(screen.screenshotHeightInPixels)
        let dw = CGFloat(screen.displayWidthInPoints)
        let dh = CGFloat(screen.displayHeightInPoints)
        let frame = screen.displayFrame

        let cx = max(0, min(coord.x, sw))
        let cy = max(0, min(coord.y, sh))
        // AppKit coordinates: origin is bottom-left.
        // Image coordinates: origin is top-left.
        let pointX = cx * (dw / sw)
        let pointY = cy * (dh / sh)
        let appKitY = dh - pointY

        let global = CGPoint(x: pointX + frame.origin.x, y: appKitY + frame.origin.y)
        print("""
        📍 Point map: raw=(\(String(format: "%.1f", coord.x)), \(String(format: "%.1f", coord.y))) \
        clamped=(\(String(format: "%.1f", cx)), \(String(format: "%.1f", cy))) \
        box=\(Self.formatBox(result.boundingBox)) \
        image=\(screen.screenshotWidthInPixels)x\(screen.screenshotHeightInPixels)px \
        displayPoints=\(screen.displayWidthInPoints)x\(screen.displayHeightInPoints) \
        frame=(\(String(format: "%.1f", frame.origin.x)), \(String(format: "%.1f", frame.origin.y)), \(String(format: "%.1f", frame.width)), \(String(format: "%.1f", frame.height))) \
        mappedAppKit=(\(String(format: "%.1f", global.x)), \(String(format: "%.1f", global.y))) \
        label=\(result.elementLabel ?? "nil") screen=\(result.screenNumber.map(String.init) ?? "cursor")
        """)
        // Publish the target so the buddy cursor overlay can fly to it.
        pointingTarget = BuddyPointingTarget(
            screenLocation: global,
            label: result.elementLabel
        )
    }

    private func logPointingResult(_ result: GeminiClient.PointingResult, screens: [ScreenCaptureResult]) {
        guard let coord = result.coordinate else {
            print("📍 Claude point: none")
            return
        }

        let screenSummary = screens.enumerated().map { idx, screen in
            "#\(idx + 1)=\(screen.screenshotWidthInPixels)x\(screen.screenshotHeightInPixels)px frame=\(screen.displayFrame)"
        }.joined(separator: " | ")

        print("""
        📍 Claude point: raw=(\(String(format: "%.1f", coord.x)), \(String(format: "%.1f", coord.y))) \
        box=\(Self.formatBox(result.boundingBox)) \
        label=\(result.elementLabel ?? "nil") screen=\(result.screenNumber.map(String.init) ?? "cursor") \
        screens=[\(screenSummary)]
        """)
    }

    private static func formatBox(_ box: CGRect?) -> String {
        guard let box else { return "nil" }
        return "(\(String(format: "%.1f", box.minX)), \(String(format: "%.1f", box.minY)), \(String(format: "%.1f", box.maxX)), \(String(format: "%.1f", box.maxY)))"
    }

    // MARK: - Routing

    /// Binary route from Gemini Flash → VoiceIntent. Falls back to local keyword
    /// classifier if the Gemini call throws or returns empty.
    private func resolveVoiceIntent(
        transcript: String,
        firstImage: (data: Data, label: String)?,
        history: [(userPlaceholder: String, assistantResponse: String)]
    ) async -> VoiceIntent {
        if let image = firstImage {
            do {
                let route = try await routerClient.route(
                    image: image,
                    transcript: transcript,
                    history: history
                )
                switch route {
                case .answer: return .explain
                case .action: return .action
                }
            } catch {
                print("⚠️ Gemini router failed, falling back to local classifier: \(error)")
            }
        }
        switch GeminiFlashRouterClient.localFallbackRoute(transcript: transcript) {
        case .answer: return .explain
        case .action: return .action
        }
    }

    // MARK: - Voice prompts

    /// Combined Sonnet prompt: model chooses between point (Computer Use) and
    /// plan (☐ checklist) based on the request. Detected post-stream by checking
    /// for ☐ in the output.
    /// True when the transcript looks like a follow-up on a previous turn.
    /// Short queries, vague pronouns, or connectors signal the user is referencing prior context.
    static func isFollowUp(_ transcript: String) -> Bool {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wordCount = t.split(separator: " ").count
        if wordCount <= 4 { return true }
        let followUpPrefixes = ["and ", "also ", "what about ", "how about ", "now ", "then ", "ok ", "okay ", "next "]
        if followUpPrefixes.contains(where: { t.hasPrefix($0) }) { return true }
        let vagueTerms = [" it ", " this ", " that ", " those ", " them ", " the same ", " the plan ", " the steps "]
        return vagueTerms.contains(where: { t.contains($0) })
    }

    private static func actionPrompt(
        for transcript: String,
        screens: [ScreenCaptureResult]
    ) -> String {
        let imageDims = screens.first.map { "\($0.screenshotWidthInPixels)x\($0.screenshotHeightInPixels)" } ?? "submitted"

        return """
        Two tools. Pick based on step count only:

        computer — use when ONE click on a currently visible element answers the request. This includes: closing an app (point at red X), opening an app that's visible in the Dock, clicking a button that's already on screen. Point at the exact pixel in the \(imageDims) screenshot.

        give_plan — use when 2 or more clicks are needed. Navigation through menus, going to a folder, changing a setting, creating something. Steps ONLY — no explanation sentence, no context, no intro. Jump straight to the first click. Each step starts with Click/Select/Open/Type/Toggle, 5 words max, no keyboard shortcuts unless there is absolutely no clickable alternative.

        EXAMPLES:
        "how do I close PowerPoint" → computer: point at red X button
        "open FaceTime" (visible in Dock) → computer: point at FaceTime icon
        "where is the search bar" → computer: point at search bar
        "how do I find the downloads folder" → give_plan: ["Click Finder in Dock", "Click Go menu", "Click Downloads"]
        "how to make a Discord server" → give_plan: ["Click + in left sidebar", "Select Create My Own", "Type server name", "Click Create"]
        "change my password" → give_plan: ["Click Apple menu", "Open System Settings", "Click Users & Groups", "Click Change Password"]

        User request: "\(transcript)"
        """
    }

    // MARK: - Plan checklist normalization

    /// True when the streaming response looks like Sonnet chose the PLAN format.
    /// We treat any presence of ☐ or □ as commitment to checklist mode.
    static func looksLikeChecklist(_ text: String) -> Bool {
        text.contains("☐") || text.contains("□")
    }

    /// Convert Sonnet's prose/streamed output into a clean ☐-prefixed checklist (≤4 rows).
    static func normalizedPlanChecklist(_ text: String) -> String {
        var raw = GeminiClient.parsePointing(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop any explanation sentence before the first ☐ marker.
        if let firstCheckbox = raw.range(of: "☐") {
            raw = String(raw[firstCheckbox.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stripped = raw
            .replacingOccurrences(of: "—", with: ". ")
            .replacingOccurrences(of: " then ", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: ". then ", with: "\n", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let explicitRows = stripped
            .components(separatedBy: .newlines)
            .map(cleanPlanRow)
            .filter { !$0.isEmpty && !isPlanIntro($0) }

        let rows: [String]
        if raw.contains("\n"), explicitRows.count >= 2 {
            rows = explicitRows
        } else {
            rows = splitPlanSentences(stripped)
        }

        return rows
            .prefix(4)
            .map { "☐ \($0)" }
            .joined(separator: "\n")
    }

    static func extractPlanSteps(from text: String) -> [String] {
        var raw = GeminiClient.parsePointing(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstCheckbox = raw.range(of: "☐") {
            raw = String(raw[firstCheckbox.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let stripped = raw
            .replacingOccurrences(of: "—", with: ". ")
            .replacingOccurrences(of: " then ", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: ". then ", with: "\n", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let explicitRows = stripped
            .components(separatedBy: .newlines)
            .map(cleanPlanRow)
            .filter { !$0.isEmpty && !isPlanIntro($0) }

        let rows: [String]
        if raw.contains("\n"), explicitRows.count >= 2 {
            rows = explicitRows
        } else {
            rows = splitPlanSentences(stripped)
        }
        return Array(rows.prefix(4))
    }

    private static func splitPlanSentences(_ text: String) -> [String] {
        let expanded = text
            .replacingOccurrences(of: #"(?i)\band then\b"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bthen\b"#, with: ".", options: .regularExpression)

        return expanded
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map(cleanPlanRow)
            .filter { !$0.isEmpty && !isPlanIntro($0) }
    }

    private static func cleanPlanRow(_ row: String) -> String {
        var cleaned = row
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[☐□\-\*\d\.\)\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^step\s+\d+\s*[:\.-]?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^click\s+"#, with: "select ", options: .regularExpression)

        if cleaned.count > 50 {
            cleaned = String(cleaned.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func isPlanIntro(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.hasPrefix("here's how")
            || lower.hasPrefix("here is how")
            || lower.hasPrefix("to do this")
            || lower.hasPrefix("you can")
            || lower.hasPrefix("the steps")
            || lower.hasPrefix("follow these")
    }

    /// Spoken form of the checklist: drop the ☐ prefix on each line, join with periods.
    private static func spokenPlan(from checklist: String) -> String {
        checklist
            .components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^[☐□\-\*\d\.\)\s]+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    // MARK: - Error messaging

    private static func friendlyError(_ error: Error) -> String {
        let desc = error.localizedDescription
        let code = (error as NSError).code
        // SCStreamErrorDomain -3801: Screen Recording permission revoked by TCC.
        // Common in dev builds because Xcode re-signs the app each run.
        if code == -3801
            || desc.contains("declined TCCs")
            || (desc.contains("Screen") && desc.contains("capture")) {
            return "screen recording permission needed — open System Settings → Privacy → Screen Recording and re-enable Narrait, then relaunch."
        }
        if desc.contains("Microphone") || desc.contains("audio input") {
            return "microphone permission needed — check System Settings → Privacy → Microphone."
        }
        if code == 429
            || desc.contains("429")
            || desc.contains("quota")
            || desc.contains("RESOURCE_EXHAUSTED") {
            if let seconds = desc.range(of: #"retry in (\d+)"#, options: .regularExpression)
                .map({ String(desc[$0]) })
                .flatMap({ Int($0.components(separatedBy: " ").last ?? "") }) {
                return "model rate limit hit — retry in \(seconds)s."
            }
            return "model rate limit hit — try again shortly or check billing limits."
        }
        if desc.contains("API key") || desc.contains("401") {
            return "API key missing or invalid — check the menu bar icon → settings."
        }
        return "something went wrong — try again."
    }

    private static func looksIncomplete(_ text: String) -> Bool {
        let cleaned = GeminiClient.parsePointing(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !cleaned.isEmpty else { return true }
        if cleaned.hasSuffix("-") || cleaned.hasSuffix("—") || cleaned.hasSuffix(",") || cleaned.hasSuffix(":") { return true }
        if cleaned.hasSuffix(".") || cleaned.hasSuffix("!") || cleaned.hasSuffix("?") { return false }

        let badEndings = [
            " a", " an", " and", " are", " as", " at", " by", " for", " from",
            " in", " into", " is", " of", " of the", " on", " or", " over",
            " just", " that", " the", " this", " to", " which", " with", " your"
        ]
        return badEndings.contains { cleaned.hasSuffix($0) }
    }

    private static func polishSpokenText(_ text: String, fallback: String) -> String {
        var cleaned = GeminiClient.parsePointing(from: text).spokenText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fallback }
        cleaned = removeInternalPointTags(from: cleaned)
        cleaned = removeSelfCorrectionPreamble(from: cleaned)
        guard !cleaned.isEmpty else { return fallback }
        if !looksIncomplete(cleaned) { return cleaned }

        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -—,:;"))
        let danglingPhrases = [" where ", " which ", " that ", " when ", " so ", " because ", " where you", " you "]
        for phrase in danglingPhrases {
            if let range = cleaned.range(of: phrase, options: [.caseInsensitive, .backwards]),
               cleaned.distance(from: cleaned.startIndex, to: range.lowerBound) > 12 {
                let prefix = cleaned[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    return prefix.hasSuffix(".") ? String(prefix) : "\(prefix)."
                }
            }
        }

        return fallback
    }

    private static func removeInternalPointTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s*\[(?:POINT|BOX):[^\]]+\]"#, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeSelfCorrectionPreamble(from text: String) -> String {
        let markers = [
            "Let me answer properly.",
            "let me answer properly.",
            "Let me answer that properly.",
            "let me answer that properly."
        ]
        for marker in markers {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                return String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if text.localizedCaseInsensitiveContains("that refusal doesn't apply"),
           let lastParagraph = text.components(separatedBy: "\n\n").last {
            return lastParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Private

    private func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        ttsClient.cancel()
        pointingTarget = nil
        // If mic was recording, stop it immediately so it doesn't keep buffering.
        if state == .recording {
            Task { await micRecorder.stop() }
        }
        state = .idle
    }
}
