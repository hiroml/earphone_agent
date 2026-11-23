# 調査: 市販 BT イヤホンのマイクをバックグラウンドで常時取得できるか（iOS / Android）

- 調査日: 2026-11-22
- 関連: [open-questions.md](../open-questions.md) Q2, Q3
- 重点: iOS（CLAUDE.md で対象 OS = iOS に決定済み）。Android は比較用に概要のみ。

## 問い
1. アプリがバックグラウンド（画面ロック・他アプリ使用中）でも、BT イヤホンのマイク音声を取り続けられるか
2. バックグラウンドの状態から、録音を**新たに開始**できるか（イヤホンのボタン、ショートカット等をきっかけに）
3. App Store 審査や OS の仕様上のリスクは何か

## 結論

**iOS: 「条件付きで可能」。フォアグラウンドで始めた録音セッションは、バックグラウンドでも継続できる。ただし、バックグラウンドからの開始・再開は原則できない。**

- ✅ フォアグラウンドでユーザー操作により録音を開始し、`audio` バックグラウンドモードを宣言しておけば、ロック中・他アプリ使用中も録音を継続できる（Apple DTS の回答）
- ❌ バックグラウンドから新たに録音を開始することは、プライバシー上の制限でブロックされる。イヤホンのボタン、`AudioRecordingIntent`、HFP 接続のいずれをきっかけにしても同じ（Apple DTS の回答）
- ⚠️ 電話・Siri・アラームなどで中断されると、バックグラウンドのままでは再開に失敗する報告が多い。**ユーザーがアプリを前面に出す必要がある**前提で設計すべき
- ❌ CallKit / LiveCommunicationKit / PushToTalk ならバックグラウンドから開始できるが、**通話・通信アプリ専用**であり、音声アシスタントに転用するのは審査リスクが高い

**Android: 可能性は高い（未検証）。** フォアグラウンドサービス（種類: `microphone`）を、アプリが見えている状態で起動すれば継続録音できる。常時通知の表示が必須。

## 詳細・根拠（iOS）

### 1. 継続録音は可能、開始はフォアグラウンドのみ
- DTS（2024-12）: "An app must be in the foreground to start recording. If the app has specified the 'audio' background mode in its info.plist configuration, it can then continue recording when it moves into the background."
  — https://developer.apple.com/forums/thread/770556
- 別の DTS エンジニアも「フォアグラウンドで開始した録音は、バックグラウンドで無期限に継続できる」と回答している。
  — https://developer.apple.com/forums/thread/120038
