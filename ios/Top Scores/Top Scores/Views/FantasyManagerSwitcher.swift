import SwiftUI

/// Manager identity and live points share one stable, horizontally scrolling row.
struct FantasyManagerSwitcher: View {
    let entries: [FantasyLeagueTableEntry]
    let selectedEntryID: Int?
    let gameweekID: Int?
    let staleEntryIDs: Set<Int>
    let select: (Int) -> Void
    let addRival: () -> Void

    @ScaledMetric(relativeTo: .caption) private var scaledBadgeSize = 56.0
    private var badgeSize: CGFloat { min(scaledBadgeSize, 76) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(entries) { entry in
                            managerButton(entry)
                                .id(entry.entryID)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 9)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: entries.map(\.entryID)) { _, _ in
                    if let selectedEntryID { proxy.scrollTo(selectedEntryID, anchor: .center) }
                }
                .onChange(of: selectedEntryID) { _, entryID in
                    if let entryID {
                        proxy.scrollTo(entryID, anchor: .center)
                    }
                }
            }

            Button(action: addRival) {
                VStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .frame(width: badgeSize, height: badgeSize)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    Text("Add")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.top, 9)
                .padding(.leading, 10)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(FantasyManagerPillButtonStyle())
            .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1) }
            .accessibilityLabel("Add rival")
        }
    }

    private func managerButton(_ entry: FantasyLeagueTableEntry) -> some View {
        let selected = entry.entryID == selectedEntryID
        let initials = fantasyManagerInitials(entry.managerName)
        let stale = staleEntryIDs.contains(entry.entryID) && displayedScore(entry) != nil
        return Button { select(entry.entryID) } label: {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(.secondarySystemGroupedBackground))
                    badge(entry)
                }
                .frame(width: badgeSize, height: badgeSize)
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .overlay {
                    if selected {
                        Circle().stroke(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text(displayedScore(entry).map(String.init) ?? "—")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(stale ? Color.yellow : Color(.label), in: Capsule())
                        .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
                        .fixedSize()
                        .offset(x: 7, y: -5)
                }
                Text(initials)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .frame(minWidth: badgeSize + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(FantasyManagerPillButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.managerName), \(entry.teamName)\(entry.isUser ? ", your team" : "")")
        .accessibilityValue(scoreAccessibilityValue(entry, stale: stale))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Shows this manager’s team")
    }

    @ViewBuilder
    private func badge(_ entry: FantasyLeagueTableEntry) -> some View {
        if let source = entry.clubBadgeSrc, let url = URL(string: source) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        .frame(width: badgeSize, height: badgeSize)
                        .clipShape(Circle())
                } else {
                    fallbackBadge(entry.entryID)
                }
            }
        } else {
            fallbackBadge(entry.entryID)
        }
    }

    private func fallbackBadge(_ entryID: Int) -> some View {
        let hue = Double((entryID.magnitude &* 137) % 360) / 360
        return Circle()
            .fill(Color(hue: hue, saturation: 0.4, brightness: 0.45))
            .overlay {
                Image(systemName: "tshirt.fill")
                    .font(.system(size: badgeSize * 0.42))
                    .foregroundStyle(Color(hue: hue, saturation: 0.22, brightness: 0.95))
            }
    }

    private func displayedScore(_ entry: FantasyLeagueTableEntry) -> Int? {
        entry.squad?.scorePhase == .expected ? nil : entry.currentGameweekScore
    }

    private func scoreAccessibilityValue(_ entry: FantasyLeagueTableEntry, stale: Bool) -> String {
        let week = gameweekID.map { "Gameweek \($0), " } ?? ""
        let score = displayedScore(entry).map { "\($0) points" } ?? "Score unavailable"
        return week + score + (stale ? ", saved score, refreshing" : "")
    }
}

private struct FantasyManagerPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

func fantasyManagerInitials(_ name: String) -> String {
    let parts = name.split { $0.isWhitespace || $0 == "-" }
    guard !parts.isEmpty else { return "?" }
    if parts.count == 1 {
        return String(parts[0].prefix(2)).uppercased()
    }
    return parts.prefix(3).compactMap(\.first).map(String.init).joined().uppercased()
}

func fantasyManagerSwitcherEntries(
    _ entries: [FantasyLeagueTableEntry],
    rivalEntryIDs: [Int]
) -> [FantasyLeagueTableEntry] {
    let ownTeam = entries.filter(\.isUser)
    var seen = Set(ownTeam.map(\.entryID))
    let rivals: [FantasyLeagueTableEntry] = rivalEntryIDs.compactMap { entryID in
        guard seen.insert(entryID).inserted else { return nil }
        return entries.first { $0.entryID == entryID && !$0.isUser }
    }
    let savedOrder = Dictionary(uniqueKeysWithValues: rivals.enumerated().map { ($0.element.entryID, $0.offset) })
    return ownTeam + rivals.sorted { lhs, rhs in
        let left = lhs.currentGameweekScore
        let right = rhs.currentGameweekScore
        if left != right {
            if let left, let right { return left > right }
            return left != nil
        }
        return savedOrder[lhs.entryID, default: 0] < savedOrder[rhs.entryID, default: 0]
    }
}
