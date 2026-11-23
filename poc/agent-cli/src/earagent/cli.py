"""対話 CLI。iPhone なしでエージェントの振る舞いを試すためのもの。

  テキスト          … 自分の発話として送る
  /other テキスト   … 他人の発話（クラウドに送らない）
  /todos            … ローカルの ToDo 一覧（API を使わない）
  /reset            … 会話履歴をリセット
  /quit             … 終了

LLM は --provider で切り替える（claude: 既定 / sarashina: 日本語特化、Web 検索なし）。
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import anthropic
import httpx
from dotenv import find_dotenv, load_dotenv

from .agent import AgentReply, VoiceAgent
from .sarashina import DEFAULT_MODEL as SARASHINA_DEFAULT_MODEL
from .sarashina import SarashinaAgent, SarashinaError, SarashinaRateLimitError
from .todo_store import TodoStore
from .utterance import Speaker, Utterance

DEFAULT_TODO_FILE = Path(__file__).resolve().parents[2] / "data" / "todos.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="earagent", description="イヤホン音声エージェント（テキスト試作）")
    parser.add_argument("-p", "--prompt", help="1 回だけ送って終了する（自分の発話として）")
    parser.add_argument("--provider", default="claude", choices=["claude", "sarashina"], help="使う LLM")
    parser.add_argument("--model", help=f"sarashina のモデル（既定: {SARASHINA_DEFAULT_MODEL}）")
    parser.add_argument(
        "--effort",
        default="medium",
        choices=["low", "medium", "high", "xhigh", "max"],
        help="推論の深さ（sarashina の推論モデルは low/medium/high のみ）",
    )
    parser.add_argument("--todo-file", type=Path, default=Path(os.environ.get("EARAGENT_TODO_FILE", DEFAULT_TODO_FILE)))
    parser.add_argument("-v", "--verbose", action="store_true", help="ツール呼び出し・時間・トークンを表示")
    args = parser.parse_args(argv)

    load_dotenv(find_dotenv(usecwd=True))
    store = TodoStore(args.todo_file)
    try:
        agent = _build_agent(args, store)
    except SarashinaError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return 2

    if args.prompt:
        return _send(agent, Utterance(args.prompt, Speaker.SELF), args.verbose)

    print(f"earagent [{_describe(agent)}]: 話しかけてください（/other, /todos, /reset, /quit）")
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


Agent = VoiceAgent | SarashinaAgent


def _build_agent(args: argparse.Namespace, store: TodoStore) -> Agent:
    if args.provider == "sarashina":
        if args.effort not in ("low", "medium", "high"):
            raise SarashinaError("sarashina の --effort は low / medium / high のいずれかです")
        return SarashinaAgent(store, model=args.model or SARASHINA_DEFAULT_MODEL, reasoning_effort=args.effort)
    if args.model:
        raise SarashinaError("--model は --provider sarashina のときだけ指定できます")
    return VoiceAgent(store, effort=args.effort)


def _describe(agent: Agent) -> str:
    if isinstance(agent, SarashinaAgent):
        return f"sarashina / {agent.model}"
    return "claude / claude-opus-5-5"


def _send(agent: Agent, utterance: Utterance, verbose: bool) -> int:
    try:
        reply = agent.handle(utterance)
    except SarashinaRateLimitError as e:
        print(f"エラー: Sarashina の{e}", file=sys.stderr)
        return 1
    except SarashinaError as e:
        print(f"エラー: {e}", file=sys.stderr)
        return 1
    except httpx.HTTPError as e:
        print(f"エラー: Sarashina API に接続できません（{type(e).__name__}）", file=sys.stderr)
        return 1
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