- ⚠️ 同スレッド 770556 に「30 秒以上継続できなかった」という非公式報告（2026-01）がある。DTS 回答と矛盾するため、**実機での検証が必要**。
  - → **2026-11-23 の実機検証で再現せず**（iPhone 15 / iOS 26.2.1 / Liberty 5。背面・ロック中に 21 分継続、STALL 0）。[PoC 結果](../../poc/ios-bg-mic/README.md#結果記録)

### 2. バックグラウンドからの開始は不可
- DTS（2026-02）: "There's a privacy block in place that prevents recording sessions from activating in the background." HFP 接続でもこの制限は変わらない。
  — https://developer.apple.com/forums/thread/816408
- Shortcuts やアクションボタンから `AudioRecordingIntent` を実行しても、"Target is not foreground" で失敗する報告がある（非公式）。
  — https://developer.apple.com/forums/thread/815725
- MFi 認定ヘッドセットのボタンからバックグラウンド録音を開始しようとして、失敗した報告もある。
  — https://developer.apple.com/forums/thread/674632

### 3. 中断（電話・アラーム等）からの復帰
- バックグラウンド中に中断されると、再開時に `AVAudioSessionErrorCodeCannotStartRecording` が出るという報告が多い。OS バージョンによって挙動が変わっている。
  — https://developer.apple.com/forums/thread/120038
  — https://developer.apple.com/forums/thread/813278 （通話後の `setActive(true)` 失敗）
- 回避策として報告されているもの: 中断が終わったら Live Activity や通知でユーザーに再開を促し、アプリを前面に出して再開してもらう。

### 4. PushToTalk / CallKit という抜け道
- DTS: "Our voice communication APIs (CallKit, LiveCommunicationKit, and the PushToTalk framework) do allow this … but they can't be used for any other purpose."
  — https://developer.apple.com/forums/thread/816408
- 「音声アシスタントに PTT を使ってよいか」という質問スレッド（2026-04）は、調査時点で回答なし。
  — https://developer.apple.com/forums/thread/823466
- PTT はチャンネル参加型の通信機能という位置づけで、チャンネルへの参加にもフォアグラウンドが必要。
  — https://developer.apple.com/forums/thread/773981
- → **このプロダクトでは採用しない前提で進めるのが安全。**

### 5. BT の HFP 経由で起きる副作用
- HFP のマイクを入力に選ぶと、**出力も HFP に切り替わる**。その結果、音楽の音質が低下（モノラル化）する（QA1799 に基づくフォーラム回答）。
  — https://developer.apple.com/forums/thread/784318
  — https://developer.apple.com/forums/thread/90503
- 車載機器と接続している場合、録音開始によって音声の出力先が変わる報告がある。
  — https://developer.apple.com/forums/thread/836224
- **iOS 26 以降** は `AVAudioSession.CategoryOptions.bluetoothHighQualityRecording` で、対応する AirPods（H2 チップ搭載: AirPods Pro 2 / AirPods 4）から高音質で録音できる。**EU では非対応。**
  — https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording
  — https://developer.apple.com/videos/play/wwdc2025/251/
  — https://www.engadget.com/audio/headphones/ios-26-updates-for-airpods-preview-enhanced-audio-recording-camera-remote-and-more-173036046.html

### 6. AirPods の操作をトリガーにできるか
- iOS 17 以降、AirPods の軸を押すミュート操作を、通知（mute gesture notification）として受け取れる。CallKit を使わない通信アプリも登録すれば利用できる。
  — https://developer.apple.com/videos/play/wwdc2023/10233
- **アイデア:** 録音セッションをバックグラウンドで維持したまま、ミュート操作を「話しかけ開始」のトリガーとして使う。これなら録音の新規開始ではない。
  → バックグラウンドで届くか、通信アプリ以外で使って審査に通るかは**未確認**。

### 7. App Store 審査（Guideline 2.5.4 ほか）
- `audio` バックグラウンドモードの用途がレビュアーに伝わらず、リジェクトされる例が多い。審査メモに「ユーザーから見える、バックグラウンド録音が必要な機能」を明記し、操作の画面録画を添付するのが定石。
  — https://developer.apple.com/forums/thread/826849
  — https://developer.apple.com/forums/thread/776949
- 録音中であることを示す表示が不十分だとして指摘を受けた例がある。同意なしの録音はガイドライン違反のリスクがある（フォーラム上の言及であり、規約本文は未確認）。
  — https://developer.apple.com/forums/thread/671406
  — https://developer.apple.com/app-store/review/guidelines/

## 詳細・根拠（Android、概要）
- Android 14 以降は、フォアグラウンドサービスに `foregroundServiceType="microphone"` と `FOREGROUND_SERVICE_MICROPHONE` の宣言が必要。`RECORD_AUDIO` は「アプリ使用中のみ」の権限なので、**アプリが見えている状態でサービスを起動**する必要がある（例外条件あり）。
  — https://developer.android.com/about/versions/14/changes/fgs-types-required
  — https://developer.android.com/develop/background-work/services/fgs/service-types
- BT マイクへの切り替えは `AudioManager.setCommunicationDevice()` を使う（Android 13 以降、`startBluetoothSco()` からの移行が推奨）。
  — https://developer.android.com/develop/connectivity/bluetooth/ble-audio/audio-manager
- 複数アプリがマイクを使う場合は、前面にあるアプリが優先される。他アプリの利用によって入力デバイスが変わることがある。
  — https://developer.android.com/media/platform/sharing-audio-input
- 構造は iOS と似ていて「前面で開始 → サービスで継続」。ただし iOS より柔軟で、常時通知という分かりやすい UX が前提になっている。

## 設計への示唆
1. **「セッション型」UX を前提にする。** ユーザーがアプリで「リスニング開始」を押す → 以降はバックグラウンドで継続 → 中断されたら通知で再開を促す。「完全に放置で常時待機」は iOS では保証できない。
2. **電話・Siri などによる中断は必ず起きる前提にする。** 中断を検知し、ユーザーに分かりやすく知らせる（イヤホンへの音声通知、Live Activity）。
3. **HFP による音楽音質の劣化をどう扱うか**（音楽を聴きながら使えるか）は UX 上の大きな論点。対応 AirPods + iOS 26 の高音質録音で緩和できる可能性がある。
4. **音声処理の中核部分は、ネイティブ（Swift / AVAudioEngine）で書く方が有利**と見られる。`AVAudioSession` の細かい制御、中断処理、AirPods 固有の API が必要なため。クロスプラットフォーム（RN / Flutter）を選ぶ場合も、ネイティブモジュール化はほぼ必須。→ モバイルフレームワーク選定（ADR）の入力になる。
5. PushToTalk / CallKit の流用は採用しない。

## 未確認事項・実機検証が必要なこと
- [x] フォアグラウンドで開始した録音が、ロック状態で継続するか（「30 秒で止まる」報告の真偽） → **21 分継続を確認、報告は否定**（2026-11-23）。1h 以上は未確認
- [ ] 中断（着信、Siri、アラーム、他アプリでの音楽再生・録音）からバックグラウンドのまま再開できるか（iOS 26）
- [ ] BT の接続・切断で経路が変わったときの挙動（イヤホンを外す／ケースに戻す）
- [ ] AirPods のミュート操作がバックグラウンドで通知として届くか（検証機は Liberty 5 のため、AVRCP タップで代替検証）
- [ ] `bluetoothHighQualityRecording` 使用時に、音楽再生の音質と STT の精度がどう変わるか
- [ ] 常時録音 + VAD での電池消費（1 時間あたりの %）（後回し）
- [x] Liberty 5 の HFP 入力フォーマット → 16kHz・モノラル。マイク使用中は出力も HFP になり、停止で A2DP 44.1kHz に戻る（2026-11-23）
- [ ] 審査: 録音中の表示（オレンジドット以外の UI）と、審査メモの書き方

## 次のアクション
1. **PoC（作成済み → [poc/ios-bg-mic](../../poc/ios-bg-mic/README.md)）:** `poc/ios-bg-mic/` に最小の Swift アプリを作り、上の検証項目を実機で確かめる（AVAudioEngine の入力 tap + 簡易 VAD + ログ出力のみ）。
2. 結果をもとに ADR「音声取得方式とセッションモデル」を作成する。
3. モバイルフレームワーク選定の ADR では、示唆 4（音声処理の中核はネイティブが有利）を考慮する。
