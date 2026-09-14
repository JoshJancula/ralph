#!/usr/bin/env python3
"""Exercise Ralph's real Claude launch against a local, non-billable API stub.

Unlike argv stubs, this proves Claude itself loads operator rules and executes
the Skill tool. Requires an installed Claude CLI, but no account or API key.
Run: python3 tests/acceptance/accept-claude-native-context.py --run-local-cli-acceptance
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MessagesAPI(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "count_tokens" in self.path:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"input_tokens":1000}')
            return
        self.requests.append(body)
        invoked = {
            block.get("input", {}).get("skill")
            for message in body.get("messages", [])
            for block in message.get("content", [])
            if isinstance(block, dict) and block.get("name") == "Skill"
        }
        skill = next((name for name in ("project-context-proof", "personal-context-proof")
                      if name not in invoked), None)
        content = ({"type": "tool_use", "id": f"tool-{skill}", "name": "Skill",
                    "input": {"skill": skill}} if skill else
                   {"type": "text", "text": "native-context-proof-complete"})
        reason = "tool_use" if skill else "end_turn"
        response = {
            "id": "msg-native-context", "type": "message", "role": "assistant",
            "model": body.get("model", "claude-haiku-4-5"), "content": [content],
            "stop_reason": reason, "stop_sequence": None,
            "usage": {"input_tokens": 1000, "output_tokens": 50},
        }
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if body.get("stream") else "application/json")
        self.end_headers()
        if not body.get("stream"):
            self.wfile.write(json.dumps(response).encode())
            return
        start = {**response, "content": [], "stop_reason": None}
        block = {**content, "input": {}} if skill else {"type": "text", "text": ""}
        delta = ({"type": "input_json_delta", "partial_json": json.dumps(content["input"])}
                 if skill else {"type": "text_delta", "text": content["text"]})
        events = [
            ("message_start", {"message": start}),
            ("content_block_start", {"index": 0, "content_block": block}),
            ("content_block_delta", {"index": 0, "delta": delta}),
            ("content_block_stop", {"index": 0}),
            ("message_delta", {"delta": {"stop_reason": reason, "stop_sequence": None},
                               "usage": {"output_tokens": 50}}),
            ("message_stop", {}),
        ]
        for name, fields in events:
            self.wfile.write(f"event: {name}\ndata: {json.dumps({'type': name, **fields})}\n\n".encode())
        self.wfile.flush()


def write_fixture(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def check_case(repo, cli, root, endpoint, mode, split):
    project = root / "project"
    personal = root / "personal-config"
    agent = root / "agent" if split else project
    agent.mkdir(parents=True, exist_ok=True)
    fixtures = {
        project / "CLAUDE.md": "PROJECT-MEMORY-PROOF-7e92\n@operator-context.md\n",
        project / "operator-context.md": "PROJECT-IMPORT-PROOF-9a12\n",
        project / ".claude/rules/operator.md": "PROJECT-RULE-PROOF-b834\n",
        personal / "CLAUDE.md": "PERSONAL-MEMORY-PROOF-f183\n",
        personal / "rules/operator.md": "PERSONAL-RULE-PROOF-c792\n",
        personal / "settings.json": json.dumps({"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": "printf 'PERSONAL-HOOK-PROOF-43ca\\n'"}]}]}}),
        project / ".claude/settings.json": json.dumps({"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": "printf 'PROJECT-HOOK-PROOF-38fa\\n'"}]}]}}),
        project / ".claude/settings.local.json": json.dumps({"hooks": {"SessionStart": [
            {"hooks": [{"type": "command", "command": "printf 'LOCAL-HOOK-PROOF-28ca\\n'"}]}]}}),
        project / ".claude/skills/project-context-proof/SKILL.md":
            "---\nname: project-context-proof\ndescription: Verify project operator context.\n---\nPROJECT-SKILL-BODY-PROOF-282a\n",
        personal / "skills/personal-context-proof/SKILL.md":
            "---\nname: personal-context-proof\ndescription: Verify personal operator context.\n---\nPERSONAL-SKILL-BODY-PROOF-362b\n",
    }
    for path, text in fixtures.items():
        write_fixture(path, text)
    (project / ".ralph").symlink_to(repo / "bundle/.ralph", target_is_directory=True)
    before = {path: path.read_bytes() for path in fixtures}
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CLAUDE", "ANTHROPIC", "RALPH"))}
    env.update({
        "ANTHROPIC_BASE_URL": endpoint, "ANTHROPIC_API_KEY": "local-test-not-a-real-key",
        "CLAUDE_CONFIG_DIR": str(personal), "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "1", "CLAUDE_PLAN_CLI": cli,
        "WORKSPACE": str(project), "RALPH_PROJECT_ROOT": str(project),
        "RALPH_AGENT_WORKSPACE": str(agent), "RALPH_PLAN_WORKSPACE_ROOT": str(root / "state"),
        "RALPH_MODE": mode, "RALPH_NATIVE_HOOKS": "off", "RALPH_PLAN_CAPTURE_USAGE": "1",
        "RALPH_PLAN_CLI_RESUME": "0", "RALPH_PLAN_SUBAGENTS": "inherit",
        "SELECTED_MODEL": "haiku", "RALPH_CLAUDE_MAX_BUDGET_USD": "1",
        "PROMPT_STATIC": "RALPH-APPENDED-INSTRUCTIONS-PROOF-19c7",
        "PROMPT": "Invoke project-context-proof and personal-context-proof using Skill, then finish.",
        "OUTPUT_LOG": str(root / "output.log"), "EXIT_CODE_FILE": str(root / "exit-code"),
        "SESSION_ID_FILE": str(root / "session-id"),
    })
    MessagesAPI.requests = []
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; ralph_run_plan_invoke_claude', "_",
         str(repo / "bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh")],
        cwd=agent, env=env, text=True, capture_output=True, timeout=90,
    )
    requests = MessagesAPI.requests
    assert result.returncode == 0 and requests, f"Claude failed: {result.stdout}\n{result.stderr}"
    first = json.dumps(requests[0])
    for marker in ("PROJECT-MEMORY-PROOF-7e92",
                   "PROJECT-RULE-PROOF-b834", "PERSONAL-MEMORY-PROOF-f183",
                   "PERSONAL-RULE-PROOF-c792", "PERSONAL-HOOK-PROOF-43ca",
                   "RALPH-APPENDED-INSTRUCTIONS-PROOF-19c7"):
        assert marker in first, f"{mode} split={split}: missing startup context {marker}"
    if not split:
        for marker in ("PROJECT-IMPORT-PROOF-9a12", "PROJECT-HOOK-PROOF-38fa", "LOCAL-HOOK-PROOF-28ca"):
            assert marker in first, f"Project context missing: {marker}"
    # Claude requires its own approval for imports outside the agent cwd.
    # A fresh split workspace has no such approval; Ralph must not forge it.
    assert "Skill" in {tool["name"] for tool in requests[0].get("tools", [])}, "Skill tool missing"
    transcript = json.dumps(requests)
    for marker in ("PROJECT-SKILL-BODY-PROOF-282a", "PERSONAL-SKILL-BODY-PROOF-362b"):
        assert marker in transcript, f"{mode} split={split}: Skill did not load {marker}"
    assert before == {path: path.read_bytes() for path in fixtures}, "Operator files changed"
    print(f"PASS: {mode}, {'separate' if split else 'same'} workspace: rules, skills, personal hooks, additive prompt, unchanged files"
          + ("; project/local hooks and imports" if not split else ""), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-local-cli-acceptance", action="store_true", required=True)
    args = parser.parse_args()
    assert args.run_local_cli_acceptance
    cli = shutil.which("claude")
    if not cli:
        parser.error("Claude CLI is required")
    repo = Path(__file__).resolve().parents[2]
    server = ThreadingHTTPServer(("127.0.0.1", 0), MessagesAPI)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="ralph-native-context-") as directory:
            for mode, split in (("native", False), ("no", True), ("hybrid", True)):
                root = Path(directory) / f"{mode}-{split}"
                check_case(repo, cli, root, f"http://127.0.0.1:{server.server_port}", mode, split)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
