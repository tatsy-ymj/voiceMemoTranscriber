import SwiftUI

@main
struct VoiceMemoTranscriberApp: App {
    @StateObject private var appController = AppController()

    init() {
        if isAnotherInstanceRunning() {
            AppLogger.shared.log("Another instance detected. Terminating this launch.")
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text(appController.watching ? "Status: Watching" : "Status: Idle")
                    .font(.headline)

                Text("Folder:")
                    .font(.subheadline)
                Text(appController.watchFolderDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider()

                Button("Select Watch Folder…") {
                    appController.selectWatchFolder()
                }

                Button(appController.watching ? "Stop Watching" : "Start Watching") {
                    appController.toggleWatching()
                }
                .disabled(appController.watchFolderURL == nil)

                Button("Request Speech Permission") {
                    appController.requestSpeechPermissionManual()
                }

                Button("Open Log") {
                    appController.openLogFile()
                }

                Menu("Recent Results") {
                    if appController.recentResults.isEmpty {
                        Text("No results yet")
                    } else {
                        ForEach(appController.recentResults) { row in
                            Text(recentResultText(row))
                                .lineLimit(1)
                        }
                    }
                }

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(10)
            .frame(width: 320)
            .alert("VoiceMemoTranscriber", isPresented: $appController.showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appController.alertMessage)
            }
        } label: {
            Image(systemName: appController.watching ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return apps.contains { $0.processIdentifier != currentPID }
    }

    private func recentResultText(_ row: ProcessedStore.RecentRecord) -> String {
        let stamp = Self.recentDateFormatter.string(from: row.processedAt)
        switch row.status {
        case .success:
            return "[OK] \(stamp) \(row.fileName)"
        case .failed:
            let reason = row.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "failed"
            return "[NG] \(stamp) \(row.fileName) - \(reason)"
        }
    }

    private static let recentDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
