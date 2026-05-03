import AppKit
import CoreGraphics
import SwiftUI

@main
struct NarraitApp: App {
    @NSApplicationDelegateAdaptor(NarraitAppDelegate.self) var appDelegate

    var body: some Scene {
        // LSUIElement = true removes the dock icon and app menu.
        // This empty Settings scene satisfies SwiftUI's scene requirement.
        Settings { EmptyView() }
    }
}

@MainActor
final class NarraitAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var coordinator: ActivationCoordinator?
    private var buddyOverlay: BuddyOverlayManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 Narrait: launching...")

        // Request permissions up-front so TCC registers the grant before first use.
        requestPermissions()

        // Load API keys from bundled .env
        APIKeyStore.loadFromBundleIfNeeded()

        warnIfMissingKeys()

        // Build dependency graph
        let overlay = ResponseOverlayManager()
        let cursorPointer = CursorPointer()
        let ttsClient = GeminiTTSClient()
        let anthropicClient = GeminiClient()
        let micRecorder = MicRecorder()
        let groqClient = GroqWhisperClient()
        let conversationStore = ConversationStore()
        let hotkeyMonitor = GlobalHotkeyMonitor()
        let assessmentDetector = AssessmentDetector()

        let coordinator = ActivationCoordinator(
            overlay: overlay,
            cursorPointer: cursorPointer,
            ttsClient: ttsClient,
            claudeClient: anthropicClient,
            micRecorder: micRecorder,
            groqClient: groqClient,
            conversationStore: conversationStore,
            hotkeyMonitor: hotkeyMonitor,
            assessmentDetector: assessmentDetector
        )

        self.coordinator = coordinator
        self.menuBarController = MenuBarController(coordinator: coordinator)

        // Buddy overlay — one transparent NSWindow per screen, screenSaver-level,
        // click-through. Follows the cursor at 60fps and flies to AI-pointed elements.
        let buddyOverlay = BuddyOverlayManager()
        buddyOverlay.show(coordinator: coordinator)
        self.buddyOverlay = buddyOverlay

        coordinator.start()

        print("✅ Narrait: ready")
        print("   → Hold Option to explain what's under your cursor")
        print("   → Hold Cmd+Option to speak a question")
    }

    func applicationWillTerminate(_ notification: Notification) {
        buddyOverlay?.hide()
        coordinator?.stop()
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // Screen Recording — CGRequestScreenCaptureAccess opens System Settings
        // if not already granted and registers the bundle in TCC.
        if !CGPreflightScreenCaptureAccess() {
            print("⚠️ Narrait: Screen Recording not granted — opening System Settings")
            CGRequestScreenCaptureAccess()
        } else {
            print("✅ Narrait: Screen Recording already granted")
        }

        // Accessibility — required for CGEventTap (global hotkeys).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if trusted {
            print("✅ Narrait: Accessibility already granted")
        } else {
            print("⚠️ Narrait: Accessibility not granted — System Settings dialog shown")
        }
    }

    private func warnIfMissingKeys() {
        if APIKeyStore.anthropicKey.isEmpty {
            print("⚠️ Narrait: ANTHROPIC_API_KEY not set — click the menu bar icon to add it")
        }
        if APIKeyStore.geminiKey.isEmpty {
            print("⚠️ Narrait: GEMINI_API_KEY not set — voice routing will fall back to Claude")
        }
        if APIKeyStore.groqKey.isEmpty {
            print("⚠️ Narrait: GROQ_API_KEY not set — voice input will not work")
        }
    }
}
