# Narrait — Claude Instructions

## Project

Narrait is an AI-powered assistive companion for disabled users navigating computers. macOS menu bar app (Swift, no traditional UI). Users hold a modifier key over anything on screen — a form field, a software icon, a paragraph — and Narrait explains it in plain language. Voice input supported for follow-ups and step-by-step walkthroughs.

Stack: Swift 5.9 · ScreenCaptureKit · Claude Sonnet 4.6 (SSE streaming) · Groq Whisper Large v3 · Cartesia Sonic TTS · local Keychain · no backend.

Team: musthafa · hrishikesh · rah

## Key docs

- `README.md` — build plan, build order, demo script, verification checklist
- `ARCHITECTURE.md` — component map, state machine, sequence diagrams, threading model, failure modes
- `CONTEXT.md` — live team context: decisions, what's in progress, open questions

**Read these at the start of every session before writing any code.**

## How to maintain CONTEXT.md

Update `CONTEXT.md` automatically during work. Don't ask permission — just do it.

**When a decision is made** (API choice, architecture call, design tradeoff, anything that affects other devs):
→ Prepend a row to the Decisions table with today's date.

**When work starts on a module or feature:**
→ Add or update the dev's row in "What's in progress."

**When a module or feature ships:**
→ Move it from "What's in progress" to "What's been built." Include a one-line description.

**When an open question is resolved:**
→ Check the box and add the answer inline.

**When a new open question or blocker surfaces:**
→ Add it to the relevant section.

**When architecture changes:**
→ Update `ARCHITECTURE.md` and log the decision in `CONTEXT.md`.

Keep entries short. One line is fine. The goal is that any dev can open `CONTEXT.md` cold and know what's happening.

## Commit and git conventions

- Never commit or push autonomously. Provide a suggested commit message and let the dev run it.
- Never add `Co-Authored-By` lines or mention Claude in commit messages.
- Suggested commit messages should be short, lowercase, imperative: `add ClaudeClient SSE streaming`, `fix cursor coord transform on retina displays`.

## Code conventions

- Swift 5.9. Async/await throughout — no callbacks, no NotificationCenter for internal comms.
- `@MainActor` on all UI-touching types. API clients are plain `actor` or `class` with async methods that bridge back to main.
- `ActivationCoordinator` is the single orchestrator. API clients and UI components never call each other directly.
- No comments unless the why is non-obvious. No docstrings.
- No feature flags, no backwards-compat shims — just change the code.
- Clicky source is at `clicky-reference/` — read it before building any of: screen capture, hotkey monitoring, response overlay, menu bar setup, mic recording. Most of the hard macOS plumbing is already solved there.

## What not to do

- Don't add features beyond what's asked.
- Don't refactor surrounding code when fixing a bug.
- Don't add error handling for scenarios that can't happen.
- Don't introduce abstractions for hypothetical future requirements.
- Don't generate or guess URLs.
