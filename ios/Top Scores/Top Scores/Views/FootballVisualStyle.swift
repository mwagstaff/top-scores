import Combine
import Foundation
import SwiftUI

@MainActor
final class StadiumBackdropStore: ObservableObject {
    static let assetNames = (1...22).map { String(format: "HeaderStadium%02d", $0) }

    private static let previousAssetNameKey = "appearance.previousHeaderStadiumAssetName"
    private static let rotationInterval: TimeInterval = 60 * 60
    private static let rotationIntervalNanoseconds: UInt64 = 3_600_000_000_000

    @Published private(set) var assetName: String

    private let defaults: UserDefaults
    private var lastRotationDate: Date

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        self.lastRotationDate = now

        let previousAssetName = defaults.string(forKey: Self.previousAssetNameKey)
        let candidates = Self.assetNames.filter { $0 != previousAssetName }
        let selectedAssetName = candidates.randomElement() ?? Self.assetNames[0]
        self.assetName = selectedAssetName
        defaults.set(selectedAssetName, forKey: Self.previousAssetNameKey)
    }

    func rotateIfNeeded(now: Date = Date()) {
        guard now.timeIntervalSince(lastRotationDate) >= Self.rotationInterval else { return }
        rotate(now: now)
    }

    func runHourlyRotation() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.rotationIntervalNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            rotateIfNeeded()
        }
    }

    private func rotate(now: Date = Date()) {
        let candidates = Self.assetNames.filter { $0 != assetName }
        guard let nextAssetName = candidates.randomElement() else { return }
        assetName = nextAssetName
        lastRotationDate = now
        defaults.set(nextAssetName, forKey: Self.previousAssetNameKey)
    }
}

private struct StadiumBackdropAssetNameKey: EnvironmentKey {
    static let defaultValue = "HeaderStadium01"
}

extension EnvironmentValues {
    var stadiumBackdropAssetName: String {
        get { self[StadiumBackdropAssetNameKey.self] }
        set { self[StadiumBackdropAssetNameKey.self] = newValue }
    }
}

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

struct FootballScreenBackdrop: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.stadiumBackdropAssetName) private var stadiumBackdropAssetName

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                FootballVisualStyle.pageBackground

                RemoteStadiumArtworkImage(
                    asset: stadiumArtworkStore.backdropAsset(selectionKey: stadiumBackdropAssetName),
                    apiBaseURL: preferences.apiBaseURL,
                    fallbackAssetName: stadiumBackdropAssetName
                )
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: 300)
                    .clipped()
                    .blur(radius: accessibilityReduceTransparency ? 0 : 2.5, opaque: true)
                    .offset(y: -42)
                    .opacity(accessibilityReduceTransparency ? 0.32 : 0.60)

                LinearGradient(
                    colors: [
                        FootballVisualStyle.pageBackground.opacity(0.28),
                        FootballVisualStyle.pageBackground.opacity(0.44),
                        FootballVisualStyle.pageBackground.opacity(0.94),
                        FootballVisualStyle.pageBackground,
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.46)
                )

                RadialGradient(
                    colors: [.clear, FootballVisualStyle.pageBackground.opacity(0.74)],
                    center: .top,
                    startRadius: 80,
                    endRadius: max(proxy.size.width, 360) * 0.72
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct FootballHeroHeader: View {
    let title: String
    var subtitle: String?
    var subtitleLink: URL?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if subtitleLink == nil {
            headerContent
                .accessibilityElement(children: .combine)
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(
                    dynamicTypeSize.isAccessibilitySize ? .title2 : .largeTitle,
                    design: .rounded,
                    weight: .heavy
                ))
                .foregroundStyle(Color.white.opacity(0.96))
                .contentTransition(.opacity)

            if let subtitle {
                if let subtitleLink {
                    Link(destination: subtitleLink) {
                        HStack(spacing: 5) {
                            Text(subtitle)
                            Image(systemName: "arrow.up.right.square")
                                .imageScale(.small)
                        }
                        .font((dynamicTypeSize.isAccessibilitySize ? Font.body : .headline).weight(.semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtitle)
                    .accessibilityHint("Opens in another app or browser")
                } else {
                    Text(subtitle)
                        .font((dynamicTypeSize.isAccessibilitySize ? Font.body : .headline).weight(.semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 8 : 4)
        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 14 : 10)
    }
}

struct FootballNavigationScreen<Content: View>: View {
    let title: String
    var subtitle: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                FootballVisualStyle.pageBackground
                    .ignoresSafeArea()

                FootballScreenBackdrop()

                VStack(spacing: 0) {
                    FootballHeroHeader(title: title, subtitle: subtitle)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .environment(\.colorScheme, .dark)
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
