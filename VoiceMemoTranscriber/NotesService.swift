import Foundation

enum NotesServiceError: Error, LocalizedError {
    case automationDenied(String)
    case defaultAccountUnavailable(String)
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied(let msg):
            return "Notes automation permission denied: \(msg). Open System Settings > Privacy & Security > Automation and allow this app to control Notes."
        case .defaultAccountUnavailable(let msg):
            return "Notes default account is unavailable: \(msg). Open Notes once and ensure an account exists."
        case .scriptError(let msg):
            return "Notes automation failed: \(msg)"
        }
    }
}

final class NotesService {
    private let targetFolderName = "VoiceMemoTranscriber"

    private let script = """
    on run argv
        set folderName to item 1 of argv
        set noteTitle to item 2 of argv
        set noteBodyHTML to item 3 of argv

        tell application "Notes"
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
    end run
    """

    func createNote(title: String, body: String) throws {
        let normalizedBody = normalizeLineEndingsForNotes(body)
        let noteBodyHTML = wrapAsNotesHTML(normalizedBody)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, targetFolderName, title, noteBodyHTML]

        let err = Pipe()
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw classifyScriptError(message)
        }
    }

    private func classifyScriptError(_ message: String) -> NotesServiceError {
        let lower = message.lowercased()
        if lower.contains("(-1743)") || lower.contains("not authorized to send apple events") {
            return .automationDenied(message)
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
