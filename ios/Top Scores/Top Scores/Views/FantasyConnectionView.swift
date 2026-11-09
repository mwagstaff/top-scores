import SwiftUI

struct FantasyConnectionView: View {
    var pairingSecret: String? = nil
    @ObservedObject private var sync = FantasyPreferenceSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: FantasyBrowserPairing?
    @State private var error: String?
    @State private var approved = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                if approved {
                    Section {
                        Label("Browser connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Return to the website. Your team, rivals and saved leagues will appear automatically.")
                    }
                } else if let pairingSecret {
                    Section("Connect this browser") {
                        if loading { ProgressView("Checking the website request…") }
                        if let pairing {
                            Text("Only continue if you scanned the QR code on the browser you want to connect. Check that it shows this code:")
                            Text(pairing.code.prefix(3) + " " + pairing.code.suffix(3))
                                .font(.largeTitle.monospacedDigit().bold())
                                .accessibilityLabel("Connection code \(pairing.code.map(String.init).joined(separator: " "))")
                            Text("If the codes match, tap Connect this browser below to finish pairing.")
                            Text(pairing.mode == "merge" ? "Use your app’s team and merge the browser’s saved rivals and leagues." : "Use your app’s team, rivals and leagues on that browser.")
                            Text(pairing.once ? "Import once. The browser will remain independent." : "Future changes will sync across your connected devices.").font(.footnote)
                            Button("Connect this browser", systemImage: "link") {
                                Task {
                                    error = nil
                                    do { try await sync.connectBrowser(pairingSecret); approved = true }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(sync.busy || sync.conflict != nil || pairing.expiry < .now)
                        }
                        if error != nil && pairing == nil {
                            Button("Try again") { Task { await inspect(pairingSecret) } }.disabled(loading)
                        }
                    }
                } else {
                    Section("Start on the website") {
                        Text("On the website’s FPL page, choose Connect to app. Scan its QR code with your phone’s camera, then confirm the connection here.")
                        Text("The website imports your team, rivals and saved leagues automatically. No account or FPL password needed.").font(.footnote)
                    }
                }
                if sync.conflict != nil {
                    Section("Settings changed on another device") {
                        Text("Choose which settings to keep before connecting this browser.")
                        Button("Keep this device’s settings") { Task { await sync.resolve(useLocal: true) } }.disabled(sync.busy)
                        Button("Use synced settings") { Task { await sync.resolve(useLocal: false) } }.disabled(sync.busy)
                    }
                }
                if sync.connected && pairingSecret == nil {
                    Section("Connected devices") {
                        Text("Changes sync while FPL is open. Offline changes are kept on this device and retried when you reconnect.").font(.footnote)
                        Button("Sync now") { Task { await sync.synchronize(); await sync.loadDevices() } }.disabled(sync.busy)
                        ForEach(sync.devices) { device in
                            Button("Disconnect \(device.label)", role: .destructive) { Task { await sync.disconnect(deviceID: device.id) } }.disabled(sync.busy)
                        }
                        Button("Disconnect this device", role: .destructive) { Task { await sync.disconnect() } }.disabled(sync.busy)
                    }
                }
                if !sync.status.isEmpty { Section { Text(sync.status).font(.footnote) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(pairingSecret == nil ? "Website sync" : "Connect browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if pairingSecret != nil && !approved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }.disabled(sync.busy)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .interactiveDismissDisabled(sync.busy)
            .task {
                if let pairingSecret { await inspect(pairingSecret) }
                else { await sync.loadDevices() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func inspect(_ secret: String) async {
        loading = true; error = nil
        defer { loading = false }
        do { pairing = try await sync.inspectBrowser(secret) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
