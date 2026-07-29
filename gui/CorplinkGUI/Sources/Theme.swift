import SwiftUI

/// Visual language aligned with the AEye app icon: slate field + teal arc accent.
enum CLTheme {
    static let slate = Color(red: 0.22, green: 0.30, blue: 0.40)
    static let slateDeep = Color(red: 0.14, green: 0.19, blue: 0.26)
    static let mist = Color(red: 0.90, green: 0.93, blue: 0.95)
    static let teal = Color(red: 0.18, green: 0.72, blue: 0.72)
    static let tealSoft = Color(red: 0.18, green: 0.72, blue: 0.72).opacity(0.18)
    static let warn = Color(red: 0.95, green: 0.62, blue: 0.28)
    static let danger = Color(red: 0.90, green: 0.38, blue: 0.36)
    static let ok = Color(red: 0.35, green: 0.78, blue: 0.55)

    static var panelFill: Color { Color.white.opacity(0.06) }
    static var panelStroke: Color { Color.white.opacity(0.10) }
    static var hairline: Color { Color.white.opacity(0.08) }
}

struct CLPanel<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CLTheme.panelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(CLTheme.panelStroke, lineWidth: 1)
                    )
            )
    }
}

struct CLPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? CLTheme.slateDeep : Color.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(enabled ? CLTheme.teal : Color.white.opacity(0.08))
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
    }
}

struct CLGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.55 : 0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0.03)))
            )
    }
}
