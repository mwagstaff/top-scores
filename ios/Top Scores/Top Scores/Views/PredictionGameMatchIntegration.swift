import SwiftUI

private struct PredictionGameStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: PredictionGameStore? = nil
}

private struct PredictionGameReturnToFixturesKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var returnFromPredictionGameToFixtures: () -> Void {
        get { self[PredictionGameReturnToFixturesKey.self] }
        set { self[PredictionGameReturnToFixturesKey.self] = newValue }
    }

    var predictionGameStore: PredictionGameStore? {
        get { self[PredictionGameStoreEnvironmentKey.self] }
        set { self[PredictionGameStoreEnvironmentKey.self] = newValue }
    }
}

extension Match {
    nonisolated var predictionGameFixtureID: String? {
        guard let matchDetailsID else { return nil }
        return PredictionGameFixtureID.normalized(matchDetailsID)
    }

    nonisolated var predictionGameKickoff: Date? {
        if let kickoffAt {
            if let date = try? Date(kickoffAt, strategy: .iso8601) { return date }
            if let date = try? Date(kickoffAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        }
        return dateTime
    }

    /// Before activation, use the existing fixture without creating a game account.
    nonisolated func canOfferPredictionGame(at date: Date) -> Bool {
        let status = scoreStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return predictionGameFixtureID != nil && homeScore == nil && awayScore == nil
            && ["", "ns", "notstarted", "not_started", "scheduled"].contains(status)
            && predictionGameKickoff.map { $0 > date } == true
    }
}

/// Keeps optional game observations and requests outside the fixture list's rendering state.
struct PredictionGameFixtureHydration: View {
    @ObservedObject var store: PredictionGameStore
    let fixtureIDs: [String]
    let apiBaseURL: String
    var isActive = true

    private struct Request: Hashable {
        let enabled: Bool
        let active: Bool
        let fixtureIDs: [String]
        let baseURL: String
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: Request(enabled: store.enabled, active: isActive, fixtureIDs: fixtureIDs, baseURL: apiBaseURL)) {
                guard store.enabled, isActive, !fixtureIDs.isEmpty else { return }
                await store.loadEntries(fixtureIDs: fixtureIDs, apiBaseURL: apiBaseURL)
            }
    }
}

/// Observe availability only around the accessories, keeping score-list rendering independent.
struct PredictionGameMatchAvailability<Content: View>: View {
    @Environment(\.predictionGameStore) private var store
    let match: Match
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if let store, let fixtureID = match.predictionGameFixtureID {
            PredictionGameObservedAvailability(store: store, fixtureID: fixtureID, content: content)
        } else {
            content(false)
        }
    }
}

private struct PredictionGameObservedAvailability<Content: View>: View {
    @ObservedObject var store: PredictionGameStore
    let fixtureID: String
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(store.enabled && store.fixture(for: fixtureID)?.ai != nil)
    }
}

/// Adds a clear invitation only to fixtures that can accept a prediction.
struct PredictionGameMatchControl<Fallback: View>: View {
    @Environment(\.predictionGameStore) private var store
    let match: Match
    var isLargePresentation = false
    var previewScore: PredictionGameScore? = nil
    var fillsAvailableWidth = false
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if let store, let fixtureID = match.predictionGameFixtureID {
            PredictionGameMatchButton(
                store: store,
                match: match,
                fixtureID: fixtureID,
                isLargePresentation: isLargePresentation,
                previewScore: previewScore,
                fillsAvailableWidth: fillsAvailableWidth,
                fallback: fallback
            )
        } else {
            fallback()
        }
    }
}

