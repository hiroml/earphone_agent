"""Sarashina エージェントのテスト（httpx.MockTransport で API を模擬。実 API は呼ばない）。"""

import json

import httpx
import pytest

from earagent.sarashina import API_URL, SarashinaAgent, SarashinaError, SarashinaRateLimitError
from earagent.todo_store import TodoStore
from earagent.utterance import Speaker, Utterance


def _completion(message: dict, finish: str = "stop") -> dict:
    return {
        "id": "x",
        "object": "chat.completion",
        "choices": [{"index": 0, "message": message, "finish_reason": finish, "logprobs": None}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    }


class Scripted:
    """順番にレスポンスを返し、受け取ったリクエストを記録する。"""

    def __init__(self, responses: list[httpx.Response]) -> None:
        self.responses = list(responses)
        self.requests: list[dict] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        assert str(request.url) == API_URL
        assert request.headers["Authorization"] == "Bearer test-key"
        self.requests.append(json.loads(request.content))
        return self.responses.pop(0)


def _agent(tmp_path, handler, model="sarashina3.2-mini-thinking") -> SarashinaAgent:
    return SarashinaAgent(
        TodoStore(tmp_path / "todos.json"),
        api_key="test-key",
        model=model,
        http_client=httpx.Client(transport=httpx.MockTransport(handler)),
    )


def test_missing_api_key_raises(tmp_path, monkeypatch):
    monkeypatch.delenv("SARASHINA_API_KEY", raising=False)
    with pytest.raises(SarashinaError):
        SarashinaAgent(TodoStore(tmp_path / "t.json"))


def test_tool_call_then_answer(tmp_path):
    tool_msg = {
        "role": "assistant",
        "content": "",
        "reasoning": "ENCRYPTED==",
        "tool_calls": [
            {
                "id": "call-1",
                "type": "function",
                "function": {"name": "add_todo", "arguments": json.dumps({"title": "見積書を送る", "due": "2026-11-27", "note": None})},
            }
        ],
    }
    handler = Scripted(
        [
            httpx.Response(200, json=_completion(tool_msg, "tool_calls")),
            httpx.Response(200, json=_completion({"role": "assistant", "content": "ToDoに入れました。", "tool_calls": None})),
        ]
    )
    agent = _agent(tmp_path, handler)
    reply = agent.handle(Utterance("金曜までに見積書送らないと", Speaker.SELF))

    assert reply is not None and reply.text == "ToDoに入れました。"
    assert reply.tool_calls == ["add_todo"]
    assert [t.title for t in agent.todos.list()] == ["見積書を送る"]

    first, second = handler.requests
    assert first["messages"][0]["role"] == "system"
    assert first["reasoning_effort"] == "medium"
    assert first["tools"][0]["type"] == "function"
    # 2 回目: 推論結果（reasoning）をそのまま返し、tool の結果を tool_call_id 付きで送る
    assert second["messages"][-2]["reasoning"] == "ENCRYPTED=="
    assert second["messages"][-1] == {"role": "tool", "tool_call_id": "call-1", "content": second["messages"][-1]["content"]}
    assert "見積書を送る" in second["messages"][-1]["content"]
    # None のキーは履歴に残さない
    assert "tool_calls" not in agent.messages[-1]


def test_invalid_tool_arguments_returns_error_to_model(tmp_path):
    bad = {
        "role": "assistant",
        "content": "",
        "tool_calls": [{"id": "c", "type": "function", "function": {"name": "add_todo", "arguments": "{oops"}}],
    }
    handler = Scripted(
        [
            httpx.Response(200, json=_completion(bad, "tool_calls")),
            httpx.Response(200, json=_completion({"role": "assistant", "content": "すみません。"})),
        ]
    )
    agent = _agent(tmp_path, handler)
    agent.handle(Utterance("…", Speaker.SELF))
    assert handler.requests[1]["messages"][-1]["content"].startswith("エラー:")
    assert agent.todos.list() == []


def test_non_thinking_model_has_no_reasoning_effort(tmp_path):
    handler = Scripted([httpx.Response(200, json=_completion({"role": "assistant", "content": "はい"}))])
    agent = _agent(tmp_path, handler, model="sarashina3-nano")
    agent.handle(Utterance("こんにちは", Speaker.SELF))
    assert "reasoning_effort" not in handler.requests[0]
    assert handler.requests[0]["max_completion_tokens"] <= 8000


def test_other_speaker_is_not_sent(tmp_path):
    handler = Scripted([])
    agent = _agent(tmp_path, handler)
    assert agent.handle(Utterance("来週までに送って", Speaker.OTHER)) is None
    assert handler.requests == []


def test_rate_limit(tmp_path):
    handler = Scripted([httpx.Response(429, headers={"Retry-After": "12"}, json={"message": "Too Many Requests"})])
    agent = _agent(tmp_path, handler)
    with pytest.raises(SarashinaRateLimitError) as e:
        agent.handle(Utterance("…", Speaker.SELF))
    assert e.value.retry_after == 12


def test_http_error(tmp_path):
    handler = Scripted([httpx.Response(400, json={"message": "Bad Request"})])
    agent = _agent(tmp_path, handler)
    with pytest.raises(SarashinaError, match="400"):
        agent.handle(Utterance("…", Speaker.SELF))
