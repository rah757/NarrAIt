import AppKit
import SwiftUI

@MainActor
final class HowToUseWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HowToUseView { [weak self] in
            self?.window?.close()
        }
        let host = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(red: 14/255, green: 15/255, blue: 18/255, alpha: 1.0)
        win.setContentSize(NSSize(width: 540, height: 580))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

struct HowToUseView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background

            VStack(alignment: .leading, spacing: 22) {
                hero
                interactionCards
                refusalCallout
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)

            CloseButton(action: onClose)
                .padding(14)
        }
        .frame(width: 540, height: 580)
    }

    private var background: some View {
        ZStack {
            Color(hex: "#0E0F12")
            LinearGradient(
                colors: [
                    Color(hex: "#6B70FF").opacity(0.12),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            LinearGradient(
                colors: [
                    Color.clear,
                    Color(hex: "#15B8FF").opacity(0.08)
                ],
                startPoint: .center,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BrandMarkLarge()
                Text("Narrait")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(hex: "#F4F5F7"))
            }
            Text("Your AI guide for getting around your Mac.")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#A8AAB1"))
        }
    }

    private var interactionCards: some View {
        VStack(spacing: 12) {
            InteractionCard(
                keys: ["⌥"],
                title: "Hold Option",
                text: "Point at anything on screen — a button, a form field, an icon — and Narrait explains it in plain language.",
                accent: Color(hex: "#6B70FF")
            )
            InteractionCard(
                keys: ["⌘", "⌥"],
                title: "Hold Cmd+Option",
                text: "Ask a question by voice. Narrait listens while held, then answers about whatever's on screen.",
                accent: Color(hex: "#15B8FF")
            )
            InteractionCard(
                symbol: "person.crop.circle.badge.checkmark",
                title: "Choose a profile",
                text: "Profiles tune Narrait for Low Vision, Dyslexia, or Plain English. Switch them from the menu bar icon.",
                accent: Color(hex: "#3DD68C")
            )
        }
    }

    private var refusalCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "#F4A300"))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Narrait won't help with graded work.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#ECEEF1"))
                Text("It describes the screen. It doesn't do the thinking for you.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#A8AAB1"))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: "#F4A300").opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: "#F4A300").opacity(0.25), lineWidth: 0.6)
                )
        )
    }
}

private struct InteractionCard: View {
    var keys: [String] = []
    var symbol: String? = nil
    let title: String
    let text: String
    let accent: Color

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            keyOrSymbol
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.35), accent.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(accent.opacity(0.5), lineWidth: 0.8)
                        )
                )
                .shadow(color: accent.opacity(isHovering ? 0.45 : 0.2), radius: 10, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#F4F5F7"))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#A8AAB1"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.05 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private var keyOrSymbol: some View {
        if !keys.isEmpty {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

private struct BrandMarkLarge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#6B70FF"), Color(hex: "#345CFF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)

            Triangle()
                .fill(Color.white)
                .frame(width: 11, height: 11)
                .offset(x: 1.5)
        }
        .shadow(color: Color(hex: "#345CFF").opacity(0.5), radius: 8, x: 0, y: 3)
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

private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "#A8AAB1"))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.12 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

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
