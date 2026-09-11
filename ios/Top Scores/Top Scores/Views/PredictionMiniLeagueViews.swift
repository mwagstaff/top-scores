import SwiftUI

/// Private tables live inside the game. Opening an invitation only opens a preview.
struct PredictionMiniLeaguesView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var leagues = PredictionMiniLeagueStore()
    @State private var sheet: LeagueSheet?
    @State private var selectedLeagueID: String?
    let initialInvitationCode: String?

    init(initialInvitationCode: String? = nil) { self.initialInvitationCode = initialInvitationCode }

    private enum LeagueSheet: Identifiable {
        case create, join(String)
        var id: String { switch self { case .create: "create"; case .join(let code): "join-\(code)" } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if leagues.isLoading && leagues.leagues.isEmpty {
                    MiniLeagueLoading("Getting your dressing room ready…")
                } else {
                    if let error = leagues.errorMessage {
                        MiniLeagueErrorCard(error) { Task { await load() } }
                    }
                    actions
                    if leagues.leagues.isEmpty && leagues.errorMessage == nil { emptyState }
                    ForEach(leagues.leagues) { league in
                        NavigationLink {
                            PredictionMiniLeagueDetailView(leagueID: league.id, leagues: leagues)
                        } label: { MiniLeagueCard(league: league) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mini-league-card-\(league.id)")
                    }
                }
                Label("Invitation only. Your league stays between you and your group.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(BeatAIStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .miniLeagueScreen(title: "My Leagues")
        .accessibilityIdentifier("mini-leagues-home")
        .refreshable { await load() }
        .task(id: "\(preferences.apiBaseURL)|\(game.privateLeagueScopeID)") { await load() }
        .task(id: initialInvitationCode) {
            if let initialInvitationCode { sheet = .join(initialInvitationCode) }
        }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .create:
                    PredictionMiniLeagueCreateView(leagues: leagues) { league in
                        sheet = nil
                        selectedLeagueID = league.id
                    }
                case .join(let code):
                    PredictionMiniLeagueJoinView(leagues: leagues, initialCode: code) { league in
                        sheet = nil
                        selectedLeagueID = league.id
                    }
                }
            }
            .preferredColorScheme(.dark)
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $selectedLeagueID) { id in
            PredictionMiniLeagueDetailView(leagueID: id, leagues: leagues)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("THE BRAGGING RIGHTS START HERE", systemImage: "flag.checkered.2.crossed")
                .font(.caption.weight(.heavy))
                .tracking(1.3)
                .foregroundStyle(BeatAIStyle.gold)
            Text("Same matches.\nYour own rivalry.")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("Bring your friends and family together. Every pick counts toward your private table.")
                .font(.subheadline)
                .foregroundStyle(BeatAIStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var actions: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button { sheet = .create } label: {
                Label("Create League", systemImage: "plus")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(BeatAIPrimaryButtonStyle())
            .accessibilityIdentifier("mini-league-create")
            Button { sheet = .join("") } label: {
                Label("Join League", systemImage: "ticket")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 12)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.16)) }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mini-league-join")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                MiniLeagueBadge(size: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your first league awaits")
                        .font(.title3.weight(.bold))
                    Text("Start a family derby or take on your mates. Choose a competition, give your league a name and share the invitation.")
                        .font(.subheadline)
                        .foregroundStyle(BeatAIStyle.muted)
                }
            }
            Divider().overlay(.white.opacity(0.08))
            Label("Already have a code? Tap Join League.", systemImage: "ticket.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(BeatAIStyle.green)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 20)
    }

    private func load() async { await leagues.load(game: game, apiBaseURL: preferences.apiBaseURL) }
}

