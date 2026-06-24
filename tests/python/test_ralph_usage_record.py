import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "bundle/.ralph/python/ralph-usage-record.py"
PYTHONPATH_DIR = REPO_ROOT / "bundle/.ralph/python"


def _run_usage_record(
    tmp_path: Path,
    plan_key: str,
    start: str,
    end: str,
    workspace_root: Path,
    runtime: str = "cursor",
    env_overrides: dict | None = None,
) -> dict:
    usage_file = tmp_path / "usage.json"
    usage_file.parent.mkdir(parents=True, exist_ok=True)
    workspace_root.mkdir(parents=True, exist_ok=True)
    tool_results_dir = workspace_root / "tool-results" / plan_key
    tool_results_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["RALPH_PLAN_WORKSPACE_ROOT"] = str(workspace_root)
    env["PYTHONPATH"] = str(PYTHONPATH_DIR)
    if env_overrides:
        for k, v in env_overrides.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = str(v)
    cmd = [
        sys.executable,
        str(SCRIPT_PATH),
        str(usage_file),
        "1",
        "test-model",
        runtime,
        "5",
        "100",
        "10",
        "20",
        "0",
        "0",
        "0.0",
        start,
        end,
        plan_key,
        "",
        "fresh",
        "",
        "",
        "0",
        "",
        "",
        "0",
        "0",
        "0",
        "0",
        "",
        "0",
        "",
        "0",
        "",
        "",
        "",
    ]
    subprocess.run(cmd, check=True, env=env)
    with open(usage_file, "r", encoding="utf-8") as fh:
        return json.load(fh)


def test_proxy_read_bytes_populated(tmp_path: Path):
    plan_key = "read-bytes-fixture"
    workspace_root = tmp_path / "workspace"
    tool_results_dir = workspace_root / "tool-results" / plan_key
    tool_results_dir.mkdir(parents=True, exist_ok=True)
    entry = {
        "id": "entry123",
        "storedAt": "2026-01-01T00:02:00Z",
        "bytes": 5000,
        "tool": "ralph_proxy_read",
        "path": str(tool_results_dir / "entry123.txt"),
        "metadata": {
            "storageLayout": "window",
            "window": {
                "lineStart": 1,
                "lineEnd": 10,
                "lineLimit": 500,
                "lineCount": 10,
                "byteCount": 2048,
                "policyLimited": False,
            },
        },
    }
    index_path = tool_results_dir / "index.jsonl"
    index_path.parent.mkdir(parents=True, exist_ok=True)
    index_path.write_text(json.dumps(entry) + "\n", encoding="utf-8")

    doc = _run_usage_record(
        tmp_path,
        plan_key,
        start="2026-01-01T00:01:00Z",
        end="2026-01-01T00:03:00Z",
        workspace_root=workspace_root,
    )
    invocation = doc["invocations"][0]
    assert invocation["proxy_read_bytes"] == 2048


def test_proxy_read_bytes_missing_without_index(tmp_path: Path):
    plan_key = "missing-index-fixture"
    workspace_root = tmp_path / "workspace"
    doc = _run_usage_record(
        tmp_path,
        plan_key,
        start="2026-01-01T00:01:00Z",
        end="2026-01-01T00:03:00Z",
        workspace_root=workspace_root,
    )
    invocation = doc["invocations"][0]
    assert "proxy_read_bytes" not in invocation


def test_opencode_cache_key_injected_env_var_true(tmp_path: Path):
    plan_key = "opencode-cache-key-injected-true"
    workspace_root = tmp_path / "workspace"
    doc = _run_usage_record(
        tmp_path,
        plan_key,
        start="2026-01-01T00:01:00Z",
        end="2026-01-01T00:03:00Z",
        workspace_root=workspace_root,
        runtime="opencode",
        env_overrides={"RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED": "1"},
    )
    invocation = doc["invocations"][0]
    assert invocation["opencode_cache_key_injected"] is True


def test_usage_record_writes_canonical_fields(tmp_path: Path):
    plan_key = "canonical-fields-fixture"
    workspace_root = tmp_path / "workspace"
    doc = _run_usage_record(
        tmp_path,
        plan_key,
        start="2026-01-01T00:01:00Z",
        end="2026-01-01T00:03:00Z",
        workspace_root=workspace_root,
    )
    assert doc["schema_version"] == 2
    invocation = doc["invocations"][0]
    assert invocation["uncached_input_tokens"] == 100
    assert invocation["total_input_tokens"] == 120
    assert invocation["cache_efficiency_ratio"] == round(0 / 120, 4)
    assert invocation["measurement_source"]["uncached_input_tokens"] == "measured"
    assert invocation["measurement_source"]["cache_read_input_tokens"] == "measured"


def test_opencode_cache_key_injected_env_var_absent(tmp_path: Path):
    plan_key = "opencode-cache-key-injected-absent"
    workspace_root = tmp_path / "workspace"
    doc = _run_usage_record(
        tmp_path,
        plan_key,
        start="2026-01-01T00:01:00Z",
        end="2026-01-01T00:03:00Z",
        workspace_root=workspace_root,
        runtime="opencode",
        env_overrides={"RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED": None},
    )
    invocation = doc["invocations"][0]
    assert invocation["opencode_cache_key_injected"] is False


class RalphUsageRecordOpencodeCacheKeyInjectedTests(unittest.TestCase):
    def test_opencode_cache_key_injected_env_var_true(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp_path = Path(td)
            workspace_root = tmp_path / "workspace"
            plan_key = "opencode-cache-key-injected-true-unittest"
            doc = _run_usage_record(
                tmp_path,
                plan_key,
                start="2026-01-01T00:01:00Z",
                end="2026-01-01T00:03:00Z",
                workspace_root=workspace_root,
                runtime="opencode",
                env_overrides={"RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED": "1"},
            )
            invocation = doc["invocations"][0]
            self.assertIs(invocation["opencode_cache_key_injected"], True)

    def test_opencode_cache_key_injected_env_var_absent(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp_path = Path(td)
            workspace_root = tmp_path / "workspace"
            plan_key = "opencode-cache-key-injected-absent-unittest"
            doc = _run_usage_record(
                tmp_path,
                plan_key,
                start="2026-01-01T00:01:00Z",
                end="2026-01-01T00:03:00Z",
                workspace_root=workspace_root,
                runtime="opencode",
                env_overrides={"RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED": None},
            )
            invocation = doc["invocations"][0]
            self.assertIs(invocation["opencode_cache_key_injected"], False)
