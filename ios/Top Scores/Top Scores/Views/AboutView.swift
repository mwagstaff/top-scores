import SwiftUI
#if DEBUG
import UserNotifications
#endif

struct AboutView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    #if DEBUG
    @State private var diagnostics = DebugDiagnosticsState()
    @State private var isLoadingDiagnostics = false
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "sportscourt")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                        Text("Top Scores")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Your personalized TV guide for football matches.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                #if DEBUG
                Section {
                    if isLoadingDiagnostics {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Refreshing diagnostics...")
                                .foregroundStyle(.secondary)
                        }
                    }
                    diagnosticsRow(title: "Device token", value: diagnostics.deviceToken)
                    diagnosticsRow(title: "Server device token", value: diagnostics.serverDeviceToken ?? "Unknown")
                    diagnosticsRow(title: "Local APNS token", value: diagnostics.localAPNSToken ?? "None")
                    diagnosticsRow(title: "Server APNS token", value: diagnostics.serverAPNSToken ?? "None")
                    diagnosticsRow(title: "Token match", value: diagnostics.tokenMatch)
                    diagnosticsRow(title: "Push auth status", value: diagnostics.pushAuthStatus)
                    diagnosticsRow(title: "Build environment", value: diagnostics.localBuildEnvironment)
                    diagnosticsRow(title: "Server build environment", value: diagnostics.serverBuildEnvironment)
                    diagnosticsRow(title: "API base URL", value: preferences.apiBaseURL)
                    diagnosticsRow(title: "Last sync attempt", value: diagnostics.lastSyncAttempt)
                    diagnosticsRow(title: "Last sync success", value: diagnostics.lastSyncSuccess)
                    diagnosticsRow(title: "Last sync failure", value: diagnostics.lastSyncFailure)
                    diagnosticsRow(
                        title: "Last sync HTTP status",
                        value: diagnostics.lastSyncHTTPStatus.map(String.init) ?? "N/A"
                    )
                    diagnosticsRow(title: "Last sync failure reason", value: diagnostics.lastSyncFailureReason ?? "None")
                    diagnosticsRow(title: "Server record updated at", value: diagnostics.serverRecordUpdatedAt ?? "Unknown")

                    HStack {
                        Button("Refresh diagnostics") {
                            Task { await refreshDiagnostics() }
                        }
                        Spacer()
                        Button("Sync preferences now") {
                            Task {
                                await PreferencesSyncService.shared.syncPreferences(preferences.snapshot)
                                await refreshDiagnostics()
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Debug Diagnostics")
                        Spacer()
                        Text("DEBUG")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                #endif
            }
            .navigationTitle("About")
            .toolbarTitleDisplayMode(.inline)
            #if DEBUG
            .task {
                await refreshDiagnostics()
            }
            #endif
        }
    }

    #if DEBUG
    private func diagnosticsRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func refreshDiagnostics() async {
        isLoadingDiagnostics = true
        await NotificationManager.shared.checkAuthorizationStatus()

        let localAPNSToken = NotificationManager.shared.currentAPNSToken
        let pushStatus = displayAuthorizationStatus(NotificationManager.shared.authorizationStatus)
        let localBuild = NotificationManager.shared.isDevelopmentBuild ? "Development (sandbox APNS)" : "Production (live APNS)"
        let syncDiagnostics = await PreferencesSyncService.shared.diagnostics()
        let serverDiagnostics = await fetchServerDiagnostics(
            baseURL: preferences.apiBaseURL,
            deviceToken: DeviceIdentity.currentToken
        )

        diagnostics = DebugDiagnosticsState(
            deviceToken: DeviceIdentity.currentToken,
            serverDeviceToken: serverDiagnostics?.deviceToken,
            localAPNSToken: localAPNSToken,
            serverAPNSToken: serverDiagnostics?.apnsToken,
            tokenMatch: tokenMatchLabel(
                deviceToken: DeviceIdentity.currentToken,
                serverDeviceToken: serverDiagnostics?.deviceToken,
                apnsToken: localAPNSToken,
                serverAPNSToken: serverDiagnostics?.apnsToken
            ),
            pushAuthStatus: pushStatus,
            localBuildEnvironment: localBuild,
            serverBuildEnvironment: serverBuildLabel(serverDiagnostics?.isDevelopmentBuild),
            lastSyncAttempt: displayDate(syncDiagnostics.lastSyncAttempt),
            lastSyncSuccess: displayDate(syncDiagnostics.lastSyncSuccess),
            lastSyncFailure: displayDate(syncDiagnostics.lastSyncFailure),
            lastSyncHTTPStatus: syncDiagnostics.lastSyncHTTPStatus,
            lastSyncFailureReason: syncDiagnostics.lastSyncFailureReason,
            serverRecordUpdatedAt: serverDiagnostics?.updatedAt
        )
        isLoadingDiagnostics = false
    }

    private func fetchServerDiagnostics(baseURL: String, deviceToken: String) async -> ServerPreferencesRecord? {
        guard let root = URL(string: baseURL) else { return nil }
        let endpoint = root.appendingPathComponent("preferences").appendingPathComponent(deviceToken)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        DeviceIdentity.applyHeader(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(ServerPreferencesEnvelope.self, from: data)
            return payload.data
        } catch {
            return nil
        }
    }

    private func displayAuthorizationStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private func serverBuildLabel(_ isDevelopmentBuild: Bool?) -> String {
        switch isDevelopmentBuild {
        case .some(true):
            return "Development (sandbox APNS)"
        case .some(false):
            return "Production (live APNS)"
        case .none:
            return "Unknown"
        }
    }

    private func tokenMatchLabel(
        deviceToken: String,
        serverDeviceToken: String?,
        apnsToken: String?,
        serverAPNSToken: String?
    ) -> String {
        if serverDeviceToken == nil && serverAPNSToken == nil {
            return "Unknown"
        }
        let deviceMatch = serverDeviceToken == deviceToken
        let apnsMatch: Bool
        if let apnsToken, let serverAPNSToken {
            apnsMatch = apnsToken == serverAPNSToken
        } else {
            apnsMatch = false
        }

        if deviceMatch && apnsMatch {
            return "Match"
        }
        if deviceMatch || apnsMatch {
            return "Partial match"
        }
        return "Mismatch"
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return Self.diagnosticsDateFormatter.string(from: date)
    }

    private static let diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private struct DebugDiagnosticsState {
        var deviceToken: String = DeviceIdentity.currentToken
        var serverDeviceToken: String?
        var localAPNSToken: String?
        var serverAPNSToken: String?
        var tokenMatch: String = "Unknown"
        var pushAuthStatus: String = "notDetermined"
        var localBuildEnvironment: String = "Unknown"
        var serverBuildEnvironment: String = "Unknown"
        var lastSyncAttempt: String = "Never"
        var lastSyncSuccess: String = "Never"
        var lastSyncFailure: String = "Never"
        var lastSyncHTTPStatus: Int?
        var lastSyncFailureReason: String?
        var serverRecordUpdatedAt: String?
    }

    private struct ServerPreferencesEnvelope: Decodable {
        let data: ServerPreferencesRecord?
    }

    private struct ServerPreferencesRecord: Decodable {
        let deviceToken: String?
        let apnsToken: String?
        let isDevelopmentBuild: Bool?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case deviceToken
            case apnsToken
            case isDevelopmentBuild
            case updatedAt
        }
    }
    #endif
}

#Preview {
    AboutView()
        .environmentObject(PreferencesStore())
}
