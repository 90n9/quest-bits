import SwiftUI

// Design tokens from DESIGN.md (QuestBit-cozy-rpg, version 1).
// "Cozy RPG" theme: parchment surfaces, wood-brown ink, harvest gold + herb green
// accents. Headings use Alegreya, body uses Quicksand — both variable TTFs bundled
// in Contents/Resources/Fonts and registered via ATSApplicationFontsPath (see
// build-app.sh). The app is locked to light appearance (TodoApp.swift) because
// DESIGN.md defines no dark-mode tokens.
//
// Token names keep their original (Miro-era) identifiers so Views.swift call sites
// stay stable; the DESIGN.md alias for each is noted inline.
enum Theme {

    // MARK: colors:
    enum Colors {
        static let primary        = Color(hex: 0x4a3423)  // bark — primary buttons, dark bars
        static let onPrimary      = Color(hex: 0xf9f0dd)  // cream text on bark
        static let brandYellow    = Color(hex: 0xd9a33c)  // harvest gold — brand accent
        static let brandYellowDeep = Color(hex: 0xc08c28) // gold-deep — in-progress, emphasis
        static let yellowLight    = Color(hex: 0xf4e3b8)  // gold-light chip fill
        static let yellowDark     = Color(hex: 0x7a5a12)  // gold-dark chip text
        static let brandBlue      = Color(hex: 0xc8622f)  // ember rust — links, selection, focus
        static let bluePressed    = Color(hex: 0xa34d20)  // ember-pressed
        static let brandCoral     = Color(hex: 0xd98d6a)  // clay — warm callouts
        static let coralLight     = Color(hex: 0xf3cdb7)  // clay-light chip fill
        static let coralDark      = Color(hex: 0x8a3a12)  // clay-dark chip text
        static let roseLight      = Color(hex: 0xf6dfd0)  // blush parchment tint
        static let brandTeal      = Color(hex: 0x5c8f4a)  // herb green accent
        static let tealLight      = Color(hex: 0xddead0)  // herb-light chip fill
        static let mossDark       = Color(hex: 0x3f6b2a)  // moss chip text
        static let brandRed       = Color(hex: 0xeecdc0)  // soft error background
        static let brandRedDark   = Color(hex: 0xd9b2a2)  // error border
        static let successAccent  = Color(hex: 0x6f9b3c)  // quest-complete green
        static let canvas         = Color(hex: 0xfaf3e3)  // parchment — main background & cards
        static let vellum         = Color(hex: 0xfdf9ec)  // brightest cream — input field fill
        static let surface        = Color(hex: 0xf1e5cc)  // aged parchment — panels, pressed fills
        static let surfaceSoft    = Color(hex: 0xf6eedd)  // quiet parchment section
        static let surfaceYellow  = Color(hex: 0xf7ebc9)  // gold-tinted chip surface
        static let surfacePricingFeatured = Color(hex: 0xf5e3b3) // selection highlight (pale gold)
        static let hairline       = Color(hex: 0xd9c4a0)  // parchment hairline
        static let hairlineSoft   = Color(hex: 0xe7d9bb)  // quiet divider
        static let hairlineStrong = Color(hex: 0xc2a87e)  // input/border emphasis
        static let inkDeep        = Color(hex: 0x33241a)  // espresso headlines
        static let ink            = Color(hex: 0x4a3423)  // primary text (bark)
        static let charcoal       = Color(hex: 0x5d4430)  // pressed-state bark
        static let slate          = Color(hex: 0x6f583f)  // secondary text
        static let steel          = Color(hex: 0x8c745c)  // tertiary text
        static let stone          = Color(hex: 0xa08a6e)  // captions, muted labels
        static let muted          = Color(hex: 0xb5a289)  // disabled, placeholders
        static let onDark         = Color(hex: 0xf9f0dd)  // cream on dark wood
        static let onDarkMuted    = Color(hex: 0xcbb598)  // muted cream on dark wood
    }

    // MARK: typography: Alegreya (headings) + Quicksand (body), bundled OFL fonts
    private static func alegreya(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        Font.custom("Alegreya", size: size).weight(weight)
    }
    private static func quicksand(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom("Quicksand", size: size).weight(weight)
    }

    enum Fonts {
        static let heading2      = Theme.alegreya(36, .bold)
        static let heading3      = Theme.alegreya(28, .bold)
        static let heading4      = Theme.alegreya(22, .bold)
        static let heading5      = Theme.alegreya(18, .bold)
        static let subtitle      = Theme.quicksand(18)
        static let bodyMd        = Theme.quicksand(16)
        static let bodyMdMedium  = Theme.quicksand(16, .semibold)
        static let bodySm        = Theme.quicksand(14)
        static let bodySmMedium  = Theme.quicksand(14, .semibold)
        static let caption       = Theme.quicksand(13)
        static let captionBold   = Theme.quicksand(13, .bold)
        static let micro         = Theme.quicksand(12, .medium)
        // Spec also gives micro-uppercase 0.5px letterSpacing; Font can't carry tracking,
        // so apply `.tracking(0.5)` at use sites.
        static let microUppercase = Theme.quicksand(11, .bold)
        static let buttonMd      = Theme.quicksand(14, .bold)
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

// MARK: - bundled art (Contents/Resources/{Icons,Frames,Textures})

/// Cached loader for bundled art files. All assets are CC0 / MIT / ISC —
/// license texts ship next to the files in the same bundle subdirectory.
enum QBArt {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, ext: String, subdirectory: String,
                      template: Bool = false) -> NSImage? {
        let key = "\(subdirectory)/\(name).\(ext)"
        if let hit = cache[key] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext,
                                        subdirectory: subdirectory),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = template
        cache[key] = img
        return img
    }
}

