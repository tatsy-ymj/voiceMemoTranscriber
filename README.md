# VoiceMemoTranscriber (macOS 13+, SwiftUI Menu Bar App)

Voice Memos由来の音声ファイル（m4a/wav/aiff/caf）を監視フォルダで検知し、Speech frameworkで文字起こししてNotesに毎回新規ノートを作成する最小実用アプリです。

## 1. プロジェクト作成手順（Xcode）

1. Xcodeで `App` (SwiftUI, macOS) を作成
2. Product Name を `VoiceMemoTranscriber` に設定
3. このリポジトリ内 `VoiceMemoTranscriber` フォルダのSwiftファイルをターゲットへ追加
4. ターゲットの `Info` で `Info.plist File` を以下に設定
   - `VoiceMemoTranscriber/Support/Info.plist`
5. ターゲットの `Signing & Capabilities` で Entitlements ファイルを
   - `VoiceMemoTranscriber/Support/VoiceMemoTranscriber.entitlements`
   に設定（Sandboxはfalse）

## 2. UI / 機能

メニューバー項目:
- Select Watch Folder…
- Start Watching / Stop Watching
- Request Speech Permission
- Open Log
- Quit

状態表示:
- Status: Watching / Idle
- 現在の監視フォルダ

## 3. 実装ポイント

- 監視: `DispatchSourceFileSystemObject` でディレクトリFDをイベント駆動監視
- 検知後: フォルダ全走査で対象拡張子ファイルを抽出
- 安定化待ち: 数秒間隔でサイズを複数回チェックし、書き込み完了後に処理
- 文字起こし: `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest`（既定ロケール `ja-JP`）
- Notes保存: `osascript` で AppleScript を実行し、Notes内フォルダ `VoiceMemoTranscriber` に毎回新規ノートを作成
- 本文改行は Notes 向けに `\\n` を `\\r` へ正規化
- ノートタイトルは `yyyy-MM-dd HH:mm`（日時のみ）
- ノート本文は「文字起こし本文」+ 改行 + 「元ファイルのfile://リンク」
- 重複防止: `path + size + mtime` のSHA256指紋をJSON保存
- キュー: 逐次1件ずつ処理（同時実行なし）
- ログ: Console + `~/Library/Logs/VoiceMemoTranscriber/app.log`

## 4. 権限

初回利用時に以下を許可:
- Speech Recognition
- Automation（Notes 操作）

必要に応じて:
- Full Disk Access
  - Voice Memosの実ファイル保存先（Group Containers）を読む場合、実行主体（アプリまたはTerminal）に必要になる場合があります。

`NSSpeechRecognitionUsageDescription` と `NSAppleEventsUsageDescription` は Info.plist に設定済み。

### マイク権限について
このアプリはファイル文字起こし中心のためマイク権限は通常不要です。
ただし環境差で要求される場合があるため、その場合は許可してください。

## 5. 動作確認

1. アプリ起動
2. `Select Watch Folder…` で監視先フォルダを選択
3. `Start Watching`
4. 監視フォルダへ `.m4a/.wav/.aiff/.caf` を追加
5. 数秒後、Notesに新規ノート作成されることを確認
6. `Open Log` でログ確認

## 6. トラブルシュート

### `Speech recognition permission denied`
- System Settings > Privacy & Security > Speech Recognition で許可
- メニュー `Request Speech Permission` から再試行

### Notes作成に失敗
- System Settings > Privacy & Security > Automation でアプリのNotes制御を許可

### 監視フォルダが読めない
- Full Disk Access をアプリ（または実行元Terminal）へ付与

### 同じファイルが再処理されない
- 重複防止仕様です（fingerprintベース）
- `~/Library/Application Support/VoiceMemoTranscriber/processed.json` を削除すると再処理可能

## 7. Sandbox ON で運用したい場合（注意）

まずはSandbox OFFを推奨。
Sandbox ON にする場合は最低限以下を検討:
- User-selected file read/write 権限
- Security-scoped bookmark の適切な `startAccessingSecurityScopedResource()` 運用
- Apple Events（Notes）関連の制約対応
