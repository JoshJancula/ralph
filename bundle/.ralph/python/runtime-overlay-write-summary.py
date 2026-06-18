#!/usr/bin/env python3
"""Write the runtime overlay summary JSON."""
import json, os, subprocess, sys

def list_from_env(key):
    raw = os.environ.get(key, "")
    return [line for line in raw.splitlines() if line]

def hook_metrics(state_dir, helper, mutation_proven=False):
    if not state_dir or not os.path.isfile(helper):
        return {
            "native_hook_events": 0,
            "hook_compactions": 0,
            "hook_rewrites": 0,
            "hook_original_bytes": 0,
            "hook_compacted_bytes": 0,
            "proxy_shell_compaction_events": 0,
            "proxy_shell_compactions": 0,
            "proxy_shell_original_bytes": 0,
            "proxy_shell_compacted_bytes": 0,
            "compaction_original_bytes": 0,
            "compaction_compacted_bytes": 0,
            "compaction_saved_bytes": 0,
            "compaction_measured_not_applied_bytes": 0,
        }
    plan_key = os.environ.get("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", "")
    proc = subprocess.run(
        [sys.executable, helper, "aggregate-hook-telemetry", state_dir, plan_key],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {
            "native_hook_events": 0,
            "hook_compactions": 0,
            "hook_rewrites": 0,
            "hook_original_bytes": 0,
            "hook_compacted_bytes": 0,
            "proxy_shell_compaction_events": 0,
            "proxy_shell_compactions": 0,
            "proxy_shell_original_bytes": 0,
            "proxy_shell_compacted_bytes": 0,
            "compaction_original_bytes": 0,
            "compaction_compacted_bytes": 0,
            "compaction_saved_bytes": 0,
            "compaction_measured_not_applied_bytes": 0,
        }
    try:
        metrics = json.loads(proc.stdout)
    except json.JSONDecodeError:
        metrics = {}
    if not isinstance(metrics, dict):
        metrics = {}
    native_original = int(metrics.get("hook_original_bytes") or 0)
    native_compacted = int(metrics.get("hook_compacted_bytes") or 0)
    proxy_original = int(metrics.get("proxy_shell_original_bytes") or 0)
    proxy_compacted = int(metrics.get("proxy_shell_compacted_bytes") or 0)
    hook_saved = max(0, native_original - native_compacted)
    proxy_saved = max(0, proxy_original - proxy_compacted)
    compaction_original = native_original + proxy_original
    compaction_compacted = native_compacted + proxy_compacted
    if mutation_proven:
        compaction_saved = hook_saved + proxy_saved
        compaction_measured_not_applied = 0
    else:
        compaction_saved = proxy_saved
        compaction_measured_not_applied = hook_saved
    return {
        "native_hook_events": int(metrics.get("native_hook_events") or 0),
        "hook_compactions": int(metrics.get("hook_compactions") or 0),
        "hook_rewrites": int(metrics.get("hook_rewrites") or 0),
        "hook_original_bytes": native_original,
        "hook_compacted_bytes": native_compacted,
        "proxy_shell_compaction_events": int(metrics.get("proxy_shell_compaction_events") or 0),
        "proxy_shell_compactions": int(metrics.get("proxy_shell_compactions") or 0),
        "proxy_shell_original_bytes": proxy_original,
        "proxy_shell_compacted_bytes": proxy_compacted,
        "compaction_original_bytes": compaction_original,
        "compaction_compacted_bytes": compaction_compacted,
        "compaction_saved_bytes": compaction_saved,
        "compaction_measured_not_applied_bytes": compaction_measured_not_applied,
    }

def byte_savings_metrics(state_dir, helper):
    if not state_dir or not os.path.isfile(helper):
        return {}
    plan_key = os.environ.get("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", "")
    proc = subprocess.run(
        [sys.executable, helper, "aggregate-byte-savings", state_dir, plan_key],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    try:
        metrics = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}
    return metrics if isinstance(metrics, dict) else {}

def coerce_bool(value):
    if isinstance(value, bool):
        return value
    if value is None or value == "":
        return False
    text = str(value).strip().lower()
    return text in ("1", "true", "yes", "on")

summary_path = sys.argv[1]
helper = sys.argv[2]
state_dir = os.environ.get("RUNTIME_OVERLAY_STATE_DIR_VALUE", "")

existing = {}
if os.path.exists(summary_path):
    try:
        with open(summary_path, encoding="utf-8") as _ef:
            existing = json.load(_ef)
    except (OSError, json.JSONDecodeError, ValueError):
        existing = {}

def _ms(env_key, summary_key, default=""):
    val = os.environ.get(env_key, "")
    if val != "":
        return val
    return existing.get(summary_key, default)

def _ml(env_key, summary_key):
    raw = os.environ.get(env_key, "")
    if raw:
        return [line for line in raw.splitlines() if line]
    return existing.get(summary_key, [])

native_hooks_configured_str = _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED_VALUE", "native_hooks_configured")
native_hooks_configured = coerce_bool(native_hooks_configured_str)
hook_events = int(os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS_VALUE", "") or existing.get("native_hook_events") or 0)

def _ms_or_none(env_key, summary_key):
    val = os.environ.get(env_key, "")
    if val:
        return val
    ex = existing.get(summary_key)
    return ex if ex else None

def _ms_or_empty(env_key, summary_key):
    if env_key in os.environ:
        return os.environ.get(env_key, "")
    return existing.get(summary_key, "")

data = {
    "runtime": _ms("RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE", "runtime"),
    "plan_key": _ms("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", "plan_key"),
    "tool_access_mode": _ms("RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE_VALUE", "tool_access_mode"),
    "native_hooks_requested": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED_VALUE", "native_hooks_requested"),
    "native_hooks_configured": native_hooks_configured,
    "native_hook_events": hook_events,
    "native_hooks_observed_effect": _ms_or_none("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT_VALUE", "native_hooks_observed_effect"),
    "native_hooks_observed_reason": _ms_or_none("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON_VALUE", "native_hooks_observed_reason"),
    "native_hooks_effective": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE_VALUE", "native_hooks_effective"),
    "native_hooks_reason": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON_VALUE", "native_hooks_reason"),
    "native_hooks_used_on_run": False,
    "native_output_mutation_proven": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE", "native_output_mutation_proven"),
    "cache_key_injected": coerce_bool(
        os.environ.get("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_VALUE", "")
        or os.environ.get("RALPH_OPENCODE_CACHE_KEY_INJECTED", "")
        or _ms("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_VALUE", "cache_key_injected")
    ),
    "cache_key_injected_provider_id": (
        os.environ.get("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID_VALUE", "")
        or os.environ.get("RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID", "")
        or _ms_or_empty("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID_VALUE", "cache_key_injected_provider_id")
    ),
    "native_shell_wrapper_enabled": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED_VALUE", "native_shell_wrapper_enabled"),
    "native_shell_wrapper_effective": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE_VALUE", "native_shell_wrapper_effective"),
    "native_shell_wrapper_reason": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON_VALUE", "native_shell_wrapper_reason"),
    "native_shell_compaction_authoritative": _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE_VALUE", "native_shell_compaction_authoritative"),
    "fallback_path_active": _ms("RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE_VALUE", "fallback_path_active"),
    "mcp_effective": _ms("RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_VALUE", "mcp_effective"),
    "proxy_shell_compact_effective": _ms("RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE_VALUE", "proxy_shell_compact_effective"),
    "cache_key_injected": coerce_bool(_ms("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_VALUE", "cache_key_injected")),
    "cache_key_injected_provider_id": _ms_or_empty("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID_VALUE", "cache_key_injected_provider_id"),
    "overlay_mode": _ms("RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE_VALUE", "overlay_mode"),
    "generated_files": _ml("RUNTIME_OVERLAY_ARRAY_GENERATED_FILES", "generated_files"),
    "mutated_files": _ml("RUNTIME_OVERLAY_ARRAY_MUTATED_FILES", "mutated_files"),
    "warnings": _ml("RUNTIME_OVERLAY_ARRAY_WARNINGS", "warnings"),
    "capabilities": _ml("RUNTIME_OVERLAY_ARRAY_CAPABILITIES", "capabilities"),
    "updated_at": os.environ.get("RUNTIME_OVERLAY_SUMMARY_UPDATED_AT", ""),
}
mutation_proven = coerce_bool(
    _ms("RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE", "native_output_mutation_proven")
)
hook_metrics_data = hook_metrics(state_dir, helper, mutation_proven)
hook_metrics_data["native_hook_events"] = max(hook_events, hook_metrics_data.get("native_hook_events", 0))
data.update(hook_metrics_data)
if state_dir:
    data["overlay_state_dir"] = state_dir
byte_savings_data = byte_savings_metrics(state_dir, helper)
if byte_savings_data:
    data["byte_savings_by_path"] = byte_savings_data

if native_hooks_configured:
    observed_hook_events = hook_metrics_data.get("native_hook_events", 0)
    data["native_hooks_used_on_run"] = observed_hook_events > 0
    if observed_hook_events == 0:
        data["native_hooks_observed_effect"] = "configured_but_no_surface_observed"
        if not data.get("native_hooks_observed_reason"):
            data["native_hooks_observed_reason"] = "hook active but no hook surface observed"

with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
