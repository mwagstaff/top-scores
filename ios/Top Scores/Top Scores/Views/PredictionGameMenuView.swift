import SwiftUI

struct PredictionGameMenuView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDimFlashingLights) private var dimFlashingLights
    @ScaledMetric(relativeTo: .largeTitle) private var heroTitleSize = 46
    @State private var latestResultMessage = ""
    @State private var celebratedRoundID: String?
    @State private var fireworksID = UUID()
    @State private var showsFireworks = false

    let onStartPredictions: () -> Void
    let onProgress: () -> Void
    let onMyLeagues: () -> Void
    let onPredictionsVisibilityChanged: () -> Void
    let isStarting: Bool
    let predictionSet: PredictionGamePredictionSet?

    init(
        onStartPredictions: @escaping () -> Void,
        onProgress: @escaping () -> Void,
        onPredictionsVisibilityChanged: @escaping () -> Void,
        isStarting: Bool = false,
        predictionSet: PredictionGamePredictionSet? = nil,
        onMyLeagues: @escaping () -> Void = {}
    ) {
        self.onStartPredictions = onStartPredictions
        self.onProgress = onProgress
        self.onMyLeagues = onMyLeagues
        self.onPredictionsVisibilityChanged = onPredictionsVisibilityChanged
        self.isStarting = isStarting
        self.predictionSet = predictionSet
    }

    var body: some View {
        ZStack {
            BeatAIBackground()
            if showsFireworks && !reduceMotion && !dimFlashingLights {
                PredictionGameFireworks(trigger: fireworksID)
                    .id(fireworksID)
                    .transition(.opacity)
                    .task(id: fireworksID) {
                        try? await Task.sleep(for: .seconds(2.6))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.25)) { showsFireworks = false }
                    }
            }
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    VStack(spacing: 20) {
                        visibilityCard
                        if let latestResult { latestResultCard(latestResult) }
                        predictionCallToAction
                        benefits
                        progressCard
                        leaguesCard
                        if let message = game.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Couldn’t update your game", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline.weight(.semibold))
                                Text(message).font(.footnote).foregroundStyle(BeatAIStyle.muted)
                                Button("Try again", action: onStartPredictions)
                                    .frame(minHeight: 44)
                                    .disabled(isStarting)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        BeatAIGameCenterStatus()
                        Text("3 points for an exact score. 1 for the right result.\nSame rules for you and the AI.")
                            .font(.footnote)
                            .foregroundStyle(BeatAIStyle.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("prediction-game-home")
        .onChange(of: latestResult, initial: true) { _, result in
            present(result)
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "crown.fill")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(BeatAIStyle.gold)
                .shadow(color: .black.opacity(0.6), radius: 12, y: 3)
                .accessibilityHidden(true)
            Text("Beat the AI")
                .font(.system(size: min(heroTitleSize, 56), weight: .black, design: .rounded))
                .shadow(color: .black.opacity(0.7), radius: 12, y: 3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Don't let humanity down. We're counting on you.")
                .font(.headline)
                .shadow(color: .black, radius: 8)
                .fixedSize(horizontal: false, vertical: true)
            PredictionGameCompetitionPicker()
                .padding(.top, 4)
            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 70 : 130)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 400 : 350)
        .background {
            GeometryReader { geometry in
                Image("BeatAIHero")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            stops: [.init(color: .black.opacity(0.18), location: 0),
                                    .init(color: BeatAIStyle.background.opacity(0.3), location: 0.55),
                                    .init(color: BeatAIStyle.background, location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibilityCard: some View {
        BeatAIPanel {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show AI predictions", isOn: predictionsVisibility)
                        .font(.headline)
                        .accessibilityIdentifier("beat-ai-show-predictions")
                        .tint(BeatAIStyle.blue)
                        .accessibilityHint("Shows or hides prediction scores in the match list")
                    Text("See the AI’s picks in your fixtures.")
                        .font(.footnote)
                        .foregroundStyle(BeatAIStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Toggle(isOn: predictionsVisibility) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(BeatAIStyle.gold)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show AI score predictions")
                            .font(.subheadline.weight(.bold))
                        Text("See the AI’s picks in your fixtures.")
                            .font(.caption)
                            .foregroundStyle(BeatAIStyle.muted)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                }
                .tint(BeatAIStyle.blue)
                .accessibilityLabel("Show AI predictions")
                .accessibilityIdentifier("beat-ai-show-predictions")
                .accessibilityHint("Shows or hides prediction scores in the match list")
            }
        }
    }

    private var latestResult: PredictionGameRecentGameweek? {
        game.latestResult
    }

    private func latestResultCard(_ result: PredictionGameRecentGameweek) -> some View {
        let outcome = result.headToHeadOutcome
        let presentation = BeatAILatestResultPresentation(outcome: outcome)
        return BeatAIPanel(accent: presentation.color) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Latest result", systemImage: "flag.checkered")
                        .font(.subheadline.weight(.bold))
                    Spacer(minLength: 12)
                    Text("\(result.resolvedCompetitionName) · \(result.label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BeatAIStyle.muted)
                        .multilineTextAlignment(.trailing)
                }

                latestResultScoreboard(result, presentation: presentation)

                Text(latestResultMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.color)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(result.played) \(result.played == 1 ? "match" : "matches") scored in this round")
                    .font(.caption)
                    .foregroundStyle(BeatAIStyle.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Latest result, \(result.label). \(presentation.title). You \(result.youPoints) points. AI \(result.aiPoints) points. \(latestResultMessage)")
        }
        .accessibilityIdentifier("beat-ai-latest-result")
    }

    private func latestResultScore(title: String, points: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(BeatAIStyle.muted)
            Text(points.formatted())
                .font(.system(.title, design: .rounded, weight: .black))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(points == 1 ? "point" : "points")
                .font(.caption2)
                .foregroundStyle(BeatAIStyle.muted)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func latestResultScoreboard(
        _ result: PredictionGameRecentGameweek,
        presentation: BeatAILatestResultPresentation
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    latestResultScore(title: "YOU", points: result.youPoints, color: presentation.color)
                    latestResultScore(title: "AI", points: result.aiPoints, color: BeatAIStyle.purple)
                }
                latestResultOutcome(presentation)
            }
        } else {
            HStack(spacing: 20) {
                latestResultScore(title: "YOU", points: result.youPoints, color: presentation.color)
                latestResultOutcome(presentation)
                    .frame(maxWidth: .infinity)
                latestResultScore(title: "AI", points: result.aiPoints, color: BeatAIStyle.purple)
            }
        }
    }

    private func latestResultOutcome(_ presentation: BeatAILatestResultPresentation) -> some View {
        VStack(spacing: 5) {
            Image(systemName: presentation.symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(presentation.color)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
        }
    }

    private func present(_ result: PredictionGameRecentGameweek?) {
        guard let result else {
            latestResultMessage = ""
            showsFireworks = false
            return
        }
        latestResultMessage = BeatAILatestResultCopy.random(for: result.headToHeadOutcome)
        guard result.headToHeadOutcome == .userWin,
              celebratedRoundID != result.id, !reduceMotion, !dimFlashingLights else { return }
        celebratedRoundID = result.id
        fireworksID = UUID()
        withAnimation(.easeOut(duration: 0.2)) { showsFireworks = true }
    }

    private var predictionCallToAction: some View {
        Button(action: onStartPredictions) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if isStarting { ProgressView().tint(.white) }
                    else { Image(systemName: "square.and.pencil").accessibilityHidden(true) }
                    Text(isStarting ? "Opening your predictions…" : "Make your predictions")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .accessibilityHidden(true)
                }
                if let predictionSet {
                    Text([predictionSet.gameweekLabel, "\(fixtures.count) matches"].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    if let deadline = fixtures.filter({ game.canEdit(fixture: $0) }).map(\.kickoffAt).min() {
                        Text("Next pick locks \(deadline.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text("Each pick locks at its match’s kick-off.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                } else {
                    Text("Your next \(game.selectedCompetition.name) matches await.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(BeatAIPrimaryButtonStyle())
        .disabled(isStarting)
        .accessibilityIdentifier("beat-ai-start")
    }

    private var benefits: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), alignment: .top), count: 3)
        return LazyVGrid(columns: columns, spacing: 14) {
            benefit("Predict scores", symbol: "soccerball", color: BeatAIStyle.blue)
            benefit("Take on the AI", symbol: "sparkles", color: BeatAIStyle.purple)
            benefit("Earn your crown", symbol: "trophy.fill", color: BeatAIStyle.gold)
        }
        .padding(.vertical, 4)
    }

    private func benefit(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressCard: some View {
        Button(action: onProgress) {
            BeatAIPanel(accent: BeatAIStyle.gold) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(BeatAIStyle.gold)
                            .font(.title3)
                            .accessibilityHidden(true)
                        Text("Your progress")
                            .font(.title3.weight(.bold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(BeatAIStyle.muted)
                            .accessibilityHidden(true)
                    }
                    if !game.achievements.isEmpty {
                        let unlockedCount = game.achievements.filter(\.unlocked).count
                        HStack {
                            Text("\(unlockedCount) of \(game.achievements.count) achievements unlocked")
                            Spacer(minLength: 8)
                            Image(systemName: "trophy.fill")
                                .foregroundStyle(BeatAIStyle.gold)
                                .accessibilityHidden(true)
                        }
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        ProgressView(value: Double(unlockedCount), total: Double(game.achievements.count))
                            .tint(BeatAIStyle.gold)
                            .accessibilityHidden(true)
                    } else {
                        Text("Your achievement progress appears when your record loads.")
                            .font(.subheadline)
                            .foregroundStyle(BeatAIStyle.muted)
                    }
                    Text("Your record, achievements and leaderboards")
                        .font(.caption)
                        .foregroundStyle(BeatAIStyle.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier("beat-ai-progress")
    }

    private var leaguesCard: some View {
        Button(action: onMyLeagues) {
            BeatAIPanel(accent: BeatAIStyle.green) {
                HStack(spacing: 14) {
                    Image(systemName: "flag.checkered.2.crossed")
                        .font(.title2)
                        .foregroundStyle(BeatAIStyle.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("My Leagues").font(.title3.weight(.bold))
                        Text("Your people. Your table. Your bragging rights.")
                            .font(.caption)
                            .foregroundStyle(BeatAIStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BeatAIStyle.muted)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityIdentifier("beat-ai-my-leagues")
    }

    private var fixtures: [PredictionGameFixture] {
        predictionSet?.fixtures.map { game.fixture(for: $0.id) ?? $0 } ?? []
    }

    private var predictionsVisibility: Binding<Bool> {
        Binding(
            get: { preferences.showPredictedScores },
            set: { visible in
                guard visible != preferences.showPredictedScores else { return }
                preferences.showPredictedScores = visible
                onPredictionsVisibilityChanged()
            }
        )
    }
}

struct BeatAILatestResultPresentation {
    let title: String
    let symbol: String
    let color: Color

    init(outcome: PredictionGameRoundOutcome) {
        switch outcome {
        case .userWin:
            title = "You won"
            symbol = "trophy.fill"
            color = BeatAIStyle.green
        case .draw:
            title = "Round drawn"
            symbol = "equal.circle.fill"
            color = BeatAIStyle.gold
        case .aiWin:
            title = "AI won"
            symbol = "cpu.fill"
            color = BeatAIStyle.red
        }
    }
}

enum BeatAILatestResultCopy {
    static let wins = [
        "Humanity clings on this time…",
        "The machines have requested a recount.",
        "A tidy little win for carbon-based life.",
        "The algorithm has gone suspiciously quiet.",
        "Human instinct: still annoyingly effective."
    ]

    static let draws = [
        "Honours even. Nobody updates their résumé.",
        "A diplomatic result between brain and processor.",
        "Dead level. Rivetingly inconclusive.",
        "Neither side will be mentioning this one at dinner.",
        "Humanity and machinery agree to call it a day."
    ]

    static let losses = [
        "An easy win for our new robotic overlords.",
        "The algorithm sends its warmest regards.",
        "Human intuition has left the chat.",
        "Still, at least the AI can’t enjoy it.",
        "A difficult round for organic intelligence."
    ]

    static func messages(for outcome: PredictionGameRoundOutcome) -> [String] {
        switch outcome {
        case .userWin: wins
        case .draw: draws
        case .aiWin: losses
        }
    }

    static func random(for outcome: PredictionGameRoundOutcome) -> String {
        messages(for: outcome).randomElement() ?? "The points are in."
    }
}

private struct PredictionGameFireworks: View {
    private struct Particle {
        let origin: CGPoint
        let delay: TimeInterval
        let duration: TimeInterval
        let angle: Double
        let distance: CGFloat
        let size: CGFloat
        let colorIndex: Int
    }

    private struct SeededRandom {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func unit() -> Double {
            Double(next() >> 11) / 9_007_199_254_740_992.0
        }
    }

    @State private var startedAt = Date.now
    private let particles: [Particle]

    init(trigger: UUID) {
        particles = Self.makeParticles(trigger: trigger)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let scale = min(size.width, size.height)
                let colors = [BeatAIStyle.gold, BeatAIStyle.green, BeatAIStyle.blue, BeatAIStyle.purple, .white]

                for particle in particles {
                    let progress = (elapsed - particle.delay) / particle.duration
                    guard progress >= 0, progress <= 1 else { continue }
                    let eased = 1 - pow(1 - progress, 2)
                    let distance = particle.distance * scale * eased
                    let gravity = scale * 0.055 * progress * progress
                    let point = CGPoint(
                        x: particle.origin.x * size.width + CGFloat(cos(particle.angle)) * distance,
                        y: particle.origin.y * size.height + CGFloat(sin(particle.angle)) * distance + gravity
                    )
                    let tailDistance = max(0, distance - scale * 0.025)
                    let tail = CGPoint(
                        x: particle.origin.x * size.width + CGFloat(cos(particle.angle)) * tailDistance,
                        y: particle.origin.y * size.height + CGFloat(sin(particle.angle)) * tailDistance + gravity
                    )
                    let opacity = max(0, 1 - progress) * min(1, progress * 8)
                    let color = colors[particle.colorIndex % colors.count]
                    var path = Path()
                    path.move(to: tail)
                    path.addLine(to: point)
                    context.stroke(path, with: .color(color.opacity(opacity * 0.65)), lineWidth: particle.size * 0.7)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - particle.size / 2, y: point.y - particle.size / 2,
                            width: particle.size, height: particle.size
                        )),
                        with: .color(color.opacity(opacity))
                    )
                }
            }
        }
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func makeParticles(trigger: UUID) -> [Particle] {
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in trigger.uuidString.utf8 {
            seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        var random = SeededRandom(seed: seed)
        var particles: [Particle] = []
        for burst in 0..<4 {
            let origin = CGPoint(
                x: CGFloat(0.12 + random.unit() * 0.76),
                y: CGFloat(0.08 + random.unit() * 0.48)
            )
            let delay = Double(burst) * 0.38 + random.unit() * 0.12
            let color = Int(random.next() % 5)
            for index in 0..<14 {
                particles.append(Particle(
                    origin: origin,
                    delay: delay,
                    duration: 0.8 + random.unit() * 0.45,
                    angle: (Double(index) / 14.0) * .pi * 2 + random.unit() * 0.12,
                    distance: CGFloat(0.09 + random.unit() * 0.10),
                    size: CGFloat(2.2 + random.unit() * 2.2),
                    colorIndex: (color + index / 5) % 5
                ))
            }
        }
        return particles
    }
}

/// The selected competition scopes the gameweek, record and friends' tables together.
struct PredictionGameCompetitionPicker: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var isSelecting = false
    var onSelection: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(game.availableCompetitions) { competition in
                Button {
                    guard competition.id != game.selectedCompetitionID else { return }
                    onSelection()
                    isSelecting = true
                    Task {
                        await game.selectCompetition(competition.id, apiBaseURL: preferences.apiBaseURL)
                        isSelecting = false
                    }
                } label: {
                    if competition.id == game.selectedCompetitionID {
                        Label(competition.name, systemImage: "checkmark")
                    } else {
                        Text(competition.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "soccerball").accessibilityHidden(true)
                Text(game.selectedCompetition.name)
                    .font(.subheadline.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isSelecting { ProgressView().tint(BeatAIStyle.gold) }
                else { Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold)) }
            }
            .foregroundStyle(BeatAIStyle.gold)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .padding(.vertical, 4)
            .background(BeatAIStyle.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(BeatAIStyle.gold.opacity(0.25)) }
        }
        .disabled(isSelecting || game.isSaving)
        .accessibilityLabel("Competition")
        .accessibilityValue(game.selectedCompetition.name)
        .accessibilityHint("Choose which competition to predict and compare with friends")
        .accessibilityIdentifier("beat-ai-competition")
    }
}
