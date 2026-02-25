import AppKit
import Combine
import Foundation

final class AppController: ObservableObject {
    @Published var watching = false
    @Published var showAlert = false
    @Published var alertMessage = ""
    @Published private(set) var recentResults: [ProcessedStore.RecentRecord] = []

    private let logger = AppLogger.shared
    private let speechTranscriber = SpeechTranscriber(localeIdentifier: AppConstants.defaultLocale)
    private let notesService = NotesService()
    private let processedStore = ProcessedStore()

    private var watcher: DirectoryWatcher?
    private var openPanel: NSOpenPanel?
    private let processingQueue = DispatchQueue(label: "voice.memo.transcriber.processing")
    private var queuedPaths: [String] = []
    private var queuedSet: Set<String> = []
    private var knownPaths: Set<String> = []
    private var isProcessing = false
    private var activeSecurityScopedURL: URL?

    @Published private(set) var watchFolderURL: URL?

    var watchFolderDisplay: String {
        watchFolderURL?.path ?? "(not selected)"
    }

    init() {
        restoreWatchFolderBookmark()
        refreshRecentResults()
        logger.log("App launched")
    }

    deinit {
        stopSecurityScopedAccess()
    }

    func selectWatchFolder() {
        DispatchQueue.main.async {
            if self.openPanel != nil { return }

            NSApp.activate(ignoringOtherApps: true)

            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Select"
            panel.directoryURL = self.watchFolderURL ?? self.defaultVoiceMemosRecordingsFolderIfExists()

            self.openPanel = panel
            panel.begin { [weak self] response in
                guard let self else { return }
                defer { self.openPanel = nil }

                if response == .OK, let url = panel.url {
                    self.stopSecurityScopedAccess()
                    self.watchFolderURL = url
                    self.persistWatchFolderBookmark(url)
                    self.logger.log("Selected watch folder: \(url.path)")
                }
            }
        }
    }

    private func defaultVoiceMemosRecordingsFolderIfExists() -> URL? {
        let path = ("~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings" as NSString)
            .expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func toggleWatching() {
        if watching {
            stopWatching()
        } else {
            startWatching()
        }
    }

    func requestSpeechPermissionManual() {
        Task {
            let granted = await speechTranscriber.requestAuthorization()
            if granted {
                logger.log("Speech permission granted")
                await MainActor.run {
                    self.showTransientAlert("Speech recognition permission is granted.")
                }
            } else {
                logger.error("Speech permission denied")
                await MainActor.run {
                    self.showTransientAlert("Speech recognition permission is denied. Open System Settings > Privacy & Security > Speech Recognition.")
                }
            }
        }
    }

    func openLogFile() {
        NSWorkspace.shared.open(AppLogger.shared.logFileURL)
    }

    func editNoteTemplate() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Edit Note Format"
            alert.informativeText = "Available placeholders: {date} {time} {transcribed_text} {original_audio} {filename}"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Reset Default")
            alert.addButton(withTitle: "Cancel")

            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 170)
            guard let textView = scroll.documentView as? NSTextView else {
                self.showTransientAlert("Failed to open note format editor.")
                return
            }
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = self.currentNoteTemplate()
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            alert.accessoryView = scroll

