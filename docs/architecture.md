# アーキテクチャ

> ステータス: **未確定**。下図は検討用のたたき台。決定事項は ADR を作成してから反映する。

## 処理パイプライン（たたき台）

```
[イヤホン / スマホ マイク]
        │ 音声ストリーム
        ▼
[VAD / ウェイクワード]  ← オンデバイス・常時稼働（軽量）
        │ 発話区間のみ
        ▼
[STT 音声認識]          ← オンデバイス or クラウド
        │ テキスト
        ▼
[エージェント (LLM + tool use)]
   ├─ tool: web_search / summarize
   ├─ tool: todo (create / update / list)
   ├─ tool: navigation (route / guidance)
   └─ tool: memory (短期文脈)
        │ 応答テキスト
        ▼
[TTS 音声合成] → [イヤホン]
```

## 主要な設計論点
- オンデバイス処理とクラウド処理の境界（電池・レイテンシ・プライバシーのトレードオフ）
- 常時リスニングと BT プロファイル（HFP / A2DP / LE Audio）の扱い
- エージェントループの実行場所（端末 / サーバ）
- ToDo・履歴データの保存先と同期

## 関連 ADR
- [ADR-0001](adr/0001-record-architecture-decisions.md) アーキテクチャ決定を ADR で記録する
