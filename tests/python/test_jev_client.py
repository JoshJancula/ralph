#!/usr/bin/env python3
"""Unit tests for bundle/.ralph/python/jev_client.py (Python peer of jev-client.sh).

REQUIRED ASSERTIONS:
  1. Five-token availability matrix (ok|disabled|no-key|no-curl|breaker-open).
  2. Registry thresholds match the bash peer for every seeded questionSetId.
  3. Breaker file is shared between peers.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY = REPO_ROOT / "bundle" / ".ralph" / "jev" / "questions.registry.json"
BASH_CLIENT = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "jev" / "jev-client.sh"
BASH_POLICY = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "jev" / "jev-policy.sh"
BASH_KEY = REPO_ROOT / "bundle" / ".ralph" / "bash-lib" / "jev" / "jev-key-store.sh"

jev = load_ralph_script("jev_client.py")


def _seeded_question_set_ids() -> list[str]:
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    sets = data.get("questionSets") or {}
    return sorted(sets.keys())


class JevClientTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmpdir = tempfile.mkdtemp(prefix="ralph-jev-client-py.")
        self.addCleanup(shutil.rmtree, self._tmpdir, ignore_errors=True)
        self.state_dir = os.path.join(self._tmpdir, "jev-state")
        os.makedirs(self.state_dir, exist_ok=True)

        self._env_patch = mock.patch.dict(
            os.environ,
            {
                "RALPH_WAIT_SCALE": "0",
                "RALPH_JEV_STATE_DIR": self.state_dir,
                "RALPH_JEV_REGISTRY": str(REGISTRY),
                "RALPH_DIR": str(REPO_ROOT / "bundle" / ".ralph"),
                "RALPH_CONFIG_HOME": os.path.join(self._tmpdir, "config"),
                "RALPH_PROJECT_ROOT": os.path.join(self._tmpdir, "project"),
                "HOME": os.path.join(self._tmpdir, "home"),
            },
            clear=False,
        )
        self._env_patch.start()
        self.addCleanup(self._env_patch.stop)
        os.makedirs(os.environ["RALPH_CONFIG_HOME"], exist_ok=True)
        os.makedirs(os.environ["RALPH_PROJECT_ROOT"], exist_ok=True)
        os.makedirs(os.environ["HOME"], exist_ok=True)

        for key in (
            "RALPH_JEV",
            "TYPESAFE_API_KEY",
            "RALPH_JEV_KEY_SOURCE",
            "RALPH_JEV_SHADOW",
            "JEV_TRANSPORT",
            "JEV_FIXTURE_DIR",
            "RALPH_JEV_MODEL",
        ):
            os.environ.pop(key, None)

    def _bash(self, script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged = dict(os.environ)
        if env:
            merged.update(env)
        merged["RALPH_WAIT_SCALE"] = "0"
        body = f"""
