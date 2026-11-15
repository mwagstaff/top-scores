import SwiftUI

struct MatchAnalysisCard: View {
    let momentum: MatchMomentum?
    let stats: MatchStats?
    let homeTeam: String
    let awayTeam: String
    let isLive: Bool
    var refreshFailed = false
    @ScaledMetric(relativeTo: .subheadline) private var valueWidth: CGFloat = 72
    @State private var showStats = false
    @State private var periodID = "all"
    @State private var expanded = false
    @ObservedObject private var colors = TeamColorCatalog.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasMomentum: Bool { momentum?.isRenderable == true }
    private var showingStats: Bool { showStats || !hasMomentum }
    private var periods: [MatchStats.Period] { stats?.availablePeriods ?? [] }
    private var period: MatchStats.Period? { periods.first { $0.id == periodID } ?? periods.first }
    private var summary: [MatchStats.Row] { stats?.summaryRows ?? [] }
    private var visibleRows: [MatchStats.Row] {
        let all = period?.rows ?? []
        let key = all.filter(\.headline)
        return expanded || key.isEmpty ? all : key
    }
    private func color(_ side: String) -> Color {
        MatchAnalysisPalette.colors(side, catalog: colors, homeTeam: homeTeam, awayTeam: awayTeam, colorScheme: colorScheme).background
    }

    var body: some View {
        if hasMomentum || stats != nil {
            VStack(alignment: .leading, spacing: 12) {
                if hasMomentum, stats != nil {
                    Picker("Match analysis", selection: $showStats) {
                        Text("Momentum").tag(false)
                        Text("Match stats").tag(true)
                    }
                    .pickerStyle(.segmented)
                } else if showingStats {
                    Text("Match stats").font(.headline)
                }
                if !showingStats, let momentum {
                    MatchMomentumCard(momentum: momentum, homeTeam: homeTeam, awayTeam: awayTeam,
                                      isLive: isLive && stats == nil, embedded: true, hideHeading: stats != nil)
                    if !summary.isEmpty {
                        Divider()
                        ForEach(summary) { row($0, bars: false) }
                        Button { showStats = true } label: {
                            Text("View match stats →").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                } else {
                    if periods.count > 1 {
                        Picker("Statistics period", selection: Binding(get: { period?.id ?? "all" }, set: { periodID = $0 })) {
                            ForEach(periods) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if periods.count == 1, let period, period.id != "all" {
                        Text(period.label).font(.caption).foregroundStyle(.secondary)
                    }
                    if let period {
                        ViewThatFits(in: .horizontal) {
                            HStack { team(homeTeam, side: "home"); Spacer(); team(awayTeam, side: "away") }
                            VStack(alignment: .leading, spacing: 6) { team(homeTeam, side: "home"); team(awayTeam, side: "away") }
                        }
                        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, stat in
                            if expanded && !stat.headline && (index == 0 || visibleRows[index - 1].group != stat.group) {
                                Divider().padding(.top, 8)
                                Text(stat.group).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            row(stat)
                        }
                        if period.rows.contains(where: { !$0.headline }) && period.rows.contains(where: \.headline) {
                            Divider()
                            Button { expanded.toggle() } label: {
                                HStack {
                                    Text(expanded ? "Show key stats" : "Show all stats")
                                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                }
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                        }
                        if period.rows.contains(where: { $0.home == nil || $0.away == nil }) {
                            Text("— Not available").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(stats?.status == "pending" ? "Waiting for match stats." : "Match stats aren’t available for this match.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if (showingStats ? visibleRows : summary).contains(where: { $0.homeEstimated || $0.awayEstimated }) {
                    Text("est. = estimated xG").font(.caption).foregroundStyle(.secondary)
                }
                if !periods.isEmpty {
                    if refreshFailed || (isLive && (stats?.updatedDate.map { Date().timeIntervalSince($0) > 180 } ?? false)) {
                        Text("Showing the last available stats.").font(.caption).foregroundStyle(.secondary)
                    }
                    if isLive, let date = stats?.updatedDate {
                        Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private func team(_ name: String, side: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(side)).frame(width: 9, height: 9)
            Text(name)
        }.font(.caption)
    }

    private func row(_ stat: MatchStats.Row, bars: Bool = true) -> some View {
        VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(stat.label).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                HStack(alignment: .top) {
                    Text(stat.display(home: true)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(stat.display(home: false)).frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.subheadline.weight(.semibold)).monospacedDigit()
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(stat.display(home: true)).fontWeight(.semibold).frame(width: valueWidth, alignment: .leading)
                    Text(stat.label).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Text(stat.display(home: false)).fontWeight(.semibold).multilineTextAlignment(.trailing).frame(width: valueWidth, alignment: .trailing)
                }.font(.subheadline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            if bars {
                GeometryReader { proxy in
                    if let share = stat.homeShare {
                        HStack(spacing: 3) {
                            Capsule().fill(color("home")).frame(width: max(0, proxy.size.width - 3) * share)
                            Capsule().fill(color("away")).frame(width: max(0, proxy.size.width - 3) * (1 - share))
                        }
                    } else {
                        Capsule().fill(.secondary.opacity(0.15))
                    }
                }.frame(height: 4).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.label): \(homeTeam) \(stat.home == nil ? "not available" : stat.display(home: true)), \(awayTeam) \(stat.away == nil ? "not available" : stat.display(home: false))")
    }
}