private struct MiniLeagueCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let league: PredictionMiniLeague

    var body: some View {
        BeatAIPanel(accent: BeatAIStyle.green) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    MiniLeagueBadge(size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(league.name).font(.title3.weight(.bold))
                        Text(league.competitionName)
                            .font(.caption.weight(.semibold)).foregroundStyle(BeatAIStyle.gold)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        .foregroundStyle(BeatAIStyle.muted).padding(.top, 8)
                }
                if league.status == "closed" {
                    Label("League closed · Results kept", systemImage: "lock.fill")
                        .font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                } else if let position = league.position {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(position.formatted(.number)).font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("of \(league.memberCount) in your league").font(.subheadline.weight(.semibold))
                            Text(position == 1 ? "Setting the pace" : league.gapToLeader == 0 ? "Level on points at the top" : "\(league.gapToLeader) points off the top")
                                .font(.caption).foregroundStyle(BeatAIStyle.green)
                        }
                        Spacer(minLength: 0)
                        if !typeSize.isAccessibilitySize {
                            Text("\(league.points) pts").font(.headline).monospacedDigit()
                        }
                    }
                } else {
                    Label("Ready for the next full round", systemImage: "clock")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(BeatAIStyle.green)
                }
                HStack {
                    Text(league.currentRound?.label ?? "Fixtures coming soon")
                    Spacer(minLength: 8)
                    Label("\(league.memberCount)", systemImage: "person.2.fill")
                }
                .font(.caption).foregroundStyle(BeatAIStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct PredictionMiniLeagueCreateView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var leagues: PredictionMiniLeagueStore
    @State private var name = ""
    @State private var competitionID = ""
    @State private var showAI = true
    let onCreated: (PredictionMiniLeague) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MiniLeagueBadge(size: 64)
                Text("Give your rivalry a home.")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                VStack(alignment: .leading, spacing: 8) {
                    Text("League name").font(.headline)
                    TextField("The Family Derby", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .padding(16)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("mini-league-name")
                    Text("2–40 characters. Make it yours.").font(.caption).foregroundStyle(BeatAIStyle.muted)
                }
                BeatAIPanel(accent: BeatAIStyle.gold) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Competition", selection: $competitionID) {
                            ForEach(game.availableCompetitions) { competition in Text(competition.name).tag(competition.id) }
                        }
                        .pickerStyle(.menu)
                        .tint(BeatAIStyle.gold)
                        .accessibilityIdentifier("mini-league-competition")
                        Text("Everyone predicts the same AI-supported matches in each round. Your existing picks count automatically.")
                            .font(.footnote).foregroundStyle(BeatAIStyle.muted)
                    }
                }
                Toggle(isOn: $showAI) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Invite the AI to your table").font(.headline)
                        Text("One shared benchmark for the whole league.")
                            .font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                }
                .tint(BeatAIStyle.purple)
                Text("Your league starts from the next full round. Invitations last 7 days and you can revoke them at any time.")
                    .font(.footnote).foregroundStyle(BeatAIStyle.muted)
                if let error = leagues.errorMessage { MiniLeagueInlineError(message: error) }
                Button {
                    Task {
                        if let league = await leagues.create(name: trimmedName, competitionID: competitionID, showAI: showAI, game: game, apiBaseURL: preferences.apiBaseURL) { onCreated(league) }
                    }
                } label: {
                    HStack { if leagues.isWorking { ProgressView().tint(.white) }; Text("Create League") }
                }
                .buttonStyle(BeatAIPrimaryButtonStyle())
                .disabled(leagues.isWorking || !(2...40).contains(trimmedName.count) || competitionID.isEmpty)
                .accessibilityIdentifier("mini-league-create-confirm")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
        }
        .miniLeagueScreen(title: "Create League")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(leagues.isWorking) } }
        .interactiveDismissDisabled(leagues.isWorking)
        .onAppear { competitionID = game.selectedCompetitionID }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct PredictionMiniLeagueJoinView: View {
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var leagues: PredictionMiniLeagueStore
    @State private var code: String
    @State private var previewedCode: String?
    let onJoined: (PredictionMiniLeague) -> Void

    init(leagues: PredictionMiniLeagueStore, initialCode: String, onJoined: @escaping (PredictionMiniLeague) -> Void) {
        self.leagues = leagues
        _code = State(initialValue: initialCode)
        self.onJoined = onJoined
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("YOUR INVITATION TO THE TABLE", systemImage: "ticket.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(BeatAIStyle.gold)
                Text("There’s room for\none more rival.")
                    .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Invitation code or link").font(.headline)
                    TextField("Enter your invitation", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .padding(16)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .onSubmit { preview() }
                        .accessibilityIdentifier("mini-league-invite-code")
                }
                if let invitation = leagues.invitationPreview, previewedCode == code {
                    BeatAIPanel(accent: BeatAIStyle.green) {
                        VStack(alignment: .leading, spacing: 14) {
                            MiniLeagueBadge(size: 48)
                            Text(invitation.leagueName).font(.title.weight(.bold))
                            Text(invitation.competitionName).font(.subheadline.weight(.semibold)).foregroundStyle(BeatAIStyle.gold)
                            Label("\(invitation.memberCount) in the league", systemImage: "person.2.fill").font(.subheadline)
                            Text(invitation.alreadyMember ? "You’re already part of this league." : "You’ll score from the next full round. Earlier results won’t be imported.")
                                .font(.footnote).foregroundStyle(BeatAIStyle.muted)
                        }
                    }
                    Button {
                        Task {
                            if let league = await leagues.join(code: code, game: game, apiBaseURL: preferences.apiBaseURL) { onJoined(league) }
                        }
                    } label: {
                        HStack { if leagues.isWorking { ProgressView().tint(.white) }; Text(invitation.alreadyMember ? "Open League" : "Join League") }
                    }
                    .buttonStyle(BeatAIPrimaryButtonStyle())
                    .disabled(leagues.isWorking)
                    .accessibilityIdentifier("mini-league-join-confirm")
                } else {
                    Button(action: preview) {
                        HStack { if leagues.isWorking { ProgressView().tint(.white) }; Text("Find League") }
                    }
                    .buttonStyle(BeatAIPrimaryButtonStyle())
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || leagues.isWorking)
                }
                if let error = leagues.errorMessage { MiniLeagueInlineError(message: error) }
                Text("Only join invitations from people you trust. Your Game Center name and league results will be visible to the group.")
                    .font(.footnote).foregroundStyle(BeatAIStyle.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
        }
        .miniLeagueScreen(title: "Join League")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(leagues.isWorking) } }
        .interactiveDismissDisabled(leagues.isWorking)
        .task {
            // Preview is read-only; membership always requires the Join League button.
            if !code.isEmpty { await loadPreview() }
        }
    }

    private func preview() { Task { await loadPreview() } }
    private func loadPreview() async {
        let requested = code
        if await leagues.preview(code: requested, game: game, apiBaseURL: preferences.apiBaseURL), requested == code { previewedCode = requested }
    }
}

