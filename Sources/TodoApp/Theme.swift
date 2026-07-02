import SwiftUI

// Design tokens from DESIGN.md (Miro-design-analysis, version alpha).
// Typography uses the system font (SF Pro) with DESIGN.md's sizes/weights/tracking —
// Roobert PRO is proprietary and not bundled. The app is locked to light appearance
// (TodoApp.swift) because DESIGN.md defines no dark-mode tokens.
enum Theme {

    // MARK: colors:
    enum Colors {
        static let primary        = Color(hex: 0x1c1c1e)
        static let onPrimary      = Color(hex: 0xffffff)
        static let brandYellow    = Color(hex: 0xffd02f)
        static let brandYellowDeep = Color(hex: 0xfcb900)
        static let yellowLight    = Color(hex: 0xfff4c4)
        static let yellowDark     = Color(hex: 0x746019)
        static let brandBlue      = Color(hex: 0x4262ff)
        static let bluePressed    = Color(hex: 0x2a41b6)
        static let brandCoral     = Color(hex: 0xff9999)
        static let coralLight     = Color(hex: 0xffc6c6)
        static let coralDark      = Color(hex: 0x600000)
        static let roseLight      = Color(hex: 0xfde0f0)
        static let brandTeal      = Color(hex: 0x0fbcb0)
        static let tealLight      = Color(hex: 0xc3faf5)
        static let mossDark       = Color(hex: 0x187574)
        static let brandRed       = Color(hex: 0xfbd4d4)
        static let brandRedDark   = Color(hex: 0xe3c5c5)
        static let successAccent  = Color(hex: 0x00b473)
        static let canvas         = Color(hex: 0xffffff)
        static let surface        = Color(hex: 0xf7f8fa)
        static let surfaceSoft    = Color(hex: 0xfafbfc)
        static let surfaceYellow  = Color(hex: 0xfff8e0)
        static let surfacePricingFeatured = Color(hex: 0xf5f3ff)
        static let hairline       = Color(hex: 0xe0e2e8)
        static let hairlineSoft   = Color(hex: 0xeef0f3)
        static let hairlineStrong = Color(hex: 0xc7cad5)
        static let inkDeep        = Color(hex: 0x050038)
        static let ink            = Color(hex: 0x1c1c1e)
        static let charcoal       = Color(hex: 0x2c2c34)
        static let slate          = Color(hex: 0x555a6a)
        static let steel          = Color(hex: 0x6b6f7e)
        static let stone          = Color(hex: 0x8e91a0)
        static let muted          = Color(hex: 0xa5a8b5)
        static let onDark         = Color(hex: 0xffffff)
        static let onDarkMuted    = Color(hex: 0xa5a8b5)
    }

    // MARK: typography: (system font stand-in for Roobert PRO)
    enum Fonts {
        static let heading2      = Font.system(size: 36, weight: .medium)
        static let heading3      = Font.system(size: 28, weight: .medium)
        static let heading4      = Font.system(size: 22, weight: .medium)
        static let heading5      = Font.system(size: 18, weight: .medium)
        static let subtitle      = Font.system(size: 18, weight: .regular)
        static let bodyMd        = Font.system(size: 16, weight: .regular)
        static let bodyMdMedium  = Font.system(size: 16, weight: .medium)
        static let bodySm        = Font.system(size: 14, weight: .regular)
        static let bodySmMedium  = Font.system(size: 14, weight: .medium)
        static let caption       = Font.system(size: 13, weight: .regular)
        static let captionBold   = Font.system(size: 13, weight: .semibold)
        static let micro         = Font.system(size: 12, weight: .medium)
        // Spec also gives micro-uppercase 0.5px letterSpacing; Font can't carry tracking,
        // so apply `.tracking(0.5)` at use sites.
        static let microUppercase = Font.system(size: 11, weight: .semibold)
        static let buttonMd      = Font.system(size: 14, weight: .medium)
        static let codeBadge     = Font.system(size: 11, weight: .semibold, design: .monospaced)
    }

    // MARK: rounded:
    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
    }

    // MARK: spacing:
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

// MARK: - components: button-primary / button-primary-pressed / button-primary-disabled

/// Black pill primary CTA (`button-primary`). Pressed → charcoal; disabled → hairline/muted.
struct QBPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.buttonMd)
            .foregroundStyle(isEnabled ? Theme.Colors.onPrimary : Theme.Colors.muted)
            .padding(.horizontal, compact ? 14 : 24)
            .padding(.vertical, compact ? 5 : 12)
            .background(
                !isEnabled ? Theme.Colors.hairline
                    : configuration.isPressed ? Theme.Colors.charcoal
                    : Theme.Colors.primary,
                in: Capsule()
            )
    }
}

/// Outlined pill secondary action (`button-secondary`).
struct QBSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.buttonMd)
            .foregroundStyle(isEnabled ? Theme.Colors.ink : Theme.Colors.muted)
            .padding(.horizontal, compact ? 14 : 24)
            .padding(.vertical, compact ? 5 : 12)
            .background(configuration.isPressed ? Theme.Colors.surface : .clear, in: Capsule())
            .overlay(Capsule().stroke(Theme.Colors.hairlineStrong, lineWidth: 1))
    }
}

/// White pill for dark surfaces (`button-on-dark`), e.g. the promo/update banner.
struct QBOnDarkButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.buttonMd)
            .foregroundStyle(Theme.Colors.primary)
            .padding(.horizontal, compact ? 14 : 24)
            .padding(.vertical, compact ? 5 : 12)
            .background(
                configuration.isPressed ? Theme.Colors.hairline : Theme.Colors.onDark,
                in: Capsule()
            )
    }
}

/// Quieter rectangular ghost button (`button-ghost`).
struct QBGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.buttonMd)
            .foregroundStyle(isEnabled ? Theme.Colors.ink : Theme.Colors.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                configuration.isPressed ? Theme.Colors.surface : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// Inline text link (`button-link`).
struct QBLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodySmMedium)
            .foregroundStyle(configuration.isPressed ? Theme.Colors.bluePressed : Theme.Colors.brandBlue)
    }
}

/// 36×36 circular utility button (`button-icon-circular`).
struct QBIconCircularButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodySmMedium)
            .foregroundStyle(isEnabled ? Theme.Colors.ink : Theme.Colors.muted)
            .frame(width: 36, height: 36)
            .background(configuration.isPressed ? Theme.Colors.surface : Theme.Colors.canvas, in: Circle())
            .overlay(Circle().stroke(Theme.Colors.hairline, lineWidth: 1))
            .contentShape(Circle())
    }
}

// MARK: - components: badges & chips

/// Full-pill badge chip (`badge-tag-*` / `badge-promo` / `badge-success`): caption-bold, 4×10 padding.
struct QBBadge: ViewModifier {
    let background: Color
    let foreground: Color

    func body(content: Content) -> some View {
        content
            .font(Theme.Fonts.captionBold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}

extension View {
    func qbBadge(background: Color, foreground: Color) -> some View {
        modifier(QBBadge(background: background, foreground: foreground))
    }

    /// `card-base`: canvas surface, 16px corners, hairline-soft border.
    func qbCard(padding: CGFloat = Theme.Spacing.xl) -> some View {
        self.padding(padding)
            .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .stroke(Theme.Colors.hairlineSoft, lineWidth: 1)
            )
    }
}
