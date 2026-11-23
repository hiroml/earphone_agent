# PoC: エージェント本体（テキスト試作）

発話テキスト → Claude（tool use）→ 読み上げ用の応答テキスト、を WSL 上で試すための CLI。
iOS の音声認識・話者判別とは独立して開発し、後で統合する。仕様: [docs/specs/agent-core.md](../../docs/specs/agent-core.md)

## 機能
| 機能 | 実装 |
|---|---|
| 調査・検索 | サーバーツール `web_search` / `web_fetch`（Anthropic 側で実行、地域は日本） |
| ToDo | クライアントツール `add_todo` / `list_todos` / `complete_todo` → ローカル JSON（`data/todos.json`） |
| アドバイス | モデル自身（短い話し言葉で返すようシステムプロンプトで指定） |
| 送信ゲート | **本人の発話（`Speaker.SELF`）だけ** を API に送る。他人・不明は送らない（[ADR-0002](../../docs/adr/0002-send-only-own-voice-to-cloud.md)） |
| 会話文脈 | 履歴をそのまま保持（`/reset` で消去） |

## LLM の切り替え（`--provider`）
| provider | モデル | 調査（Web 検索） | ToDo | 備考 |
|---|---|---|---|---|
| `claude`（既定） | `claude-opus-5-5` | ✅ | ✅ | effort は既定 `medium`。拒否時のサーバー側フォールバックを有効化 |
| `sarashina` | `sarashina3.2-mini-thinking`（既定）など | ❌ | ✅ | 日本語特化（SB Intuitions）。`--model` で変更、`--effort` は low/medium/high |

- Sarashina のモデル: `sarashina3.2-mini-thinking`（推論）/ `sarashina3-nano`（軽量・高速）/ `sarashina3-mini`（2026-11-27 以降に提供終了予定）。
- Sarashina は日本国内からのアクセスが前提（国外・VPN 経由だと 403 になりうる）。レート制限は 30 回/分（nano は 60）。
- ToDo ツールと「本人の発話だけ送る」ゲートは両方で共通。精度・速度の比較は後で行う（同じ発話を両方に送って比べる）。

## 使い方
```bash
cd poc/agent-cli
uv sync
uv run earagent -v            # 対話モード（-v で使用ツール・時間・トークンを表示）
uv run earagent -p "明日の9時に歯医者に電話する"   # 1 回だけ
uv run earagent --provider sarashina -v                         # Sarashina で対話
uv run earagent --provider sarashina --model sarashina3-nano -v  # 軽量モデル
uv run pytest                 # テスト（API は呼ばない）
```
API キーはリポジトリ直下の `.env` から読む（`ANTHROPIC_API_KEY` / `SARASHINA_API_KEY`）。

対話モードのコマンド:

| 入力 | 動作 |
|---|---|
| テキスト | 自分の発話として送信 |
| `/other テキスト` | 他人の発話（クラウドに送らないことの確認用） |
| `/todos` | ローカル ToDo 一覧（API を使わない） |
| `/reset` | 会話履歴をリセット |
| `/quit` | 終了 |

## 動作確認結果（2026-11-23、effort=medium）
| 発話 | 結果 | 時間 |
|---|---|---|
| 「金曜までに田中さんに見積書を送らないと」 | 明示依頼なしで ToDo 登録（期限 11/27 を推定） | 8.1s |
| `/other` 来週の会議は木曜10時から | 送信されず | - |
| 「今日の東京の天気は？」 | web_search で回答、出典を一言 | 11.9s |
| 「寝つきが悪い、いい方法は？」 | ツールなしで短い助言 | 4.2s |
| 「さっきの ToDo は何件？」 | 文脈を踏まえ list_todos | 5.7s |

**課題: 音声 UX としては遅い**（4〜12 秒）。改善候補 → 仕様の「未決事項」を参照。
