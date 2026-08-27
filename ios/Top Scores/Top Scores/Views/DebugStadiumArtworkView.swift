#if DEBUG
import SwiftUI
import UIKit

struct DebugStadiumArtworkView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore

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
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore

    let title: String
    let subtitle: String
    let assets: [StadiumArtworkAsset]

    var body: some View {
        FootballNavigationScreen(title: title, subtitle: subtitle) {
            if assets.isEmpty {
                ContentUnavailableView(
                    "No images assigned",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("Refresh the server catalogue and check the artwork assignments.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(assets) { asset in
                            DebugStadiumArtworkCard(
                                asset: asset,
                                teamNames: teamNames(for: asset),
                                apiBaseURL: preferences.apiBaseURL
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
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
    let asset: StadiumArtworkAsset
    let teamNames: [String]
    let apiBaseURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DebugStadiumArtworkThumbnail(asset: asset, apiBaseURL: apiBaseURL)
                .frame(maxWidth: .infinity)
                .aspectRatio(asset.previewAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(asset.id)
                    .font(.headline)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    DebugArtworkBadge(text: asset.role.debugTitle)
                    DebugArtworkBadge(text: asset.lightContext.rawValue.capitalized)
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

            if let sourceURL = asset.credit.sourcePage.flatMap(URL.init(string:)) {
                Link("Open source credit", destination: sourceURL)
                    .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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
        if lhs.lightContext != rhs.lightContext {
            return lhs.lightContext.rawValue < rhs.lightContext.rawValue
        }
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
#endif
