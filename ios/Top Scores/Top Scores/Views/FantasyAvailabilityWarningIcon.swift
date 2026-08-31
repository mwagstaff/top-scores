import SwiftUI

struct FantasyAvailabilityWarningIcon: View {
    var label = "Player has an availability issue"
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.orange)
            .accessibilityLabel(label)
    }
}