struct PredictionMiniLeagueDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var game: PredictionGameStore
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let leagueID: String
    @ObservedObject var leagues: PredictionMiniLeagueStore
    @State private var scope: PredictionMiniLeagueScope = .round
    @State private var selectedRoundID: String?
    @State private var selectedSeasonID: String?
    @State private var showsSettings = false
    @State private var membershipEnded = false
    @State private var showsPredictions = false

    private var detail: PredictionMiniLeagueDetailResponse? { leagues.detail?.league.id == leagueID ? leagues.detail : nil }
    private var selectedRound: PredictionMiniLeagueRound? {
        detail?.rounds.first { $0.id == selectedRoundID } ?? detail?.league.currentRound
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let detail {
                    matchdayHeader(detail.league)
                    Picker("Standings period", selection: $scope) {
                        ForEach(PredictionMiniLeagueScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mini-league-standings-period")
                    periodPicker(detail)
                    if leagues.isLoadingDetail { ProgressView().frame(maxWidth: .infinity).padding(8) }
                    if let error = leagues.errorMessage { MiniLeagueErrorCard(error) { Task { await load() } } }
                    if !leagues.standings.isEmpty {
                        standings
                    } else if !leagues.isLoadingDetail {
                        BeatAIPanel(accent: BeatAIStyle.green) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A clean sheet for everyone.").font(.title3.weight(.bold))
                                Text("Your table will come to life when the first round opens. Everyone gets the same matches.")
                                    .font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                            }
                        }
                    }
                    if let round = selectedRound, detail.league.status != "closed" {
                        Button { showsPredictions = true } label: {
                            Label("Make your predictions", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(BeatAIPrimaryButtonStyle())
                        .accessibilityIdentifier("mini-league-predict")
                        Text("\(round.fixtureCount) shared matches · Your picks also count in your other eligible leagues.")
                            .font(.caption).foregroundStyle(BeatAIStyle.muted)
                    }
                    rulesFooter
                } else if leagues.isLoadingDetail {
                    MiniLeagueLoading("Setting out the table…")
                } else {
                    MiniLeagueErrorCard(leagues.errorMessage ?? "This league is unavailable.") { Task { await load() } }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .miniLeagueScreen(title: detail?.league.name ?? "My League")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if detail != nil {
                    Button("League options", systemImage: "ellipsis.circle") { showsSettings = true }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("mini-league-options")
                }
            }
        }
        .task(id: "\(leagueID)|\(game.privateLeagueScopeID)|\(preferences.apiBaseURL)") { await load() }
        .onChange(of: scope) { _, _ in Task { await load() } }
        .onChange(of: selectedRoundID) { _, _ in Task { await load() } }
        .onChange(of: selectedSeasonID) { _, _ in Task { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $showsSettings, onDismiss: { if !membershipEnded { Task { await load() } } }) {
            if let detail {
                NavigationStack { PredictionMiniLeagueSettingsView(detail: detail, leagues: leagues, onMembershipEnded: { membershipEnded = true; showsSettings = false; dismiss() }) }
                    .preferredColorScheme(.dark)
                    .presentationDragIndicator(.visible)
            }
        }
        .navigationDestination(isPresented: $showsPredictions) {
            if let round = selectedRound {
                PredictionMiniLeaguePredictionsView(leagueID: leagueID, leagueName: detail?.league.name ?? "My League", round: round, showsAI: detail?.league.showAI ?? true)
            }
        }
    }

    private func matchdayHeader(_ league: PredictionMiniLeague) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MiniLeagueBadge(size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(league.competitionName.uppercased())
                        .font(.caption.weight(.bold)).tracking(1).foregroundStyle(BeatAIStyle.gold)
                    Text(league.name).font(.system(.title, design: .rounded, weight: .heavy))
                }
            }
            HStack(spacing: 10) {
                Label("\(league.memberCount) rivals", systemImage: "person.2.fill")
                Text("·")
                Label("Private league", systemImage: "lock.fill")
            }
            .font(.caption.weight(.medium)).foregroundStyle(BeatAIStyle.muted)
            if league.status == "closed" {
                Label("League closed. Your results are kept here.", systemImage: "flag.checkered")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BeatAIStyle.gold)
            } else if league.startsFrom != nil && !leagues.standings.contains(where: { $0.isYou && $0.played > 0 }) {
                Text("You’re in. Your scoring starts with your next full round.")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(BeatAIStyle.green)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func periodPicker(_ detail: PredictionMiniLeagueDetailResponse) -> some View {
        if scope == .round {
            Menu {
                ForEach(detail.rounds) { round in Button("\(round.label) · \(round.seasonLabel)") { selectedRoundID = round.id } }
            } label: {
                HStack {
                    Text(selectedRound?.label ?? "Next round")
                    Spacer()
                    Text(selectedRound?.completed == true ? "Final" : "Matchday")
                        .foregroundStyle(BeatAIStyle.green)
                    Image(systemName: "chevron.down")
                }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            .disabled(detail.rounds.isEmpty)
        } else {
            let seasons = detail.rounds.reduce(into: [PredictionMiniLeagueRound]()) { result, round in
                if !result.contains(where: { $0.seasonId == round.seasonId }) { result.append(round) }
            }
            Picker("Season", selection: Binding(get: { selectedSeasonID ?? selectedRound?.seasonId ?? seasons.first?.seasonId ?? "" }, set: { selectedSeasonID = $0 })) {
                ForEach(seasons) { Text($0.seasonLabel).tag($0.seasonId) }
            }
            .pickerStyle(.menu).tint(BeatAIStyle.gold)
        }
    }

    private var standings: some View {
        VStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                HStack {
                    Text("THE TABLE").tracking(1)
                    Spacer()
                    Text("EXACT").frame(width: 48)
                    Text("PTS").frame(width: 44)
                }
                .font(.caption2.weight(.bold)).foregroundStyle(BeatAIStyle.muted)
                .padding(.horizontal, 14)
            }
            ForEach(leagues.standings) { row in MiniLeagueStandingRow(row: row) }
        }
    }

    private var rulesFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("3 points for an exact score. 1 for the right result.", systemImage: "soccerball")
            Text("Level on points? Exact scores decide the order. Still level? You share the position.")
            Label("Other members’ predictions stay hidden until each match locks.", systemImage: "lock.shield")
            if detail?.league.showAI == true {
                Text("Top Scores AI uses one shared set of predictions fixed when the round opens. This can differ from your personal AI opponent.")
            }
        }
        .font(.footnote).foregroundStyle(BeatAIStyle.muted).padding(.top, 8)
    }

    private func load() async {
        await leagues.loadDetail(leagueID: leagueID, scope: scope, roundID: selectedRoundID, seasonID: selectedSeasonID, game: game, apiBaseURL: preferences.apiBaseURL)
    }
}

