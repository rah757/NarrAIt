# Narrait — Team Context

> Updated automatically by Claude during work sessions. Don't overthink the format — a line is better than nothing.

**Last updated:** 2026-05-03
**Team:** musthafa · hrishikesh · rah

---

## What's been built

| Module | Description |
|---|---|
| `Narrait.xcodeproj` | Full Xcode project scaffold — LSUIElement, entitlements, no sandbox, macOS 14.2+ |
| `Core/KeychainStore` | Reads `.env` bundle file into UserDefaults; exposes anthropicKey/groqKey/cartesiaKey |
| `Core/AccessProfile` | 4-profile enum (Default, Blind / Low Vision, Dyslexia, Language Support) + UserDefaults persistence |
| `Core/SystemPrompts` | Locked base rubric + per-profile clauses; refusal logic baked in |
| `Core/ConversationStore` | 6-turn rolling history, 30s idle expiry, in-memory only |
| `Core/ScreenCapture` | Multi-display JPEG capture via ScreenCaptureKit; cursor screen first; excludes own windows |
| `Core/GlobalHotkeyMonitor` | CGEventTap state machine: Option-hold → hover-explain, Cmd+Option → voice push-to-talk |
| `Core/ActivationCoordinator` | Full state machine (idle/capturing/streaming/playing/recording/transcribing/blocked); single orchestrator |
| `API/ClaudeClient` | Direct Anthropic SSE streaming; [POINT:x,y:label] tag parsing; max_tokens 400 |
| `API/CartesiaTTSClient` | Cartesia /tts/bytes REST; speed control per profile |
| `API/GroqWhisperClient` | Groq whisper-large-v3; multipart WAV POST → transcript |
| `Audio/MicRecorder` | AVAudioEngine 16kHz PCM16 capture; converts to WAV for Groq |
| `Audio/AudioPlayer` | AVAudioPlayer wrapper; stop() and stopHard() |
| `UI/ResponseOverlay` | Cursor-following NSPanel; streaming text; in-bubble waveform/spinner leading icon |
| `UI/CursorPointer` | Highlight ring overlay; animates to [POINT:] coords |
| `UI/MenuBarController` | NSStatusItem hosting NSPopover; gray icon when blocked |
| `UI/MenuBarPopover` | SwiftUI popover surface — live status pill, profile pills with accents, hotkey rows, footer actions |
| `UI/HowToUseWindow` | SwiftUI help window — hero, three interaction cards, academic-refusal callout |
| `NarraitApp` | @main entry; wires dependency graph; starts coordinator |

---

## What's in progress

| Dev | Working on | Notes |
|---|---|---|
| rah | MVP complete — ready to open in Xcode | Add API keys via menu bar icon or .env bundle resource |

---

## Decisions

Newest first.

