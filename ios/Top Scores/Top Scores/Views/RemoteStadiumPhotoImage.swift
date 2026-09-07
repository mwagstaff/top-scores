import SwiftUI
import UIKit

struct StadiumPhotoLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatesSheen = false

    let isLoading: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.018, green: 0.028, blue: 0.034)

                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.07, blue: 0.065),
                        Color(red: 0.018, green: 0.028, blue: 0.034),
                        Color(red: 0.025, green: 0.045, blue: 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if isLoading, !reduceMotion {
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.black.opacity(0.16),
                            Color.white.opacity(0.035),
                            Color.black.opacity(0.20),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.56)
                    .scaleEffect(x: 1.4)
                    .offset(x: animatesSheen ? proxy.size.width * 1.2 : -proxy.size.width * 1.2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            startSheenIfNeeded()
        }
        .onChange(of: reduceMotion) { _, _ in
            startSheenIfNeeded()
        }
        .onChange(of: isLoading) { _, _ in
            startSheenIfNeeded()
        }
        .accessibilityHidden(true)
    }

    private func startSheenIfNeeded() {
        guard isLoading, !reduceMotion else {
            animatesSheen = false
            return
        }
        animatesSheen = false
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            animatesSheen = true
        }
    }
}

struct RemoteStadiumPhotoImage: View {
    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed
    }

    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadState: LoadState = .loading

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                StadiumPhotoLoadingView(isLoading: true)
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity)
            case .failed:
                StadiumPhotoLoadingView(isLoading: false)
            }
        }
        .task(id: url.absoluteString) {
            loadState = .loading
            let image = await StadiumPhotoCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                loadState = image.map(LoadState.loaded) ?? .failed
            }
        }
    }
}

struct StadiumHeroEdgeFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black, location: 0),
                .init(color: Color.black.opacity(0.35), location: 0.10),
                .init(color: Color.black.opacity(0.10), location: 0.25),
                .init(color: Color.black.opacity(0.05), location: 0.48),
                .init(color: Color.black.opacity(0.20), location: 0.70),
                .init(color: Color.black.opacity(0.65), location: 0.88),
                .init(color: Color.black, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .accessibilityHidden(true)
    }
}
