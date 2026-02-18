import AppKit
import Foundation

enum NotesServiceError: Error, LocalizedError {
    case automationDenied(String)
    case defaultAccountUnavailable(String)
    case notesNotRunning(String)
    case appleEventHandlerFailed(String)
    case launchFailed(String)
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied(let msg):
            return "Notes automation permission denied: \(msg). Open System Settings > Privacy & Security > Automation and allow this app to control Notes."
        case .defaultAccountUnavailable(let msg):
            return "Notes default account is unavailable: \(msg). Open Notes once and ensure an account exists."
        case .notesNotRunning(let msg):
            return "Notes is not ready: \(msg). Open Notes once and retry."
        case .appleEventHandlerFailed(let msg):
            return "Notes AppleEvent handler failed: \(msg). Retrying may resolve this."
        case .launchFailed(let msg):
            return "Failed to launch Notes: \(msg)"
        case .scriptError(let msg):
            return "Notes automation failed: \(msg)"
        }
    }
}

final class NotesService {
    private let targetFolderName = "VoiceMemoTranscriber"
    private let notesBundleID = "com.apple.Notes"
    private let logger = AppLogger.shared

    func createNote(title: String, body: String) throws {
        let normalizedBody = normalizeLineEndingsForNotes(body)
        let noteBodyHTML = wrapAsNotesHTML(normalizedBody)

        logger.log("NotesService: createNote start")
        try launchNotesIfNeeded()

        var lastError: Error?
        for attempt in 1...4 {
            do {
                logger.log("NotesService: attempt \(attempt) run create script")
                do {
                    try runCreateScript(title: title, noteBodyHTML: noteBodyHTML)
                } catch let e as NotesServiceError {
                    switch e {
                    case .notesNotRunning:
                        logger.error("NotesService: NSAppleScript path got -600, trying osascript fallback")
                        try runCreateScriptViaOSAScriptPlain(title: title, noteBodyText: normalizedBody)
                    case .appleEventHandlerFailed:
                        logger.error("NotesService: NSAppleScript path got -10000, trying osascript plain-text fallback")
                        try runCreateScriptViaOSAScriptPlain(title: title, noteBodyText: normalizedBody)
                    default:
                        throw e
                    }
                }
                logger.log("NotesService: createNote succeeded")
                return
            } catch let error as NotesServiceError {
                lastError = error
                switch error {
                case .notesNotRunning:
                    logger.log("NotesService: attempt \(attempt) got -600, relaunching Notes and retrying")
                    try launchNotesIfNeeded()
                    Thread.sleep(forTimeInterval: min(2.5, 0.5 * Double(attempt)))
                    continue
                case .appleEventHandlerFailed:
                    logger.log("NotesService: attempt \(attempt) got -10000, relaunching Notes and retrying")
                    try launchNotesIfNeeded()
                    Thread.sleep(forTimeInterval: min(2.5, 0.7 * Double(attempt)))
                    continue
                default:
                    throw error
                }
            } catch {
                lastError = error
                throw error
            }
        }

        throw lastError ?? NotesServiceError.scriptError("Unknown Notes error")
    }

    private func launchNotesIfNeeded() throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).filter { !$0.isTerminated }
        if let app = apps.first {
            logger.log("NotesService: Notes already running (pid: \(app.processIdentifier))")
            _ = app.activate(options: [.activateIgnoringOtherApps])
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        logger.log("NotesService: launching Notes")

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notesBundleID) else {
            throw NotesServiceError.launchFailed("Cannot resolve Notes application URL.")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var launchError: Error?
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            launchError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)

        if let launchError {
            throw NotesServiceError.launchFailed(launchError.localizedDescription)
        }
        if !waitForNotesRunning(timeout: 6.0) {
            throw NotesServiceError.notesNotRunning("Timed out waiting for Notes process.")
        }
        let launched = NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).first
        logger.log("NotesService: Notes process is running (pid: \(launched?.processIdentifier ?? -1))")
    }

    private func waitForNotesRunning(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).contains(where: { !$0.isTerminated }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func runCreateScript(title: String, noteBodyHTML: String) throws {
        let folderNameEsc = escapeForAppleScript(targetFolderName)
        let titleEsc = escapeForAppleScript(title)
        let bodyEsc = escapeForAppleScript(noteBodyHTML)

        let script = """
        set folderName to "\(folderNameEsc)"
        set noteTitle to "\(titleEsc)"
        set noteBodyHTML to "\(bodyEsc)"

        tell application id "com.apple.Notes"
            launch
            activate
            set acc to default account
            set targetFolder to missing value

            tell acc
                repeat with f in folders
                    if name of f is folderName then
                        set targetFolder to f
                        exit repeat
                    end if
                end repeat

                if targetFolder is missing value then
                    set targetFolder to make new folder with properties {name:folderName}
                end if

                make new note at targetFolder with properties {name:noteTitle, body:noteBodyHTML}
            end tell
        end tell
        """
        try executeAppleScript(script)
    }

    private func runCreateScriptViaOSAScriptPlain(title: String, noteBodyText: String) throws {
        let folderNameEsc = escapeForAppleScript(targetFolderName)
        let titleEsc = escapeForAppleScript(title)
        let bodyEsc = escapeForAppleScript(noteBodyText)

        let script = """
        set folderName to "\(folderNameEsc)"
        set noteTitle to "\(titleEsc)"
        set noteBodyText to "\(bodyEsc)"
        tell application id "com.apple.Notes"
            launch
            activate
            delay 0.3
            set acc to default account
            set targetFolder to missing value
            tell acc
                repeat with f in folders
                    if name of f is folderName then
                        set targetFolder to f
                        exit repeat
                    end if
                end repeat
                if targetFolder is missing value then
                    set targetFolder to make new folder with properties {name:folderName}
                end if
                make new note at targetFolder with properties {name:noteTitle, body:noteBodyText}
            end tell
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw classifyScriptError(message)
        }
    }

    private func executeAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw NotesServiceError.scriptError("Failed to initialize AppleScript.")
        }
        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            let number = (errorDict[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let message = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let combined = number != nil ? "\(message) (code: \(number!))" : message
            throw classifyScriptError(combined, errorNumber: number)
        }
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func classifyScriptError(_ message: String, errorNumber: Int? = nil) -> NotesServiceError {
        let lower = message.lowercased()
        if errorNumber == -1743 || lower.contains("(-1743)") || lower.contains("not authorized to send apple events") {
            return .automationDenied(message)
        }
        if errorNumber == -10000 || lower.contains("(-10000)") || lower.contains("appleevent handler failed") {
            return .appleEventHandlerFailed(message)
        }
        if errorNumber == -600 || lower.contains("(-600)") || lower.contains("application isn’t running") || lower.contains("application is not running") {
            return .notesNotRunning(message)
        }
        if lower.contains("can't get default account")
            || lower.contains("can’t get default account")
            || lower.contains("default account") {
            return .defaultAccountUnavailable(message)
        }
        return .scriptError(message)
    }

    private func normalizeLineEndingsForNotes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
    }

    private func wrapAsNotesHTML(_ text: String) -> String {
        let escaped = escapeHTML(text)
        let withBreaks = escaped.replacingOccurrences(of: "\r", with: "<br>")
        return "<html><body>\(withBreaks)</body></html>"
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
