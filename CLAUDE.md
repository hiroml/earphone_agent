# CLAUDE.md

このファイルは Claude Code がこのリポジトリで作業する際の前提・ルールをまとめたもの。
**決まったことは即ここに反映する。未決事項は「未決」と明記し、推測で埋めない。**

---

## 1. プロジェクト概要

**earphone_agent**（仮称）: イヤホンと連携するスマホ常駐型 AI エージェントアプリ。

- イヤホンのマイク（＋スマホのマイク）で **周囲の音 / ユーザー自身の声** を拾う
- 拾った音声を文字起こし・理解し、エージェントとして行動する
  - 必要な情報の **調査**（Web 検索・要約）
  - **ToDo リスト** の作成・更新（会話から自動抽出も含む）
  - **道順案内**（音声でのナビゲーション）
  - その他、拡張可能なツール群
- 応答は主にイヤホンへの **音声** で返す（画面を見なくても使える体験が中心）

詳細なビジョン・ユースケースは [docs/vision.md](docs/vision.md)、要件は [docs/requirements.md](docs/requirements.md) を参照。

### 現在のフェーズ
**Phase 0: 構想・技術調査**（コードはまだ無い）
- 優先: 技術的な実現可能性の検証（特にイヤホンマイクの取得・バックグラウンド動作・電池）
- フェーズ定義とマイルストーンは [docs/roadmap.md](docs/roadmap.md)

---

## 2. 技術スタック

| レイヤ | 状態 | 内容 / 候補 |
|---|---|---|
| モバイル | **未決** | React Native (Expo) / Flutter / ネイティブ (Swift + Kotlin) |
| 対象 OS | **IOS** | iOS / Android / 両方（まずどちらか一方で PoC が現実的） |
| 音声取得 | **イヤホンのマイク** | BT HFP 経由のイヤホンマイク / スマホ内蔵マイク / 併用 |
| VAD・ウェイクワード | **未決** | オンデバイス（Silero VAD, Porcupine 等） |
| STT（音声認識） | **未決** | オンデバイス (Whisper 系, OS 標準) / クラウド |
| LLM・エージェント | **Claude API** | Claude API（tool use）を第一候補。比較用に Sarashina API（日本語特化）も試作に組み込み済み |
| TTS（音声合成） | **未決** | OS 標準 / クラウド TTS |
| バックエンド | **未決** | 不要（端末完結）/ 軽量 API サーバ |
| 地図・経路 | **google map** | Google Maps / Apple MapKit / OSS |

> スタックが決まったら: この表を更新 → ADR を `docs/adr/` に追加 → §4 のコマンドを埋める。

### 検証環境（実機）
| 項目 | 値 | 備考 |
|---|---|---|
| 端末 | iPhone 15 | |
| iOS | 26.2.1 | |
| イヤホン | Anker Soundcore Liberty 5 | BT 5.4、SBC / AAC / LDAC、マイク 6 基、マルチポイント対応。LE Audio は未確認 |
| 開発 PC | Windows + WSL（Mac なし） | iOS のビルドは CI で行う（§4） |

- Liberty 5 は AirPods ではない。そのため **iOS 26 の BT 高品質録音（H2 AirPods 専用）と、AirPods のミュート操作 API は前提にしない**。マイクは HFP 経由になる。
- イヤホンからの操作は AVRCP（再生/一時停止など）のリモコンコマンドとして受け取れるかを検証中（open-questions Q10）。

---

## 3. リポジトリ構成

```
.
├── CLAUDE.md              # このファイル（Claude への指示）
├── CLAUDE.local.md        # 個人用メモ（git 管理外・任意）
├── README.md
├── .claude/
│   ├── settings.json      # 権限設定（チーム共有）
│   ├── agents/            # サブエージェント定義
│   └── skills/            # プロジェクト用スキル（/adr, /spec など）
├── docs/
│   ├── vision.md          # 何を作りたいか
│   ├── requirements.md    # 機能・非機能要件
│   ├── architecture.md    # アーキテクチャ（決定次第更新）
│   ├── roadmap.md         # フェーズとマイルストーン
│   ├── open-questions.md  # 未決事項・調査課題
│   ├── glossary.md        # 用語集
│   ├── adr/               # Architecture Decision Records
│   ├── specs/             # 機能仕様
│   └── research/          # 技術調査メモ
└── (app/, server/ などはスタック決定後に追加)
```

---

## 4. 開発コマンド

**未定**（スタック決定後に記載）。

```bash
# install:   TBD
# dev:       TBD
# test:      TBD
# lint:      TBD
# typecheck: TBD
```

### エージェント本体（テキスト試作）: `poc/agent-cli`（Python / uv）
```bash
cd poc/agent-cli
uv sync              # 依存インストール
uv run earagent -v   # 対話 CLI（API キーはリポジトリ直下の .env）
uv run pytest        # テスト（API を呼ばない）
```

### iOS のビルド環境（Mac なし）
- 開発は Windows / WSL。Xcode はローカルに無い。
- iOS のビルドは **GitHub Actions の macOS ランナー**（XcodeGen → xcodebuild → 未署名 IPA）で行う。インストールは Windows の **Sideloadly** で行う。
- `.xcodeproj` は手書きしない。`project.yml`（XcodeGen）で管理する。
- ビルドエラーは CI のログ（Artifacts の `xcodebuild-log`）で確認する。
- 例: [poc/ios-bg-mic/README.md](poc/ios-bg-mic/README.md)

