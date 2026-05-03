# Narrait — System Design

```mermaid
flowchart TD
    %% ── Inputs ──────────────────────────────────────────────────────────────
    subgraph INPUT["Input Triggers"]
        OPT["⌥ Option held\nHover Explain"]
        CMDOPT["⌘⌥ Cmd+Option\nVoice Push-to-Talk"]
        DBLTAP["⌥⌥ Double-tap Option\nMagnifier (Low Vision only)"]
    end

    %% ── Assessment Guard ─────────────────────────────────────────────────────
    ASSESS["🛡️ AssessmentDetector\nPolls every 2s\n• Proctoring app bundle IDs\n• Window titles: quiz/exam/test"]
    BLOCKED["🔒 BLOCKED\nAll features frozen\nOverlay hidden"]
    ASSESS -->|detected| BLOCKED

    %% ── Hover Path ───────────────────────────────────────────────────────────
    OPT --> HOVER_START

    subgraph HOVER["Hover-Explain Path (Option held)"]
        HOVER_START["Capture cursor position\n+ selected text"]
        HOVER_START --> L1["Level 1: Cursor crop\n(red ring marker)"]
        L1 --> GEMINI_HOVER["Gemini Flash\nrouterClient.answer()"]
        GEMINI_HOVER -->|confident answer| HOVER_OUT
        GEMINI_HOVER -->|needs more context| L3["Level 3: Full screen\n(enables POINT coords)"]
        L3 --> GEMINI_HOVER2["Gemini Flash\nrouterClient.answer()"]
        GEMINI_HOVER2 --> HOVER_OUT
        HOVER_OUT["✅ Response\n→ Bubble overlay\n→ TTS spoken\n→ Fade 3s\n→ Optional green ring"]
    end

    %% ── Voice Path ───────────────────────────────────────────────────────────
    CMDOPT --> MIC["🎤 MicRecorder\n(hold to record)"]
    MIC --> GROQ["Groq Whisper Large v3\nSpeech → Text transcript"]
    GROQ --> SCREENCAP["📸 ScreenCapture\nAll screens captured\n(1280×800 CU format)"]
    SCREENCAP --> ROUTER

    subgraph ROUTING["Gemini Flash Router"]
        ROUTER["Gemini Flash\ngemini-2.5-flash-preview\nRoutes with screenshot + transcript"]
        ROUTER -->|route: answer| EXPLAIN["💬 Explain path\nGemini Flash answers directly\n(fast, cheap)"]
        ROUTER -->|route: action| ACTION["⚡ Action path\nSonnet + Computer Use"]
        ROUTER -->|Gemini fails| FALLBACK["Local keyword classifier\nfallback"]
        FALLBACK --> EXPLAIN
        FALLBACK --> ACTION
        ISFOLLOW["isFollowUp()?\n≤4 words / vague pronouns\n/ connectors"] -->|yes| HISTORY["Inject last 2\nconversation turns"]
        HISTORY --> ACTION
    end

    EXPLAIN --> GEMINI_ANS["Gemini Flash\nrouterClient.answer()\n(with conversation history)"]
    GEMINI_ANS --> BUBBLE["💬 Bubble overlay + TTS\nFade after 3s"]

    %% ── Sonnet + Tools ───────────────────────────────────────────────────────
    ACTION --> SONNET

    subgraph SONNET_BOX["Sonnet claude-sonnet-4-6 + Computer Use"]
        SONNET["Anthropic Messages API\ncomputer-use-2025-11-24 beta\nActionPrompt: step-count routing"]

        SONNET -->|"calls computer tool\n(mouse_move)"| POINT_TOOL["🖱️ Computer Use\nPixel coordinates returned\nfrom screenshot space"]
        SONNET -->|"calls give_plan tool\n(2+ steps)"| PLAN_TOOL["📋 give_plan\nReturns steps[] array\n5 words max each"]
        SONNET -->|plain text| PLAIN["Plain spoken answer"]

        POINT_TOOL --> COORD["[POINT:y,x:label]\nCoordinate tag injected\ninto response"]
        PLAN_TOOL -->|1 step| SINGLE["Single step\n→ spoken as bubble\n(no ring, no panel)"]
        PLAN_TOOL -->|2–4 steps| CHECKLIST["☐ Checklist built\n→ Side panel"]
    end

    %% ── Point outcome ────────────────────────────────────────────────────────
    COORD --> COORD_MAP["Coordinate mapping\nScreenshot px → AppKit global pts\n(retina + multi-screen aware)"]
    COORD_MAP --> GREEN["🟢 Green ring\nCursorPointer panel\n(.screenSaver level)\n15s auto-fade"]
    COORD --> TTS_POINT["🔊 TTS: 'i marked it on your screen'"]

    %% ── Plan execution ───────────────────────────────────────────────────────
    CHECKLIST --> SIDE_PANEL["📐 Side panel\nSiri-blue gradient\nFrosted glass\nTop-right anchor"]
    SIDE_PANEL --> SPEAK1["🔊 TTS: speak step 1"]
    SPEAK1 --> EXEC1["Sonnet CU call\n→ point at step 1 element"]

    EXEC1 --> WAIT["⏳ Wait for user click\nMouseMonitor watches\nleft mouse down"]
    WAIT -->|click| CHECK["✅ Mark step complete\n→ blue checkmark"]
    CHECK --> NEXT_STEP["🔊 TTS: speak step N+1\n→ Sonnet CU call\n→ point at step N+1"]
    NEXT_STEP --> WAIT
    CHECK -->|last step| DONE["Overlay fades 3s\nPlan complete"]

    %% ── Other outputs ────────────────────────────────────────────────────────
    PLAIN --> BUBBLE2["💬 Bubble overlay + TTS\nFade after 3s"]
    SINGLE --> BUBBLE3["💬 Bubble overlay + TTS"]

    %% ── Magnifier ────────────────────────────────────────────────────────────
    DBLTAP --> MAG_CHECK{"AccessProfile\n== .vision?"}
    MAG_CHECK -->|yes| MAGNIFIER["🔍 MagnifierPanel\nToggle on/off\n200px circular loupe\nBackground queue 20fps\nCGWindowListCreateImage"]
    MAG_CHECK -->|no| IGNORE["No-op"]

    %% ── Profiles ─────────────────────────────────────────────────────────────
    subgraph PROFILES["Access Profiles (system prompt clause injected)"]
        P1["Default\nClear practical guidance"]
        P2["Blind / Low Vision\nSpatial layout emphasis\nCursor warp to target\nMagnifier available"]
        P3["Dyslexia\nShort sentences\n0.5× TTS speed"]
        P4["Language Support\nJargon translated inline"]
    end

    %% ── Logging ──────────────────────────────────────────────────────────────
    subgraph LOGS["APILogger → ~/Library/Logs/Narrait/"]
        L_GEM["gemini.json\nAll Anthropic + Gemini calls\ntokens, latency, prompts"]
        L_GROQ["groq.json\nWhisper transcriptions"]
        L_TTS["gemini_tts.json\nTTS calls"]
    end

    %% ── Style ────────────────────────────────────────────────────────────────
    classDef api fill:#1a3aff22,stroke:#1a3aff,color:#c8d8ff
    classDef ui fill:#0f2a1a,stroke:#2d6a4f,color:#95d5b2
    classDef trigger fill:#2a1a0f,stroke:#e07b39,color:#ffd9b3
    classDef guard fill:#2a0f0f,stroke:#e03939,color:#ffb3b3
    classDef tool fill:#1a2a2a,stroke:#00c2ff,color:#b3eeff

    class GEMINI_HOVER,GEMINI_HOVER2,GEMINI_ANS,ROUTER api
    class SONNET,POINT_TOOL,PLAN_TOOL,COORD,COORD_MAP tool
    class GREEN,SIDE_PANEL,BUBBLE,BUBBLE2,BUBBLE3 ui
    class OPT,CMDOPT,DBLTAP trigger
    class ASSESS,BLOCKED guard
```

