#!/usr/bin/env python3
"""Jev (TypeSafe AI) optional HTTP client — Python peer of jev-client.sh.

Compaction and other Python surfaces call this module because they already
depend on python3. It MUST share configuration with the bash peer:

  * the same bundle/.ralph/jev/questions.registry.json (or RALPH_JEV_REGISTRY)
  * the same Section B environment variables
  * the same breaker file under RALPH_JEV_STATE_DIR

So RALPH_JEV_SHADOW=1 yields shadow behavior on both peers, and a breaker
opened by bash is observed here (and vice versa).

STDLIB ONLY. Do not import requests, typesafe_sdk, httpx, or yaml.

Section C exit codes, expressed as the ``code`` half of ``(value, code)``
tuples (except boolean / string helpers noted below):

  0  success
  1  declined / unavailable (normal; silent)
  2  transport, HTTP, or protocol error
  3  input rejected before any network use

Jev is always optional. No failure path here may fail a Ralph run.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, MutableMapping, Optional

# Sibling redaction helper (first-party, not a third-party dependency).
_MODULE_DIR = Path(__file__).resolve().parent
if str(_MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(_MODULE_DIR))

try:
    from jev_redact import redact_text as _redact_text
except ImportError:  # pragma: no cover - fail closed at call sites
    _redact_text = None  # type: ignore[assignment]

_DEFAULT_RALPH_DIR = _MODULE_DIR.parent
_DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
_DEFAULT_MODEL = "jev-latest"
_DEFAULT_TIMEOUT_MS = 4000
_DEFAULT_MAX_RETRIES = 2
_MAX_TOKENS = 32000
_BYTES_PER_TOKEN = 4
_BUDGET_BYTES = _MAX_TOKENS * _BYTES_PER_TOKEN
_QSID_SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
_JEV_KEYCHAIN_SERVICE = "ralph.jev"
_JEV_KEYCHAIN_ACCOUNT = "TYPESAFE_API_KEY"


# ---------------------------------------------------------------------------
# Env / path helpers (Section B)
# ---------------------------------------------------------------------------


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= 0 else default


def state_dir() -> str:
    """Resolve RALPH_JEV_STATE_DIR. Default: <state_root>/jev."""
    explicit = _env("RALPH_JEV_STATE_DIR")
    if explicit:
        return explicit.rstrip("/")
    state_root = _env("RALPH_PLAN_WORKSPACE_ROOT") or os.path.join(
        os.getcwd(), ".ralph-workspace"
    )
    return os.path.join(state_root.rstrip("/"), "jev")


def registry_path() -> str:
    """Resolve RALPH_JEV_REGISTRY. Default: <RALPH_DIR>/jev/questions.registry.json."""
    explicit = _env("RALPH_JEV_REGISTRY")
    if explicit:
        return explicit
    ralph_dir = _env("RALPH_DIR") or str(_DEFAULT_RALPH_DIR)
    return os.path.join(ralph_dir.rstrip("/"), "jev", "questions.registry.json")


def _artifact_ns() -> str:
    return _env("RALPH_ARTIFACT_NS") or _env("RALPH_PLAN_KEY") or ""


def _workspace_root() -> str:
    if _env("RALPH_PROJECT_ROOT"):
        return _env("RALPH_PROJECT_ROOT").rstrip("/")
    if _env("RALPH_MCP_WORKSPACE"):
        return _env("RALPH_MCP_WORKSPACE").rstrip("/")
    return os.getcwd().rstrip("/")


def _config_home() -> Optional[str]:
    """Mirror ralph_model_store_config_dir (RALPH_CONFIG_HOME / XDG / ~/.config/ralph)."""
    if _env("RALPH_CONFIG_HOME"):
        return _env("RALPH_CONFIG_HOME").rstrip("/")
    base = _env("XDG_CONFIG_HOME")
    if not base:
        home = _env("HOME")
        if not home:
            return None
        base = os.path.join(home, ".config")
    return os.path.join(base.rstrip("/"), "ralph")


def _fixture_dir() -> str:
    return _env("JEV_FIXTURE_DIR") or "tests/fixtures/jev"


def _timeout_secs() -> int:
    ms = _env_int("RALPH_JEV_TIMEOUT_MS", _DEFAULT_TIMEOUT_MS)
    secs = (ms + 999) // 1000
    return max(1, secs)


def _max_retries() -> int:
    return _env_int("RALPH_JEV_MAX_RETRIES", _DEFAULT_MAX_RETRIES)


def _transport() -> str:
    return _env("JEV_TRANSPORT") or "https"


def _is_shadow() -> bool:
    return _env("RALPH_JEV_SHADOW") == "1"


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def _atomic_write(path: str, content: str) -> bool:
    directory = os.path.dirname(path)
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return False
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(content if content.endswith("\n") else content + "\n")
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def _append_jsonl(path: str, line: str) -> bool:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line.rstrip("\n") + "\n")
        return True
    except OSError:
        return False


def _usage_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return max(0, int(value))


def record_usage(
    request_obj: Mapping[str, Any], response_body: Mapping[str, Any]
) -> None:
    """Append one per-call usage line to <state_dir>/usage.jsonl. Best-effort.

    Written from the transport so every live call site is covered, including
    ones that never write a decision record. Only successful calls are
    recorded; retried 429/529 attempts are not.
    """
    try:
        usage = response_body.get("usage")
        in_tok = out_tok = None
        if isinstance(usage, Mapping):
            in_tok = _usage_int(usage.get("input_tokens"))
            out_tok = _usage_int(usage.get("output_tokens"))
        measured = in_tok is not None or out_tok is not None
        model = response_body.get("model")
        record = {
            "timestamp": _iso_now(),
            "model": model if _model_is_resolved(model) else "",
            "questionSetId": str(request_obj.get("questionSetId") or ""),
            "input_tokens": in_tok or 0,
            "output_tokens": out_tok or 0,
            "usageSource": "measured" if measured else "unavailable",
            "transport": _transport(),
            "planKey": _artifact_ns(),
        }
        _append_jsonl(
            os.path.join(state_dir(), "usage.jsonl"),
            json.dumps(record, separators=(",", ":"), ensure_ascii=False),
        )
    except Exception:
        return


def _which(name: str) -> bool:
    return shutil.which(name) is not None


# ---------------------------------------------------------------------------
# Key resolution (Section G) — mirrors jev-key-store.sh
# ---------------------------------------------------------------------------


def _set_key_source(token: str) -> None:
    os.environ["RALPH_JEV_KEY_SOURCE"] = token


def _env_file_enabled() -> bool:
    return _env("RALPH_JEV_ENV_FILE", "1") != "0"


def _parse_env_typesafe_key(path: str) -> Optional[str]:
    """Parse-only dotenv carve-out: extract TYPESAFE_API_KEY, never source/eval."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                line = raw.rstrip("\r\n")
                line = line.lstrip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export ") or line.startswith("export\t"):
                    line = line[6:].lstrip()
                if not line.startswith("TYPESAFE_API_KEY="):
                    continue
                val = line[len("TYPESAFE_API_KEY=") :]
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                    val = val[1:-1]
                else:
                    val = val.rstrip()
                return val if val else None
    except OSError:
        return None
    return None


