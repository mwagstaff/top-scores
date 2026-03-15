import SwiftUI

struct FantasyLionIconView: View {
    let size: CGFloat
    var scale: CGFloat = 1.0

    var body: some View {
        Image("FantasyPremierLeagueLion")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size * scale, height: size * scale)
            .frame(width: size, height: size)
    }
}
