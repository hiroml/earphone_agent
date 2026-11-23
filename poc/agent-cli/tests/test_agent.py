"""API を呼ばないテスト: 送信ゲートとクライアントツールの実行。"""

import json
from types import SimpleNamespace

import pytest

from earagent.agent import VoiceAgent
from earagent.todo_store import TodoStore
from earagent.utterance import Speaker, Utterance, may_send_to_cloud


class ExplodingClient:
    """呼ばれたら失敗するクライアント（送信されないことの確認用）。"""

    def __getattr__(self, name):
        raise AssertionError("API が呼ばれてはいけない")


@pytest.fixture
def agent(tmp_path):
    return VoiceAgent(TodoStore(tmp_path / "todos.json"), client=ExplodingClient())


@pytest.mark.parametrize(
    ("speaker", "text", "expected"),
    [
        (Speaker.SELF, "牛乳買わなきゃ", True),
        (Speaker.OTHER, "来週までに送ってね", False),
        (Speaker.UNKNOWN, "何か", False),
        (Speaker.SELF, "   ", False),
    ],
)
def test_may_send_to_cloud(speaker, text, expected):
    assert may_send_to_cloud(Utterance(text, speaker)) is expected


@pytest.mark.parametrize("speaker", [Speaker.OTHER, Speaker.UNKNOWN])
def test_non_self_utterance_is_not_sent(agent, speaker):
    assert agent.handle(Utterance("来週までに資料送って", speaker)) is None
    assert agent.messages == []


def test_add_and_list_todo_tools(agent):
    r = agent._run_tool("t1", "add_todo", {"title": "資料を送る", "due": "2026-11-30", "note": None})
    assert r["is_error"] is False and r["tool_use_id"] == "t1"
    assert json.loads(r["content"])["title"] == "資料を送る"

    r = agent._run_tool("t2", "list_todos", {"include_done": False})
    assert [t["title"] for t in json.loads(r["content"])] == ["資料を送る"]


def test_complete_unknown_todo_returns_error_result(agent):
    r = agent._run_tool("t3", "complete_todo", {"todo_id": 42})
    assert r["is_error"] is True and "見つかりません" in r["content"]


def test_unknown_tool_returns_error_result(agent):
    r = agent._run_tool("t4", "delete_everything", {})
    assert r["is_error"] is True


def test_list_empty(agent):
    r = agent._run_tool("t5", "list_todos", {"include_done": True})
    assert r["content"] == "ToDo はありません。"


def test_refusal_stops_loop(tmp_path):
    response = SimpleNamespace(
        stop_reason="refusal",
        content=[],
        usage=SimpleNamespace(input_tokens=1, output_tokens=0, cache_read_input_tokens=0, cache_creation_input_tokens=None),
    )
    client = SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(create=lambda **_: response)))
    agent = VoiceAgent(TodoStore(tmp_path / "t.json"), client=client)
    reply = agent.handle(Utterance("…", Speaker.SELF))
    assert reply is not None and reply.stop_reason == "refusal"
    assert "お答えできません" in reply.text
