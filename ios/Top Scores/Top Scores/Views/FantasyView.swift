import SwiftUI
import UIKit
import Combine

struct FantasyView: View {
    let isSelected: Bool

    @AppStorage(StorageKeys.managerEntryID) private var managerEntryID = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSafariHelp = false
    @State private var showChromeHelp = false
    @State private var hasInitiatedClipboardCapture = false
    @State private var clipboardStatusMessage = ""
    @State private var lastClipboardChangeCount = UIPasteboard.general.changeCount
    @State private var showSuccessInterstitial = false

    private let clipboardPollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                if managerEntryID.isEmpty {
                    setupSection
                    safariHelpSection
                    chromeHelpSection
                } else {
                    managerSection
                    debugSection
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
            updateClipboardStatusMessage()
            if isSelected, hasInitiatedClipboardCapture {
                checkClipboardForManagerID(forceRead: true)
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected, hasInitiatedClipboardCapture {
                checkClipboardForManagerID(forceRead: true)
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard isSelected, hasInitiatedClipboardCapture, newValue == .active else { return }
            checkClipboardForManagerID(forceRead: true)
        }
        .onReceive(clipboardPollTimer) { _ in
            guard isSelected, hasInitiatedClipboardCapture, scenePhase == .active, managerEntryID.isEmpty else { return }
            checkClipboardForManagerID(forceRead: false)
        }
        .onChange(of: managerEntryID) { _, newValue in
            if newValue.isEmpty {
                hasInitiatedClipboardCapture = false
                lastClipboardChangeCount = UIPasteboard.general.changeCount
                updateClipboardStatusMessage()
            }
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
                Label("Open the Fantasy Premier League website", systemImage: "safari")
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

                    Text("These steps match the Safari flow shown in your screenshots.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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

    private var managerSection: some View {
        Section("Manager linked") {
            Text("Manager ID")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(managerEntryID)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            Text("Stored locally on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            Button("Delete stored manager ID", role: .destructive) {
                managerEntryID = ""
            }
        }
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

    private enum StorageKeys {
        static let managerEntryID = "fantasy.managerEntryID"
    }
}

#Preview {
    FantasyView(isSelected: true)
}
