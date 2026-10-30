import SwiftUI

struct WatchabilityRatingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let index: MatchWatchabilityIndex
    var showsLabel = true

    var body: some View {
        Group {
            if showsLabel && dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    stars
                    Text(index.ratingTitle)
                }
            } else {
                HStack(spacing: 8) {
                    stars
                    if showsLabel {
                        Text(index.ratingTitle)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Watchability: \(index.ratingTitle), \(index.ratingStars) out of 5 stars")
    }

    private var stars: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { position in
                Image(systemName: position <= index.ratingStars ? "star.fill" : "star")
                    .foregroundStyle(position <= index.ratingStars ? tierColor : Color.secondary.opacity(0.46))
            }
        }
    }

    private var tierColor: Color {
        switch index.ratingStars {
        case 5: Color(red: 0.38, green: 0.86, blue: 0.35)
        case 4: Color(red: 0.92, green: 0.80, blue: 0.22)
        case 3: Color(red: 0.98, green: 0.63, blue: 0.16)
        default: Color(red: 0.96, green: 0.47, blue: 0.16)
        }
    }
}
