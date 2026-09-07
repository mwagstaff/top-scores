#if DEBUG
import SwiftUI
import UIKit
import Security

struct DebugStadiumArtworkView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore

    @State private var adminKey = ""
    @State private var adminMessage: String?

    @State private var isRefreshing = false
    @State private var refreshMessage: String?

    var body: some View {
        FootballNavigationScreen(title: "Stadium artwork", subtitle: "Debug tools") {
            List {
                Section("Server catalogue") {
                    if let catalog = stadiumArtworkStore.catalog {
                        LabeledContent("Version", value: String(catalog.catalogVersion.prefix(12)))
                        LabeledContent("Generated", value: catalog.generatedAt)
                        LabeledContent("Images", value: "\(catalog.assets.count)")
                    } else {
                        Text("No stadium artwork catalogue is loaded.")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await refreshAndCacheAllImages() }
                    } label: {
                        HStack(spacing: 10) {
                            if isRefreshing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise.icloud")
                            }
                            Text(isRefreshing ? "Pulling images…" : "Pull latest images")
                        }
                    }
                    .disabled(isRefreshing)

                    if let refreshMessage {
                        Text(refreshMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Image administration") {
                    SecureField("Artwork admin key", text: $adminKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save admin key") {
                        do {
                            try DebugArtworkAdminKey.save(adminKey, server: preferences.apiBaseURL)
                            adminMessage = adminKey.isEmpty ? "Admin key removed." : "Admin key saved on this device."
                        } catch { adminMessage = error.localizedDescription }
                    }
                    if let adminMessage { Text(adminMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("Use the server's artwork admin key to delete images. Deleted photographs stay excluded from future deployments.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Browse") {
                    NavigationLink {
                        DebugStadiumArtworkCollectionsView()
                    } label: {
                        DebugArtworkNavigationLabel(
                            title: "Teams and stadiums",
                            subtitle: "Inspect every assigned image",
                            systemImage: "sportscourt"
                        )
                    }

                    NavigationLink {
                        DebugStadiumArtworkGalleryView(
                            title: "Generic images",
                            subtitle: "Scores and match artwork",
                            assets: genericAssets
                        )
                    } label: {
                        DebugArtworkNavigationLabel(
                            title: "Generic images",
                            subtitle: "\(genericAssets.count) screen and match images",
                            systemImage: "photo.stack"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .task(id: preferences.apiBaseURL) {
            adminKey = DebugArtworkAdminKey.load(server: preferences.apiBaseURL)
            adminMessage = nil
        }
        .navigationTitle("Stadium artwork")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var genericAssets: [StadiumArtworkAsset] {
        (stadiumArtworkStore.catalog?.assets ?? [])
            .filter { $0.role != .team }
            .sorted(by: DebugStadiumArtworkSort.assets)
    }

    private func refreshAndCacheAllImages() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshMessage = "Refreshing the catalogue from \(preferences.apiBaseURL)…"
        defer { isRefreshing = false }

        await stadiumArtworkStore.ensureFresh(
            apiBaseURL: preferences.apiBaseURL,
            force: true
        )

        if let error = stadiumArtworkStore.lastRefreshErrorDescription {
            refreshMessage = "Catalogue refresh failed: \(error)"
            return
        }
        guard let catalog = stadiumArtworkStore.catalog else {
            refreshMessage = "The server returned no usable stadium artwork catalogue."
            return
        }

        refreshMessage = "Catalogue refreshed. Downloading \(catalog.assets.count) images…"
        let loadedCount = await StadiumArtworkImageCache.shared.prefetch(
            assets: catalog.assets,
            apiBaseURL: preferences.apiBaseURL
        )
        if loadedCount == catalog.assets.count {
            refreshMessage = "Pulled and cached all \(loadedCount) images."
        } else {
            refreshMessage = "Cached \(loadedCount) of \(catalog.assets.count) images. Open the galleries to identify any failed downloads."
        }
    }
}

private struct DebugStadiumArtworkCollectionsView: View {
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore
    @State private var searchText = ""

    var body: some View {
        FootballNavigationScreen(title: "Teams and stadiums", subtitle: "Artwork assignments") {
            Group {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No team artwork available",
                        systemImage: "sportscourt",
                        description: Text("Pull the latest server catalogue to inspect its assignments.")
                    )
                } else if filteredCollections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        collectionSection(title: "Teams", kind: .team)
                        collectionSection(title: "Stadiums", kind: .stadium)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .searchable(text: $searchText, prompt: "Search teams or stadiums")
        }
        .navigationTitle("Teams and stadiums")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func collectionSection(
        title: String,
        kind: DebugStadiumArtworkCollection.Kind
    ) -> some View {
        let values = filteredCollections.filter { $0.kind == kind }
        if !values.isEmpty {
            Section(title) {
                ForEach(values) { collection in
                    NavigationLink {
                        DebugStadiumArtworkGalleryView(
                            title: collection.title,
                            subtitle: collection.subtitle,
                            assets: collection.assets
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(collection.title)
                            Text("\(collection.assets.count) image\(collection.assets.count == 1 ? "" : "s")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var filteredCollections: [DebugStadiumArtworkCollection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collections }
        return collections.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var collections: [DebugStadiumArtworkCollection] {
        guard let catalog = stadiumArtworkStore.catalog else { return [] }
        let teamAssets = catalog.assets.filter { $0.role == .team }

        let teams = catalog.teams.compactMap { teamID, team -> DebugStadiumArtworkCollection? in
            let assets = teamAssets.filter { $0.teamIDs.contains(teamID) }
            guard !assets.isEmpty else { return nil }
            let stadiums = Set(assets.compactMap(\.stadium)).sorted()
            return DebugStadiumArtworkCollection(
                id: "team:\(teamID)",
                kind: .team,
                title: team.name,
                subtitle: stadiums.joined(separator: ", "),
                assets: assets.sorted(by: DebugStadiumArtworkSort.assets)
            )
        }

        let stadiumGroups = Dictionary(
            grouping: teamAssets.compactMap { asset -> (String, StadiumArtworkAsset)? in
                guard let stadium = asset.stadium?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !stadium.isEmpty else { return nil }
                return (stadium, asset)
            },
            by: { $0.0 }
        )
        let stadiums = stadiumGroups.map { stadium, values in
            let assets = values.map(\.1)
            let teamNames = Set(
                assets.flatMap(\.teamIDs).compactMap { catalog.teams[$0]?.name }
            ).sorted()
            return DebugStadiumArtworkCollection(
                id: "stadium:\(stadium)",
                kind: .stadium,
                title: stadium,
                subtitle: teamNames.joined(separator: ", "),
                assets: assets.sorted(by: DebugStadiumArtworkSort.assets)
            )
        }

        return (teams + stadiums).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

private struct DebugStadiumArtworkGalleryView: View {
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore

    let title: String
    let subtitle: String
    let assets: [StadiumArtworkAsset]
    @State private var previewMode = "Match"

    private var visibleAssets: [StadiumArtworkAsset] {
        guard let catalog = stadiumArtworkStore.catalog else { return assets }
        let ids = Set(assets.map(\.id))
        return catalog.assets.filter { ids.contains($0.id) }.sorted(by: DebugStadiumArtworkSort.assets)
    }

    private var showsHeroes: Bool { visibleAssets.contains { $0.role == .team } }

    var body: some View {
        FootballNavigationScreen(title: title, subtitle: subtitle) {
            if visibleAssets.isEmpty {
                ContentUnavailableView(
                    "No images assigned",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("Refresh the server catalogue and check the artwork assignments.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if showsHeroes {
                            Picker("Hero preview", selection: $previewMode) {
                                Text("Match").tag("Match")
                                Text("Team").tag("Team")
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)

                            Text("Sample content • rotation paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(visibleAssets) { asset in
                            DebugStadiumArtworkCard(
                                asset: asset,
                                teamNames: teamNames(for: asset),
                                galleryAssets: visibleAssets,
                                previewMode: showsHeroes ? previewMode : "Original"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, showsHeroes ? 0 : 16)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func teamNames(for asset: StadiumArtworkAsset) -> [String] {
        guard let catalog = stadiumArtworkStore.catalog else { return [] }
        return asset.teamIDs.compactMap { catalog.teams[$0]?.name }.sorted()
    }
}

private struct DebugStadiumArtworkCard: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var artworkStore: StadiumArtworkStore
    @State private var confirmDeletion = false
    @State private var isDeleting = false
    @State private var deletionError: String?

    let asset: StadiumArtworkAsset
    let teamNames: [String]
    let galleryAssets: [StadiumArtworkAsset]
    let previewMode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DebugStadiumArtworkHeroPreview(asset: asset, mode: previewMode)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(asset.id)
                        .font(.headline)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        DebugArtworkBadge(text: asset.role.debugTitle)
                    }

                    if let stadium = asset.stadium, !stadium.isEmpty {
                        Label(stadium, systemImage: "sportscourt")
                    }
                    if !teamNames.isEmpty {
                        Label(teamNames.joined(separator: ", "), systemImage: "person.3")
                    }

                    Text("\(asset.width) × \(asset.height) • \(ByteCountFormatter.string(fromByteCount: Int64(asset.byteSize), countStyle: .file))")
                    Text("SHA-256 \(asset.sha256.prefix(16))…")
                        .textSelection(.enabled)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                NavigationLink {
                    DebugStadiumArtworkHeroReview(assets: galleryAssets, initialAssetID: asset.id,
                                                 initialMode: "Original")
                        .id(asset.id)
                } label: {
                    Label("View original", systemImage: "photo")
                }

                NavigationLink {
                    DebugStadiumArtworkHeroReview(assets: galleryAssets, initialAssetID: asset.id,
                                                 initialMode: previewMode == "Original" ? "Match" : previewMode)
                        .id(asset.id)
                } label: {
                    Label("Adjust framing", systemImage: "crop")
                }

                Button(role: .destructive) { confirmDeletion = true } label: {
                    Label(isDeleting ? "Deleting…" : "Delete image", systemImage: "trash")
                }
                .disabled(isDeleting)
                if let deletionError {
                    Text(deletionError).font(.footnote).foregroundStyle(.red)
                }

                if let sourceURL = asset.credit.sourcePage.flatMap(URL.init(string:)) {
                    Link("Open source credit", destination: sourceURL)
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(14)
        }
        .confirmationDialog("Delete this photograph from the server?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete image", role: .destructive) { isDeleting = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("It will be removed from every team's rotation. Local approved and staged copies are moved aside the next time artwork is published from your Mac.")
        }
        .task(id: isDeleting) {
            guard isDeleting else { return }
            defer { isDeleting = false }
            deletionError = nil
            let token = DebugArtworkAdminKey.load(server: preferences.apiBaseURL)
            guard !token.isEmpty else {
                deletionError = "Save your artwork admin key on the Stadium artwork screen first."
                return
            }
            do {
                try await artworkStore.deleteArtwork(asset, apiBaseURL: preferences.apiBaseURL, adminToken: token)
            } catch {
                deletionError = "\(error.localizedDescription) Refresh the catalogue before retrying if the connection was interrupted."
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            FootballCardSurface(accentColor: Color.accentColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FootballVisualStyle.cardCornerRadius, style: .continuous)
                .stroke(FootballVisualStyle.border, lineWidth: 1)
        }
    }
}

private struct DebugStadiumArtworkThumbnail: View {
    let asset: StadiumArtworkAsset
    let apiBaseURL: String

    @State private var image: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if didFinishLoading {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.title2)
                    Text("Download failed")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: "\(apiBaseURL)|\(asset.sha256)") {
            image = nil
            didFinishLoading = false
            let loadedImage = await StadiumArtworkImageCache.shared.image(
                for: asset,
                apiBaseURL: apiBaseURL
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
            didFinishLoading = true
        }
        .accessibilityLabel("\(asset.id) stadium artwork")
    }
}

private struct DebugArtworkNavigationLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 2)
    }
}

private struct DebugArtworkBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

private struct DebugStadiumArtworkCollection: Identifiable {
    enum Kind: String {
        case team
        case stadium
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let assets: [StadiumArtworkAsset]
}

private enum DebugStadiumArtworkSort {
    static func assets(_ lhs: StadiumArtworkAsset, _ rhs: StadiumArtworkAsset) -> Bool {
        if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
        return lhs.id < rhs.id
    }
}

private extension StadiumArtworkRole {
    var debugTitle: String {
        switch self {
        case .genericBackdrop: "Screen"
        case .genericMatch: "Match"
        case .team: "Team"
        }
    }
}

private extension StadiumArtworkAsset {
    var previewAspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// Shares the real hero layout between the gallery and the framing editor.
private struct DebugStadiumArtworkHeroPreview: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var artworkStore: StadiumArtworkStore
    let asset: StadiumArtworkAsset
    let mode: String
    var predictions = true

    private var teamName: String {
        asset.teamIDs.compactMap { artworkStore.catalog?.teams[$0]?.name }.first ?? "Arsenal"
    }
    private var match: Match {
        Match(date: "2026-09-06", time: "16:30", homeTeam: teamName,
              awayTeam: teamName == "Chelsea" ? "Arsenal" : "Chelsea",
              league: "Premier League", leagueId: "premier-league", tvChannels: [])
    }
    private var context: TeamDetailsContext {
        TeamDetailsContext(teamID: nil, teamName: teamName, displayName: teamName,
                           alternateNames: [], originatingLeagueID: "premier-league",
                           originatingLeagueName: "Premier League", originatingMatch: nil)
    }

    var body: some View {
        Group {
            if mode == "Match" {
                MatchDetailScoreboardHero(
                    match: match, kickoffText: "Sun 6 Sep, 16:30",
                    predictionDisplay: predictions
                        ? .available(homeGoals: 1, awayGoals: 2, homeWinProbability: 0.57,
                                     drawProbability: 0.24, awayWinProbability: 0.19) : .hidden,
                    teamCompetitionEntries: []
                )
            } else if mode == "Team" {
                TeamDetailsHero(context: context, competitionID: "premier-league",
                                competitionName: "Premier League")
            } else {
                DebugStadiumArtworkThumbnail(asset: asset, apiBaseURL: preferences.apiBaseURL)
                    .id(asset.sha256)
                    .aspectRatio(asset.previewAspectRatio, contentMode: .fit)
            }
        }
        .environment(\.stadiumArtworkReviewAsset, asset)
        .allowsHitTesting(false)
        .coordinateSpace(name: "TeamDetailsScroll")
    }
}

private struct DebugStadiumArtworkHeroReview: View {
    @EnvironmentObject private var artworkStore: StadiumArtworkStore
    let assets: [StadiumArtworkAsset]
    let initialAssetID: String
    @State private var selection: String?
    @State private var mode: String
    @State private var predictions = true
    @State private var largerText = false
    @State private var drafts: [String: StadiumArtworkFocalPoint] = [:]
    @State private var copied = false

    init(assets: [StadiumArtworkAsset], initialAssetID: String, initialMode: String = "Match") {
        self.assets = assets
        self.initialAssetID = initialAssetID
        _mode = State(initialValue: initialMode)
    }

    private var index: Int { assets.firstIndex { $0.id == (selection ?? initialAssetID) } ?? 0 }
    private var asset: StadiumArtworkAsset {
        var value = assets[index]
        value.focalPoint = drafts[value.id] ?? value.focalPoint
        return value
    }
    private var teamName: String {
        asset.teamIDs.compactMap { artworkStore.catalog?.teams[$0]?.name }.first ?? "Arsenal"
    }
    var body: some View {
        FootballNavigationScreen(title: "Hero review", subtitle: teamName) {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Preview", selection: $mode) {
                        Text("Match").tag("Match")
                        Text("Team").tag("Team")
                        Text("Original").tag("Original")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    DebugStadiumArtworkHeroPreview(asset: asset, mode: mode, predictions: predictions)
                        .environment(\.dynamicTypeSize, largerText ? .accessibility1 : .large)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Button("Previous", systemImage: "chevron.left") { step(-1) }
                                .disabled(index == 0)
                            Spacer()
                            Text("\(index + 1) of \(assets.count)").monospacedDigit()
                            Spacer()
                            Button("Next", systemImage: "chevron.right") { step(1) }
                                .disabled(index == assets.count - 1)
                        }
                        Text(asset.id).font(.caption).textSelection(.enabled)
                        Text("Sample content • rotation paused").font(.caption).foregroundStyle(.secondary)
                        Toggle("Show predictions", isOn: $predictions)
                        Toggle("Larger text", isOn: $largerText)
                        Text("Framing").font(.headline)
                        Text("Choose the part of the photograph to keep centred. Movement stops at the image edges.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value: coordinate(\.x), in: 0...1) { Text("Horizontal focal point") }
                        HStack { Text("Left"); Spacer(); Text("Right") }.font(.caption)
                        Slider(value: coordinate(\.y), in: 0...1) { Text("Vertical focal point") }
                        HStack { Text("Top"); Spacer(); Text("Bottom") }.font(.caption)
                        HStack {
                            Button("Reset framing") { drafts[asset.id] = assets[index].focalPoint ?? .center }
                            Spacer()
                            Button(copied ? "Copied" : "Copy framing settings") {
                                UIPasteboard.general.string = framingSettings
                                copied = true
                            }
                        }
                        Text("Preview changes are not published. Copy settings before leaving, then merge them into focal_points in config/publishing.yaml and publish the artwork.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
    }

    private func step(_ amount: Int) {
        selection = assets[min(assets.count - 1, max(0, index + amount))].id
        copied = false
    }

    private func coordinate(_ keyPath: WritableKeyPath<StadiumArtworkFocalPoint, Double>) -> Binding<Double> {
        Binding(get: { (asset.focalPoint ?? .center)[keyPath: keyPath] }, set: { value in
            var point = asset.focalPoint ?? .center
            point[keyPath: keyPath] = value
            drafts[asset.id] = point
            copied = false
        })
    }

    private var framingSettings: String {
        var values = drafts
        values[asset.id] = asset.focalPoint ?? .center
        return "focal_points:\n" + values.keys.sorted().map { id in
            let point = values[id]!
            return "  \(id): {x: \(String(format: "%.3f", point.x)), y: \(String(format: "%.3f", point.y))}"
        }.joined(separator: "\n") + "\n"
    }
}

/// Credentials are scoped to the selected server and never stored in preferences or the app bundle.
private enum DebugArtworkAdminKey {
    private static func query(server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "top-scores.stadium-artwork-admin",
         kSecAttrAccount as String: server]
    }

    static func load(server: String) -> String {
        var values = query(server: server)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String, server: String) throws {
        let values = query(server: server)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(values as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let update = [kSecValueData as String: Data(trimmed.utf8),
                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        var status = SecItemUpdate(values as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(values.merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not save the artwork admin key securely."])
    }
}

#endif
