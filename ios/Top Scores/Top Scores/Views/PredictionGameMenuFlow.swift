import SwiftUI

/// One game presentation owns navigation and Game Center, including its system sign-in sheet.
struct PredictionGameMenuFlow: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    let onPredictionsVisibilityChanged: () -> Void
    var invitationCode: String? = nil

    @ObservedObject private var invitationRouter = PredictionLeagueInvitationRouter.shared
    @State private var path: [Destination] = []
    @State private var predictionSet: PredictionGamePredictionSet?
    @State private var showsRules = false
    @State private var refreshID = UUID()
    @State private var metadataTask: Task<Void, Never>?

    private enum Destination: Hashable { case predictions, progress; case leagues(String?) }

    var body: some View {
        NavigationStack(path: $path) {
            PredictionGameMenuView(
                onStartPredictions: { path.append(.predictions) },
                onProgress: { path.append(.progress) },
                onPredictionsVisibilityChanged: onPredictionsVisibilityChanged,
                predictionSet: predictionSet,
                onMyLeagues: { path.append(.leagues(nil)) }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("beat-ai-close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("How to play", systemImage: "gearshape") { showsRules = true }
                        .labelStyle(.iconOnly)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .predictions:
                    PredictionGameWeekView(
                        predictionSet: predictionSet,
                        onPredictionsVisibilityChanged: onPredictionsVisibilityChanged
                    )
                case .progress:
                    PredictionGameProgressView()
                case .leagues(let code):
                    PredictionMiniLeaguesView(initialInvitationCode: code)
                }
            }
        }
        .tint(.white)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(game.isSaving)
        .sheet(isPresented: $showsRules) { rules }
        .task(id: preferences.apiBaseURL) {
            path = invitationCode.map { [.leagues($0)] } ?? []
            openPendingInvitation()
            predictionSet = nil
            await game.gameScreenDidAppear(apiBaseURL: preferences.apiBaseURL)
            refreshMetadata()
            await game.loadDashboard(apiBaseURL: preferences.apiBaseURL)
        }
        .onChange(of: invitationRouter.pendingInvitation) { _, _ in openPendingInvitation() }
        .onChange(of: invitationCode) { _, code in
            if let code { path = [.leagues(code)] }
        }
        .onChange(of: game.playerScopeID) { _, _ in
            predictionSet = nil
            refreshMetadata()
        }
        .onChange(of: game.selectedCompetitionID) { _, _ in
            predictionSet = nil
            refreshMetadata()
        }
        .onChange(of: path) { _, updated in
            if updated.isEmpty { refreshMetadata() }
        }
        .onDisappear {
            metadataTask?.cancel()
            refreshID = UUID()
            game.gameScreenDidDisappear()
        }
    }

    private func openPendingInvitation() {
        guard let invitation = invitationRouter.pendingInvitation else { return }
        path = [.leagues(invitation.code)]
        invitationRouter.pendingInvitation = nil
    }

    private func refreshMetadata() {
        metadataTask?.cancel()
        let id = UUID()
        refreshID = id
        let baseURL = preferences.apiBaseURL
        let competitionID = game.selectedCompetitionID
        metadataTask = Task {
            let loaded = await game.loadPredictionSet(apiBaseURL: baseURL, reportErrors: false, includeLocked: true)
            guard !Task.isCancelled, refreshID == id, baseURL == preferences.apiBaseURL,
                  competitionID == game.selectedCompetitionID else { return }
            predictionSet = loaded
        }
    }

    private var rules: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Football instincts.\nBragging rights.")
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text("Pick any match with an AI score and take on the AI, one competition at a time.")
                        .foregroundStyle(.secondary)
                    VStack(spacing: 18) {
                        rule("Exact score", points: "3", icon: "scope")
                        rule("Correct win, draw or loss", points: "1", icon: "checkmark.circle")
                        rule("Incorrect result", points: "0", icon: "minus.circle")
                    }
                    Text("You and the AI play by the same rules. The AI’s score is fixed when you first save your prediction. Each match locks at its own kick-off.")
                    Text("Scores include extra time, if played, but exclude penalty shoot-out goals. If the match goes to penalties, an exact score earns 3 only with the correct shoot-out winner. A correct winner with a different score earns 1; a wrong winner earns 0.")
                        .foregroundStyle(.secondary)
                    Text("Your record and friends’ leaderboards stay separate for each competition. Playing extra competitions never changes your standing in another. A win against the AI means earning more points on the same match; equal points are a draw.")
                        .foregroundStyle(.secondary)
                    Label("Game Center connects automatically here. You can keep playing as a guest if sign-in is unavailable.", systemImage: "person.2.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(BeatAIBackground())
            .navigationTitle("How to play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsRules = false } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func rule(_ title: String, points: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.yellow).frame(width: 28)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(points).font(.system(.title, design: .rounded, weight: .bold))
        }
        .accessibilityElement(children: .combine)
    }
}
