import SwiftUI

enum FootballVisualStyle {
    static let pageBackground = Color(red: 0.015, green: 0.030, blue: 0.048)
    static let elevatedSurface = Color(red: 0.040, green: 0.075, blue: 0.115)
    static let cardTop = Color(red: 0.055, green: 0.105, blue: 0.165)
    static let cardBottom = Color(red: 0.025, green: 0.065, blue: 0.110)
    static let mutedText = Color(red: 0.57, green: 0.64, blue: 0.72)
    static let predictionAccent = Color(red: 0.57, green: 0.43, blue: 0.98)
    static let border = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.075)

    static let cardCornerRadius: CGFloat = 24
    static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
}

struct FootballCardSurface: View {
    let accentColor: Color
    var showsPitchMarkings = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        FootballVisualStyle.cardTop,
                        FootballVisualStyle.cardBottom,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [accentColor.opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: proxy.size.width * 0.78
                )

                if showsPitchMarkings {
                    FootballPitchLines()
                        .stroke(Color.white.opacity(0.025), lineWidth: 1)
                        .padding(20)
                }

                LinearGradient(
                    colors: [Color.white.opacity(0.055), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FootballPitchLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addEllipse(in: CGRect(
            x: rect.midX - rect.width * 0.12,
            y: rect.midY - rect.width * 0.12,
            width: rect.width * 0.24,
            height: rect.width * 0.24
        ))
        return path
    }
}
