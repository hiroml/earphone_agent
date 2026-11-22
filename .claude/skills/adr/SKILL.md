---
name: adr
description: 新しい ADR（Architecture Decision Record）を docs/adr/ に作成する。技術選定や後戻りしにくい設計判断をしたとき、またはユーザーが「ADR を書いて」と言ったときに使う。
---

# ADR 作成

1. `docs/adr/` の既存ファイルを確認し、次の連番 `NNNN` を決める（4 桁ゼロ埋め）。
2. `docs/adr/0000-template.md` をベースに `docs/adr/NNNN-<英語kebab-case-slug>.md` を作成する。
3. 日付は今日の日付（`date +%F`）。ステータスは、ユーザーが決定済みと言った場合のみ「承認」、それ以外は「提案中」。
4. 会話や `docs/research/` の内容から、コンテキスト・選択肢・理由を埋める。根拠の無い項目は推測で埋めず「要確認」と書く。
5. 承認の場合は以下も更新する:
   - `CLAUDE.md` §2 技術スタック表
   - `docs/architecture.md` の関連 ADR 一覧
   - `docs/open-questions.md`（該当の問いを解決済みに移動）
6. 作成したファイルと更新箇所を報告する。