set -euo pipefail
source "{BASH_KEY}"
source "{BASH_CLIENT}"
source "{BASH_POLICY}"
{script}
"""
        return subprocess.run(
            ["bash", "-c", body],
            check=False,
            capture_output=True,
            text=True,
            env=merged,
            cwd=str(REPO_ROOT),
        )

    # ------------------------------------------------------------------
    # 1. Five-token availability matrix
    # ------------------------------------------------------------------

    def test_unavailable_reason_disabled_when_ralph_jev_unset(self) -> None:
        os.environ.pop("RALPH_JEV", None)
        os.environ["TYPESAFE_API_KEY"] = "k"
        self.assertFalse(jev.available())
        self.assertEqual(jev.unavailable_reason(), "disabled")

    def test_unavailable_reason_no_key(self) -> None:
        os.environ["RALPH_JEV"] = "1"
        os.environ.pop("TYPESAFE_API_KEY", None)
        self.assertFalse(jev.available())
        self.assertEqual(jev.unavailable_reason(), "no-key")

    def test_unavailable_reason_no_curl(self) -> None:
        os.environ["RALPH_JEV"] = "1"
        os.environ["TYPESAFE_API_KEY"] = "k"
        os.environ.pop("JEV_TRANSPORT", None)

        def fake_which(name: str):
            if name == "curl":
                return None
            return shutil.which(name)

        with mock.patch.object(jev, "_which", side_effect=fake_which):
            self.assertFalse(jev.available())
            self.assertEqual(jev.unavailable_reason(), "no-curl")

    def test_unavailable_reason_breaker_open(self) -> None:
        os.environ["RALPH_JEV"] = "1"
        os.environ["TYPESAFE_API_KEY"] = "k"
        jev.breaker_open("test")
        self.assertFalse(jev.available())
        self.assertEqual(jev.unavailable_reason(), "breaker-open")

    def test_unavailable_reason_ok_when_fully_usable(self) -> None:
        os.environ["RALPH_JEV"] = "1"
        os.environ["TYPESAFE_API_KEY"] = "k"
        os.environ["JEV_TRANSPORT"] = "fixture"
        self.assertTrue(jev.available())
        self.assertEqual(jev.unavailable_reason(), "ok")

    # ------------------------------------------------------------------
    # 2. Registry thresholds identical across peers
    # ------------------------------------------------------------------

    def test_registry_thresholds_match_bash_peer_for_every_seeded_set(self) -> None:
        ids = _seeded_question_set_ids()
        self.assertGreaterEqual(len(ids), 1, "registry must seed at least one question set")

        for qsid in ids:
            for which in ("act", "escalate"):
                py_val, py_code = jev.policy_threshold(qsid, which)
                self.assertEqual(py_code, 0, f"python threshold {qsid}/{which}")
                self.assertIsNotNone(py_val)

                completed = self._bash(
                    f'''
                    val="$(jev_policy_threshold "{qsid}" "{which}")" || exit 1
                    printf "%s\\n" "$val"
                    '''
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    f"bash threshold {qsid}/{which}: {completed.stderr}",
                )
                bash_raw = completed.stdout.strip()
                bash_val = float(bash_raw)
                self.assertEqual(
                    float(py_val),
                    bash_val,
                    f"threshold drift for {qsid}/{which}: py={py_val} bash={bash_raw}",
                )

    # ------------------------------------------------------------------
    # 3. Shared breaker file
    # ------------------------------------------------------------------

    def test_breaker_file_shared_bash_open_visible_to_python(self) -> None:
        breaker_path = Path(self.state_dir) / "breaker"
        self.assertFalse(breaker_path.is_file())

        completed = self._bash("jev_breaker_open test-from-bash >/dev/null")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(breaker_path.is_file())
        self.assertEqual(jev.breaker_state(), "open")

        os.environ["RALPH_JEV"] = "1"
        os.environ["TYPESAFE_API_KEY"] = "k"
        os.environ["JEV_TRANSPORT"] = "fixture"
        self.assertFalse(jev.available())
        self.assertEqual(jev.unavailable_reason(), "breaker-open")

    def test_breaker_file_shared_python_open_visible_to_bash(self) -> None:
        jev.breaker_open("test-from-python")
        completed = self._bash('printf "%s\\n" "$(jev_breaker_state)"')
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "open")

    # ------------------------------------------------------------------
    # 4. questionSetId never reaches the wire
    # ------------------------------------------------------------------

    def test_question_set_id_is_stripped_from_the_live_request_body(self) -> None:
        """SystemOne rejects unknown top-level fields with HTTP 400.

        questionSetId is Ralph-internal (fixture lookup, decision records), so
        the transport must drop it. Fixture replay keys off that field and so
        never caught this.
        """
        captured: dict[str, object] = {}

        class _FakeResponse:
            status = 200

            def read(self) -> bytes:
                return json.dumps(
                    {
                        "model": "jev-1.13.0",
                        "answers": {"has_failure": {"type": "noul", "noul": 0.5}},
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                    }
                ).encode("utf-8")

            def __enter__(self) -> "_FakeResponse":
                return self

            def __exit__(self, *_: object) -> bool:
                return False

        def _fake_urlopen(req: object, timeout: float = 0.0) -> "_FakeResponse":
            captured["body"] = json.loads(getattr(req, "data", b"{}").decode("utf-8"))
            return _FakeResponse()

        os.environ["RALPH_JEV"] = "1"
        os.environ["TYPESAFE_API_KEY"] = "typesafe-py-wire-test-key"
        os.environ.pop("JEV_TRANSPORT", None)

        request = {
            "state": "x",
            "model": "jev-latest",
            "questions": {"has_failure": {"type": "noul", "instructions": "q"}},
            "questionSetId": "graph.failure-class",
        }
        with mock.patch.object(jev.urllib.request, "urlopen", _fake_urlopen), mock.patch.object(
            jev, "_which", return_value="/usr/bin/curl"
        ):
            body, code = jev.post_systemone(request)

        self.assertEqual(code, 0, body)
        self.assertIn("body", captured)
        wire = captured["body"]
        assert isinstance(wire, dict)
        self.assertNotIn("questionSetId", wire)
        self.assertEqual(sorted(wire.keys()), ["model", "questions", "state"])
        # The caller's dict is untouched: the strip happens at the wire only.
        self.assertEqual(request["questionSetId"], "graph.failure-class")


if __name__ == "__main__":
    unittest.main()
