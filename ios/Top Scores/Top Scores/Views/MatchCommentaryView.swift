import SwiftUI

struct MatchCommentaryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = MatchCommentaryStore()
    @State private var importantOnly = false
    @State private var showAll = false
    @State private var retry = 0

    let matchID: String
    let apiBaseURL: String
    let isLive: Bool
    let onShowRecent: () -> Void

    private var entries: [MatchCommentaryLine] {
        store.payload?.entries(importantOnly: importantOnly) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Newest first").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    filterButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Newest first").font(.caption).foregroundStyle(.secondary)
                    filterButton
                }
            }
            if store.hasError {
                Text(store.payload == nil ? "Commentary is temporarily unavailable."
                     : "Commentary couldn’t refresh. Showing the last available updates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry") { retry += 1 }
                    .buttonStyle(.bordered)
            } else if store.payload == nil {
                ProgressView("Loading commentary…")
                    .font(.footnote)
            } else if store.payload?.stale == true {
                Text("Updates may be delayed. Showing the latest available commentary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let payload = store.payload, entries.isEmpty {
                Text(importantOnly && !payload.commentary.isEmpty
                     ? "No key moments yet. Turn off the filter to see all commentary."
                     : payload.isWaitingForKickoff
                     ? "Commentary will appear here once the match starts."
                     : "Commentary isn’t available for this match yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }

            // The match screen already lazily loads this card. Keep its rows
            // eager so collapsing an offscreen history cannot retain lazy gaps.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? entries : Array(entries.prefix(10))) { line in
                    MatchCommentaryRow(line: line)
                    Divider()
                }
            }

            if entries.count > 10 {
                Button(showAll ? "Show recent updates" : "Show all \(entries.count) updates") {
                    showAll.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: showAll) { wasExpanded, isExpanded in
            if wasExpanded && !isExpanded {
                onShowRecent()
            }
        }
        .task(id: "\(matchID)|\(apiBaseURL)|\(isLive)|\(scenePhase)|\(retry)") {
            guard scenePhase == .active, let baseURL = URL(string: apiBaseURL) else { return }
            await store.follow(matchID: matchID, baseURL: baseURL)
        }
    }

    private var filterButton: some View {
        Button {
            importantOnly.toggle()
            showAll = false
        } label: {
            Label("Key moments", systemImage: importantOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .accessibilityAddTraits(importantOnly ? .isSelected : [])
    }
}

private struct MatchCommentaryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let line: MatchCommentaryLine

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Text(line.minuteText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if line.important {
                    Text("Key moment")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(line.text)
                    .font(.subheadline.weight(line.important ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityText)
    }
}

#Preview("Commentary · Dark") {
    ScrollView {
        MatchCommentaryRow(line: MatchCommentaryLine(
            id: "preview", period: 2, minute: 90, addedTime: 3, second: nil,
            type: "goal", team: "home", player: nil, relatedPlayer: nil,
            text: "Goal! The home side takes the lead in stoppage time.", important: true,
            score: .init(home: 2, away: 1)
        ))
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Commentary · Large text") {
    ScrollView {
        MatchCommentaryRow(line: MatchCommentaryLine(
            id: "preview", period: 2, minute: 90, addedTime: 3, second: nil,
            type: "shot_saved", team: "away", player: nil, relatedPlayer: nil,
            text: "Attempt saved. A right-footed shot from outside the box.", important: false,
            score: nil
        ))
        .padding()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.light)
}
