import Foundation

enum AppConstants {
    static let defaultLocale = "ja-JP"

    static let supportedExtensions: Set<String> = ["m4a", "wav", "aiff", "caf"]

    static let stabilityWaitInterval: TimeInterval = 2.0
    static let requiredStableChecks = 2
    static let maxStabilityAttempts = 8

    static let watchFolderBookmarkKey = "WatchFolderBookmark"
    static let watchFolderPathFallbackKey = "WatchFolderPathFallback"

    static let processedStoreFileName = "processed.json"
}
