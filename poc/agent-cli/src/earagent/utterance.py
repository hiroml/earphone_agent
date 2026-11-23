"""発話と、クラウド送信可否のゲート。

方針（ADR-0002 提案中）: クラウドの LLM に送るのは「ユーザー本人の発話」と判定されたものだけ。
他人の発話・判定不能な発話は端末外に出さない。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class Speaker(Enum):
    SELF = "self"
    OTHER = "other"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class Utterance:
    text: str
    speaker: Speaker
    at: datetime = field(default_factory=lambda: datetime.now().astimezone())


def may_send_to_cloud(u: Utterance) -> bool:
    """クラウド（Claude API）に送ってよい発話か。"""
    return u.speaker is Speaker.SELF and bool(u.text.strip())
