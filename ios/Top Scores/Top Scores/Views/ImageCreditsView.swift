import SwiftUI

struct ImageCreditsView: View {
    @EnvironmentObject private var stadiumArtworkStore: StadiumArtworkStore

    var body: some View {
        FootballNavigationScreen(title: "Image credits", subtitle: "Stadium artwork") {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No image credits available",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Credits will appear after the stadium artwork catalogue has been downloaded.")
                    )
                } else {
                    List {
                        ForEach(groups) { group in
                            Section(group.title) {
                                ForEach(group.assets) { asset in
                                    ImageCreditRow(asset: asset)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
        }
        .navigationTitle("Image credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var groups: [ImageCreditGroup] {
        guard let catalog = stadiumArtworkStore.catalog else { return [] }
        var values: [String: [StadiumArtworkAsset]] = [:]
        for asset in catalog.assets {
            let title: String
            if asset.role == .team,
               let teamID = asset.teamIDs.first,
               let team = catalog.teams[teamID] {
                let stadium = asset.stadium?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let stadium, !stadium.isEmpty {
                    title = "\(team.name) — \(stadium)"
                } else {
                    title = team.name
                }
            } else if asset.role == .genericMatch {
                title = "Generic match artwork"
            } else {
                title = "Generic screen artwork"
            }
            values[title, default: []].append(asset)
        }
        return values
            .map { ImageCreditGroup(title: $0.key, assets: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

private struct ImageCreditGroup: Identifiable {
    let title: String
    let assets: [StadiumArtworkAsset]
    var id: String { title }
}

private struct ImageCreditRow: View {
    let asset: StadiumArtworkAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(asset.credit.attribution)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(asset.credit.license)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { creditLinks }
                VStack(alignment: .leading, spacing: 8) { creditLinks }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var creditLinks: some View {
        if let url = asset.credit.authorURL.flatMap(URL.init(string:)) {
            Link("Author", destination: url)
        }
        if let url = asset.credit.sourcePage.flatMap(URL.init(string:)) {
            Link("Source", destination: url)
        }
        if let url = asset.credit.licenseURL.flatMap(URL.init(string:)) {
            Link("Licence", destination: url)
        }
    }
}
