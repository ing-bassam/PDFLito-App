import SwiftUI

/// Shared look of PDFLito: one corner radius, one card, one primary button.
enum Theme {
    static let cornerRadius: CGFloat = 16

    static var gradient: LinearGradient {
        LinearGradient(colors: [Color.accentColor, Color(red: 0.36, green: 0.31, blue: 0.90)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// White (or dark grey) rounded panel that groups related controls.
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// The one big action on a screen ("Scannen", "Speichern").
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.gradient))
                .shadow(color: Color.accentColor.opacity(isEnabled ? 0.35 : 0), radius: 10, y: 5)
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }
}

/// Small coloured label such as "Gut lesbar" or "Unscharf".
struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Round icon badge used in the empty state and the settings.
struct IconBadge: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.14)))
    }
}
