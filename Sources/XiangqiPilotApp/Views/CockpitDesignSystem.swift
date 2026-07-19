import SwiftUI

enum CockpitPalette {
    static let canvas = Color(red: 0.035, green: 0.047, blue: 0.067)
    static let sidebar = Color(red: 0.048, green: 0.063, blue: 0.087)
    static let panel = Color(red: 0.061, green: 0.078, blue: 0.105)
    static let panelRaised = Color(red: 0.078, green: 0.098, blue: 0.130)
    static let border = Color.white.opacity(0.095)
    static let borderStrong = Color.white.opacity(0.16)
    static let primaryText = Color(red: 0.91, green: 0.94, blue: 0.98)
    static let secondaryText = Color(red: 0.58, green: 0.64, blue: 0.72)
    static let tertiaryText = Color(red: 0.38, green: 0.43, blue: 0.51)
    static let blue = Color(red: 0.32, green: 0.64, blue: 1.0)
    static let cyan = Color(red: 0.34, green: 0.88, blue: 0.91)
    static let green = Color(red: 0.31, green: 0.82, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.31)
    static let red = Color(red: 1.0, green: 0.34, blue: 0.38)
    static let boardSurface = Color(red: 0.78, green: 0.61, blue: 0.38)
    static let boardHighlight = Color(red: 0.92, green: 0.76, blue: 0.49)
    static let boardLine = Color(red: 0.22, green: 0.13, blue: 0.075)
}

struct CockpitPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var raised: Bool = false

    func body(content: Content) -> some View {
        content
            .background(raised ? CockpitPalette.panelRaised : CockpitPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(CockpitPalette.border, lineWidth: 1)
            }
    }
}

extension View {
    func cockpitPanel(cornerRadius: CGFloat = 14, raised: Bool = false) -> some View {
        modifier(CockpitPanelModifier(cornerRadius: cornerRadius, raised: raised))
    }
}

struct StatusDot: View {
    let color: Color
    var isPulsing: Bool = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.65), radius: 4)
        }
        .frame(width: 14, height: 14)
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String?
    var trailingSymbol: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(CockpitPalette.secondaryText)

            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CockpitPalette.tertiaryText)
            }

            Spacer(minLength: 8)

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CockpitPalette.tertiaryText)
            }
        }
    }
}

struct CapsuleBadge: View {
    let title: String
    let color: Color
    var symbolName: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.11))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(color.opacity(0.25), lineWidth: 1)
        }
    }
}

struct CockpitActionButtonStyle: ButtonStyle {
    let color: Color
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 11 : 15)
            .frame(height: compact ? 30 : 38)
            .background(color.opacity(configuration.isPressed ? 0.68 : 0.88))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: color.opacity(configuration.isPressed ? 0.08 : 0.18), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(CockpitPalette.primaryText)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 30 : 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.065))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(CockpitPalette.borderStrong, lineWidth: 1)
            }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = CockpitPalette.primaryText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CockpitPalette.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}
