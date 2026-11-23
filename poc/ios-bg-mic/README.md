# PoC: iOS バックグラウンド BT イヤホンマイク継続取得

- 目的: [調査メモ](../../docs/research/2026-11-22-background-earbud-mic-capture.md) の「未確認事項」を実機で検証する
- 関連: open-questions Q2 / Q3 / Q9 / Q10
- 本体コードとは混ぜない使い捨て PoC。音声データは保存せず、音量などのメタ情報のみログに残す。

## アプリの機能
| 機能 | 内容 |
|---|---|
| リスニング | `AVAudioSession(.playAndRecord, .allowBluetooth)` + `AVAudioEngine` の入力 tap で音量（dB）を取り続ける |
| 簡易 VAD | 音量の閾値で発話区間を検出してログ（STT はしない） |
| ハートビート | 30 秒ごとに「その間に届いたバッファ数・電池・発熱・経路・アプリ状態」を記録。0 件なら `STALL` |
| イベント記録 | 中断（着信等）、経路変更、エンジン設定変更、画面ロック/解除、AirPods ミュート操作、イヤホンのタップ操作（AVRCP）、メディアサービスのリセット |
| 自動再開 | 中断後や経路変更後に再開を試み、成否をログに残す。背面で失敗したらローカル通知 → タップで前面に戻れば自動再開 |
| 設定切替 | BT 高品質録音（iOS 26+）/ mixWithOthers / voiceChat モード / タップ操作の受信 / VAD 閾値 |
| ログ出力 | 画面右上の共有ボタン、または「ファイル」アプリ → このiPhone内 → BgMic PoC の `.tsv` |

## Windows からビルド・インストールする手順（Mac 不要）

```
[WSL / Windows] コードを書く → GitHub へ push
        ↓
[GitHub Actions macOS ランナー] XcodeGen → xcodebuild → 未署名 IPA
        ↓ Artifacts からダウンロード
[Windows] Sideloadly で Apple ID 署名 → USB で iPhone にインストール
```

### 1. 事前準備（初回のみ）
- **GitHub リポジトリ**を作って push する。ワークフローは `.github/workflows/poc-ios-bg-mic.yml`。
  - public リポジトリなら macOS ランナーは無料。private の場合、macOS ランナーは無料枠の消費が大きい（Linux の約 10 倍）ので注意。
- **Windows に Sideloadly** を入れる（公式サイトの案内に従う。iTunes / iCloud の非ストア版が必要とされている）。
- **iPhone** で「設定 → プライバシーとセキュリティ → デベロッパモード」を ON にする（iOS 16 以降で必要）。
- **Apple ID**:
  - 無料の Apple ID でも可。ただし、インストールしたアプリは **7 日で失効**する（再インストールで延長できる）。
  - 有料の Apple Developer Program（年 99 USD）なら 1 年有効。TestFlight も使える。

### 2. ビルド
- `poc/ios-bg-mic/` 以下を変更して push すると、自動でビルドが走る。GitHub の Actions タブから手動実行（workflow_dispatch）もできる。
- 成功したら、Run の Artifacts から `BgMicPoC-unsigned-ipa` をダウンロードして解凍し、`.ipa` を取り出す。
- 失敗したら Artifacts の `xcodebuild-log` を確認する（Claude にそのまま渡せば修正できる）。

### 3. インストール
1. iPhone を USB で Windows に接続し、「このコンピュータを信頼」する。
2. Sideloadly に `.ipa` をドラッグし、Apple ID を入力して Start。
3. 初回は iPhone の「設定 → 一般 → VPN とデバイス管理」で、開発元（自分の Apple ID）を信頼する。

### 4. ログの回収
- アプリ右上の共有ボタン → AirDrop / メール / 「ファイルに保存」。
- または、「ファイル」アプリ → このiPhone内 → BgMic PoC → `bgmic-YYYYMMDD-HHMMSS.tsv`。
- 回収したログは `poc/ios-bg-mic/results/` に置く（git 管理外）。Claude に渡せば分析できる。
- （任意）リアルタイムで見たい場合は、libimobiledevice の `idevicesyslog` で `[BgMicPoC]` を grep する。