private struct PredictionGameMatchButton<Fallback: View>: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @ObservedObject var store: PredictionGameStore
    let match: Match
    let fixtureID: String
    let isLargePresentation: Bool
    let previewScore: PredictionGameScore?
    let fillsAvailableWidth: Bool
    @ViewBuilder let fallback: () -> Fallback
    @State private var isEditing = false

    private var fixture: PredictionGameFixture? { store.fixture(for: fixtureID) }

    private var deadline: Date? {
        guard store.enabled, let fixture else { return match.predictionGameKickoff }
        let now = Date()
        return fixture.kickoffAt.addingTimeInterval(now.timeIntervalSince(store.serverNow(relativeTo: now)))
    }

    var body: some View {
        // Update at kick-off without a repeating timer on every fixture row.
        PredictionGameDeadlineView(deadline: deadline) { date in
            if (store.enabled && (fixture?.ai != nil || previewScore != nil))
                || (previewScore != nil && match.canOfferPredictionGame(at: date)) {
                predictionButton(at: date)
            } else {
                fallback()
            }
        }
    }

    private func pillState(at date: Date) -> PredictionGamePillState {
        guard store.enabled else { return .makePick }
        guard let fixture else { return .checking }
        switch fixture.predictionAvailability(at: store.serverNow(relativeTo: date)) {
        case .editable:
            return fixture.prediction == nil ? .makePick : .editPick
        case .locked:
            switch fixture.completedPredictionHighlight {
            case .exactScore: return .exactScore
            case .userWin: return .userWin
            case .aiWin: return .aiWin
            case nil: return .locked
            }
        case .void, .awaitingAI:
            return .unavailable
        }
    }

    @ViewBuilder
    private func predictionButton(at date: Date) -> some View {
        let state = pillState(at: date)
        if match.isFinished {
            predictionLabel(state: state, showsDisclosureIndicator: false)
        } else {
            Button {
                isEditing = true
            } label: {
                predictionLabel(state: state, showsDisclosureIndicator: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("prediction-game-\(fixtureID)")
            .accessibilityLabel(accessibilityLabel(state: state))
            .accessibilityHint(state.accessibilityHint)
            .sheet(isPresented: $isEditing) {
                PredictionGameEditor(fixtureID: fixtureID)
                    .environmentObject(store)
                    .environmentObject(preferences)
            }
        }
    }

    private func predictionLabel(
        state: PredictionGamePillState,
        showsDisclosureIndicator: Bool
    ) -> some View {
        PredictionGamePillLabel(
            aiText: store.enabled ? (fixture?.ai?.displayText ?? previewScore?.displayText) : previewScore?.displayText,
            userText: store.enabled ? fixture?.prediction?.displayText : nil,
            state: state,
            isLargePresentation: isLargePresentation,
            scoreTitle: store.enabled ? "AI" : isLargePresentation ? nil : "Predicted",
            fillsAvailableWidth: fillsAvailableWidth,
            showsDisclosureIndicator: showsDisclosureIndicator
        )
        .padding(.vertical, isLargePresentation ? 0 : 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .padding(.vertical, isLargePresentation ? 0 : -8)
        .accessibilityIdentifier("prediction-game-\(fixtureID)")
        .accessibilityLabel(accessibilityLabel(state: state))
        .accessibilityHint(match.isFinished ? "View match details" : state.accessibilityHint)
    }

    private func accessibilityLabel(state: PredictionGamePillState) -> String {
        var label = "\(match.homeTeam) versus \(match.awayTeam)"
        if store.enabled, let fixture {
            if let ai = fixture.ai { label += ", AI predicts \(ai.homeScore) to \(ai.awayScore)" }
            if let prediction = fixture.prediction {
                label += ", you predict \(prediction.homeScore) to \(prediction.awayScore)"
            }
        } else if let previewScore {
            label += ", predicted score \(previewScore.homeScore) to \(previewScore.awayScore)"
        }
        return label + ", " + state.accessibilityDescription
    }
}

struct PredictionGameDeadlineView<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentDate = Date()
    let deadline: Date?
    @ViewBuilder let content: (Date) -> Content

    private struct Refresh: Hashable {
        let deadline: Date?
        let isActive: Bool
    }

    var body: some View {
        content(currentDate)
            .task(id: Refresh(deadline: deadline, isActive: scenePhase == .active)) {
                currentDate = Date()
                guard let deadline else { return }
                // Explicit timelines can render a future entry immediately.
                // Wait for the real deadline instead, then update from wall time.
                // Cancellation handles scrolling away or a changed kickoff;
                // foregrounding also refreshes after a device-clock change.
                do {
                    while true {
                        let remaining = deadline.timeIntervalSinceNow
                        guard remaining > 0 else { break }
                        try await Task.sleep(for: .seconds(remaining))
                        try Task.checkCancellation()
                    }
                    currentDate = Date()
                } catch {
                    // The view left the screen or its deadline changed.
                }
            }
    }
}

private enum PredictionGamePillState {
    case makePick, editPick, locked, exactScore, userWin, aiWin, unavailable, checking

    var isEditable: Bool { self == .makePick || self == .editPick }
    var accessibilityDescription: String {
        switch self {
        case .makePick: "add your prediction"
        case .editPick: "edit your prediction"
        case .locked: "predictions locked"
        case .exactScore: "exact score, you earned 3 points"
        case .userWin: "you beat the AI"
        case .aiWin: "the AI beat you"
        case .unavailable: "predictions unavailable"
        case .checking: "prediction eligibility has not been checked"
        }
    }
    var accessibilityHint: String {
        switch self {
        case .makePick: "Opens Beat the AI to enter your score before kick-off"
        case .editPick: "Change your score before kick-off"
        case .locked, .exactScore, .userWin, .aiWin: "Opens the match comparison; predictions can no longer be changed"
        case .unavailable, .checking: "Opens the prediction details and checks availability"
        }
    }
}

private struct PredictionGamePillLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let aiText: String?
    let userText: String?
    let state: PredictionGamePillState
    var isLargePresentation = false
    var scoreTitle: String? = "AI"
    var fillsAvailableWidth = false
    var showsDisclosureIndicator = true

    private var accent: Color {
        switch state {
        case .makePick: .accentColor
        case .editPick: .predictedScore
        case .exactScore: BeatAIStyle.gold
        case .userWin: BeatAIStyle.green
        case .aiWin: BeatAIStyle.red
        case .locked, .unavailable, .checking: .secondary
        }
    }

    private var isCompletedHighlight: Bool {
        switch state {
        case .exactScore, .userWin, .aiWin: true
        default: false
        }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize && !isLargePresentation {
                VStack(alignment: .leading, spacing: 4) {
                    if let aiText {
                        Text(scoreTitle.map { "\($0): \(aiText)" } ?? aiText)
                        if let userText {
                            Text("You: \(userText)")
                                .foregroundStyle(Color.primary)
                        }
                    }
                    interactionLabel(shortPrompt: false)
                }
            } else if isLargePresentation {
                HStack(spacing: 12) {
                    scoreLabels()
                }
            } else if fillsAvailableWidth {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { scoreLabels() }
                        .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 6) { scoreLabels(shortPrompt: true) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(spacing: 4) { scoreLabels(shortPrompt: true) }
                }
            } else {
                HStack(spacing: 6) {
                    scoreLabels()
                }
            }
        }
        .font(isLargePresentation ? .headline : .caption2.weight(.semibold))
        .lineLimit(dynamicTypeSize.isAccessibilitySize && !isLargePresentation ? nil : 1)
        .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize && !isLargePresentation ? 1 : 0.8)
        .monospacedDigit()
        .foregroundStyle(accent)
        .padding(.horizontal, fillsAvailableWidth ? 8 : 10)
        .padding(.vertical, 6)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, minHeight: fillsAvailableWidth ? 28 : nil)
        .background(accent.opacity(state == .makePick ? 0.22 : isCompletedHighlight ? 0.18 : state.isEditable ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(state == .makePick ? 0.8 : isCompletedHighlight ? 0.72 : state.isEditable ? 0.45 : 0.18), lineWidth: state == .makePick || isCompletedHighlight ? 1.5 : 1)
        }
    }

    @ViewBuilder
    private func scoreLabels(shortPrompt: Bool = false) -> some View {
        if let aiText {
            Text(scoreTitle.map { "\($0): \(aiText)" } ?? aiText)
        }
        HStack(spacing: 6) {
            if aiText != nil, let userText {
                Text("You: \(userText)")
                    .foregroundStyle(Color.primary)
            }
            interactionLabel(shortPrompt: shortPrompt)
        }
    }

    private func interactionLabel(shortPrompt: Bool) -> some View {
        HStack(spacing: 5) {
            switch state {
            case .makePick:
                Text(shortPrompt ? "Predict" : "Make your pick")
                disclosureIndicator
            case .editPick:
                Image(systemName: "pencil")
                disclosureIndicator
            case .locked:
                disclosureIndicator
            case .exactScore:
                Image(systemName: "scope")
                disclosureIndicator
            case .userWin:
                Image(systemName: "checkmark.circle.fill")
                disclosureIndicator
            case .aiWin:
                Image(systemName: "xmark.circle.fill")
                disclosureIndicator
            case .unavailable:
                Label("Unavailable", systemImage: "minus.circle")
            case .checking:
                Label("Check prediction", systemImage: "arrow.clockwise")
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var disclosureIndicator: some View {
        if showsDisclosureIndicator {
            Image(systemName: "chevron.right").imageScale(.small)
        }
    }
}

#Preview("Prediction pill states") {
    VStack(alignment: .leading, spacing: 20) {
        PredictionGamePillLabel(aiText: "0–2", userText: nil, state: .makePick)
        PredictionGamePillLabel(aiText: "0–2", userText: "1–3", state: .editPick)
        PredictionGamePillLabel(aiText: "0–2", userText: nil, state: .locked)
        PredictionGamePillLabel(aiText: "0–2", userText: "1–3", state: .locked)
        PredictionGamePillLabel(aiText: "1–1", userText: "2–0", state: .exactScore)
        PredictionGamePillLabel(aiText: "1–1", userText: "2–1", state: .userWin)
        PredictionGamePillLabel(aiText: "2–1", userText: "0–0", state: .aiWin)
        PredictionGamePillLabel(aiText: nil, userText: nil, state: .unavailable)
        PredictionGamePillLabel(aiText: nil, userText: nil, state: .checking)
    }
    .padding(24)
}