/// Bundled SVG icon (Contents/Resources/Icons — Lucide ISC / Tabler MIT sets).
/// Rendered as a template image so it tints via `.foregroundStyle(...)` like an
/// SF Symbol. Name is the file basename, e.g. "lucide-map", "tabler-campfire".
struct QBIcon: View {
    let name: String
    var size: CGFloat = 15

    var body: some View {
        if let img = QBArt.image(name, ext: "svg", subdirectory: "Icons", template: true) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            // Dev-build fallback if the bundle is missing the icon.
            Image(systemName: "questionmark.circle")
                .font(.system(size: size - 2))
        }
    }
}

/// Parchment surface: canvas color with the Paper001 fiber texture tiled at low
/// opacity — texture without hurting text contrast (DESIGN.md `{colors.parchment}`).
struct QBParchmentBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Theme.Colors.canvas
                if let paper = QBArt.image("paper", ext: "jpg", subdirectory: "Textures") {
                    Image(nsImage: paper)
                        .resizable(resizingMode: .tile)
                        .opacity(0.12)
                }
            }
            .clipped()
        }
    }
}

/// Hearth surface: Planks037A wood grain under a bark scrim — the update banner.
struct QBHearthBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            ZStack {
                if let planks = QBArt.image("planks", ext: "jpg", subdirectory: "Textures") {
                    Image(nsImage: planks).resizable(resizingMode: .tile)
                }
                Theme.Colors.primary.opacity(0.85)
            }
            .clipped()
        }
    }
}

/// Ornamental quest frame: Kenney fantasy border (white line-art, template-tinted)
/// stretched 9-slice around the content. Decorative only — never intercepts clicks.
struct QBQuestFrame: ViewModifier {
    var color: Color = Theme.Colors.hairlineStrong

    func body(content: Content) -> some View {
        content.overlay {
            if let frame = QBArt.image("panel-border", ext: "png",
                                       subdirectory: "Frames", template: true) {
                Image(nsImage: frame)
                    .renderingMode(.template)
                    .resizable(capInsets: EdgeInsets(top: 30, leading: 30,
                                                     bottom: 30, trailing: 30),
                               resizingMode: .stretch)
                    .foregroundStyle(color)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func qbParchment() -> some View { modifier(QBParchmentBackground()) }
    func qbHearth() -> some View { modifier(QBHearthBackground()) }
    func qbQuestFrame(_ color: Color = Theme.Colors.hairlineStrong) -> some View {
        modifier(QBQuestFrame(color: color))
    }
}

/// Themed replacement for a grouped-`Form` section: micro-uppercase label
/// (matches the sidebar section headers) above a soft-parchment card.
struct QBDetailSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs + 2) {
            if let title {
                Text(title.uppercased())
                    .font(Theme.Fonts.microUppercase)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Colors.steel)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.sm)
            // Border-less raised-paper card (2px warm drop edge) so it can't be
            // confused with the stroked input fields sitting inside it. Shadow goes
            // on the background shape only — on the container it would cascade to
            // every child view and double-outline the fields.
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.Colors.surfaceSoft)
                    .shadow(color: Color(hex: 0x8a6a48).opacity(0.25),
                            radius: 0, x: 0, y: 2)
            }
        }
    }
}

/// `text-input` component: bright vellum field with hairline-strong border and a
/// tighter radius — visually "inset", distinct from the border-less section cards.
struct QBFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.Colors.vellum,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Theme.Colors.hairlineStrong, lineWidth: 1)
            )
    }
}

extension View {
    func qbField() -> some View { modifier(QBFieldStyle()) }
}

/// Compact date field: a vellum button showing the formatted date that opens a
/// graphical calendar popover with quick-pick chips — replaces the fiddly
/// stepper-field DatePicker.
struct QBDateField: View {
    @Binding var date: Date
    @State private var showPicker = false

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.steel)
                Text(Self.fmt.string(from: date))
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.Colors.vellum,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Theme.Colors.hairlineStrong, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.xs) {
                    quickPick("Today", days: 0)
                    quickPick("Tomorrow", days: 1)
                    quickPick("Next week", days: 7)
                }
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            .padding(Theme.Spacing.md)
            // Popovers don't inherit the window tint — re-apply for the calendar.
            .tint(Theme.Colors.brandBlue)
        }
    }

    private func quickPick(_ label: String, days: Int) -> some View {
        Button(label) {
            date = Calendar.current.date(byAdding: .day, value: days,
                                         to: Calendar.current.startOfDay(for: Date())) ?? Date()
            showPicker = false
        }
        .buttonStyle(QBSecondaryButtonStyle(compact: true))
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

/// Quieter rectangular ghost button (`button-ghost`). `onDark` renders cream text
/// for bark surfaces (the hearth).
struct QBGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var onDark = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.buttonMd)
            .foregroundStyle(
                !isEnabled ? (onDark ? Theme.Colors.onDarkMuted.opacity(0.5) : Theme.Colors.muted)
                    : onDark ? Theme.Colors.onDarkMuted
                    : Theme.Colors.ink
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                configuration.isPressed
                    ? (onDark ? Theme.Colors.charcoal : Theme.Colors.surface)
                    : .clear,
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