private struct MiniLeagueStandingRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: PredictionMiniLeagueStanding
    private var accent: Color { row.isAI ? BeatAIStyle.purple : row.isYou ? BeatAIStyle.blue : BeatAIStyle.gold }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if row.isAI { Image(systemName: "sparkles").font(.title3) }
                else { Text("\(row.rank)").font(.system(.title3, design: .rounded, weight: .heavy)).monospacedDigit() }
            }
            .foregroundStyle(accent)
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.isYou ? "\(row.displayName) · You" : row.displayName)
                    .font(.subheadline.weight(row.isYou || row.isAI ? .bold : .semibold))
                if row.isAI {
                    Text("Shared benchmark").font(.caption2).foregroundStyle(BeatAIStyle.purple)
                } else if row.status != "active" {
                    Text(row.status == "removed" ? "Removed member" : "Former member")
                        .font(.caption2).foregroundStyle(BeatAIStyle.muted)
                } else {
                    Text("\(row.correctResults) correct results · \(row.played) played")
                        .font(.caption2).foregroundStyle(BeatAIStyle.muted)
                }
                if typeSize.isAccessibilitySize {
                    Text("\(row.points) points · \(row.exactScores) exact scores")
                        .font(.subheadline.weight(.bold)).foregroundStyle(accent)
                }
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                Text("\(row.exactScores)").font(.subheadline.weight(.medium)).frame(width: 36)
                Text("\(row.points)").font(.system(.title3, design: .rounded, weight: .bold)).frame(width: 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 17)
        .background(row.isYou ? BeatAIStyle.blue.opacity(0.18) : row.isAI ? BeatAIStyle.purple.opacity(0.08) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(row.isYou || row.isAI ? accent.opacity(0.4) : .white.opacity(0.06)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.isAI ? "Benchmark" : "Position \(row.rank)"), \(row.displayName)\(row.isYou ? ", you" : ""), \(row.points) points, \(row.exactScores) exact scores, \(row.correctResults) correct results")
        .accessibilityIdentifier(row.isYou ? "mini-league-your-standing" : "mini-league-standing-\(row.id)")
    }
}

struct MiniLeagueBadge: View {
    var size: CGFloat = 48
    var body: some View {
        Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: size * 0.88, weight: .light))
            .foregroundStyle(BeatAIStyle.green.opacity(0.7))
            .overlay {
                Image(systemName: "soccerball")
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(y: -size * 0.025)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MiniLeagueLoading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(BeatAIStyle.green)
            Text(title).font(.subheadline).foregroundStyle(BeatAIStyle.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }
}

struct MiniLeagueInlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MiniLeagueErrorCard: View {
    let message: String
    let retry: () -> Void
    init(_ message: String, retry: @escaping () -> Void) { self.message = message; self.retry = retry }
    var body: some View {
        BeatAIPanel(accent: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                Label("A pause in play", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.subheadline).foregroundStyle(BeatAIStyle.muted)
                Button("Try again", action: retry).font(.subheadline.weight(.bold)).frame(minHeight: 44)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    func miniLeagueScreen(title: String) -> some View {
        self.background { BeatAIBackground() }
            .foregroundStyle(.white)
            .fontDesign(.rounded)
            .tint(BeatAIStyle.blue)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BeatAIStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .environment(\.colorScheme, .dark)
    }
}
