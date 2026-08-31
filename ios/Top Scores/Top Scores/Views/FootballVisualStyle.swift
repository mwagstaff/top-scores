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

enum FootballSectionAccent {
    static let fantasy = Color(red: 0.55, green: 0.38, blue: 0.94)
    static let action = Color(red: 0.20, green: 0.72, blue: 0.46)
    static let media = Color(red: 0.24, green: 0.56, blue: 0.94)
    static let venue = Color(red: 0.94, green: 0.61, blue: 0.20)
}

struct FootballCardSurface: View {
    let accentColor: Color
    var showsPitchMarkings = false
    var accentOpacity = 0.18

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
                    colors: [accentColor.opacity(accentOpacity), .clear],
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

private struct FootballTintedSurfaceModifier: ViewModifier {
    let accentColor: Color
    let cornerRadius: CGFloat
    let showsPitchMarkings: Bool
    let accentOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                FootballCardSurface(
                    accentColor: accentColor,
                    showsPitchMarkings: showsPitchMarkings,
                    accentOpacity: accentOpacity
                )
            }
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.34), FootballVisualStyle.border],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }
}

extension View {
    func footballTintedSurface(
        accentColor: Color,
        cornerRadius: CGFloat,
        showsPitchMarkings: Bool = false,
        accentOpacity: Double = 0.18
    ) -> some View {
        modifier(
            FootballTintedSurfaceModifier(
                accentColor: accentColor,
                cornerRadius: cornerRadius,
                showsPitchMarkings: showsPitchMarkings,
                accentOpacity: accentOpacity
            )
        )
    }
}

struct LiveInPlayStandingsNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.liveMatch)
                .frame(width: 7, height: 7)
            Text("Live in-play standings. Provisional, subject to change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct LiveStandingsRowBackground: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !isActive || accessibilityReduceMotion
            )
        ) { context in
            Rectangle()
                .fill(Color.liveMatch)
                .opacity(liveStandingsRowHighlightOpacity(
                    at: context.date,
                    isActive: isActive,
                    reduceMotion: accessibilityReduceMotion
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityHidden(true)
    }
}

func liveStandingsRowHighlightOpacity(
    at date: Date,
    isActive: Bool,
    reduceMotion: Bool
) -> Double {
    guard isActive else { return 0 }
    guard !reduceMotion else { return 0.14 }

    let cycleDuration = 2.2
    let cyclePosition = date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    let pulse = (1 - cos(cyclePosition * 2 * .pi)) / 2
    return 0.07 + (0.13 * pulse)
}

struct FootballPitchSegmentOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil

    var id: Value { value }
}

struct FootballPitchSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [FootballPitchSegmentOption<Value>]
    let accessibilityLabel: String
    var minimumHeight: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                optionButton(option)
            }
        }
        .frame(minHeight: minimumHeight)
        .background {
            FootballPitchSegmentedBackground(
                selectedIndex: selectedIndex,
                segmentCount: options.count
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var selectedIndex: Int {
        options.firstIndex(where: { $0.value == selection }) ?? 0
    }

    private func optionButton(_ option: FootballPitchSegmentOption<Value>) -> some View {
        let isSelected = selection == option.value

        return Button {
            withAnimation(accessibilityReduceMotion ? nil : FootballVisualStyle.easeOut) {
                selection = option.value
            }
        } label: {
            HStack(spacing: 10) {
                if let systemImage = option.systemImage {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(isSelected ? 0.14 : 0.055))
                        Circle()
                            .stroke(Color.white.opacity(isSelected ? 0.52 : 0.18), lineWidth: 1)
                        Image(systemName: systemImage)
                            .font(.system(size: 17, weight: .bold))
                    }
                    .frame(width: 38, height: 38)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.subheadline.weight(.heavy))
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.58))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(option.subtitle ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FootballPitchSegmentedBackground: View {
    let selectedIndex: Int
    let segmentCount: Int

    var body: some View {
        GeometryReader { proxy in
            let safeSegmentCount = max(segmentCount, 1)
            let segmentWidth = proxy.size.width / CGFloat(safeSegmentCount)
            let lineColor = Color.white.opacity(0.20)

            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.095, blue: 0.075),
                        Color(red: 0.018, green: 0.045, blue: 0.050),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.48, blue: 0.16),
                        Color(red: 0.015, green: 0.28, blue: 0.10),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: segmentWidth)
                .offset(x: segmentWidth * CGFloat(min(max(selectedIndex, 0), safeSegmentCount - 1)))

                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { index in
                        Rectangle()
                            .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.026 : 0))
                    }
                }

                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(lineColor.opacity(0.76), lineWidth: 1)
                    .padding(6)

                ForEach(Array(1..<safeSegmentCount), id: \.self) { index in
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: proxy.size.height - 12)
                        .position(
                            x: segmentWidth * CGFloat(index),
                            y: proxy.size.height / 2
                        )
                }

                Circle()
                    .stroke(lineColor, lineWidth: 1)
                    .frame(width: 46, height: 46)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(lineColor.opacity(0.72), lineWidth: 1)
                    .frame(width: 30, height: 38)
                    .position(x: 5, y: proxy.size.height / 2)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(lineColor.opacity(0.72), lineWidth: 1)
                    .frame(width: 30, height: 38)
                    .position(x: proxy.size.width - 5, y: proxy.size.height / 2)

                LinearGradient(
                    colors: [Color.white.opacity(0.07), .clear],
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