def _keychain_available() -> bool:
    system = platform.system()
    if system == "Darwin":
        return _which("security")
    return _which("secret-tool")


def _keychain_get() -> Optional[str]:
    try:
        if platform.system() == "Darwin":
            completed = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-s",
                    _JEV_KEYCHAIN_SERVICE,
                    "-a",
                    _JEV_KEYCHAIN_ACCOUNT,
                    "-w",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=_timeout_secs(),
            )
        else:
            completed = subprocess.run(
                [
                    "secret-tool",
                    "lookup",
                    "service",
                    _JEV_KEYCHAIN_SERVICE,
                    "account",
                    _JEV_KEYCHAIN_ACCOUNT,
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=_timeout_secs(),
            )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    key = (completed.stdout or "").rstrip("\n")
    return key or None


def _run_key_command(cmd: str) -> Optional[str]:
    try:
        completed = subprocess.run(
            ["bash", "-c", cmd],
            check=False,
            capture_output=True,
            text=True,
            timeout=_timeout_secs(),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    key = (completed.stdout or "").rstrip("\n")
    return key or None


def _credentials_cfg() -> Optional[dict[str, Any]]:
    home = _config_home()
    if not home:
        return None
    path = os.path.join(home, "jev-credentials.json")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def key_resolve() -> Optional[str]:
    """Section G chain. Returns the key or None. Sets RALPH_JEV_KEY_SOURCE."""
    env_key = _env("TYPESAFE_API_KEY")
    if env_key:
        _set_key_source("env")
        return env_key

    if _env_file_enabled():
        env_path = os.path.join(_workspace_root(), ".env")
        if os.path.isfile(env_path):
            val = _parse_env_typesafe_key(env_path)
            if val:
                _set_key_source("env-file")
                return val

    cfg = _credentials_cfg()
    if cfg is None:
        _set_key_source("none")
        return None

    cmd = cfg.get("command")
    if isinstance(cmd, str) and cmd:
        _set_key_source("command")
        return _run_key_command(cmd)

    if cfg.get("keychain") is True:
        if _keychain_available():
            _set_key_source("keychain")
            return _keychain_get()
        # Tooling absent: skip silently to next backend.

    if cfg.get("file") is True:
        _set_key_source("file")
        home = _config_home()
        if not home:
            return None
        path = os.path.join(home, "jev-api-key")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                key = handle.read().rstrip("\n")
        except OSError:
            return None
        return key or None

    _set_key_source("none")
    return None


# ---------------------------------------------------------------------------
# Circuit breaker — shared file with the bash peer
# ---------------------------------------------------------------------------


def _breaker_path() -> str:
    return os.path.join(state_dir(), "breaker")


def _breaker_load() -> tuple[str, int]:
    path = _breaker_path()
    if not os.path.isfile(path):
        return "closed", 0
    try:
        with open(path, "r", encoding="utf-8") as handle:
            line = handle.readline().strip()
    except OSError:
        return "closed", 0
    parts = line.split()
    state = parts[0] if parts else "closed"
    if state not in ("open", "closed"):
        state = "closed"
    consecutive = 0
    if len(parts) > 1 and parts[1].isdigit():
        consecutive = int(parts[1])
    return state, consecutive


def _breaker_store(state: str, consecutive: int) -> None:
    _atomic_write(_breaker_path(), f"{state} {consecutive}")


def _breaker_emit_open_decision() -> None:
    record = {
        "decision": "fallback",
        "reason": "breaker-open",
        "breakerState": "open",
        "fallbackUsed": True,
    }
    record_decision(record)


def breaker_state() -> str:
    """Return ``closed`` or ``open``."""
    state, _ = _breaker_load()
    return state or "closed"


def breaker_open(reason: str = "") -> None:
    """Force-open the breaker. Emits one decision on closed->open only."""
    del reason  # caller context; recorded reason is always breaker-open
    state, consecutive = _breaker_load()
    if state == "open":
        return
    _breaker_store("open", consecutive)
    _breaker_emit_open_decision()


def breaker_record_failure(reason: str = "") -> None:
    """Record a failure. Opens after two consecutive failures, or immediately on 401/422."""
    state, consecutive = _breaker_load()
    if state == "open":
        return
    if reason in ("http-401", "http-422"):
        breaker_open(reason)
        return
    consecutive += 1
    if consecutive >= 2:
        _breaker_store("open", consecutive)
        _breaker_emit_open_decision()
        return
    _breaker_store("closed", consecutive)


def breaker_record_success() -> None:
    """Reset consecutive failures. Does not close an already-open breaker."""
    state, _ = _breaker_load()
    if state == "open":
        return
    _breaker_store("closed", 0)


# ---------------------------------------------------------------------------
# Availability gate
# ---------------------------------------------------------------------------


def available() -> bool:
    """True only when Jev is fully usable. Silent (no prints)."""
    if _env("RALPH_JEV") != "1":
        return False
    if key_resolve() is None:
        return False
    if _transport() != "fixture" and not _which("curl"):
        return False
    if breaker_state() != "closed":
        return False
    return True


def unavailable_reason() -> str:
    """One of: ok | disabled | no-key | no-curl | breaker-open."""
    if _env("RALPH_JEV") != "1":
        return "disabled"
    if key_resolve() is None:
        return "no-key"
    if _transport() != "fixture" and not _which("curl"):
        return "no-curl"
    if breaker_state() != "closed":
        return "breaker-open"
    return "ok"


# ---------------------------------------------------------------------------
# Registry / policy
# ---------------------------------------------------------------------------


def _load_registry() -> Optional[dict[str, Any]]:
    path = registry_path()
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _load_set(question_set_id: str) -> Optional[dict[str, Any]]:
    if not question_set_id:
        return None
    registry = _load_registry()
    if registry is None:
        return None
    sets = registry.get("questionSets")
    if not isinstance(sets, dict):
        return None
    entry = sets.get(question_set_id)
    return entry if isinstance(entry, dict) else None


def policy_questions(question_set_id: str) -> tuple[Optional[dict[str, Any]], int]:
    """Return (questions object, code). Code 1 when unknown."""
    set_obj = _load_set(question_set_id)
    if set_obj is None:
        return None, 1
    questions = set_obj.get("questions")
    if not isinstance(questions, dict):
        return None, 1
    return questions, 0


def policy_threshold(question_set_id: str, which: str) -> tuple[Optional[float], int]:
    """Return (threshold, code). ``which`` is ``act`` or ``escalate``.

    Thresholds come ONLY from the registry — callers never supply their own.
    """
    if which == "act":
        key = "actThreshold"
    elif which == "escalate":
        key = "escalateThreshold"
    else:
        return None, 1
    set_obj = _load_set(question_set_id)
    if set_obj is None:
        return None, 1
    policy = set_obj.get("policy")
    if not isinstance(policy, dict):
        return None, 1
    raw = policy.get(key)
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None, 1
    return float(raw), 0


def _answer_confidence(ans: Mapping[str, Any]) -> Optional[float]:
    ans_type = ans.get("type")
    if ans_type == "noul" or (
        "noul" in ans and "choice" not in ans and "score" not in ans
    ):
        raw = ans.get("noul")
    elif "confidence" in ans:
        raw = ans.get("confidence")
    else:
        return None
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return float(raw)


def policy_decide(
    question_set_id: str, answers: Mapping[str, Any] | str
) -> tuple[Optional[dict[str, Any]], int]:
    """Decide act|gather|fallback from registry thresholds.

    When RALPH_JEV_SHADOW=1: record the would-have decision (shadow=true,
    decision field keeps act|gather|fallback) and return decision=fallback
    so callers keep their deterministic path.
    """
    if isinstance(answers, str):
        try:
            answers_obj = json.loads(answers)
        except json.JSONDecodeError:
            return None, 1
    else:
        answers_obj = dict(answers)
    if not isinstance(answers_obj, dict):
        return None, 1

    set_obj = _load_set(question_set_id)
    if set_obj is None:
        return None, 1
    policy = set_obj.get("policy")
    if not isinstance(policy, dict):
        return None, 1
    primary = policy.get("primaryQuestion")
    if not isinstance(primary, str) or not primary:
        return None, 1
    ans = answers_obj.get(primary)
    if not isinstance(ans, dict):
        return None, 1
    conf = _answer_confidence(ans)
    if conf is None:
        return None, 1

    chosen = ans.get("choice", None)
    questions = set_obj.get("questions") if isinstance(set_obj.get("questions"), dict) else {}
    qdef = questions.get(primary) if isinstance(questions, dict) else None
    criteria = qdef.get("criteria") if isinstance(qdef, dict) else None
    version = set_obj.get("version", 1)
    if not isinstance(version, int):
        try:
            version = int(version)
        except (TypeError, ValueError):
            version = 1

    unoffered = (
        "choice" in ans
        and isinstance(criteria, dict)
        and len(criteria) > 0
        and chosen is not None
        and str(chosen) not in criteria
    )
    if unoffered:
        decision = {
            "decision": "fallback",
            "chosen": chosen,
            "confidence": conf,
            "questionSetId": question_set_id,
            "questionSetVersion": version,
            "reason": "option-not-offered",
        }
    else:
        act_t = policy.get("actThreshold")
        esc_t = policy.get("escalateThreshold")
        if not isinstance(act_t, (int, float)) or isinstance(act_t, bool):
            return None, 1
        if not isinstance(esc_t, (int, float)) or isinstance(esc_t, bool):
            return None, 1
        if conf >= float(act_t):
            decision = {
                "decision": "act",
                "chosen": chosen,
                "confidence": conf,
                "questionSetId": question_set_id,
                "questionSetVersion": version,
                "reason": "act",
            }
        elif conf >= float(esc_t):
            decision = {
                "decision": "gather",
                "chosen": chosen,
                "confidence": conf,
                "questionSetId": question_set_id,
                "questionSetVersion": version,
                "reason": "gather",
            }
        else:
            decision = {
                "decision": "fallback",
                "chosen": chosen,
                "confidence": conf,
                "questionSetId": question_set_id,
                "questionSetVersion": version,
                "reason": "fallback",
            }

    if _is_shadow():
        _shadow_record(decision, set_obj, answers_obj)
        returned = dict(decision)
        returned["decision"] = "fallback"
        returned["shadow"] = True
        returned["fallbackUsed"] = True
        returned["reason"] = "shadow"
        return returned, 0

    return decision, 0


def _shadow_record(
    decision: Mapping[str, Any],
    set_obj: Mapping[str, Any],
    answers: Mapping[str, Any],
) -> None:
    record: dict[str, Any] = dict(decision)
    record["surface"] = set_obj.get("surface") or record.get("surface") or ""
    record["answers"] = dict(answers) if isinstance(answers, dict) else {}
    record["shadow"] = True
    record["fallbackUsed"] = True
    record["registryVersion"] = "1"
    record_decision(record)


# ---------------------------------------------------------------------------
# Request builder
# ---------------------------------------------------------------------------


def estimate_request_size(
    state_text: str, questions: Mapping[str, Any] | str
) -> bool:
    """Return True when state + longest question fit the 32k-token budget.

    Ralph owns this arithmetic because Jev is documented as unreliable at
    counting. Heuristic: four bytes per token (deliberately conservative).
    """
    if isinstance(questions, str):
        try:
            questions_obj = json.loads(questions)
        except json.JSONDecodeError:
            return False
    else:
        questions_obj = questions
    if not isinstance(questions_obj, dict):
        return False
    state_bytes = len(state_text.encode("utf-8"))
    longest = 0
    for value in questions_obj.values():
        try:
            length = len(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
        except (TypeError, ValueError):
            return False
        if length > longest:
            longest = length
    return (state_bytes + longest) <= _BUDGET_BYTES


def build_request(
    state_text: str, questions: Mapping[str, Any] | str
) -> tuple[Optional[dict[str, Any]], int]:
    """Redact, size-gate, then assemble {state, model, questions}. Code 0 | 3."""
    if _redact_text is None:
        return None, 3
    if isinstance(questions, str):
        try:
            questions_obj = json.loads(questions)
        except json.JSONDecodeError:
            return None, 3
    else:
        questions_obj = dict(questions)
    if not isinstance(questions_obj, dict):
        return None, 3

    try:
        redacted = _redact_text(state_text)
    except Exception:
        return None, 3

    if not estimate_request_size(redacted, questions_obj):
        return None, 3

    model = _env("RALPH_JEV_MODEL") or _DEFAULT_MODEL
    body = {"state": redacted, "model": model, "questions": questions_obj}
    return body, 0


# ---------------------------------------------------------------------------
# Fixture transport
# ---------------------------------------------------------------------------


def _fixture_path_for_request(request_json: str | Mapping[str, Any]) -> tuple[Optional[str], int]:
    if isinstance(request_json, Mapping):
        req = dict(request_json)
        request_bytes = json.dumps(req, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )
    else:
        try:
            req = json.loads(request_json)
        except json.JSONDecodeError:
            print("fixture-missing", file=sys.stderr)
            return None, 3
        if not isinstance(req, dict):
            print("fixture-missing", file=sys.stderr)
            return None, 3
        request_bytes = request_json.encode("utf-8")

    directory = _fixture_dir()
    qsid = req.get("questionSetId")
    if isinstance(qsid, str) and qsid:
        if not _QSID_SAFE.match(qsid):
            print("fixture-missing", file=sys.stderr)
            return None, 3
        return os.path.join(directory, f"{qsid}.json"), 0

    hex_digest = _sha256_hex(request_bytes).lower()
    if not re.fullmatch(r"[0-9a-f]+", hex_digest):
        print("fixture-missing", file=sys.stderr)
        return None, 3
    return os.path.join(directory, f"sha256-{hex_digest}.json"), 0


def post_systemone_fixture(
    request_json: str | Mapping[str, Any], attempt_index: int = 0
) -> tuple[Optional[dict[str, Any]], int, int]:
    """Replay a recorded fixture.

    Returns (body, http_status, code). Code 0 with any status class; 3 missing;
    2 other failure.
    """
    path, path_code = _fixture_path_for_request(request_json)
    if path_code != 0 or not path:
        return None, 0, 3
    if not os.path.isfile(path):
        print("fixture-missing", file=sys.stderr)
        return None, 0, 3
    try:
        with open(path, "r", encoding="utf-8") as handle:
            fixture = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None, 0, 2
    if not isinstance(fixture, dict):
        return None, 0, 2

    if attempt_index < 0:
        attempt_index = 0

    sequence = fixture.get("sequence")
    if isinstance(sequence, list) and sequence:
        idx = attempt_index if attempt_index < len(sequence) else len(sequence) - 1
        step = sequence[idx]
        if not isinstance(step, dict):
            return None, 0, 2
        status = int(step.get("status", 200))
        if "body" in step and isinstance(step["body"], dict):
            body = dict(step["body"])
        else:
            body = {k: v for k, v in step.items() if k not in ("status", "sequence")}
    else:
        status = int(fixture.get("status", 200))
        if "body" in fixture and isinstance(fixture["body"], dict):
            body = dict(fixture["body"])
        else:
            body = {k: v for k, v in fixture.items() if k not in ("status", "sequence")}

    return body, status, 0


# ---------------------------------------------------------------------------
# Live HTTP transport (urllib — stdlib peer of curl)
# ---------------------------------------------------------------------------


def _post_fail(reason: str) -> tuple[None, int]:
    breaker_record_failure(reason)
    return None, 2


def post_systemone(
    request_json: str | Mapping[str, Any],
) -> tuple[Optional[dict[str, Any]], int]:
    """POST to SystemOne. Returns (response, code) with code 0 | 2 | 3.

    When JEV_TRANSPORT=fixture this NEVER performs a live HTTP call.
    """
    if isinstance(request_json, Mapping):
        body_obj = dict(request_json)
        body_bytes = json.dumps(body_obj, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )
    else:
        if not request_json:
            return None, 2
        try:
            body_obj = json.loads(request_json)
        except json.JSONDecodeError:
            return None, 2
        body_bytes = request_json.encode("utf-8")

    use_fixture = _transport() == "fixture"
    key: Optional[str] = None
    endpoint = _env("RALPH_JEV_ENDPOINT") or _DEFAULT_ENDPOINT
    timeout = float(_timeout_secs())

    if not use_fixture:
        if not _which("curl"):
            # Match bash availability / transport preconditions.
            return None, 2
        key = key_resolve()
        if not key:
            return None, 2

    max_retries = _max_retries()
    retries_done = 0

    while True:
        if use_fixture:
            if _transport() != "fixture":
                return None, 2
            fixture_body, status, fixture_code = post_systemone_fixture(
                body_obj, attempt_index=retries_done
            )
            if fixture_code == 3:
                return None, 3
            if fixture_code != 0:
                if retries_done < max_retries:
                    time.sleep(1 << retries_done)
                    retries_done += 1
                    continue
                return _post_fail("connection-failure")
            assert fixture_body is not None
            response_body = fixture_body
        else:
            if _transport() == "fixture":
                return None, 2
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {key}",
            }
            # questionSetId is Ralph-internal routing metadata (fixture lookup,
            # decision records). SystemOne rejects unknown top-level fields with
            # HTTP 400, so it is stripped here - at the wire - not at call sites.
            if "questionSetId" in body_obj:
                wire_obj = {k: v for k, v in body_obj.items() if k != "questionSetId"}
                wire_bytes = json.dumps(
                    wire_obj, separators=(",", ":"), ensure_ascii=False
                ).encode("utf-8")
            else:
                wire_bytes = body_bytes
            req = urllib.request.Request(
                endpoint, data=wire_bytes, headers=headers, method="POST"
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    status = int(getattr(resp, "status", 200) or 200)
                    raw = resp.read()
            except urllib.error.HTTPError as exc:
                status = int(exc.code)
                raw = exc.read() if exc.fp is not None else b""
            except (urllib.error.URLError, TimeoutError, OSError):
                if retries_done < max_retries:
                    time.sleep(1 << retries_done)
                    retries_done += 1
                    continue
                return _post_fail("connection-failure")

            try:
                response_body = json.loads(raw.decode("utf-8") if raw else "{}")
            except (json.JSONDecodeError, UnicodeDecodeError):
                response_body = None

        if status == 401:
            breaker_open("http-401")
            breaker_record_failure("http-401")
            return None, 2
        if status == 422:
            breaker_open("http-422")
            breaker_record_failure("http-422")
            return None, 2
        if status in (429, 529):
            if retries_done < max_retries:
                time.sleep(1 << retries_done)
                retries_done += 1
                continue
            return _post_fail(f"http-{status}")

        if not (200 <= status <= 299):
            return _post_fail(f"http-{status}")

        if not isinstance(response_body, dict) or "answers" not in response_body:
            return _post_fail("protocol")

        breaker_record_success()
        record_usage(body_obj, response_body)
        return response_body, 0


# ---------------------------------------------------------------------------
# ask — compose availability + registry questions + build + post
# ---------------------------------------------------------------------------


def ask(
    question_set_id: str, state_text: str
) -> tuple[Optional[dict[str, Any]], int]:
    """Ask a registered question set. Returns (response, code) 0 | 1 | 2 | 3.

    Declines silently (code 1) when unavailable. Adds questionSetId onto the
    request so fixture transport can resolve by set id.
    """
    if not available():
        return None, 1
    questions, q_code = policy_questions(question_set_id)
    if q_code != 0 or questions is None:
        return None, 1
    request, b_code = build_request(state_text, questions)
    if b_code != 0 or request is None:
        return None, 3
    request = dict(request)
    request["questionSetId"] = question_set_id
    return post_systemone(request)


# ---------------------------------------------------------------------------
# Decision recording
# ---------------------------------------------------------------------------


def _model_is_resolved(model: Any) -> bool:
    return (
        isinstance(model, str)
        and bool(model)
        and model != "jev-latest"
        and model != "null"
    )


def _redact_inline(text: str) -> Optional[str]:
    if _redact_text is None:
        return None
    try:
        # Single-line for logs: collapse newlines after redaction.
        out = _redact_text(text).replace("\n", " ").replace("\r", " ")
        return out
    except Exception:
        return None


def record_decision(decision_record: Mapping[str, Any] | str) -> int:
    """Append one redacted Section E decision line. Returns 0 | 3."""
    if isinstance(decision_record, str):
        if not decision_record:
            return 0
        try:
            input_obj: MutableMapping[str, Any] = json.loads(decision_record)
        except json.JSONDecodeError:
            return 3
    else:
        input_obj = dict(decision_record)
    if not isinstance(input_obj, dict):
        return 3

    directory = state_dir()
    plan_key = _artifact_ns()
    request_id = _sha256_hex(
        f"{_iso_now()}-{os.getpid()}-{time.time_ns()}".encode("utf-8")
    )[:16]
    ts = _iso_now()

    raw_response: Any = None
    for key in ("rawResponse", "responseBody", "response"):
        candidate = input_obj.get(key)
        if isinstance(candidate, dict):
            raw_response = candidate
            break
    if raw_response is None:
        raw_response = {
            "model": input_obj.get("model", ""),
            "answers": input_obj.get("answers", {}),
            "usage": input_obj.get("usage", {"input_tokens": 0, "output_tokens": 0}),
        }

    resolved_model = ""
    if isinstance(raw_response, dict):
        candidate = raw_response.get("model")
        if _model_is_resolved(candidate):
            resolved_model = str(candidate)
    if not resolved_model:
        candidate = input_obj.get("model")
        if _model_is_resolved(candidate):
            resolved_model = str(candidate)

    record: dict[str, Any] = {
        "timestamp": (
            input_obj["timestamp"]
            if isinstance(input_obj.get("timestamp"), str) and input_obj["timestamp"]
            else ts
        ),
        "surface": input_obj.get("surface", ""),
        "questionSetId": input_obj.get("questionSetId", ""),
        "registryVersion": input_obj.get("registryVersion", "1"),
        "questionSetVersion": input_obj.get("questionSetVersion", 1),
        "model": resolved_model,
        "answers": input_obj["answers"] if isinstance(input_obj.get("answers"), dict) else {},
        "decision": input_obj.get("decision", "fallback"),
        "chosen": input_obj["chosen"] if "chosen" in input_obj else None,
        "confidence": input_obj["confidence"] if "confidence" in input_obj else 0,
        "fallbackUsed": input_obj["fallbackUsed"] if "fallbackUsed" in input_obj else True,
        "shadow": input_obj["shadow"] if "shadow" in input_obj else False,
        "latencyMs": input_obj["latencyMs"] if "latencyMs" in input_obj else 0,
        "usage": (
            input_obj["usage"]
            if isinstance(input_obj.get("usage"), dict)
            else {"input_tokens": 0, "output_tokens": 0}
        ),
        "breakerState": input_obj.get("breakerState", "closed"),
        "transport": input_obj.get("transport", "https"),
        "requestId": request_id,
        "planKey": plan_key,
    }
    if isinstance(input_obj.get("reason"), str):
        record["reason"] = input_obj["reason"]

    try:
        record_line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError):
        return 3

    redacted_line = _redact_inline(record_line)
    if not redacted_line:
        return 3

    if isinstance(raw_response, dict):
        to_store = dict(raw_response)
        if resolved_model:
            to_store["model"] = resolved_model
        elif to_store.get("model") == "jev-latest":
            to_store["model"] = ""
        try:
            stored = json.dumps(to_store, separators=(",", ":"), ensure_ascii=False)
        except (TypeError, ValueError):
            stored = ""
        if stored:
            stored_redacted = _redact_inline(stored)
            if stored_redacted is None:
                return 3
            response_path = os.path.join(directory, "responses", f"{request_id}.json")
            _atomic_write(response_path, stored_redacted)

    log_path = os.path.join(directory, "decisions.jsonl")
    _append_jsonl(log_path, redacted_line)
    return 0


# ---------------------------------------------------------------------------
# CLI (optional; keep importable for tests)
# ---------------------------------------------------------------------------


def main(argv: Optional[list[str]] = None) -> int:
    """Minimal CLI for smoke checks. Prefer importing the module from tests."""
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print(
            "usage: jev_client.py "
            "{available|unavailable-reason|threshold|breaker-state} ...",
            file=sys.stderr,
        )
        return 2
    cmd = args[0]
    if cmd == "available":
        return 0 if available() else 1
    if cmd == "unavailable-reason":
        print(unavailable_reason())
        return 0
    if cmd == "breaker-state":
        print(breaker_state())
        return 0
    if cmd == "threshold" and len(args) >= 3:
        value, code = policy_threshold(args[1], args[2])
        if code != 0 or value is None:
            return code
        # Match bash jq -r numeric printing (strip trailing .0 for ints).
        if float(value).is_integer():
            print(int(value))
        else:
            print(value)
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
