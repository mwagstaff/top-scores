import SwiftUI

private struct TeamStadiumPhotoPrewarmingEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var teamStadiumPhotoPrewarmingEnabled: Bool {
        get { self[TeamStadiumPhotoPrewarmingEnabledKey.self] }
        set { self[TeamStadiumPhotoPrewarmingEnabledKey.self] = newValue }
    }
}

private struct TeamStadiumPhotoPrewarmModifier: ViewModifier {
    @Environment(\.teamStadiumPhotoPrewarmingEnabled) private var isPrewarmingEnabled

    let context: TeamDetailsContext
    let candidateMatches: [Match]
    let apiBaseURL: String

    private var taskID: String {
        let matchKeys = candidateMatches.prefix(4).map {
            $0.matchDetailsID ?? $0.id
        }
        return [
            apiBaseURL,
            context.id,
            matchKeys.joined(separator: ",")
        ].joined(separator: "|")
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrewarmingEnabled {
            content.task(id: taskID, priority: .utility) {
                await TeamLinkStadiumPhotoPrewarmer.shared.prewarm(
                    context: context,
                    candidateMatches: candidateMatches,
                    apiBaseURL: apiBaseURL
                )
            }
        } else {
            content
        }
    }
}

private struct EnvironmentTeamStadiumPhotoPrewarmModifier: ViewModifier {
    @EnvironmentObject private var preferences: PreferencesStore

    let context: TeamDetailsContext
    let candidateMatches: [Match]

    func body(content: Content) -> some View {
        content.prewarmTeamStadiumPhoto(
            for: context,
            candidateMatches: candidateMatches,
            apiBaseURL: preferences.apiBaseURL
        )
    }
}

extension View {
    func prewarmTeamStadiumPhoto(
        for context: TeamDetailsContext,
        candidateMatches: [Match] = [],
        apiBaseURL: String
    ) -> some View {
        modifier(
            TeamStadiumPhotoPrewarmModifier(
                context: context,
                candidateMatches: candidateMatches,
                apiBaseURL: apiBaseURL
            )
        )
    }

    func prewarmTeamStadiumPhotoFromEnvironment(
        for context: TeamDetailsContext,
        candidateMatches: [Match] = []
    ) -> some View {
        modifier(
            EnvironmentTeamStadiumPhotoPrewarmModifier(
                context: context,
                candidateMatches: candidateMatches
            )
        )
    }
}
