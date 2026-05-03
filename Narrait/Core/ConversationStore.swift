import Foundation

// Rolling conversation history. We store more than we send so follow-up context
// stays useful without bloating each vision request.
// In-memory only — gone on quit. Clears after 5 minutes of idle or profile switch.
// Both hover and voice interactions share this store so follow-up questions work
// across modalities (hover something → ask voice question about it → coherent context).
@MainActor
final class ConversationStore {
    struct Turn {
        let userText: String
        let assistantText: String
    }

    private var turns: [Turn] = []
    private var idleTimer: Timer?
    private let maxTurns = 10
    private let idleTimeout: TimeInterval = 300  // 5 minutes

    // Returns compact recent turns formatted for provider message arrays.
    // Each turn becomes a user placeholder + assistant response pair.
    func recentTurns(maxTurnsToSend: Int = 4, maxCharactersPerField: Int = 220) -> [(userPlaceholder: String, assistantResponse: String)] {
        turns.suffix(maxTurnsToSend).map {
            (
                userPlaceholder: Self.truncate($0.userText, limit: maxCharactersPerField),
                assistantResponse: Self.truncate($0.assistantText, limit: maxCharactersPerField)
            )
        }
    }

    func append(userText: String, assistantText: String) {
        turns.append(Turn(userText: userText, assistantText: assistantText))
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
        resetIdleTimer()
    }

    func clear() {
        turns.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.turns.removeAll()
                print("💬 ConversationStore: cleared after 5min idle")
            }
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
