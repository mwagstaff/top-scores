import SwiftUI

struct PredictionMiniLeagueSettingsView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    let detail: PredictionMiniLeagueDetailResponse
    @ObservedObject var leagues: PredictionMiniLeagueStore
    var onMembershipEnded: () -> Void = {}
    @State private var newInvitation: PredictionMiniLeagueInvitation?
    @State private var confirmation: LeagueAction?
    @State private var showsConfirmation = false
    @State private var name = ""
    @State private var showAI = true
    @State private var settingsSaved = false

    private var current: PredictionMiniLeagueDetailResponse {
        leagues.detail?.league.id == detail.league.id ? leagues.detail! : detail
    }
    private var league: PredictionMiniLeague { current.league }
    private var isOpen: Bool { league.status != "closed" }
    private enum LeagueAction {
        case remove(PredictionMiniLeagueMember), reinstate(PredictionMiniLeagueMember), transfer(PredictionMiniLeagueMember)
        case revoke(PredictionMiniLeagueInvitationRecord), close, leave
        var title: String {
            switch self {
            case .remove(let member): "Remove \(member.displayName)?"
            case .reinstate(let member): "Allow \(member.displayName) to rejoin?"
            case .transfer(let member): "Make \(member.displayName) the owner?"
            case .revoke: "Revoke this invitation?"
            case .close: "Close this league?"
            case .leave: "Leave this league?"
            }
        }
        var button: String {
            switch self {
            case .remove: "Remove member"
            case .reinstate: "Allow rejoining"
            case .transfer: "Transfer ownership"
            case .revoke: "Revoke invitation"
            case .close: "Close league"
            case .leave: "Leave league"
            }
        }
        var message: String {
            switch self {
            case .remove: "They’ll lose access immediately. Earlier locked predictions stay in the results. Existing invitation links won’t let them back in."
            case .reinstate: "They can join again with a new valid invitation. Their scoring starts from the next full round."
            case .transfer: "They’ll control invitations and membership. You’ll stay in the league as a member."
            case .revoke: "This link and code will stop working immediately. Existing members keep their places."
            case .close: "No new predictions will count. Existing results stay available, and invitations stop working."
            case .leave: "You’ll lose access. Earlier locked predictions stay in the results. You can only rejoin while the league is open, starting from the next full round."
            }
        }
        var isDestructive: Bool {
            switch self { case .remove, .revoke, .close, .leave: true; case .reinstate, .transfer: false }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    MiniLeagueBadge(size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(league.name).font(.title2.weight(.bold))
                        Text(league.isOwner ? "You’re the league owner" : "Your private league")
                            .font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                    }
                }
                if let error = leagues.errorMessage { MiniLeagueInlineError(message: error) }
                if league.isOwner && isOpen {
                    invitations
                    settings
                }
                members
                if isOpen {
                    if league.isOwner {
                        Text("To leave, transfer ownership to another active member first, or close the league.")
                            .font(.footnote).foregroundStyle(BeatAIStyle.muted)
                        Button("Close league", role: .destructive) { confirm(.close) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("mini-league-close")
                    } else {
                        Button("Leave league", role: .destructive) { confirm(.leave) }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("mini-league-leave")
                    }
                } else {
                    Button("Leave closed league", role: .destructive) { confirm(.leave) }
                        .frame(minHeight: 44)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .disabled(leagues.isWorking)
        }
        .miniLeagueScreen(title: "League options")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(leagues.isWorking) }
        }
        .interactiveDismissDisabled(leagues.isWorking)
        .overlay { if leagues.isWorking { ProgressView().padding(20).background(BeatAIStyle.background, in: Capsule()) } }
        .task {
            name = league.name
            showAI = league.showAI
            if league.isOwner && isOpen { await leagues.loadInvitations(leagueID: league.id, game: game, apiBaseURL: preferences.apiBaseURL) }
        }
        .onChange(of: game.privateLeagueScopeID) { _, _ in
            newInvitation = nil
            dismiss()
        }
        .confirmationDialog(confirmation?.title ?? "League options", isPresented: $showsConfirmation, titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation.button, role: confirmation.isDestructive ? .destructive : nil) { Task { await perform(confirmation) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmation?.message ?? "") }
    }

    private var invitations: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Invite your next rival", systemImage: "ticket.fill")
                .font(.title3.weight(.bold)).foregroundStyle(BeatAIStyle.gold)
            Text("Anyone with a valid invitation can join. Each code lasts 7 days. Creating a replacement immediately revokes the previous link and code.")
                .font(.footnote).foregroundStyle(BeatAIStyle.muted)
            if let invitation = newInvitation, invitation.expiresAt > game.serverNow(), !leagues.invitations.contains(where: { $0.id == invitation.id && $0.revokedAt != nil }) {
                BeatAIPanel(accent: BeatAIStyle.green) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(invitation.code)
                            .font(.system(.title3, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Invitation code, \(invitation.code)")
                        Text("Valid until \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(BeatAIStyle.muted)
                        ShareLink(item: invitation.url, subject: Text("Join \(league.name) on Top Scores"), message: Text("Our private \(league.competitionName) prediction league. Invitation code: \(invitation.code)")) {
                            Label("Share invitation", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(BeatAIPrimaryButtonStyle())
                        .accessibilityIdentifier("mini-league-share-invitation")
                    }
                }
            }
            Button {
                Task { newInvitation = await leagues.createInvitation(leagueID: league.id, game: game, apiBaseURL: preferences.apiBaseURL) }
            } label: {
                Label(newInvitation == nil ? "Create invitation" : "Replace invitation", systemImage: "plus.circle")
                    .font(.headline).frame(minHeight: 44)
            }
            .accessibilityIdentifier("mini-league-new-invitation")
            if !leagues.invitations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Invitation history").font(.subheadline.weight(.bold))
                    ForEach(leagues.invitations) { invitation in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Created \(invitation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption.weight(.medium))
                                Text(invitation.revokedAt != nil ? "Revoked" : invitation.expiresAt <= game.serverNow() ? "Expired" : "Valid until \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(BeatAIStyle.muted)
                            }
                            Spacer(minLength: 4)
                            if invitation.revokedAt == nil && invitation.expiresAt > game.serverNow() {
                                Button("Revoke", role: .destructive) { confirm(.revoke(invitation)) }
                                    .font(.caption.weight(.semibold)).frame(minHeight: 44)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("League details").font(.title3.weight(.bold))
            TextField("League name", text: $name)
                .textInputAutocapitalization(.words)
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Toggle("Show Top Scores AI in the table", isOn: $showAI)
                .font(.subheadline.weight(.medium)).tint(BeatAIStyle.purple)
            Button("Save league details") {
                Task {
                    if await leagues.updateLeague(leagueID: league.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), showAI: showAI, game: game, apiBaseURL: preferences.apiBaseURL) != nil {
                        settingsSaved = true
                        await reload()
                    }
                }
            }
            .font(.subheadline.weight(.bold)).frame(minHeight: 44)
            .disabled(!(2...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count))
            if settingsSaved {
                Label("League details saved", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(BeatAIStyle.green)
            }
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The squad").font(.title3.weight(.bold))
            ForEach(current.members) { member in
                HStack(spacing: 12) {
                    Image(systemName: member.isOwner ? "crown.fill" : "person.fill")
                        .foregroundStyle(member.isOwner ? BeatAIStyle.gold : BeatAIStyle.muted)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.displayName + (member.isYou ? " · You" : ""))
                            .font(.subheadline.weight(.semibold))
                        Text(member.isOwner ? "Owner" : member.status == "active" ? "Member" : member.status == "removed" ? "Removed" : "Former member")
                            .font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                    Spacer(minLength: 0)
                    if league.isOwner && isOpen && !member.isYou {
                        Menu {
                            if member.status == "active" {
                                Button("Transfer ownership", systemImage: "crown") { confirm(.transfer(member)) }
                                Button("Remove member", systemImage: "person.badge.minus", role: .destructive) { confirm(.remove(member)) }
                            } else if member.status == "removed" {
                                Button("Allow rejoining", systemImage: "person.badge.plus") { confirm(.reinstate(member)) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Options for \(member.displayName)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func confirm(_ action: LeagueAction) { confirmation = action; showsConfirmation = true }
    private func reload() async {
        await leagues.loadDetail(leagueID: detail.league.id, game: game, apiBaseURL: preferences.apiBaseURL)
    }
    private func perform(_ action: LeagueAction) async {
        let id = detail.league.id
        let succeeded: Bool
        switch action {
        case .remove(let member): succeeded = await leagues.removeMember(leagueID: id, memberID: member.id, game: game, apiBaseURL: preferences.apiBaseURL)
        case .reinstate(let member): succeeded = await leagues.reinstateMember(leagueID: id, memberID: member.id, game: game, apiBaseURL: preferences.apiBaseURL)
        case .transfer(let member): succeeded = await leagues.transferOwnership(leagueID: id, memberID: member.id, game: game, apiBaseURL: preferences.apiBaseURL)
        case .revoke(let invitation):
            succeeded = await leagues.revokeInvitation(leagueID: id, invitationID: invitation.id, game: game, apiBaseURL: preferences.apiBaseURL)
            if succeeded, newInvitation?.id == invitation.id { newInvitation = nil }
        case .close: succeeded = await leagues.closeLeague(leagueID: id, game: game, apiBaseURL: preferences.apiBaseURL)
        case .leave:
            succeeded = await leagues.leaveLeague(leagueID: id, game: game, apiBaseURL: preferences.apiBaseURL)
            if succeeded { dismiss(); onMembershipEnded(); return }
        }
        if succeeded { await reload() }
    }
}
