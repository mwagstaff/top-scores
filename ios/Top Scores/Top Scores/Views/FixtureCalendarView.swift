import SwiftUI

struct FixtureCalendarView: View {
    @Binding var selection: Date
    let dateRange: ClosedRange<Date>
    let availableDateKeys: Set<String>
    let competitionsByDate: [String: [FixtureCalendarCompetitionSummary]]
    let contextTitle: String
    let subscribingFeed: PersonalCalendarFeed?
    let subscriptionError: String
    let onViewMatches: () -> Void
    let onSubscribe: (PersonalCalendarFeed) -> Void
    var onLoadMonth: (Date) async throws -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var subscriptionsExpanded = false
    @State private var loadingMonths: Set<String> = []
    @State private var failedMonths: Set<String> = []
    @State private var visibleMonthID: String?
    @ScaledMetric(relativeTo: .body) private var dayHeight = 60.0

    private var background: Color {
        colorScheme == .dark ? FootballVisualStyle.pageBackground : Color(.systemGroupedBackground)
    }

    private var selectedKey: String { FixtureCalendarMonth.dateKey(for: selection) }
    private var todayDirection: ComparisonResult {
        let today = Date()
        let monthID = visibleMonthID ?? FixtureCalendarMonth.monthKey(for: selection)
        let todayMonthID = FixtureCalendarMonth.monthKey(for: today)
        if monthID != todayMonthID { return monthID.compare(todayMonthID) }
        return Calendar.current.compare(selection, to: today, toGranularity: .day)
    }
    private var selectedIndicators: FixtureCalendarIndicators {
        FixtureCalendarIndicators(competitions: competitionsByDate[selectedKey] ?? [])
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    VStack(spacing: 0) {
                        Text("Fixtures · \(contextTitle)")
                            .font(.subheadline)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                        monthList
                            .task {
                                // The lazy sections need their first layout before an
                                // initial scroll from a full-screen presentation.
                                await Task.yield()
                                reader.scrollTo(FixtureCalendarMonth.monthKey(for: selection), anchor: .top)
                            }

                        if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 600 {
                            // Separate sibling regions keep both the calendar and its actions
                            // reachable when large text or landscape cannot fit the footer.
                            ScrollView { footer }
                                .frame(maxHeight: geometry.size.height * 0.46)
                                .accessibilityIdentifier("fixtureCalendarActions")
                        } else {
                            footer
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if todayDirection != .orderedSame {
                                Button {
                                    selection = Calendar.current.startOfDay(for: Date())
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                        visibleMonthID = FixtureCalendarMonth.monthKey(for: selection)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if todayDirection == .orderedDescending {
                                            Image(systemName: "chevron.left").accessibilityHidden(true)
                                        }
                                        Text("Today")
                                        if todayDirection == .orderedAscending {
                                            Image(systemName: "chevron.right").accessibilityHidden(true)
                                        }
                                    }
                                }
                                .accessibilityLabel("Today")
                                .accessibilityValue(todayDirection == .orderedDescending ? "Jump backward" :
                                    todayDirection == .orderedAscending ? "Jump forward" : "Today selected")
                                .accessibilityIdentifier("fixtureCalendarToday")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close", systemImage: "xmark") { dismiss() }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("fixtureCalendarClose")
                        }
                    }
                }
            }
            .background(background)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
        }
        .accessibilityIdentifier("fixtureCalendarScreen")
    }

    private var monthList: some View {
        ScrollView {
            LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(FixtureCalendarMonth.months(in: dateRange)) { month in
                    Section {
                        Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                            ForEach(0..<((month.leadingEmptyDays + month.days.count + 6) / 7), id: \.self) { week in
                                GridRow {
                                    ForEach(0..<7, id: \.self) { weekday in
                                        let dayIndex = week * 7 + weekday - month.leadingEmptyDays
                                        if month.days.indices.contains(dayIndex) {
                                            dayButton(month.days[dayIndex])
                                        } else {
                                            Color.clear
                                                .frame(maxWidth: .infinity, minHeight: min(dayHeight, 80))
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                        }
                        .task { await loadMonth(month.date) }
                    } header: {
                        monthHeader(month.date)
                    }
                    .id(month.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .scrollPosition(id: $visibleMonthID, anchor: .top)
        // A seven-column grid must retain readable single-line weekdays and dates.
        // Full-size accessible date/competition descriptions remain on each button.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("fixtureCalendarMonths")
    }

    private func monthHeader(_ date: Date) -> some View {
        let calendar = Calendar.current
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(date, format: .dateTime.month(.wide).year())
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if loadingMonths.contains(FixtureCalendarMonth.monthKey(for: date)) {
                    ProgressView().accessibilityLabel("Loading matching fixtures")
                } else if failedMonths.contains(FixtureCalendarMonth.monthKey(for: date)) {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await loadMonth(date) }
                    }
                    .font(.caption)
                    .accessibilityLabel("Retry loading fixtures for \(date.formatted(.dateTime.month(.wide).year()))")
                }
            }
            .padding(.horizontal, 12)
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7].uppercased())
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func loadMonth(_ date: Date) async {
        let key = FixtureCalendarMonth.monthKey(for: date)
        guard loadingMonths.insert(key).inserted else { return }
        defer { loadingMonths.remove(key) }
        failedMonths.remove(key)
        do {
            try await onLoadMonth(date)
        } catch {
            if !Task.isCancelled { failedMonths.insert(key) }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let key = FixtureCalendarMonth.dateKey(for: date)
        let isSelected = key == selectedKey
        let isAvailable = availableDateKeys.contains(key)
        let isToday = Calendar.current.isDateInToday(date)
        let indicators = FixtureCalendarIndicators(competitions: competitionsByDate[key] ?? [])
        return Button {
            selection = date
        } label: {
            VStack(spacing: 3) {
                Text(date, format: .dateTime.day())
                    .font(.body.weight(isSelected ? .bold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? background : (isAvailable ? Color.primary : Color.secondary))
                    .frame(minWidth: 36, minHeight: 36)
                    .background {
                        if isSelected { Circle().fill(Color.primary) }
                    }
                    .overlay {
                        if isToday { Circle().stroke(Color.accentColor, lineWidth: 1.5) }
                    }
                HStack(spacing: 3) {
                    ForEach(indicators.visible) { competition in
                        competitionDot(competition)
                    }
                    if indicators.overflowCount > 0 {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 7)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: min(dayHeight, 80))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(
            (isToday ? "Today. " : "") +
            (isAvailable ? indicators.accessibilityDescription : "No matches in this view")
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("fixtureCalendarDay-\(key)")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            selectedDaySummary
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            subscriptions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(colorScheme == .dark ? FootballVisualStyle.elevatedSurface : Color(.secondarySystemGroupedBackground))
    }

    private var selectedDaySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { selectedDateLabel; Spacer(minLength: 0); viewMatchesButton }
                VStack(alignment: .leading, spacing: 8) { selectedDateLabel; viewMatchesButton }
            }
            if !selectedIndicators.competitions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(selectedIndicators.visible) { competition in
                        HStack(spacing: 6) {
                            competitionDot(competition)
                            Text("\(competition.name) (\(competition.matchCount))")
                                .font(.caption)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if selectedIndicators.overflowCount > 0 {
                        Text("+ \(selectedIndicators.overflowMatchCount) more matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !availableDateKeys.contains(selectedKey) {
                Text("No matches in this view")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedDateLabel: some View {
        Text(selection, format: .dateTime.weekday(.abbreviated).day().month(.wide))
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("fixtureCalendarSelectedDate")
    }

    private var viewMatchesButton: some View {
        Button("View matches", action: onViewMatches)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!availableDateKeys.contains(selectedKey))
            .accessibilityIdentifier("fixtureCalendarViewMatches")
    }

    private var subscriptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    subscriptionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Subscribe to Calendar").font(.subheadline.weight(.semibold))
                            Text("Match & TV calendars · 5 options")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "calendar.badge.plus").foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(subscriptionsExpanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(subscriptionsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(subscriptionsExpanded ? "Hide calendar subscriptions" : "Show calendar subscriptions")
            .accessibilityIdentifier("fixtureCalendarSubscriptions")

            if subscriptionsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    subscriptionButton(.matches)
                    Text("TV · Your competitions & channels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(PersonalCalendarFeed.allCases.filter { $0.minimumScore != nil }, id: \.self) { feed in
                        subscriptionButton(feed)
                    }
                    if !subscriptionError.isEmpty {
                        Text(subscriptionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.top, 8)
                            .accessibilityIdentifier("fixtureCalendarSubscriptionError")
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func subscriptionButton(_ feed: PersonalCalendarFeed) -> some View {
        Button {
            onSubscribe(feed)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed == .matches ? "Your matches" : feed.title)
                        .foregroundStyle(Color.primary)
                    if feed == .matches {
                        Text("Matches in your active Scores view")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if subscribingFeed == feed {
                    ProgressView().accessibilityLabel("Preparing your calendar")
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(subscribingFeed != nil)
        .accessibilityLabel("Subscribe to \(feed == .matches ? "your matches" : feed.title)")
        .accessibilityHint("Opens the subscription confirmation in Calendar")
        .accessibilityIdentifier("fixtureCalendarSubscribe-\(feed.minimumScore.map(String.init) ?? "matches")")
    }

    private func competitionDot(_ competition: FixtureCalendarCompetitionSummary) -> some View {
        Circle()
            .fill(FixtureCalendarCompetitionColor.color(competitionID: competition.id, competitionName: competition.name))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

#Preview("Calendar · Dark") {
    FixtureCalendarPreview().preferredColorScheme(.dark)
}

#Preview("Calendar · Light") {
    FixtureCalendarPreview().preferredColorScheme(.light)
}

#Preview("Calendar · Large text") {
    FixtureCalendarPreview().environment(\.dynamicTypeSize, .accessibility3)
}

private struct FixtureCalendarPreview: View {
    @State private var selection = Date()
    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .month, value: 3, to: today)!
        let keys = FixtureCalendarMonth.months(in: today...end).flatMap(\.days).map { FixtureCalendarMonth.dateKey(for: $0) }
        let competitions = [
            FixtureCalendarCompetitionSummary(id: "premier-league", name: "Premier League", matchCount: 8, weight: 100),
            FixtureCalendarCompetitionSummary(id: "la-liga", name: "La Liga", matchCount: 4, weight: 90),
            FixtureCalendarCompetitionSummary(id: "bundesliga", name: "Bundesliga", matchCount: 6, weight: 80),
        ]
        FixtureCalendarView(
            selection: $selection, dateRange: today...end, availableDateKeys: Set(keys),
            competitionsByDate: Dictionary(uniqueKeysWithValues: keys.map { ($0, competitions) }),
            contextTitle: "Top Teams", subscribingFeed: nil, subscriptionError: "",
            onViewMatches: {}, onSubscribe: { _ in }
        )
    }
}