            NSApp.activate(ignoringOtherApps: true)
            let alertWindow = alert.window
            alertWindow.initialFirstResponder = textView
            alertWindow.makeFirstResponder(textView)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let edited = textView.string.trimmingCharacters(in: .newlines)
                guard !edited.isEmpty else {
                    self.showTransientAlert("Note format cannot be empty.")
                    return
                }
                UserDefaults.standard.set(edited, forKey: AppConstants.noteTemplateKey)
                self.logger.log("Updated note format template.")
            } else if response == .alertSecondButtonReturn {
                UserDefaults.standard.set(AppConstants.defaultNoteTemplate, forKey: AppConstants.noteTemplateKey)
                self.logger.log("Reset note format template to default.")
                self.showTransientAlert("Note format reset to default.")
            }
        }
    }

    func resetNoteTemplateToDefault() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Reset note format to default?"
            alert.informativeText = "Your custom note format will be replaced."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(AppConstants.defaultNoteTemplate, forKey: AppConstants.noteTemplateKey)
            self.logger.log("Reset note format template to default.")
            self.showTransientAlert("Note format reset to default.")
        }
    }

    func clearRecentResults() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Clear recent results?"
            alert.informativeText = "This will remove all transcription history records."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            self.processedStore.clearAll()
            self.refreshRecentResults()
            self.logger.log("Cleared recent processing results.")
        }
    }

    private func startWatching() {
        guard let watchFolderURL else {
            showTransientAlert("Select watch folder first.")
            return
        }

        guard startSecurityScopedAccess(for: watchFolderURL) else {
            let msg = "Cannot access folder: \(watchFolderURL.path). If App Sandbox is ON, re-select this folder and allow access. For Voice Memos folders, Full Disk Access may also be required."
            logger.error(msg)
            showTransientAlert(msg)
            return
        }

        guard FileManager.default.isReadableFile(atPath: watchFolderURL.path) else {
            let msg = "Cannot read folder: \(watchFolderURL.path). Grant Full Disk Access to this app and retry."
            logger.error(msg)
            showTransientAlert(msg)
            return
        }

        Task {
            let granted = await speechTranscriber.requestAuthorization()
            guard granted else {
                logger.error("Speech recognition permission denied. Open System Settings > Privacy & Security > Speech Recognition.")
                stopSecurityScopedAccess()
                await MainActor.run {
                    self.showTransientAlert("Speech recognition permission denied. Open System Settings > Privacy & Security > Speech Recognition and allow VoiceMemoTranscriber.")
                }
                return
            }

            do {
                watcher = try DirectoryWatcher(directoryURL: watchFolderURL) { [weak self] in
                    self?.scanAndEnqueueFromWatchFolder()
                }
                watcher?.start()
                processingQueue.async { [weak self] in
                    guard let self else { return }
                    let existing = Set(self.listAudioFiles(in: watchFolderURL).map(\.path))
                    self.knownPaths = existing
                    self.queuedPaths.removeAll()
                    self.queuedSet.removeAll()
                    self.isProcessing = false
                    self.logger.log("Baseline captured: \(existing.count) existing audio files (will ignore).")
                }
                await MainActor.run {
                    self.watching = true
                }
                logger.log("Started watching: \(watchFolderURL.path)")
            } catch {
                logger.error("Failed to start watcher: \(error.localizedDescription)")
                stopSecurityScopedAccess()
                await MainActor.run {
                    self.showTransientAlert("Failed to start watcher: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.queuedPaths.removeAll()
            self.queuedSet.removeAll()
            self.isProcessing = false
        }
        DispatchQueue.main.async {
            self.watching = false
        }
        stopSecurityScopedAccess()
        logger.log("Stopped watching")
    }

    private func scanAndEnqueueFromWatchFolder() {
        guard let folder = watchFolderURL else { return }
        processingQueue.async { [weak self] in
            guard let self else { return }
            let urls = self.listAudioFiles(in: folder)
            for url in urls {
                let path = url.path
                if self.knownPaths.contains(path) {
                    continue
                }
                self.knownPaths.insert(path)
                if !self.queuedSet.contains(path) {
                    self.queuedSet.insert(path)
                    self.queuedPaths.append(path)
                }
            }
            self.processNextIfNeeded()
        }
    }

    private func processNextIfNeeded() {
        if isProcessing { return }
        guard !queuedPaths.isEmpty else { return }

        let nextPath = queuedPaths.removeFirst()
        queuedSet.remove(nextPath)
        isProcessing = true

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.handleFile(path: nextPath)
            self.processingQueue.async { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.processNextIfNeeded()
            }
        }
    }

    private func handleFile(path: String) async {
        let fileURL = URL(fileURLWithPath: path)
        guard AppConstants.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { return }

        do {
            guard let stable = try waitForStableFile(url: fileURL) else {
                logger.log("Skip unstable or missing file: \(path)")
                return
            }

            if stable.size == 0 {
                logger.log("Skip zero-byte file: \(path)")
                return
            }

            let fingerprint = ProcessedStore.fingerprint(path: stable.url.path, size: stable.size, mtime: stable.mtime)
            if processedStore.isProcessed(fingerprint: fingerprint) {
                logger.log("Already processed, skip: \(stable.url.path)")
                return
            }

            logger.log("Start transcription: \(stable.url.lastPathComponent)")
            let transcript = try await speechTranscriber.transcribeFile(url: stable.url)

            let importedAt = Date()
            let noteContent = makeNoteContent(fileURL: stable.url, transcript: transcript, at: importedAt)

            try await MainActor.run {
                try notesService.createNote(title: noteContent.title, body: noteContent.body)
            }
            processedStore.markProcessed(
                fingerprint: fingerprint,
                path: stable.url.path,
                size: stable.size,
                mtime: stable.mtime,
                status: .success,
                errorMessage: nil
            )
            refreshRecentResults()
            logger.log("Note created for: \(stable.url.lastPathComponent)")
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                logger.log("Skip moved/temporary file: \(path)")
                return
            }
            logger.error("Failed to process \(path): \(error.localizedDescription)")
            if let notesError = error as? NotesServiceError {
                switch notesError {
                case .automationDenied:
                    logger.error("Grant Automation permission: System Settings > Privacy & Security > Automation > VoiceMemoTranscriber > Notes")
                case .notesNotRunning:
                    logger.error("Notes app is not ready. Launch Notes once, then retry.")
                case .appleEventHandlerFailed:
                    logger.error("Notes returned AppleEvent handler failed (-10000). Retrying is enabled; if it persists, restart Notes and retry.")
                case .launchFailed:
                    logger.error("Failed to launch Notes. Ensure Notes.app exists and can be opened normally.")
                case .defaultAccountUnavailable:
                    logger.error("Open Notes once and ensure a default account is configured.")
                case .scriptError:
                    break
                }
            }
            if let info = try? currentFileInfo(url: fileURL) {
                let fp = ProcessedStore.fingerprint(path: info.url.path, size: info.size, mtime: info.mtime)
                processedStore.markProcessed(
                    fingerprint: fp,
                    path: info.url.path,
                    size: info.size,
                    mtime: info.mtime,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                refreshRecentResults()
            }
            await MainActor.run {
                self.showTransientAlert("Processing failed: \(error.localizedDescription)")
            }
        }
    }

    private func listAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard AppConstants.supportedExtensions.contains(ext) else { continue }
            if url.pathComponents.contains("Capture") { continue }

            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if vals?.isRegularFile == true {
                urls.append(url)
            }
        }

        return urls.sorted { $0.path < $1.path }
    }

    private struct StableFileInfo {
        let url: URL
        let size: UInt64
        let mtime: TimeInterval
    }

    private func currentFileInfo(url: URL) throws -> StableFileInfo {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return StableFileInfo(url: url, size: size, mtime: mtime)
    }

    private func waitForStableFile(url: URL) throws -> StableFileInfo? {
        var attempts = 0
        var lastSize: UInt64 = 0
        var stableCount = 0

        while attempts < AppConstants.maxStabilityAttempts {
            attempts += 1
            if !FileManager.default.fileExists(atPath: url.path) {
                Thread.sleep(forTimeInterval: AppConstants.stabilityWaitInterval)
                continue
            }

            let info = try currentFileInfo(url: url)
            if info.size == lastSize && info.size > 0 {
                stableCount += 1
            } else {
                stableCount = 0
                lastSize = info.size
            }

            if stableCount >= AppConstants.requiredStableChecks {
                return info
            }

            Thread.sleep(forTimeInterval: AppConstants.stabilityWaitInterval)
        }

        return nil
    }

    private struct NoteContent {
        let title: String
        let body: String
    }

    private func makeNoteContent(fileURL: URL, transcript: String, at date: Date) -> NoteContent {
        var template = currentNoteTemplate()
        if !template.contains("{transcribed_text}") {
            template += "\n{transcribed_text}"
        }

        let replacements: [String: String] = [
            "{date}": DateFormatter.noteTemplateDateFormatter.string(from: date),
            "{time}": DateFormatter.noteTemplateTimeFormatter.string(from: date),
            "{transcribed_text}": transcript,
            "{original_audio}": fileURL.absoluteString,
            "{filename}": fileURL.lastPathComponent,
        ]

        var output = template
        for (token, value) in replacements {
            output = output.replacingOccurrences(of: token, with: value)
        }

        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let parts = normalized.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let fallbackTitle = fileURL.deletingPathExtension().lastPathComponent
        let title = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? String(parts.first!).trimmingCharacters(in: .whitespacesAndNewlines)
            : fallbackTitle
        let body = parts.count > 1 ? String(parts[1]) : ""
        return NoteContent(title: title, body: body)
    }

    private func currentNoteTemplate() -> String {
        let v = UserDefaults.standard.string(forKey: AppConstants.noteTemplateKey)?
            .trimmingCharacters(in: .newlines)
        if let v, !v.isEmpty {
            return v
        }
        return AppConstants.defaultNoteTemplate
    }

    private func showTransientAlert(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func refreshRecentResults() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.processedStore.recentResults(limit: AppConstants.recentResultsLimit)
            DispatchQueue.main.async {
                self.recentResults = rows
            }
        }
    }

    private func persistWatchFolderBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: AppConstants.watchFolderBookmarkKey)
            logger.log("Saved security-scoped bookmark for folder.")
        } catch {
            logger.error("Failed to save folder bookmark: \(error.localizedDescription)")
            UserDefaults.standard.set(url.path, forKey: AppConstants.watchFolderPathFallbackKey)
        }
    }

    private func restoreWatchFolderBookmark() {
        if let data = UserDefaults.standard.data(forKey: AppConstants.watchFolderBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                watchFolderURL = url
                if isStale {
                    logger.log("Watch folder bookmark is stale. Re-saving refreshed bookmark.")
                    persistWatchFolderBookmark(url)
                }
                return
            }
        }

        if let path = UserDefaults.standard.string(forKey: AppConstants.watchFolderPathFallbackKey) {
            watchFolderURL = URL(fileURLWithPath: path)
        }
    }

    @discardableResult
    private func startSecurityScopedAccess(for url: URL) -> Bool {
        if let active = activeSecurityScopedURL, active.path == url.path {
            return true
        }
        stopSecurityScopedAccess()
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURL = url
            logger.log("Started security-scoped access: \(url.path)")
            return true
        }
        if FileManager.default.isReadableFile(atPath: url.path) {
            logger.log("Security-scoped access not required or unavailable for: \(url.path)")
            return true
        }
        return false
    }

    private func stopSecurityScopedAccess() {
        guard let url = activeSecurityScopedURL else { return }
        url.stopAccessingSecurityScopedResource()
        logger.log("Stopped security-scoped access: \(url.path)")
        activeSecurityScopedURL = nil
    }
}
