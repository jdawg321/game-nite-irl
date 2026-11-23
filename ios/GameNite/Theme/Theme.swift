import SwiftUI
import UIKit

/// 60-30-10: dark charcoal (60) · light neon blue accents (30) · white call-to-action (10).
enum Theme {
    static let bg = Color(hex: 0x1A1D21)
    static let surface = Color(hex: 0x22262B)
    static let surface2 = Color(hex: 0x2A2F35)
    static let line = Color(hex: 0x363C43)
    static let ink = Color(hex: 0xE6EAEE)
    static let muted = Color(hex: 0x97A1AB)

    static let neon = Color(hex: 0x4FD8FF)
    static let ice = Color(hex: 0x9BE9FF)
    static let neonSoft = Color(hex: 0x163440)
    static let cta = Color.white
    static let ctaInk = Color(hex: 0x15181B)

    static let ok = Color(hex: 0x3FD68A)
    static let warn = Color(hex: 0xF2B84B)
    static let crit = Color(hex: 0xFF5F5F)

    /// Loops seamlessly because it starts and ends on the same color.
    static let flowColors: [Color] = [neon, ice, cta, ice, neon]
    static let bannerColors: [Color] = [neon, ice, Color(hex: 0xE9FBFF), ice, neon]
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Moving gradient

/// A horizontal gradient that slides continuously, the same effect as the prototype's buttons.
struct FlowGradient: View {
    var colors: [Color] = Theme.flowColors
    var duration: Double = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration
                HStack(spacing: 0) {
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 2)
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 2)
                }
                .offset(x: -CGFloat(t) * w * 2)
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// White call-to-action with the moving neon-to-white gradient and a blue glow.
struct CTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Theme.ctaInk)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                if isEnabled { FlowGradient() } else { Theme.surface2 }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(isEnabled ? 0.55 : 0.1), lineWidth: 1))
            .shadow(color: Theme.neon.opacity(isEnabled ? (configuration.isPressed ? 0.95 : 0.6) : 0), radius: 14, y: 5)
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Charcoal secondary button with a hairline border that turns neon on press.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(configuration.isPressed ? Theme.neon : Theme.line, lineWidth: 1))
    }
}

extension ButtonStyle where Self == CTAButtonStyle {
    static var cta: CTAButtonStyle { CTAButtonStyle() }
    static var ctaCompact: CTAButtonStyle { CTAButtonStyle(fullWidth: false) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryCompact: SecondaryButtonStyle { SecondaryButtonStyle(fullWidth: false) }
}

// MARK: - Cards, pills, labels

/// Card with a moving neon-to-white gradient border and a glow behind it.
struct GlowCard: ViewModifier {
    var duration: Double = 7
    var dimmed = false

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                FlowGradient(duration: duration)
                    .mask(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(lineWidth: 2))
            }
            .shadow(color: Theme.neon.opacity(dimmed ? 0.25 : 0.45), radius: 16, y: 8)
    }
}

/// Plain charcoal panel for everything that isn't a hero card.
struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func glowCard(duration: Double = 7, dimmed: Bool = false) -> some View {
        modifier(GlowCard(duration: duration, dimmed: dimmed))
    }
    func panel() -> some View { modifier(Panel()) }
}

struct Pill: View {
    let text: String
    var tint: Color = Theme.muted
    var filled = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(filled ? Theme.ctaInk : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(filled ? tint : tint.opacity(0.14), in: Capsule())
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }
}

// MARK: - Big block title

/// "GAME / NITE" in heavy expanded capitals, each line sized to fill the width,
/// filled with the moving gradient.
struct MegaTitle: View {
    let lines: [String]
    @State private var width: CGFloat = 320

    private static let probeSize: CGFloat = 100

    private func fontSize(for line: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: Self.probeSize, weight: .black, width: .expanded)
        let measured = (line as NSString).size(withAttributes: [.font: font]).width
        guard measured > 0 else { return 60 }
        return floor(Self.probeSize * width / measured * 0.98)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.self) { line in
                let size = fontSize(for: line)
                Text(line)
                    .font(.system(size: size, weight: .black).width(.expanded))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: size * 0.86)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        stack
            .hidden()
            .overlay { FlowGradient(duration: 8).mask(stack) }
            .shadow(color: Theme.neon.opacity(0.45), radius: 14)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityElement()
            .accessibilityLabel(lines.joined(separator: " ").capitalized)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Charcoal text field with a neon focus ring.
struct FieldStyle: ViewModifier {
    var focused: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Theme.neon : Theme.line, lineWidth: 1))
            .foregroundStyle(Theme.ink)
    }
}

extension View {
    func fieldStyle(focused: Bool = false) -> some View { modifier(FieldStyle(focused: focused)) }
}
