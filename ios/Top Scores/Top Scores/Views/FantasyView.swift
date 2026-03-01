import SwiftUI
import UIKit
import Combine

struct FantasyView: View {
    let isSelected: Bool

    @EnvironmentObject private var preferences: PreferencesStore
    @AppStorage(StorageKeys.managerEntryID) private var managerEntryID = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var fantasyViewModel = FantasyViewModel()

    @State private var showSafariHelp = false
    @State private var showChromeHelp = false
    @State private var hasInitiatedClipboardCapture = false
    @State private var clipboardStatusMessage = ""
    @State private var lastClipboardChangeCount = UIPasteboard.general.changeCount
    @State private var showSuccessInterstitial = false

    private let clipboardPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let fantasyRefreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if managerEntryID.isEmpty {
                    setupFlowView
                } else {
                    linkedFantasyView
                }
            }
            .navigationTitle("Fantasy Football")
            .toolbarTitleDisplayMode(.inline)
        }
        .overlay {
            if showSuccessInterstitial {
                successOverlay
            }
        }
        .onAppear {
            if managerEntryID.isEmpty {
                updateClipboardStatusMessage()
                if isSelected, hasInitiatedClipboardCapture {
                    checkClipboardForManagerID(forceRead: true)
                }
            } else {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
        }
        .onChange(of: isSelected) { _, selected in
            guard selected else { return }
            if managerEntryID.isEmpty {
                if hasInitiatedClipboardCapture {
                    checkClipboardForManagerID(forceRead: true)
                }
            } else {
                triggerFantasyRefresh(force: fantasyViewModel.data == nil)
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard isSelected, newValue == .active else { return }
            if managerEntryID.isEmpty {
                guard hasInitiatedClipboardCapture else { return }
                checkClipboardForManagerID(forceRead: true)
            } else {
                triggerFantasyRefresh(force: false)
            }
        }
        .onChange(of: managerEntryID) { _, newValue in
            if newValue.isEmpty {
                hasInitiatedClipboardCapture = false
                lastClipboardChangeCount = UIPasteboard.general.changeCount
                fantasyViewModel.reset()
                updateClipboardStatusMessage()
            } else {
                triggerFantasyRefresh(force: true)
            }
        }
        .onChange(of: preferences.apiBaseURL) { _, _ in
            guard !managerEntryID.isEmpty else { return }
            triggerFantasyRefresh(force: true)
        }
        .onReceive(clipboardPollTimer) { _ in
            guard isSelected,
                  hasInitiatedClipboardCapture,
                  scenePhase == .active,
                  managerEntryID.isEmpty else { return }
            checkClipboardForManagerID(forceRead: false)
        }
        .onReceive(fantasyRefreshTimer) { _ in
            guard isSelected,
                  scenePhase == .active,
                  !managerEntryID.isEmpty else { return }
            triggerFantasyRefresh(force: false)
        }
    }

    private var setupFlowView: some View {
        Form {
            setupSection
            safariHelpSection
            chromeHelpSection
            clipboardStatusSection
        }
    }

    private var linkedFantasyView: some View {
        ScrollView {
            VStack(spacing: 12) {
                if fantasyViewModel.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing Fantasy score...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }

                if let data = fantasyViewModel.data {
                    scoreSummaryCard(data)
                    pitchSection(data)
                    benchSection(data)
                } else if fantasyViewModel.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Fantasy score...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }

                if let errorMessage = fantasyViewModel.errorMessage {
                    errorCard(errorMessage)
                }

                managerMetadataCard
                debugCard

                if let data = fantasyViewModel.data {
                    summaryStatsSection(data)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL
            )
        }
    }

    private var setupSection: some View {
        Section("Connect your Fantasy account") {
            instructionStep(number: 1, text: "Open the Fantasy Premier League website using the link below")
            instructionStep(number: 2, text: "Sign in to your account, and tap the Points tab.")
            instructionStep(number: 3, text: "Copy the website address, return to this app and tap \"Allow Paste\".")

            Button {
                openFantasyLogin()
            } label: {
                Label("Open fantasy.premierleague.com", systemImage: "safari")
            }
        }
    }

    private var safariHelpSection: some View {
        Section {
            DisclosureGroup("How to do this in Safari", isExpanded: $showSafariHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    browserStepCard(
                        step: 1,
                        title: "Tap the 3 dots button",
                        detail: "Use the bottom-right menu button in Safari.",
                        symbol: "ellipsis.circle.fill"
                    )

                    browserStepCard(
                        step: 2,
                        title: "Tap Share",
                        detail: "Select Share from the menu that opens.",
                        symbol: "square.and.arrow.up.fill"
                    )

                    browserStepCard(
                        step: 3,
                        title: "Tap Copy",
                        detail: "Copy the URL, then return to Top Scores.",
                        symbol: "doc.on.doc.fill"
                    )
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var chromeHelpSection: some View {
        Section {
            DisclosureGroup("How to do this in Chrome", isExpanded: $showChromeHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    browserStepCard(
                        step: 1,
                        title: "Tap the Share button",
                        detail: "Tap the Share button in the top right-hand corner, at the end of the address bar.",
                        symbol: "square.and.arrow.up.fill"
                    )

                    browserStepCard(
                        step: 2,
                        title: "Tap Copy",
                        detail: "Copy the website address, then return to Top Scores.",
                        symbol: "doc.on.doc.fill"
                    )
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var clipboardStatusSection: some View {
        Section("Clipboard status") {
            if !hasInitiatedClipboardCapture && managerEntryID.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(clipboardStatusMessage)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(clipboardStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var managerMetadataCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manager ID")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(managerEntryID)
                .font(.headline.monospacedDigit())
                .textSelection(.enabled)

            if let lastUpdated = fantasyViewModel.lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: lastUpdated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Delete stored manager ID", role: .destructive) {
                managerEntryID = ""
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func scoreSummaryCard(_ data: FantasySquadDisplayData) -> some View {
        let currentScore = data.hasActiveFixtures ? data.computedAppliedPointsTotal : data.totalPoints

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.gameweekTitle)
                    .font(.headline)
                Text("Current gameweek score")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                VStack(spacing: 0) {
                    Text("\(currentScore)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(.label))
                    Text("PTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(.label).opacity(0.86))
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 110, height: 72)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func summaryStatsSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gameweek stats")
                .font(.headline)

            HStack(spacing: 8) {
                summaryPill(title: "GW Rank", value: formatNumber(data.rank))
                summaryPill(title: "Overall", value: formatNumber(data.overallRank))
                summaryPill(title: "Bench", value: formatNumber(data.pointsOnBench))
                summaryPill(title: "TCost", value: formatNumber(data.transfersCost))
            }
        }
    }

    private func pitchSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pitch")
                .font(.headline)

            ZStack {
                FantasyPitchBackground()

                VStack(spacing: 8) {
                    positionRow(data.goalkeepers)
                    positionRow(data.defenders)
                    positionRow(data.midfielders)
                    positionRow(data.forwards)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .frame(height: 470)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func positionRow(_ players: [FantasyDisplayPlayer]) -> some View {
        GeometryReader { proxy in
            let count = max(players.count, 1)
            let spacing: CGFloat = 4
            let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
            let cardWidth = min(68, max(42, floor(availableWidth / CGFloat(count))))

            HStack(spacing: spacing) {
                ForEach(players) { player in
                    FantasyPlayerCard(player: player, width: cardWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 90)
    }

    private func benchSection(_ data: FantasySquadDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bench")
                .font(.headline)

            GeometryReader { proxy in
                let count = max(data.bench.count, 1)
                let spacing: CGFloat = 5
                let availableWidth = proxy.size.width - (CGFloat(count - 1) * spacing)
                let cardWidth = min(70, max(44, floor(availableWidth / CGFloat(count))))

                HStack(spacing: spacing) {
                    ForEach(data.bench) { player in
                        FantasyPlayerCard(player: player, width: cardWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 104)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fantasy data unavailable")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Retry now") {
                triggerFantasyRefresh(force: true)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var successOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.green)
                Text("Manager ID saved")
                    .font(.headline)
                Text(managerEntryID)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showSuccessInterstitial)
    }

    private func triggerFantasyRefresh(force: Bool) {
        guard !managerEntryID.isEmpty else { return }
        guard isSelected else { return }
        guard scenePhase == .active else { return }
        if !force, (fantasyViewModel.isLoading || fantasyViewModel.isRefreshing) {
            return
        }

        Task {
            await fantasyViewModel.refresh(
                managerEntryID: managerEntryID,
                apiBaseURL: preferences.apiBaseURL
            )
        }
    }

    private func instructionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(text)
        }
        .font(.subheadline)
    }

    private func browserStepCard(step: Int, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step): \(title)")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func openFantasyLogin() {
        guard let url = URL(string: "https://fantasy.premierleague.com/") else { return }
        hasInitiatedClipboardCapture = true
        openURL(url)
        clipboardStatusMessage = "After copying your Points URL, return here and tap \"Allow Paste\"."
    }

    private func checkClipboardForManagerID(forceRead: Bool) {
        guard managerEntryID.isEmpty else { return }

        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        if !forceRead, currentChangeCount == lastClipboardChangeCount {
            return
        }

        lastClipboardChangeCount = currentChangeCount

        guard let clipboardText = clipboardText(from: pasteboard) else {
            clipboardStatusMessage = "Clipboard is empty. Copy your Fantasy Points URL first."
            return
        }

        guard let parsedID = FantasyManagerIDParser.parse(from: clipboardText) else {
            clipboardStatusMessage = "No manager ID found yet. Make sure you copied the URL from the Points page."
            return
        }

        managerEntryID = parsedID
        clipboardStatusMessage = "Manager ID captured from clipboard."
        showSuccessInterstitial = true

        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation {
                showSuccessInterstitial = false
            }
        }
    }

    private func clipboardText(from pasteboard: UIPasteboard) -> String? {
        if let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }

        if let url = pasteboard.url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return url
        }

        return nil
    }

    private func updateClipboardStatusMessage() {
        if managerEntryID.isEmpty, !hasInitiatedClipboardCapture {
            clipboardStatusMessage = "Waiting for Fantasy Football address..."
            return
        }

        if managerEntryID.isEmpty {
            clipboardStatusMessage = "Copy your Points URL, return to this screen, and tap \"Allow Paste\"."
        }
    }

    private func formatNumber(_ value: Int?) -> String {
        guard let value else { return "-" }
        return Self.integerFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private enum StorageKeys {
        static let managerEntryID = "fantasy.managerEntryID"
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct FantasyPitchBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.00, green: 0.67, blue: 0.34), Color(red: 0.00, green: 0.52, blue: 0.27)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let inset: CGFloat = 14

                    let pitchRect = CGRect(
                        x: inset,
                        y: inset,
                        width: width - (inset * 2),
                        height: height - (inset * 2)
                    )

                    path.addRoundedRect(in: pitchRect, cornerSize: CGSize(width: 8, height: 8))

                    let halfwayY = pitchRect.midY
                    path.move(to: CGPoint(x: pitchRect.minX, y: halfwayY))
                    path.addLine(to: CGPoint(x: pitchRect.maxX, y: halfwayY))

                    let centerCircleRadius: CGFloat = min(58, width * 0.16)
                    path.addEllipse(
                        in: CGRect(
                            x: pitchRect.midX - centerCircleRadius,
                            y: halfwayY - centerCircleRadius,
                            width: centerCircleRadius * 2,
                            height: centerCircleRadius * 2
                        )
                    )

                    let penaltyWidth = pitchRect.width * 0.52
                    let penaltyDepth = pitchRect.height * 0.17
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.minY,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (penaltyWidth / 2),
                            y: pitchRect.maxY - penaltyDepth,
                            width: penaltyWidth,
                            height: penaltyDepth
                        )
                    )

                    let sixYardWidth = penaltyWidth * 0.48
                    let sixYardDepth = penaltyDepth * 0.46
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.minY,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                    path.addRect(
                        CGRect(
                            x: pitchRect.midX - (sixYardWidth / 2),
                            y: pitchRect.maxY - sixYardDepth,
                            width: sixYardWidth,
                            height: sixYardDepth
                        )
                    )
                }
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
            }
        }
    }
}

private struct FantasyPlayerCard: View {
    let player: FantasyDisplayPlayer
    let width: CGFloat

    private var logoImage: UIImage? {
        LogoResolver.shared.image(for: player.teamName)
    }

    private var pointsBackground: AnyShapeStyle {
        if player.isUnavailable {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.62, green: 0.62, blue: 0.66), Color(red: 0.46, green: 0.46, blue: 0.50)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        if player.isPlayingNow {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.95, green: 0.20, blue: 0.66), Color(red: 1.0, green: 0.29, blue: 0.29)],
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        return AnyShapeStyle(Color(red: 0.20, green: 0.03, blue: 0.28))
    }

    private var nameBackgroundColor: Color {
        if player.isUnavailable {
            return Color(red: 0.90, green: 0.90, blue: 0.92)
        }
        return .white
    }

    private var primaryTextColor: Color {
        player.isUnavailable ? Color.gray.opacity(0.9) : .black
    }

    private var pointsForegroundColor: Color {
        if player.isUnavailable {
            return Color.white.opacity(0.82)
        }
        return .white
    }

    var body: some View {
        let crestContainerSize = max(22, min(width * 0.48, 32))
        let crestImageSize = crestContainerSize * 0.78

        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.46, blue: 0.26).opacity(0.94))

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: crestContainerSize, height: crestContainerSize)

                    if let logoImage {
                        Image(uiImage: logoImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: crestImageSize, height: crestImageSize)
                    } else {
                        Image(systemName: "person.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.gray.opacity(0.8))
                            .frame(width: crestImageSize * 0.62, height: crestImageSize * 0.62)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 4)

                if player.isUnavailable {
                    HStack(spacing: 0) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.orange)
                        Spacer(minLength: 0)
                    }
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                HStack(spacing: 4) {
                    if player.isCaptain {
                        badge(text: "C", color: .yellow)
                    }
                    if player.isViceCaptain {
                        badge(text: "V", color: .cyan)
                    }
                    if player.multiplier > 1 {
                        badge(text: "x\(player.multiplier)", color: .mint)
                    }
                }
                .padding(3)
            }
            .frame(width: width, height: 46)

            VStack(spacing: 2) {
                Text(player.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(primaryTextColor)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(width: width)
            .background(nameBackgroundColor)

            Text(player.upcomingOpponentDisplay ?? "\(player.displayPoints)")
                .font(
                    player.upcomingOpponentDisplay == nil
                    ? .system(size: 10, weight: .bold, design: .rounded)
                    : .system(size: 8, weight: .semibold, design: .rounded)
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(pointsForegroundColor)
                .frame(width: width)
                .padding(.vertical, 3)
                .background(pointsBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.95))
            )
            .foregroundStyle(.black.opacity(0.8))
    }
}

#Preview {
    FantasyView(isSelected: true)
        .environmentObject(PreferencesStore())
}