---

## 5. 作業の進め方（Claude 向けルール）

### 基本
- 応答・ドキュメント・コミットメッセージは **日本語**。コード内の識別子は英語、コメントは日本語可。
- 大きめの変更は **計画 → 合意 → 実装** の順。曖昧な要件は勝手に決めず、選択肢と推奨を示して確認する。
- 技術選定など後戻りしにくい判断をしたら **ADR を書く**（`/adr` スキル）。
- 新機能は着手前に **仕様を書く**（`/spec` スキル → `docs/specs/`）。
- 調査結果は `docs/research/YYYY-MM-DD-<topic>.md` に残す（`/research` スキル）。出典 URL と調査日を必ず書く。
- 未決事項が出たら `docs/open-questions.md` に追記する。

### コード（スタック決定後に具体化）
- 小さく動くものを優先。PoC は `poc/<topic>/` に置き、本体と混ぜない。
- 新しいロジックにはテストを書く。テスト・lint・型チェックが通るまで「完了」としない。
- 外部 API（LLM / STT / 地図など）は **インターフェースで抽象化** し、差し替え可能にする。
- 秘密情報（API キー等）はコードに書かない。`.env`（git 管理外）と `.env.example` を使う。

### Git / GitHub
**リポジトリ:** https://github.com/hiroml/earphone_agent （remote `origin` = `git@github.com:hiroml/earphone_agent.git`、SSH）

**ブランチ**
- `main` は常に「ビルドが通り、ドキュメントが最新」の状態に保つ。**`main` へ直接 push しない**（初回コミットのみ例外）。
- 作業は必ずブランチを切る。名前は `<種別>/<英語kebab-case>`。
  - 種別: `feat/` 機能、`fix/` 修正、`docs/` ドキュメント、`poc/` 検証、`chore/` 設定・CI・雑務、`refactor/` リファクタ
  - 例: `poc/ios-remote-command`、`docs/adr-stt-selection`
- 1 ブランチ 1 目的。終わったら PR で `main` にマージ（**squash merge**）し、ブランチは削除する。

**コミット**
- Conventional Commits 形式で、件名は日本語・50 字程度まで: `<type>(<scope>): <要約>`
  - type: `feat` `fix` `docs` `poc` `chore` `refactor` `test` `ci`
  - scope（任意）: `ios-bg-mic`、`docs`、`ci` など
  - 例: `poc(ios-bg-mic): イヤホンのタップ操作の受信テストを追加`
- 本文には「なぜ」を書く。1 コミット 1 論理変更。
- Claude が作るコミットの末尾には `Co-Authored-By` 行を付ける。

**PR**
- `.github/pull_request_template.md` に沿って書く（目的 / 変更点 / 検証方法 / プライバシー影響）。
- 音声・文字起こし・位置情報に関わる変更は、`privacy-reviewer` の結果を PR に記載する。
- iOS コードを変更した PR は、GitHub Actions のビルドが通ってからマージする。

**Claude の権限ルール**
- commit / push / PR 作成は、**ユーザーに頼まれたときだけ**行う。
- 禁止: force push、`main` への直接 push、push 済みの履歴の書き換え、`git reset --hard` などの破壊的操作（ユーザーの明示的な指示がある場合を除く）。
- コミットしないもの: `.env`・鍵ファイル、録音ファイル、実機ログ（`poc/**/results/`）。実機ログは要約だけを README の結果表や `docs/research/` に書く。

**GitHub 側の推奨設定（ユーザーが UI で設定する）**
- Settings → Branches → `main` に保護ルールを設定する: Require a pull request / Require status checks（CI）/ Block force pushes
- Settings → General → Pull Requests: squash merge のみ許可し、Automatically delete head branches を ON にする

---

## 6. このプロダクト特有の注意点（重要）

### プライバシー・倫理
- **周囲の音を常時拾う = 第三者の声も録る**。設計時に必ず考慮する:
  - 音声の生データは原則 **端末外に送らない／保存しない** をデフォルトとし、例外は明示的に設計・ADR 化する
  - 録音・送信中であることをユーザーが常に把握できる UI/音声フィードバック
  - データ保持期間・削除手段
- 音声・文字起こし・位置情報を扱う変更は `privacy-reviewer` サブエージェントでレビューする。

### モバイル・オーディオの制約（調査前提として意識する）
- Bluetooth イヤホンのマイクは通常 **HFP（通話プロファイル）** 経由で、音質が落ち A2DP 再生と排他になりやすい。LE Audio で改善の可能性。
- iOS / Android ともに **バックグラウンドでの常時マイク利用** に制約・審査上の注意がある。
- 常時リスニングは **電池消費** が最大の敵。VAD / ウェイクワードをオンデバイスで走らせ、重い処理は必要時のみ。
- レイテンシ目標（音声入力 → 音声応答）は要件で定義する（[docs/requirements.md](docs/requirements.md)）。

### エージェント設計
- ツール（検索・ToDo・ナビ等）は **疎結合なプラグイン** として追加できる構造を目指す。
- 「勝手に行動しない」: 外部への送信・購入・予定登録など副作用のある操作はユーザー確認を挟む。
