# 未決事項・調査課題

解決したら「解決済み」に移し、結論（ADR / research へのリンク）を書く。

## 未解決
| # | 問い | 重要度 | 担当 / 調査メモ |
|---|---|---|---|
| Q2 | 市販 BT イヤホンのマイクをバックグラウンドで常時取得できるか（OS・審査） | 高 | 🟢 **実機で背面継続を確認**（21 分・STALL 0、2026-11-23）。残: 1h 以上の継続・電池・中断からの再開 → [research](research/2026-11-22-background-earbud-mic-capture.md)、[PoC 結果](../poc/ios-bg-mic/README.md#結果記録) |
| Q3 | HFP 接続中の音楽再生品質低下をどう扱うか | 中 | 一部調査 → [research](research/2026-11-22-background-earbud-mic-capture.md) §5（iOS 26 + H2 AirPods の高品質録音で緩和の可能性） |
| Q4 | STT はオンデバイスかクラウドか（日本語精度 vs 電池 vs コスト） | 高 | |
| Q5 | 第三者の声を拾うことの法的・倫理的整理（同意、保存） | 高 | |
| Q6 | エージェントは端末で回すか、サーバで回すか | 中 | |
| Q7 | 特定のイヤホン（独自 SDK あり）に絞るか、汎用にするか | 中 | |
| Q8 | マネタイズ / API コストの負担モデル | 低 | |
| Q9 | 中断（着信・Siri 等）後の再開をどう UX 設計するか（iOS は前面復帰が必要） | 高 | [research](research/2026-11-22-background-earbud-mic-capture.md) |
| Q10 | イヤホン操作を「話しかけ」トリガーに使えるか（AirPods はミュート操作、Liberty 5 は AVRCP タップ。背面受信・HFP 中の挙動・審査） | 中 | [research](research/2026-11-22-background-earbud-mic-capture.md) §6、PoC T7 で検証 |

## 解決済み
| # | 問い | 結論 |
|---|---|---|
| Q1 | iOS / Android どちらから始めるか | iOS（CLAUDE.md §2 で決定。ADR は未作成） |
