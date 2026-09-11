import SwiftUI

enum BeatAIStyle {
    static let background = Color(red: 0.025, green: 0.055, blue: 0.12)
    static let blue = Color(red: 23.0 / 255, green: 133.0 / 255, blue: 1)
    static let gold = Color(red: 1, green: 0.79, blue: 0.27)
    static let green = Color(red: 0.27, green: 0.86, blue: 0.61)
    static let red = Color(red: 1, green: 0.32, blue: 0.38)
    static let purple = Color(red: 0.71, green: 0.57, blue: 1)
    static let muted = Color(red: 0.67, green: 0.73, blue: 0.84)
}

struct BeatAIBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.045, green: 0.095, blue: 0.19), BeatAIStyle.background],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct BeatAIPanel<Content: View>: View {
    let accent: Color
    let padding: CGFloat
    private let content: Content

    init(accent: Color = BeatAIStyle.blue, padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.075, green: 0.13, blue: 0.23), Color(red: 0.045, green: 0.085, blue: 0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(accent.opacity(0.24), lineWidth: 1)
                    }
            }
    }
}

struct BeatAIPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(
                        colors: [BeatAIStyle.blue, Color(red: 0.09, green: 0.31, blue: 0.82)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.55)
    }
}

struct BeatAIGameCenterStatus: View {
    @EnvironmentObject private var game: PredictionGameStore

    var body: some View {
        if game.isConnectingGameCenter {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting Game Center ready…")
            }
            .font(.caption)
            .foregroundStyle(BeatAIStyle.muted)
        } else if let message = game.gameCenterStatusMessage {
            Label(message, systemImage: "person.2.fill")
                .font(.caption)
                .foregroundStyle(BeatAIStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
