"""ローカル ToDo ストア（JSON ファイル）。

PoC 用の最小実装。iOS 統合時にリマインダー（EventKit）等へ差し替える想定で、
エージェントからはこのクラスのインターフェースだけを使う。
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path


@dataclass
class Todo:
    id: int
    title: str
    due: str | None
    note: str | None
    done: bool
    created_at: str
    done_at: str | None = None


class TodoNotFoundError(KeyError):
    pass


class TodoStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    # ---- 公開 API ----

    def add(self, title: str, due: str | None = None, note: str | None = None) -> Todo:
        title = title.strip()
        if not title:
            raise ValueError("title が空です")
        todos = self._load()
        next_id = max((t.id for t in todos), default=0) + 1
        todo = Todo(
            id=next_id,
            title=title,
            due=(due or None),
            note=(note or None),
            done=False,
            created_at=_now(),
        )
        todos.append(todo)
        self._save(todos)
        return todo

    def list(self, include_done: bool = False) -> list[Todo]:
        todos = self._load()
        return todos if include_done else [t for t in todos if not t.done]

    def complete(self, todo_id: int) -> Todo:
        todos = self._load()
        for t in todos:
            if t.id == todo_id:
                if not t.done:
                    t.done = True
                    t.done_at = _now()
                    self._save(todos)
                return t
        raise TodoNotFoundError(todo_id)

    # ---- 永続化 ----

    def _load(self) -> list[Todo]:
        if not self.path.exists():
            return []
        data = json.loads(self.path.read_text(encoding="utf-8"))
        return [Todo(**item) for item in data]

    def _save(self, todos: list[Todo]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps([asdict(t) for t in todos], ensure_ascii=False, indent=2)
        # 途中で落ちても壊れないよう一時ファイル経由で置き換える
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".todos-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(payload)
            os.replace(tmp, self.path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")
