# App Store Readiness Checklist (VoiceMemoTranscriber)

最終更新: 2026-02-17

このファイルは「今の実装」を前提に、App Store 提出可能レベルまで上げるための実行チェックリストです。

## 現状サマリ

- Sandbox: `OFF`（`VoiceMemoTranscriber/Support/VoiceMemoTranscriber.entitlements`）
- Notes連携: `osascript` + AppleScript（`VoiceMemoTranscriber/NotesService.swift`）
- 処理履歴: `processed.json`（`VoiceMemoTranscriber/ProcessedStore.swift`）
- 監視方式: DispatchSource + 全走査（OK）
- 逐次キュー処理: 実装済み（OK）

## フェーズ1: 審査で落ちにくい最低ライン

- [x] 1. Sandbox を `ON` に変更
  - 変更箇所: `VoiceMemoTranscriber/Support/VoiceMemoTranscriber.entitlements`
  - 追加候補:
    - `com.apple.security.app-sandbox = true`
    - `com.apple.security.files.user-selected.read-write = true`
  - 完了条件:
    - 監視フォルダを選択して再起動後もアクセス継続できる

- [x] 2. Security-scoped bookmark の開始/終了処理を厳密化
  - 変更箇所: `VoiceMemoTranscriber/AppController.swift`
  - 必須:
    - `startAccessingSecurityScopedResource()` / `stopAccessing...()` の対にする
    - stale bookmark 再保存
  - 完了条件:
    - Sandbox ON でも監視・読み込みが安定動作

- [x] 3. 権限拒否時の導線強化（設定画面へ誘導）
  - 変更箇所: `VoiceMemoTranscriber/AppController.swift`
  - 必須:
    - Speech拒否時に再試行/設定誘導メッセージ
    - Automation拒否時に具体的な許可手順を表示
  - 完了条件:
    - 拒否状態でもユーザーが自力復旧できる

- [x] 4. Notes作成失敗の分類ログ
  - 変更箇所: `VoiceMemoTranscriber/NotesService.swift`, `VoiceMemoTranscriber/AppLogger.swift`
  - 必須:
    - Apple Events拒否 / Notes未準備 / スクリプト失敗を区別
  - 完了条件:
    - ログだけで失敗原因を判定可能

## フェーズ2: 運用品質

- [ ] 5. `processed.json` を SQLite 化
  - 変更箇所: `VoiceMemoTranscriber/ProcessedStore.swift`（置換）
  - テーブル案:
    - `records(fingerprint TEXT PRIMARY KEY, path TEXT, size INTEGER, mtime REAL, status TEXT, error TEXT, created_at REAL)`
  - 完了条件:
    - 成功/失敗理由/時刻が保持される
    - 一覧取得（直近N件）が可能

- [ ] 6. メニューに「最近の処理結果」追加
  - 変更箇所: `VoiceMemoTranscriber/VoiceMemoTranscriberApp.swift`, `VoiceMemoTranscriber/AppController.swift`
  - 表示例:
    - `✅ file1.m4a`
    - `❌ file2.m4a (No speech detected)`
  - 完了条件:
    - 直近結果をアプリ内で確認できる

- [ ] 7. リトライポリシー導入
  - 変更箇所: `VoiceMemoTranscriber/AppController.swift`
  - 必須:
    - 一時エラー（I/O, Notes起動待ち）は最大N回リトライ
    - 恒久エラー（権限拒否）は即失敗
  - 完了条件:
    - 一時障害で失敗率が下がる

- [ ] 8. 長時間/大量ファイル耐性テスト
  - テスト観点:
    - 60分音声中に追加ファイル投入
    - 50件連続投入
    - 再起動後の再開
  - 完了条件:
    - 取りこぼし/重複なし、UI応答維持

## フェーズ3: 提出準備

- [ ] 9. バージョン/ビルド運用
  - 変更箇所: `VoiceMemoTranscriber/Support/Info.plist`
  - 必須:
    - `CFBundleShortVersionString` / `CFBundleVersion` 運用ルール化
  - 完了条件:
    - Archiveごとに一意ビルド番号

- [ ] 10. リリース向け README とサポート文書
  - 変更箇所: `README.md`
  - 必須:
    - 権限説明（Speech/Automation/必要時Full Disk Access）
    - 既知の制約と復旧手順
  - 完了条件:
    - 初回ユーザーが手順のみで設定完了

- [ ] 11. プライバシー情報整理
  - App Store Connect で記載する内容:
    - 収集データの有無
    - 音声/文字起こしデータの扱い（端末内処理中心であること）
  - 完了条件:
    - 実装と申告内容が一致

- [ ] 12. Archive / Validate / TestFlight 配布
  - 完了条件:
    - TestFlight 内部配布で再現性ある動作確認

## 実装優先順位（推奨）

1. Sandbox ON + Security-scoped bookmark
2. 権限導線とエラーログ強化
3. SQLite化 + 最近の処理結果UI
4. リトライ + 耐性テスト
5. 提出ドキュメント整備

## 今すぐ着手するなら

- 最初の一手: `Sandbox ON` と `Security-scoped bookmark` の完全対応。
- 理由: ここが未完だと App Store 審査と実運用の両方で詰まりやすい。