## 検証環境
| 項目 | 値 |
|---|---|
| 端末 | iPhone 15 |
| iOS | 26.2.1 |
| イヤホン | Anker Soundcore Liberty 5（BT 5.4 / SBC・AAC・LDAC / マイク 6 基 / マルチポイント対応） |

この構成で注意すること:
- **iOS 26 の BT 高品質録音は使えない見込み。** H2 チップの AirPods 専用のため。Liberty 5 のマイクは **HFP（通話品質）** 経由になる。設定の「BT 高品質録音」は ON のままでも害はない。実際の経路は `ROUTE` ログで確認する。
- **AirPods のミュート操作は使えない。** 代わりに T7 で、イヤホンのタップ操作（AVRCP）を受信できるかを試す。タップの割り当ては Soundcore アプリで確認・変更する。
- **マルチポイントの影響を避ける。** 他の機器（PC 等）とも同時接続していると経路が不安定になりうるので、試験中は iPhone だけに接続する。
- イヤホン側の「AI 通話ノイズ低減」は HFP の音声に効くはず。STT の精度評価（後の工程）の参考になる。

## 試験シナリオ
各試験の開始時に、アプリの「マーカー」で `T1 開始` のように記録しておくと、ログを読みやすい。

| # | 試験 | 手順 | 見るログ | 判定 |
|---|---|---|---|---|
| T1 | 長時間継続 | AirPods 接続 → 開始 → 画面ロック → 2h（可能なら 8h）放置 | `HEARTBEAT buffers>0` が続くか、`STALL` の有無、電池の推移 | 継続時間・1 時間あたりの電池消費 |
| T2 | 音楽との併用 | 開始 → 他アプリで音楽再生。mixWithOthers / HQ を ON/OFF の 4 通り | `ROUTE`、耳での音質評価（モノラル化するか） | 音楽を聴きながら使えるか |
| T3 | 着信 | 背面で取得中に別端末から電話 → 応答 → 終話 | `INTERRUPT began/ended` → `START ok / FAILED` | 背面のまま再開できるか |
| T4 | Siri | 背面で取得中に Siri を起動 → 終了 | 同上 | 同上 |
| T5 | アラーム / タイマー | 背面でタイマーを鳴らす → 止める | 同上 | 同上 |
| T6 | イヤホン着脱 | 背面で AirPods をケースに戻す → 取り出す | `ROUTE change`、`ENGINE configurationChange` → 再開の成否 | 経路変化後に背面で継続できるか |
| T7 | イヤホンのタップ操作 | 設定「タップ操作を受信」ON・mixWithOthers OFF で開始 → 背面・ロック中に Liberty 5 をタップ（シングル / ダブル / 長押し） | `REMOTE play/pause/...` が届くか。通話操作に置き換わらないか（`INTERRUPT` や経路変化が起きないか） | Q10: 話しかけのトリガーに使えるか |
| T7' | AirPods のミュート操作 | （AirPods がある場合のみ）背面で軸を押す | `MUTE inputMuteStateChange` | Liberty 5 では対象外 |
| T8 | 他の録音アプリ | 背面で取得中にボイスメモで録音 → 終了 | `INTERRUPT`、再開の成否 | 競合時の挙動 |
| T9 | 通知からの復帰 | T3〜T8 で再開に失敗したとき、通知をタップ | `START trigger=foregroundResume` | 再開 UX が成立するか |

## 試験シナリオ（文字起こし・話者判別）
仕様: [docs/specs/own-voice-detection.md](../../docs/specs/own-voice-detection.md)

