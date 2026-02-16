import AppKit
import Combine
import Foundation

final class AppController: ObservableObject {
    @Published var watching = false
    @Published var showAlert = false
    @Published var alertMessage = ""

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

    @Published private(set) var watchFolderURL: URL?

    var watchFolderDisplay: String {
        watchFolderURL?.path ?? "(not selected)"
    }

    init() {
        restoreWatchFolderBookmark()
        logger.log("App launched")
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
            panel.directoryURL = self.watchFolderURL

            self.openPanel = panel
            panel.begin { [weak self] response in
                guard let self else { return }
                defer { self.openPanel = nil }

                if response == .OK, let url = panel.url {
                    self.watchFolderURL = url
                    self.persistWatchFolderBookmark(url)
                    self.logger.log("Selected watch folder: \(url.path)")
                }
            }
        }
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

    private func startWatching() {
        guard let watchFolderURL else {
            showTransientAlert("Select watch folder first.")
            return
        }

        guard FileManager.default.isReadableFile(atPath: watchFolderURL.path) else {
            showTransientAlert("Cannot read folder: \(watchFolderURL.path). Grant Full Disk Access to this app/Terminal.")
            return
        }

        Task {
            let granted = await speechTranscriber.requestAuthorization()
            guard granted else {
                await MainActor.run {
                    self.showTransientAlert("Speech recognition permission denied.")
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
            let noteTitle = DateFormatter.noteTitleFormatter.string(from: importedAt)
            let noteBody = makeNoteBody(fileURL: stable.url, transcript: transcript)

            try notesService.createNote(title: noteTitle, body: noteBody)
            processedStore.markProcessed(fingerprint: fingerprint, status: .success)
            logger.log("Note created for: \(stable.url.lastPathComponent)")
        } catch {
            logger.error("Failed to process \(path): \(error.localizedDescription)")
            if let info = try? currentFileInfo(url: fileURL) {
                let fp = ProcessedStore.fingerprint(path: info.url.path, size: info.size, mtime: info.mtime)
                processedStore.markProcessed(fingerprint: fp, status: .failed)
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

    private func makeNoteBody(fileURL: URL, transcript: String) -> String {
        let sourceLink = fileURL.absoluteString
        return """
        \(transcript)
        \(sourceLink)
        """
    }

    private func showTransientAlert(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func persistWatchFolderBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: AppConstants.watchFolderBookmarkKey)
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
                return
            }
        }

        if let path = UserDefaults.standard.string(forKey: AppConstants.watchFolderPathFallbackKey) {
            watchFolderURL = URL(fileURLWithPath: path)
        }
    }
}
