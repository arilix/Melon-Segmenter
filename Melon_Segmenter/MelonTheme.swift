import SwiftUI

/// Shared color palette and styling helpers matching the Melon Segmenter logo.
enum MelonTheme {
    static let navy = Color(red: 0.06, green: 0.14, blue: 0.21)
    static let navyDeep = Color(red: 0.03, green: 0.08, blue: 0.13)
    static let leafGreen = Color(red: 0.29, green: 0.60, blue: 0.33)
    static let meadowGreen = Color(red: 0.49, green: 0.74, blue: 0.45)
    static let limeGreen = Color(red: 0.76, green: 0.83, blue: 0.47)
    static let accentTeal = Color(red: 0.16, green: 0.80, blue: 0.86)

    static let backgroundGradient = LinearGradient(
        colors: [navy, navyDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardBackground = Color.white.opacity(0.06)
}

extension View {
    /// Rounded, softly-bordered card container used throughout the app.
    func melonCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(MelonTheme.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Prominent pill button styled with the teal accent color.
struct MelonPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(MelonTheme.navyDeep)
            .padding(.vertical, 14)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background(MelonTheme.accentTeal, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Secondary pill button with a subtle outline, for lower-emphasis actions.
struct MelonSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.05 : 0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