## Component Summary

| Component | Role | Model/Tech |
|---|---|---|
| `GlobalHotkeyMonitor` | Detects Option / Cmd+Option / double-tap | AppKit flags monitor |
| `AssessmentDetector` | Polls for proctoring apps + quiz windows every 2s | CGWindowListCopyWindowInfo |
| `GeminiFlashRouterClient` | Routes voice queries: answer vs action | gemini-2.5-flash-preview |
| `GeminiClient.stream()` | Sonnet call with Computer Use + give_plan tools | claude-sonnet-4-6 |
| `GeminiFlashRouterClient.answer()` | Direct Gemini answer (explain path + hover) | gemini-2.5-flash-preview |
| `GroqWhisperClient` | Speech-to-text | whisper-large-v3 |
| `GeminiTTSClient` | Text-to-speech | Cartesia Sonic / macOS TTS |
| `CursorPointer` | Green ring overlay at CU coordinates | NSPanel .screenSaver level |
| `MagnifierPanel` | Live 2× circular loupe | CGWindowListCreateImage 20fps |
| `ResponseOverlay` | Bubble + side panel UI | SwiftUI NSPanel |
| `ConversationStore` | Last N turns for follow-up context | In-memory |
| `AccessProfile` | Injects clause into every system prompt | UserDefaults |
