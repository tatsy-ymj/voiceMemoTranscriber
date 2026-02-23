# VoiceMemoTranscriber (macOS 13+, SwiftUI Menu Bar App)

[日本語README](README.md)

VoiceMemoTranscriber watches a folder for Voice Memos audio files (`m4a/wav/aiff/caf`), transcribes them with Apple's Speech framework, and creates a new note in Apple Notes for each file.

## 1. Installation (App Store / GitHub DMG)

### App Store version
1. Install `VoiceMemoTranscriber` from the App Store.
2. Launch the app.
3. Grant initial permissions (Speech Recognition / Automation).
4. Select the watch folder via `Select Watch Folder…`.
5. Click `Start Watching`.

### GitHub release (DMG)
1. Download the `.dmg` from GitHub Releases.
2. Open the `.dmg` and copy `VoiceMemoTranscriber.app` to `Applications`.
3. Launch the app (if Gatekeeper warns on first launch, right-click the app and choose `Open`).
4. Grant initial permissions (Speech Recognition / Automation).
5. Select the watch folder and click `Start Watching`.

## 2. Quick Start (First-time Setup)

1. Launch the app.
2. Select the watch folder in `Select Watch Folder…`.
   - Recommended: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`
3. Start watching.
4. Record in Voice Memos (or add an audio file: `.m4a/.wav/.aiff/.caf`).
5. Confirm a new note is created after a few seconds.
6. Check logs via `Open Log`.

## 3. Project Setup (Xcode)

1. Create a macOS `App` project (SwiftUI) in Xcode.
2. Set Product Name to `VoiceMemoTranscriber`.
3. Add Swift files from this repository's `VoiceMemoTranscriber` folder to the target.
4. Set target `Info.plist File` to:
   - `VoiceMemoTranscriber/Support/Info.plist`
5. In `Signing & Capabilities`, set Entitlements file (Debug):
   - `VoiceMemoTranscriber/Support/VoiceMemoTranscriber.entitlements`
6. For Release builds, use:
   - `VoiceMemoTranscriber/Support/VoiceMemoTranscriber.Release.entitlements`

## 4. UI / Features

Menu bar items:
- Select Watch Folder…
- Start Watching / Stop Watching
- Request Speech Permission
- Edit Note Format...
- Reset Note Format to Default
- Open Log
- Recent Results
- Quit

Status display:
- Status: Watching / Idle
- Current watch folder path

## 5. Implementation Highlights

- Watcher: event-driven directory monitoring via `DispatchSourceFileSystemObject`
- Detection: folder scan for supported audio extensions
- Stabilization: waits until file size is stable before processing
- Transcription: `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest` (default locale: `ja-JP`)
- Notes write: `NSAppleScript` with `osascript` fallback (when needed), writes into folder `VoiceMemoTranscriber` in Notes
- Newline normalization for Notes: `\n` -> `\r`
- Custom note template (editable by user), default:
  - `{date} {time}\n{transcribed_text}\n{original_audio}`
- Template output mapping:
  - first line -> note title
  - remaining lines -> note body
- Supported placeholders:
  - `{date}`, `{time}`, `{transcribed_text}`, `{original_audio}`, `{filename}`
- Dedup/history:
  - fingerprint = SHA256(path + size + mtime)
  - stored in SQLite
- Queue:
  - strictly sequential processing (no concurrent transcription)
- Logging:
  - Console + `~/Library/Logs/VoiceMemoTranscriber/app.log`
  - under sandbox, this may be containerized

Typical watch folder on many systems (environment-dependent):
- `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`

## 6. Permissions

Grant on first use:
- Speech Recognition
- Automation (to control Notes)

May also be required:
- Full Disk Access
  - especially when reading Voice Memos data under Group Containers

Configured usage descriptions in Info.plist:
- `NSSpeechRecognitionUsageDescription`
- `NSAppleEventsUsageDescription`

Microphone permission:
- Usually not required (file-based transcription)
- Some environments may still request it

## 7. Quick Test

1. Launch app
2. Select watch folder in `Select Watch Folder…`
   - Recommended: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`
3. Start watching
4. Add an audio file (`.m4a/.wav/.aiff/.caf`) to the folder
5. Confirm a new note is created
6. Check logs via `Open Log`

## 8. Troubleshooting

### Speech permission denied
- Allow in: System Settings > Privacy & Security > Speech Recognition
- Retry via menu: `Request Speech Permission`

### Notes creation fails
- Allow in: System Settings > Privacy & Security > Automation
- If needed, reset and re-allow:
  - `tccutil reset AppleEvents com.binword.VoiceMemoTranscriber`

### Cannot read watch folder
- Re-select folder from app menu (`Select Watch Folder…`)
- Grant Full Disk Access when needed for Group Containers

### Same file not processed again
- This is expected due to fingerprint-based deduplication
- Remove DB to reprocess:
  - `~/Library/Application Support/VoiceMemoTranscriber/processed.sqlite3`

Release verification: Confirmed on February 18, 2026 (watch -> transcribe -> create note -> recent results -> clear results -> restart/bookmark restore).

## 9. Maintenance Policy

- This is a personal project. I cannot guarantee responses to Issues or Pull Requests.
- Bug reports and feature requests via Issues are welcome.
- Pull Requests are welcome, but they may not be reviewed or merged.
