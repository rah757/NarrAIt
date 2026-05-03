import AppKit
import SwiftUI

// SwiftUI surface hosted by an NSPopover anchored to the menu bar status item.
// Replaces the legacy NSMenu — gives Narrait a designed surface for the live
// status pill, profile pills, hotkey hints, and the footer action row.
struct MenuBarPopoverView: View {
    @ObservedObject var coordinator: ActivationCoordinator
    @State private var selectedProfile: AccessProfile = .current

    let onSettings: () -> Void
    let onHelp: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            profileSection
            hotkeySection
            Divider()
                .opacity(0.25)
            footerRow
        }
        .padding(20)
        .frame(width: 320)
        .background(
            ZStack {
                Color(hex: "#0E0F12").opacity(0.85)
                LinearGradient(
                    colors: [
                        profileAccent(for: selectedProfile).opacity(0.18),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            BrandMark()
            Text("Narrait")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(Color(hex: "#F4F5F7"))
            Spacer()
            StatusPill(state: coordinator.state, isBlocked: coordinator.isBlocked)
        }
    }

    // MARK: - Profile section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("YOU ARE")
            HStack(spacing: 8) {
                ForEach(AccessProfile.allCases, id: \.self) { profile in
                    ProfilePill(
                        profile: profile,
                        isSelected: selectedProfile == profile,
                        accent: profileAccent(for: profile)
                    ) {
                        selectedProfile = profile
                        AccessProfile.current = profile
                        coordinator.conversationStore.clear()
                    }
                }
            }
            Text(selectedProfile.shortDescription)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#A8AAB1"))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hotkey section

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("HOW TO USE")
            HotkeyRow(
                keys: ["⌥"],
                title: "Hold to explain",
                subtitle: "Point at anything on screen"
            )
            HotkeyRow(
                keys: ["⌘", "⌥"],
                title: "Hold to ask",
                subtitle: "Speak a question, release to send"
            )
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 18) {
            FooterButton(symbol: "key.fill", label: "API Keys", action: onSettings)
            FooterButton(symbol: "questionmark.circle.fill", label: "Guide", action: onHelp)
            Spacer()
            FooterButton(symbol: "power", label: "Quit", action: onQuit)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundColor(Color(hex: "#787A82"))
    }
}

// MARK: - Brand mark (filled play triangle, matches menu bar icon)

private struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#6B70FF"), Color(hex: "#345CFF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)

            Triangle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .offset(x: 1)
        }
        .shadow(color: Color(hex: "#345CFF").opacity(0.4), radius: 6, x: 0, y: 2)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let state: ActivationCoordinator.State
    let isBlocked: Bool

    @State private var pulse: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .scaleEffect(isAnimated ? pulse : 1.0)
                .onAppear { startPulseIfNeeded() }
                .onChange(of: state) { _, _ in startPulseIfNeeded() }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#D8DAE0"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(dotColor.opacity(0.45), lineWidth: 0.6)
                )
        )
    }

    private var label: String {
        if isBlocked { return "Blocked" }
        switch state {
        case .idle: return "Ready"
        case .capturing: return "Reading"
        case .recording: return "Listening"
        case .transcribing: return "Thinking"
        case .streaming: return "Replying"
        case .playing: return "Speaking"
        case .blocked: return "Blocked"
        }
    }

    private var dotColor: Color {
        if isBlocked { return Color(hex: "#9A9CA3") }
        switch state {
        case .idle: return Color(hex: "#3DD68C")
        case .capturing, .streaming, .playing: return Color(hex: "#15B8FF")
        case .recording, .transcribing: return Color(hex: "#6B70FF")
        case .blocked: return Color(hex: "#9A9CA3")
        }
    }

    private var isAnimated: Bool {
        switch state {
        case .recording, .transcribing, .streaming, .playing: return !isBlocked
        default: return false
        }
    }

    private func startPulseIfNeeded() {
        guard isAnimated else {
            withAnimation(.linear(duration: 0.1)) { pulse = 1.0 }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = 1.45
        }
    }
}

// MARK: - Profile pill

private struct ProfilePill: View {
    let profile: AccessProfile
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: profile.symbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isSelected ? .white : Color(hex: "#C9CBD2"))
                Text(profile.shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? .white : Color(hex: "#A8AAB1"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [accent, accent.opacity(0.7)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(isHovering ? 0.08 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isSelected ? accent.opacity(0.6) : Color.white.opacity(0.06),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(
                        color: isSelected ? accent.opacity(0.45) : .clear,
                        radius: 8,
                        x: 0,
                        y: 3
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - Hotkey row

private struct HotkeyRow: View {
    let keys: [String]
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeyGlyph(text: key)
                }
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#ECEEF1"))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#878990"))
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }
}

private struct KeyGlyph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(Color(hex: "#ECEEF1"))
            .frame(minWidth: 26, minHeight: 26)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
                    )
            )
    }
}

// MARK: - Footer button

private struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovering ? Color(hex: "#F4F5F7") : Color(hex: "#A8AAB1"))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0.0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - Profile metadata used by the popover (UI-only, not part of core)

extension AccessProfile {
    var shortName: String {
        switch self {
        case .default: return "Default"
        case .vision: return "Low Vision"
        case .dyslexia: return "Dyslexia"
        case .plainEnglish: return "Plain"
        }
    }

    var symbolName: String {
        switch self {
        case .default: return "person.crop.circle"
        case .vision: return "eye.fill"
        case .dyslexia: return "textformat.abc"
        case .plainEnglish: return "globe"
        }
    }

    var shortDescription: String {
        switch self {
        case .default:
            return "Clear, practical guidance for general use."
        case .vision:
            return "Complete spoken descriptions with layout and visible text."
        case .dyslexia:
            return "Short sentences and slower narration."
        case .plainEnglish:
            return "Jargon and idioms defined inline in everyday language."
        }
    }
}

private func profileAccent(for profile: AccessProfile) -> Color {
    switch profile {
    case .default: return Color(hex: "#6B70FF")
    case .vision: return Color(hex: "#F4A300")
    case .dyslexia: return Color(hex: "#15B8FF")
    case .plainEnglish: return Color(hex: "#3DD68C")
    }
}

// MARK: - Hex Color helper

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
