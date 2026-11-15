import SwiftUI
import Charts
import UIKit

struct MatchMomentumCard: View {
    let momentum: MatchMomentum
    let homeTeam: String
    let awayTeam: String
    let isLive: Bool
    var embedded = false
    var hideHeading = false
    @ObservedObject private var colors = TeamColorCatalog.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 24
    @State private var selectedID: String?
    @State private var plotWidth: CGFloat = 280

    private func teamColors(_ side: String) -> TeamLineupNumberColors {
        MatchAnalysisPalette.colors(side, catalog: colors, homeTeam: homeTeam, awayTeam: awayTeam, colorScheme: colorScheme)
    }

    private func description(_ annotation: MatchMomentum.Annotation) -> String {
        "\(annotation.time) \(annotation.side == "home" ? homeTeam : awayTeam) · \(annotation.label)"
    }

    var body: some View {
        if momentum.isRenderable {
            VStack(alignment: .leading, spacing: 12) {
                if !hideHeading {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Momentum").font(.headline)
                            Spacer()
                            Text("Relative pressure").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Momentum").font(.headline)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { teamLabel("home"); Spacer(minLength: 12); teamLabel("away") }
                    VStack(alignment: .leading, spacing: 6) { teamLabel("home"); teamLabel("away") }
                }
                VStack(spacing: 0) {
                    markerRow("home")
                    chart
                    markerRow("away")
                    axis
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = $0 }
                if let selected = momentum.annotations.first(where: { $0.id == selectedID }) {
                    HStack {
                        Text(description(selected)).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button { selectedID = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Close event details")
                    }
                } else {
                    Text(momentum.annotations.isEmpty ? "Above: home · Below: away" : "Select an event marker for details. Above: home · Below: away")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isLive, let updatedAt = momentum.updatedAt,
                   let date = ISO8601DateFormatter.momentum.date(from: updatedAt) {
                    Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(embedded ? 0 : 20)
            .background(.background.opacity(embedded ? 0 : 0.7), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(embedded ? 0 : 0.12), lineWidth: 1))
        }
    }

    private func teamLabel(_ side: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(teamColors(side).background)
                .overlay(Circle().stroke(teamColors(side).foreground, lineWidth: 1)).frame(width: 9, height: 9)
            Text(side == "home" ? homeTeam : awayTeam)
            Image(systemName: side == "home" ? "arrow.up" : "arrow.down").foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side == "home" ? homeTeam : awayTeam), \(side == "home" ? "above" : "below") the centre line")
    }

    private var chart: some View {
        let home = teamColors("home")
        let away = teamColors("away")
        return Chart {
            ForEach(momentum.ticks.dropFirst().dropLast(), id: \.minute) { tick in
                RuleMark(x: .value("Minute", tick.minute))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 5]))
            }
            ForEach(momentum.segments) { segment in
                ForEach(segment.points, id: \.minute) { point in
                    AreaMark(x: .value("Minute", point.minute), y: .value("Pressure", point.value),
                             series: .value("Segment", segment.id), stacking: .unstacked)
                        .foregroundStyle(segment.side == "home" ? home.background : away.background)
                        .interpolationMethod(.linear)
                    LineMark(x: .value("Minute", point.minute), y: .value("Pressure", point.value),
                             series: .value("Segment", segment.id))
                        .foregroundStyle(segment.side == "home" ? home.foreground : away.foreground)
                        .lineStyle(StrokeStyle(lineWidth: 0.7))
                        .interpolationMethod(.linear)
                }
            }
            RuleMark(y: .value("Even pressure", 0)).foregroundStyle(.secondary.opacity(0.45))
        }
        .chartXScale(domain: 0...momentum.endMinute)
        .chartYScale(domain: -momentum.scale...momentum.scale)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relative pressure. \(homeTeam) above the centre line; \(awayTeam) below. Gaps indicate missing data.")
    }

    private func markerRow(_ side: String) -> some View {
        let markers = momentum.markers(side: side, width: plotWidth)
        let lanes = (markers.map(\.lane).max() ?? -1) + 1
        return ZStack(alignment: .topLeading) {
            ForEach(markers) { marker in
                Button {
                    selectedID = selectedID == marker.id ? nil : marker.id
                } label: {
                    Text(marker.annotation.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(marker.annotation.kind == "red_card" ? Color.red : Color.primary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(selectedID == marker.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(description(marker.annotation))
                .accessibilityValue(selectedID == marker.id ? "Selected" : "")
                .position(x: marker.x, y: Double(marker.lane * 44 + 22))
            }
        }
        .frame(height: CGFloat(lanes * 44))
    }

    private var axis: some View {
        GeometryReader { proxy in
            ForEach(momentum.ticks.filter { !dynamicTypeSize.isAccessibilitySize || $0.minute != 105.5 }, id: \.minute) { tick in
                Text(tick.label).font(.caption2).foregroundStyle(.secondary)
                    .position(x: min(max(tick.minute / momentum.endMinute * proxy.size.width, 9), proxy.size.width - 9), y: axisHeight / 2)
            }
        }
        .frame(height: axisHeight)
        .padding(.top, 8)
    }

}

private extension ISO8601DateFormatter {
    static var momentum: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
