import SwiftUI
import TagwerkCore

let germanLocale = Locale(identifier: "de_DE")

extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, opacity: 1)
    }

    init(hex: String) {
        if let rgb = RGB(hex: hex) {
            self.init(rgb: rgb)
        } else {
            self.init(.sRGB, red: 0.56, green: 0.56, blue: 0.58, opacity: 1)
        }
    }

    /// The colour scale of the rating chart in the vault.
    static func rating(_ value: Double?) -> Color {
        guard let value else { return Color(.sRGB, red: 0.55, green: 0.57, blue: 0.62, opacity: 1) }
        return Color(rgb: RatingScale.color(for: value))
    }

    static func habitScore(_ score: Double) -> Color { Color(rgb: RatingScale.color(forScore: score)) }
}

enum Format {
    /// "7,4"
    static func rating(_ v: Double?) -> String {
        guard let v else { return "–" }
        return RatingScale.format(v).replacingOccurrences(of: ".", with: ",")
    }

    static func decimal(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: ".", with: ",")
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "noch nie" }
        if abs(date.timeIntervalSinceNow) < 60 { return "gerade eben" }
        return date.formatted(.relative(presentation: .named).locale(germanLocale))
    }

    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// "Do, 12. November"
    static func dayTitle(_ key: String) -> String {
        guard let d = DayKey.date(key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(germanLocale))
    }

    static func when(date: String, start: String?, end: String?, allDay: Bool) -> String {
        let day = dayTitle(date)
        if allDay || start == nil { return "\(day) · ganztägig" }
        if let start, let end { return "\(day) · \(start)–\(end)" }
        return "\(day) · \(start ?? "")"
    }

    static func due(_ key: String, today: String) -> String {
        guard let d = DayKey.distance(from: today, to: key) else { return key }
        switch d {
        case 0: return "heute"
        case 1: return "morgen"
        case 2: return "übermorgen"
        case 3...6: return "in \(d) Tagen"
        case -1: return "seit gestern überfällig"
        case ..<(-1): return "seit \(-d) Tagen überfällig"
        default: return dayTitle(key)
        }
    }
}

/// Content-layer surface: standard material, never Liquid Glass (HIG, Materials).
struct CardSurface: ViewModifier {
    var padding: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.05), lineWidth: 0.5)
            }
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardSurface(padding: padding)) }
}

/// Slight press-down for custom tappable tiles.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// The day's colour as a quiet wash behind the content: the rating scale of the vault.
struct DayBackground: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let strong = scheme == .dark ? 0.50 : 0.30
        let soft = scheme == .dark ? 0.26 : 0.16
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.55, 0], [1, 0],
                    [0, 0.42], [0.62, 0.36], [1, 0.48],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    tint.opacity(strong), tint.opacity(soft), tint.opacity(strong * 0.8),
                    tint.opacity(soft * 0.7), .clear, tint.opacity(soft * 0.6),
                    .clear, .clear, .clear,
                ]
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: tint)
    }
}

struct SectionLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

struct ToastView: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let message = store.toast {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