**準備**
- 設定の「端末内文字起こし」を ON にしてリスニングを開始する。
- 初回は日本語モデルのダウンロードが走るので、Wi-Fi に接続しておく。
- 文字起こしの状態表示が「動作中 (ja-JP)」になったことを確認する。

**記録のしかた**
- 話者が変わるたびに、画面上部の「いま話しているのは」のラベルを切り替える（自分 / 他人 / TV等 / 混在 / 無音）。
- 他人に話してもらう場合は、事前に同意を得る。

| # | 試験 | 手順 | 見るログ |
|---|---|---|---|
| S1 | 自分の声 | ラベル「自分」で、普通の声量で 5 文ほど話す（ToDo 風・質問風を混ぜる） | `STT final label=self peak=… meanLoud=…`、文字起こしの正確さ |
| S2 | 他人の声（1m） | ラベル「他人」で、1m 先の人に 5 文ほど話してもらう。自分は黙る | `label=other` の文が出るか、出た場合の音量 |
| S3 | TV・動画 | ラベル「TV等」で、2m 先でニュース動画などを流す | 同上 |
| S4 | 交互 | 自分 → 他人 → 自分 … と交互に話し、そのたびにラベルを切り替える | 自分と他人で peak / meanLoud に明確な差があるか |
| S5 | 本体マイク比較 | 設定「iPhone 本体マイクを使う」を ON にして、S1〜S3 を短く繰り返す | 他人や TV の声がどこまで文字になるか（イヤホンのマイクと比較） |
| S6 | 雑音下 | 屋外や換気扇の近くで S1 / S2 | 雑音の誤認識（`label=silence` 中の final） |

**判定したいこと**
1. Liberty 5 のマイクで、他人や TV の声は文字になるか。ほぼ消えるなら、「周囲の会話から ToDo を拾う」ことはイヤホンのマイクだけでは難しい。
2. 自分と他人で音量（peak / meanLoud）がはっきり分かれるか。分かれるなら、音量の閾値だけで「自分の声」を判別できる。
3. 自分の声を、日本語として実用的な精度で文字にできるか。

## 結果記録
| # | 日付 | 端末 / iOS | イヤホン | 設定 | 結果 | 備考 |
|---|---|---|---|---|---|---|
| T1 | | | | | | |
| T2 | | | | | | |
| T3 | | | | | | |
| T4 | | | | | | |
| T5 | | | | | | |
| T6 | | | | | | |
| T7 | | | | | | |
| T8 | | | | | | |
| T9 | | | | | | |

## ログ形式（TSV）
`time<TAB>category<TAB>message`

主なカテゴリ:

| カテゴリ | 意味 |
|---|---|
| `APP` / `CONFIG` | 起動情報・設定 |
| `START` / `STOP` | 開始・停止（trigger, appState） |
| `ENGINE` | エンジンの起動・設定変更 |
| `ROUTE` | 入出力経路 |
| `INTERRUPT` | 中断 |
| `HEARTBEAT` / `STALL` | 生存確認・停止検出 |
| `VAD` | 発話区間 |
| `MUTE` | ミュート操作（AirPods） |
| `REMOTE` | イヤホンのタップ操作（AVRCP） |
| `LIFECYCLE` | アプリ状態・画面ロック |
| `NOTIFY` | 再開を促す通知 |
| `MARK` | 手動マーカー |
| `STT` | 文字起こし（`final label=… peak=… meanLoud=… loud=… span=… lag=… text=…`）。音量は「最初の途中結果の 2 秒前〜確定」の範囲で集計。`lag` は最初の途中結果から確定までの秒数 |
| `LABEL` | 話者ラベルの切り替え |

エラーの例: `NSOSStatusErrorDomain#561145187 '!rec'` は **CannotStartRecording**（背面からの録音開始ブロック）を表す。

## ローカルでの Xcode 利用（Mac がある場合）
```bash
brew install xcodegen
cd poc/ios-bg-mic && xcodegen generate && open BgMicPoC.xcodeproj
```
