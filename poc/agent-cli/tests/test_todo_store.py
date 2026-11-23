import json

import pytest

from earagent.todo_store import TodoNotFoundError, TodoStore


@pytest.fixture
def store(tmp_path):
    return TodoStore(tmp_path / "sub" / "todos.json")


def test_add_assigns_incrementing_ids_and_persists(store):
    a = store.add("牛乳を買う")
    b = store.add("資料を送る", due="2026-11-30", note="田中さん宛て")
    assert (a.id, b.id) == (1, 2)
    assert b.due == "2026-11-30" and b.note == "田中さん宛て"

    reloaded = TodoStore(store.path)
    assert [t.title for t in reloaded.list()] == ["牛乳を買う", "資料を送る"]
    # 日本語がエスケープされずに保存される
    assert "牛乳" in store.path.read_text(encoding="utf-8")


def test_empty_title_is_rejected(store):
    with pytest.raises(ValueError):
        store.add("   ")


def test_null_like_fields_become_none(store):
    t = store.add("散歩", due="", note=None)
    assert t.due is None and t.note is None


def test_complete_hides_from_default_list(store):
    store.add("A")
    b = store.add("B")
    done = store.complete(b.id)
    assert done.done and done.done_at
    assert [t.title for t in store.list()] == ["A"]
    assert len(store.list(include_done=True)) == 2


def test_complete_is_idempotent(store):
    t = store.add("A")
    first = store.complete(t.id).done_at
    assert store.complete(t.id).done_at == first


def test_complete_unknown_id_raises(store):
    with pytest.raises(TodoNotFoundError):
        store.complete(99)


def test_file_is_valid_json_after_writes(store):
    for i in range(5):
        store.add(f"task {i}")
    data = json.loads(store.path.read_text(encoding="utf-8"))
    assert len(data) == 5
