"""音声エージェントのコア: 発話テキスト → Claude（tool use）→ 読み上げ用の応答テキスト。

- 調査: サーバーツール web_search / web_fetch（Anthropic 側で実行）
- ToDo: クライアントツール add_todo / list_todos / complete_todo（ローカル TodoStore）
- アドバイス: モデル自身
会話履歴は response.content をそのまま積む（thinking / サーバーツール結果を改変しない）。
"""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass, field
from typing import Any

import anthropic

from .todo_store import TodoNotFoundError, TodoStore
from .utterance import Utterance, may_send_to_cloud

MODEL = "claude-opus-5-5"
MAX_TOKENS = 16000
MAX_LOOP = 10

SYSTEM_PROMPT = """\
あなたは、ユーザーが装着しているイヤホン越しに話す音声アシスタントです。
あなたの返答はそのまま音声合成で読み上げられ、ユーザーは画面を見ていません。

話し方:
- 日本語で、耳で聞いて一度で分かる短い話し言葉にする。基本は 2〜3 文。詳しく求められたら少し長くてよい。
- Markdown、箇条書き記号、URL、絵文字、括弧書きの補足は使わない。

できること:
- 調べもの: 最新情報や事実確認が必要なら web_search を使い、必要なら web_fetch でページを読む。結論と要点だけを伝え、出典はサイト名を一言添える程度にする。
- ToDo: ユーザーがやるべきことを口にしたら、明示的に頼まれていなくても add_todo で登録し、登録したことを短く伝える。期限が分かれば due に入れる。一覧や完了は list_todos / complete_todo を使う。
- アドバイス: ユーザーの状況に合わせて、具体的で実行しやすい提案を短く伝える。

依頼の意図が分からないときは、推測で動かずに一つだけ聞き返す。
"""

WEB_TOOLS: list[dict[str, Any]] = [
    {
        "type": "web_search_20260209",
        "name": "web_search",
        "max_uses": 5,
        "user_location": {
            "type": "approximate",
            "country": "JP",
            "timezone": "Asia/Tokyo",
        },
    },
    {"type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 3},
]

TODO_TOOLS: list[dict[str, Any]] = [
    {
        "name": "add_todo",
        "description": "ユーザーの ToDo を 1 件登録する。やるべきことが発話に含まれていたら使う。",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "やることを短く（例: 田中さんに資料を送る）"},
                "due": {
                    "type": ["string", "null"],
                    "description": "期限。分かる場合は ISO 8601（例: 2026-11-30 または 2026-11-30T15:00）。不明なら null",
                },
                "note": {"type": ["string", "null"], "description": "補足。なければ null"},
            },
            "required": ["title", "due", "note"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_todos",
        "description": "登録済みの ToDo を一覧する。",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {
                "include_done": {"type": "boolean", "description": "完了済みも含めるか"},
            },
            "required": ["include_done"],
            "additionalProperties": False,
        },
    },
    {
        "name": "complete_todo",
        "description": "ToDo を完了にする。id は list_todos で確認する。",
        "strict": True,
        "input_schema": {
            "type": "object",
            "properties": {"todo_id": {"type": "integer"}},
            "required": ["todo_id"],
            "additionalProperties": False,
        },
    },
]


@dataclass
class AgentReply:
    text: str
    tool_calls: list[str] = field(default_factory=list)
    elapsed_sec: float = 0.0
    input_tokens: int = 0  # キャッシュ外の入力
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    output_tokens: int = 0
    stop_reason: str | None = None


class VoiceAgent:
    def __init__(
        self,
        todo_store: TodoStore,
        client: anthropic.Anthropic | None = None,
        effort: str = "medium",
    ) -> None:
        self.client = client or anthropic.Anthropic()
        self.todos = todo_store
        self.effort = effort
        self.messages: list[dict[str, Any]] = []

    def reset(self) -> None:
        self.messages = []

    def handle(self, utterance: Utterance) -> AgentReply | None:
        """発話を処理する。クラウドに送れない発話（他人・不明）は None を返し、何も送らない。"""
        if not may_send_to_cloud(utterance):
            return None

        stamp = utterance.at.strftime("%Y-%m-%d(%a) %H:%M")
        self.messages.append({"role": "user", "content": f"[現在日時 {stamp}]\n{utterance.text}"})

        reply = AgentReply(text="")
        started = time.monotonic()
        for _ in range(MAX_LOOP):
            response = self.client.beta.messages.create(
                model=MODEL,
                max_tokens=MAX_TOKENS,
                system=SYSTEM_PROMPT,
                tools=[*WEB_TOOLS, *TODO_TOOLS],
                messages=self.messages,
                output_config={"effort": self.effort},
                cache_control={"type": "ephemeral"},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            )
            usage = response.usage
            reply.input_tokens += usage.input_tokens
            reply.cache_read_tokens += usage.cache_read_input_tokens or 0
            reply.cache_write_tokens += usage.cache_creation_input_tokens or 0
            reply.output_tokens += response.usage.output_tokens
            reply.stop_reason = response.stop_reason
            # 履歴は改変せずそのまま積む
            self.messages.append({"role": "assistant", "content": response.content})

            for block in response.content:
                if block.type == "server_tool_use":
                    reply.tool_calls.append(block.name)

            if response.stop_reason == "refusal":
                reply.text = "ごめんなさい、その依頼にはお答えできません。"
                break
            if response.stop_reason == "pause_turn":
                continue
            if response.stop_reason == "tool_use":
                results = []
                for block in response.content:
                    if block.type == "tool_use":
                        reply.tool_calls.append(block.name)
                        results.append(self._run_tool(block.id, block.name, block.input))
                self.messages.append({"role": "user", "content": results})
                continue

            reply.text = "".join(b.text for b in response.content if b.type == "text").strip()
            break
        else:
            reply.text = "処理が長くなりすぎたので中断しました。"

        reply.elapsed_sec = time.monotonic() - started
        return reply

    # ---- クライアントツール ----

    def _run_tool(self, tool_use_id: str, name: str, args: Any) -> dict[str, Any]:
        content, is_error = execute_todo_tool(self.todos, name, args)
        return {"type": "tool_result", "tool_use_id": tool_use_id, "content": content, "is_error": is_error}


def execute_todo_tool(store: TodoStore, name: str, args: Any) -> tuple[str, bool]:
    """ToDo ツールを実行し (結果テキスト, エラーか) を返す。Claude / Sarashina 共通。"""
    try:
        if not isinstance(args, dict):
            raise ValueError("ツール入力が不正です")
        return _dispatch_todo(store, name, args), False
    except (ValueError, KeyError, TypeError) as e:
        if isinstance(e, TodoNotFoundError):
            return f"エラー: {e.args[0]}", True
        return f"エラー: {e}", True


def _dispatch_todo(store: TodoStore, name: str, args: dict[str, Any]) -> str:
    if name == "add_todo":
        todo = store.add(args["title"], due=args.get("due"), note=args.get("note"))
        return json.dumps(asdict(todo), ensure_ascii=False)
    if name == "list_todos":
        todos = store.list(include_done=bool(args.get("include_done", False)))
        return json.dumps([asdict(t) for t in todos], ensure_ascii=False) if todos else "ToDo はありません。"
    if name == "complete_todo":
        try:
            todo = store.complete(int(args["todo_id"]))
        except TodoNotFoundError:
            raise TodoNotFoundError(f"id={args['todo_id']} の ToDo は見つかりません") from None
        return json.dumps(asdict(todo), ensure_ascii=False)
    raise ValueError(f"未知のツール: {name}")
