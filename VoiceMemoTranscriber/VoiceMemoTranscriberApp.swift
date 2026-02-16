import SwiftUI

@main
struct VoiceMemoTranscriberApp: App {
    @StateObject private var appController = AppController()

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
}
