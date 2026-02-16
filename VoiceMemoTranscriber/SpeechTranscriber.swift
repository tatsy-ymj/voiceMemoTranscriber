import Foundation
import Speech

enum SpeechTranscriberError: Error, LocalizedError {
    case authorizationDenied
    case recognizerUnavailable
    case noResult
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition permission denied."
        case .recognizerUnavailable:
            return "Speech recognizer unavailable for selected locale."
        case .noResult:
            return "No transcription result received."
        case .recognitionFailed(let message):
            return "Speech recognition failed: \(message)"
        }
    }
}

final class SpeechTranscriber {
    private let localeIdentifier: String

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribeFile(url: URL) async throws -> String {
        let allowed = await requestAuthorization()
        guard allowed else { throw SpeechTranscriberError.authorizationDenied }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable else {
            throw SpeechTranscriberError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error, !resumed {
                    resumed = true
                    continuation.resume(throwing: SpeechTranscriberError.recognitionFailed(error.localizedDescription))
                    return
                }

                if let result, result.isFinal, !resumed {
                    resumed = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        continuation.resume(throwing: SpeechTranscriberError.noResult)
                    } else {
                        continuation.resume(returning: text)
                    }
                }
            }

            _ = task
        }
    }
}
