"""対話 CLI。iPhone なしでエージェントの振る舞いを試すためのもの。

  テキスト          … 自分の発話として送る
  /other テキスト   … 他人の発話（クラウドに送らない）
  /todos            … ローカルの ToDo 一覧（API を使わない）
  /reset            … 会話履歴をリセット
  /quit             … 終了
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import anthropic
from dotenv import find_dotenv, load_dotenv

from .agent import AgentReply, VoiceAgent
from .todo_store import TodoStore
from .utterance import Speaker, Utterance

DEFAULT_TODO_FILE = Path(__file__).resolve().parents[2] / "data" / "todos.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="earagent", description="イヤホン音声エージェント（テキスト試作）")
    parser.add_argument("-p", "--prompt", help="1 回だけ送って終了する（自分の発話として）")
    parser.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    parser.add_argument("--todo-file", type=Path, default=Path(os.environ.get("EARAGENT_TODO_FILE", DEFAULT_TODO_FILE)))
    parser.add_argument("-v", "--verbose", action="store_true", help="ツール呼び出し・時間・トークンを表示")
    args = parser.parse_args(argv)

    load_dotenv(find_dotenv(usecwd=True))
    store = TodoStore(args.todo_file)
    agent = VoiceAgent(store, effort=args.effort)

    if args.prompt:
        return _send(agent, Utterance(args.prompt, Speaker.SELF), args.verbose)

    print("earagent: 話しかけてください（/other, /todos, /reset, /quit）")
    while True:
        try:
            line = input("あなた> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not line:
            continue
        if line in ("/quit", "/exit"):
            return 0
        if line == "/reset":
            agent.reset()
            print("（会話履歴をリセットしました）")
            continue
        if line == "/todos":
            todos = store.list(include_done=True)
            for t in todos:
                mark = "✓" if t.done else " "
                due = f" 期限:{t.due}" if t.due else ""
                print(f"  [{mark}] {t.id}. {t.title}{due}")
            if not todos:
                print("  （ToDo なし）")
            continue
        if line.startswith("/other "):
            _send(agent, Utterance(line.removeprefix("/other ").strip(), Speaker.OTHER), args.verbose)
            continue
        _send(agent, Utterance(line, Speaker.SELF), args.verbose)


def _send(agent: VoiceAgent, utterance: Utterance, verbose: bool) -> int:
    try:
        reply = agent.handle(utterance)
    except anthropic.AuthenticationError:
        print("エラー: API キーが無効です（.env の ANTHROPIC_API_KEY を確認）", file=sys.stderr)
        return 1
    except anthropic.RateLimitError:
        print("エラー: レート制限に達しました。少し待って再実行してください。", file=sys.stderr)
        return 1
    except anthropic.APIStatusError as e:
        print(f"エラー: API {e.status_code}: {e.message}", file=sys.stderr)
        return 1
    except anthropic.APIConnectionError:
        print("エラー: ネットワークに接続できません。", file=sys.stderr)
        return 1

    if reply is None:
        print(f"（{utterance.speaker.value} の発話のためクラウドに送信しません）")
        return 0
    print(f"エージェント> {reply.text}")
    if verbose:
        _print_stats(reply)
    return 0


def _print_stats(reply: AgentReply) -> None:
    tools = ", ".join(reply.tool_calls) or "なし"
    print(
        f"  [tools: {tools} | {reply.elapsed_sec:.1f}s"
        f" | in {reply.input_tokens} (cache read {reply.cache_read_tokens} / write {reply.cache_write_tokens})"
        f" / out {reply.output_tokens} tok | stop: {reply.stop_reason}]"
    )


if __name__ == "__main__":
    raise SystemExit(main())
