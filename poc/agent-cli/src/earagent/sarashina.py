"""SoftBank / SB Intuitions の Sarashina API を使うエージェント（日本語特化 LLM との比較用）。

- Chat Completions API: https://docs.sarashina.ai/api-reference/chat-completions
- 認証: Authorization: Bearer $SARASHINA_API_KEY（日本国外からのアクセスは 403 になりうる）
- ツールは function 型のみ → ToDo ツールは Claude 版と共通。Web 検索は無いので調査はできない。
- 推論モデル（*-thinking）は暗号化された reasoning を返す。次のリクエストでそのまま返す必要があるため、
  アシスタントメッセージは改変せず履歴に積む。
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import httpx

from .agent import TODO_TOOLS, AgentReply, execute_todo_tool
from .todo_store import TodoStore
from .utterance import Utterance, may_send_to_cloud

API_URL = "https://api.sarashina.ai/v1/chat/completions"
DEFAULT_MODEL = "sarashina3.2-mini-thinking"
MAX_LOOP = 8

SYSTEM_PROMPT = """\
あなたは、ユーザーが装着しているイヤホン越しに話す音声アシスタントです。
あなたの返答はそのまま音声合成で読み上げられ、ユーザーは画面を見ていません。

話し方:
- 日本語で、耳で聞いて一度で分かる短い話し言葉にする。基本は 2〜3 文。
- Markdown、箇条書き記号、URL、絵文字、括弧書きの補足は使わない。

できること:
- ToDo: ユーザーがやるべきことを口にしたら、明示的に頼まれていなくても add_todo で登録し、登録したことを短く伝える。期限が分かれば due に入れる。一覧や完了は list_todos / complete_todo を使う。
- アドバイス: ユーザーの状況に合わせて、具体的で実行しやすい提案を短く伝える。

あなたは Web 検索ができない。最新情報が必要な質問には、調べられないことを正直に伝え、一般的な知識の範囲で答えられることがあれば添える。
依頼の意図が分からないときは、推測で動かずに一つだけ聞き返す。
"""


def _to_function_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Claude 形式のツール定義を Chat Completions の function 形式に変換する。"""
    return [
        {
            "type": "function",
            "function": {"name": t["name"], "description": t["description"], "parameters": t["input_schema"]},
        }
        for t in tools
    ]


SARASHINA_TOOLS = _to_function_tools(TODO_TOOLS)


class SarashinaError(Exception):
    pass


class SarashinaRateLimitError(SarashinaError):
    def __init__(self, retry_after: int | None) -> None:
        super().__init__(f"レート制限（{retry_after or '?'} 秒後に再試行）")
        self.retry_after = retry_after


class SarashinaAgent:
    def __init__(
        self,
        todo_store: TodoStore,
        api_key: str | None = None,
        model: str = DEFAULT_MODEL,
        reasoning_effort: str = "medium",
        http_client: httpx.Client | None = None,
        timeout: float = 90.0,
    ) -> None:
        key = api_key or os.environ.get("SARASHINA_API_KEY")
        if not key:
            raise SarashinaError("SARASHINA_API_KEY が設定されていません（リポジトリ直下の .env に追加してください）")
        self.todos = todo_store
        self.model = model
        self.reasoning_effort = reasoning_effort
        self.http = http_client or httpx.Client(timeout=timeout)
        self._headers = {"Authorization": f"Bearer {key}"}
        self.messages: list[dict[str, Any]] = []

    @property
    def is_thinking_model(self) -> bool:
        return self.model.endswith("-thinking")

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
            data = self._post(self._request_body())
            usage = data.get("usage") or {}
            reply.input_tokens += usage.get("prompt_tokens") or 0
            reply.output_tokens += usage.get("completion_tokens") or 0

            choice = data["choices"][0]
            message = {k: v for k, v in choice["message"].items() if v is not None}
            reply.stop_reason = choice.get("finish_reason")
            # reasoning（暗号化）を含め、改変せずに履歴へ
            self.messages.append(message)

            tool_calls = message.get("tool_calls") or []
            if tool_calls:
                for call in tool_calls:
                    name = call["function"]["name"]
                    reply.tool_calls.append(name)
                    try:
                        args = json.loads(call["function"].get("arguments") or "{}")
                    except json.JSONDecodeError:
                        content = "エラー: 引数が JSON として不正です。もう一度正しい形式で呼び出してください。"
                    else:
                        content, _ = execute_todo_tool(self.todos, name, args)
                    self.messages.append({"role": "tool", "tool_call_id": call["id"], "content": content})
                continue

            reply.text = (message.get("content") or "").strip()
            if reply.stop_reason == "length" and not reply.text:
                reply.text = "考えすぎて時間切れになりました。もう一度、短く聞いてください。"
            break
        else:
            reply.text = "処理が長くなりすぎたので中断しました。"

        reply.elapsed_sec = time.monotonic() - started
        return reply

    def _request_body(self) -> dict[str, Any]:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": [{"role": "system", "content": SYSTEM_PROMPT}, *self.messages],
            "tools": SARASHINA_TOOLS,
            # 推論モデルは thinking も上限に含まれる（上限 32768）。非推論モデルは上限 8000
            "max_completion_tokens": 16000 if self.is_thinking_model else 4000,
        }
        if self.is_thinking_model:
            body["reasoning_effort"] = self.reasoning_effort
        return body

    def _post(self, body: dict[str, Any]) -> dict[str, Any]:
        r = self.http.post(API_URL, json=body, headers=self._headers)
        if r.status_code == 429:
            retry = r.headers.get("Retry-After")
            raise SarashinaRateLimitError(int(retry) if retry and retry.isdigit() else None)
        if r.status_code >= 400:
            raise SarashinaError(f"Sarashina API {r.status_code}: {r.text[:300]}")
        return r.json()