| Date | Decision | Why |
|---|---|---|
| 2026-05-03 | Replaced legacy `NSMenu` with a SwiftUI-hosted `NSPopover` (status pill + profile pills + hotkey rows) | Premium hackathon presentation; profile is one tap not two; live state visible without opening anything |
| 2026-05-03 | Moved listening waveform and processing spinner from cursor-attached overlay into the response bubble as a leading icon | Two cursor-anchored panels were overlapping during Option / Cmd+Option; one bubble owns status now |
| 2026-05-03 | Replaced "How to Use Narrait" `NSAlert` with a designed SwiftUI window (`HowToUseWindowController`) | Matches popover design language; gives the academic-refusal rule a visible callout instead of footnote |
| 2026-05-02 | Testing `claude-haiku-4-5-20251001` for Computer Use with beta `computer-use-2025-01-24` | Sonnet pointing is stable; Haiku may reduce latency/cost if accuracy holds |
| 2026-05-02 | Reverted Cmd+Option Computer Use screenshots to the full matched target resolution | The 50% downscale hurt accuracy on small toolbar controls despite preserving aspect ratio |
| 2026-05-02 | Switched vision/reasoning to Anthropic Sonnet 4.6 with Computer Use beta `computer-use-2025-11-24` | Standard vision coordinate returns were unreliable; Computer Use is trained for UI pixel targeting |
| 2026-05-02 | Cmd+Option capture now snaps to a Computer Use compatible resolution closest to display aspect ratio | Avoids screenshot distortion while keeping Claude coordinates in the submitted image space |
| 2026-05-02 | Reverted coordinate mapping to submitted-image pixel coordinates | Computer Use returns pixels in the scaled screenshot, not Gemini's normalized 0-1000 box format |
| 2026-05-02 | Action/navigation pointing now prefers Gemini `[BOX:x1,y1,x2,y2:label]` and marks the box center | Tests whether bounding boxes are more stable than single-point coordinates on full-screen screenshots |
| 2026-05-02 | Cmd+Option coordinate testing stays full-screen/full-resolution only, with no crop refinement | Keeps returned coordinates tied to the entire screen image the user is navigating |
| 2026-05-02 | Gemini should return [POINT:] only for action/navigation requests; Narrait leaves a green marker there without moving the mouse | Keeps normal explanations from pointing unnecessarily while testing exact coordinate guidance |
| 2026-05-02 | Cmd+Option voice sends the full cursor display at native resolution for whole-screen navigation questions | Lets Gemini return [POINT:] coordinates against the entire submitted screen with less downscale ambiguity |
| 2026-05-02 | Switched TTS implementation to local macOS `AVSpeechSynthesizer` for testing | Removes TTS API latency so narration starts immediately while evaluating interaction flow |
| 2026-05-02 | Replaced Cartesia TTS with Gemini 3.1 Flash TTS Preview using existing Gemini API key | Removes separate Cartesia dependency and logs speech calls to `gemini_tts.json` |
| 2026-05-02 | Option hover sends selected text only as supplemental context with the cursor crop, never as a text-only first call | Keeps the marked hover target as the source of truth while still giving Gemini exact selected text |
| 2026-05-02 | Replaced CGEventTap hotkey listener with AppKit local+global modifier monitors | Keeps Option/Cmd+Option working across Xcode focus changes, Narrait panels, and window switches |
| 2026-05-02 | Voice stop now always halts the mic and resets overlay; coordinator logs every hotkey transition; hover marker enlarged | Eliminates "listening never stops" UI state and makes Option/Cmd+Option races debuggable from logs |
| 2026-05-02 | Killed stale Narrait process and rewrote hotkey monitor around one `Mode` enum with transition logs | Prevents old Xcode menu-bar process from masking fixes and makes Option/Cmd+Option failures observable |
| 2026-05-02 | Option release now cancels hover narration/playback and a 50ms release poll catches missed key-up events | Ensures the red marker disappears, TTS stops, and the next hover can start reliably |
| 2026-05-02 | Simplified global hotkey monitor to physical key state: Option down/up and Cmd+Option chord | Removed debounce/reconcile state that could wedge Option hover or ignore quick presses |
| 2026-05-02 | Hover shows a red on-screen marker until Option is released; hover only trusts selected text, not focused text | Keeps visible feedback aligned with the target and avoids stale focused editor text overriding the hovered element |
| 2026-05-02 | Hover Level 2 now sends a cursor-centered crop with a red marker at the activation-time cursor point | Stops Gemini from guessing a different element inside the active window |
| 2026-05-02 | Option hover is a one-shot trigger with modifier-state reconciliation; overlay sizing uses text measurement instead of SwiftUI fittingSize | Prevents missed release events from wedging hotkeys and avoids AppKit layout recursion warnings |
| 2026-05-02 | Gemini generation now uses a 2048 token cap plus low/disabled thinking where supported | Prevents Gemini 3 from spending the whole 400-token cap on thinking and returning truncated 12-word answers |
| 2026-05-02 | Gemini stream parser now reads all text parts and logs `finishReason`; hover escalates if a response looks incomplete | Prevents speaking truncated fragments like "in the center of the" |
| 2026-05-02 | Option release no longer cancels hover explanations once started | Prevents Gemini/TTS responses from cutting off mid-sentence when the user taps Option |
| 2026-05-02 | `.env` keys now refresh stored UserDefaults values on launch and Gemini model is configurable via `GEMINI_MODEL` | Prevents stale free-tier API keys or hardcoded model choices from surviving key/model changes |
| 2026-05-02 | Hotkey monitor now uses an explicit idle/pending-hover/hovering/recording state machine | Prevents Option hover and Cmd+Option voice from racing when modifier key order varies |
| 2026-05-02 | Switched from Claude to Gemini 2.5 Flash for vision/reasoning | Free tier (no card needed), 250 req/day sufficient for hackathon, same [POINT:] tag approach is model-agnostic |
| 2026-05-02 | Core pitch framing: "guidance not automation" — Narrait builds user capability, doesn't replace it | Differentiates from Cluely/OpenClaw; strengthens anti-cheating defense; aligns with disability services philosophy of independence |
| 2026-05-02 | Cost framing: ~$2/day on Claude Sonnet, ~$0.20/day on Gemini 2.0 Flash; model is swappable via env var | Competitor subscriptions ($20-30/mo) are out of reach for financial-aid students; pay-as-you-go with public math is a concrete differentiator |
| 2026-05-02 | Full bidirectional MVP — voice-in + hover-explain both in scope | Product story needs both directions |
| 2026-05-02 | No backend proxy — API keys in local Keychain | Hackathon binary; saves infra time |
| 2026-05-02 | Modifier-hold (Option) for hover-explain; Cmd+Option for voice | Deterministic on stage, no accidental triggers |
| 2026-05-02 | Cartesia Sonic for TTS over ElevenLabs | ~90ms first byte, cheaper, WebSocket stream is stable |
| 2026-05-02 | Groq Whisper Large v3 for STT over AssemblyAI | Sub-200ms, simpler REST, cheaper |
| 2026-05-02 | System rubric allows software walkthroughs, blocks academic interpretation | "this is asking for X" on coursework is the refusal trigger — not just literal answers |
| 2026-05-02 | Demo beat 1 = VS Code GitHub setup, not calculus integral | Calculus + "area under the curve" implies academic answer; VS Code onboarding is unambiguously assistive |
| 2026-05-02 | `point_to` tool-call as a first-class primitive | Needed for step-by-step walkthroughs for users who can't visually scan |
| 2026-05-02 | `ConversationStore` in-memory only, clears after 30s idle | Privacy + freshness |

---

## Open questions

- [ ] Does holding Option conflict with system shortcuts on macOS 14? Test on clean install before locking the modifier.
- [ ] Does Cartesia stream MP3 chunks or raw PCM? `AudioPlayer` design depends on this.
- [ ] What coordinate frame does Claude return in `point_to` — points or pixels? Need a test call with a known image before the cursor-pointing feature is built.
- [ ] Does `CGWarpMouseCursorPosition` require a separate entitlement beyond Accessibility permission?
- [ ] For voice queries with no recent hover, do we always send the last screen capture, or only if it's < 10s old?

---

## Blockers

*(none)*

---

## Notes / anything else

*(free-form — drop context here that doesn't fit elsewhere)*
