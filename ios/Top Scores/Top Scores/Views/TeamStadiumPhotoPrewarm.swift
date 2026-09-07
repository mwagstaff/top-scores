import SwiftUI

private struct TeamStadiumPhotoPrewarmModifier: ViewModifier {
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

    func body(content: Content) -> some View {
        content.task(id: taskID) {
            await TeamLinkStadiumPhotoPrewarmer.shared.prewarm(
                context: context,
                candidateMatches: candidateMatches,
                apiBaseURL: apiBaseURL
            )
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
