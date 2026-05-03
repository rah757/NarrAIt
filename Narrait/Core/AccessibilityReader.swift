import AppKit

// Reads text context from the focused UI element using the Accessibility API.
// Used as the fastest, cheapest first-pass context for hover-explain.
// Requires Accessibility permission (already requested at launch).
enum AccessibilityReader {

    // Returns selected text in the focused element, or nil if nothing is selected.
    static func selectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Returns a wider block of text visible near the cursor (whole value of focused element),
    // capped at 2000 chars so we don't flood the context.
    static func focusedElementText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXValueAttribute as CFString,
                                            &valueRef) == .success,
              let text = valueRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 2000 ? String(trimmed.prefix(2000)) + "…" : trimmed
    }

    // Best-effort: selected text first, then focused element text.
    // Returns (text, isSelected) — isSelected=true means it was explicitly highlighted.
    static func bestAvailableText() -> (text: String, isSelected: Bool)? {
        if let sel = selectedText() {
            return (sel, true)
        }
        if let val = focusedElementText() {
            return (val, false)
        }
        return nil
    }
}
