#!/usr/bin/env python3
"""Write per-runtime overlay summaries and regenerate the aggregate summary.json."""
from __future__ import annotations

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

from ralph_overlay_usage_fields import (
    channel_activity_counts_from_savings,
    merge_runtime_overlay_summaries,
)


def list_from_env(key: str) -> list[str]:
    raw = os.environ.get(key, "")
    return [line for line in raw.splitlines() if line]


def hook_metrics(state_dir: str, helper: str, mutation_proven: bool = False) -> dict[str, int]:
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


def byte_savings_metrics(state_dir: str, helper: str) -> dict[str, object]:
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


def byte_savings_by_channel_metrics(state_dir: str, helper: str) -> dict[str, object]:
    if not state_dir or not os.path.isfile(helper):
        return {}
    plan_key = os.environ.get("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", "")
    proc = subprocess.run(
        [sys.executable, helper, "aggregate-byte-savings-by-channel", state_dir, plan_key],
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


def coerce_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None or value == "":
        return False
    text = str(value).strip().lower()
    return text in ("1", "true", "yes", "on")


def coerce_opt_out_value(value: object) -> str:
    if value is None:
        return ""
    return str(value)


def is_opted_out(value: object) -> bool:
    text = coerce_opt_out_value(value).strip().lower()
    return text in ("0", "false", "no", "off")


def optimization_entry(
    name: str,
    capability_names: tuple[str, ...],
    summary_key: str,
    opt_out_envs: tuple[str, ...],
    capabilities: set[str],
) -> dict[str, object]:
    summary_value = os.environ.get(summary_key, "")
    capability_hits = [cap for cap in capability_names if cap in capabilities]
    opt_out_values = {env: coerce_opt_out_value(os.environ.get(env, "")) for env in opt_out_envs}
    opt_out_env = opt_out_envs[0] if len(opt_out_envs) == 1 else None
    opt_out_value = opt_out_values.get(opt_out_env, "") if opt_out_env else None
    return {
        "name": name,
        "value": summary_value,
        "effective": coerce_bool(summary_value) or bool(capability_hits),
        "capabilities": capability_hits,
        "opt_out_env": opt_out_env,
        "opt_out_envs": list(opt_out_envs),
        "opt_out_value": opt_out_value,
        "opt_out_values": opt_out_values,
        "opted_out": any(is_opted_out(value) for value in opt_out_values.values()),
    }


def build_runtime_summary(state_dir: str, helper: str, runtime: str) -> dict[str, object]:
    capabilities = set(list_from_env("RUNTIME_OVERLAY_ARRAY_CAPABILITIES"))
    native_hooks_configured_str = os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED_VALUE", "")
    native_hooks_configured = coerce_bool(native_hooks_configured_str)
    hook_events = int(os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOK_EVENTS_VALUE", "") or 0)

    cache_key_injected = coerce_bool(
        os.environ.get("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_VALUE", "")
        or os.environ.get("RALPH_OPENCODE_CACHE_KEY_INJECTED", "")
    )
    cache_key_provider = (
        os.environ.get("RUNTIME_OVERLAY_SUMMARY_CACHE_KEY_INJECTED_PROVIDER_ID_VALUE", "")
        or os.environ.get("RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID", "")
    )

    data: dict[str, object] = {
        "runtime": runtime,
        "plan_key": os.environ.get("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", ""),
        "tool_access_mode": os.environ.get("RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE_VALUE", ""),
        "native_hooks_requested": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED_VALUE", ""),
        "native_hooks_configured": native_hooks_configured,
        "native_hook_events": hook_events,
        "native_hooks_observed_effect": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT_VALUE", "") or None,
        "native_hooks_observed_reason": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON_VALUE", "") or None,
        "native_hooks_effective": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE_VALUE", ""),
        "native_hooks_reason": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON_VALUE", ""),
        "native_hooks_used_on_run": False,
        "native_output_mutation_proven": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE", ""),
        "native_shell_wrapper_enabled": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_ENABLED_VALUE", ""),
        "native_shell_wrapper_effective": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE_VALUE", ""),
        "native_shell_wrapper_reason": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_REASON_VALUE", ""),
        "native_shell_compaction_authoritative": os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_COMPACTION_AUTHORITATIVE_VALUE", ""),
        "fallback_path_active": os.environ.get("RUNTIME_OVERLAY_SUMMARY_FALLBACK_PATH_ACTIVE_VALUE", ""),
        "native_optimization_proven_channels": list_from_env("RUNTIME_OVERLAY_ARRAY_PROVEN_CHANNELS"),
        "fallback_channels_active": list_from_env("RUNTIME_OVERLAY_ARRAY_FALLBACK_CHANNELS"),
        "mcp_effective": os.environ.get("RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_VALUE", ""),
        "mcp_config_sources": list_from_env("RUNTIME_OVERLAY_SUMMARY_MCP_CONFIG_SOURCES_VALUE"),
        "mcp_effective_names": list_from_env("RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE_NAMES_VALUE"),
        "mcp_override_decisions": list_from_env("RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS_VALUE"),
        "mcp_failure_reason": os.environ.get("RUNTIME_OVERLAY_SUMMARY_MCP_FAILURE_REASON_VALUE", ""),
        "mcp_preflight_outcome": os.environ.get("RUNTIME_OVERLAY_SUMMARY_MCP_PREFLIGHT_OUTCOME_VALUE", "") or None,
        "mcp_tool_namespace": os.environ.get("RUNTIME_OVERLAY_SUMMARY_MCP_TOOL_NAMESPACE_VALUE", "") or None,
        "proxy_shell_compact_effective": os.environ.get("RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE_VALUE", ""),
        "cache_key_injected": cache_key_injected,
        "cache_key_injected_provider_id": cache_key_provider,
        "overlay_mode": os.environ.get("RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE_VALUE", ""),
        "bg_tier": os.environ.get("RUNTIME_OVERLAY_SUMMARY_BG_TIER_VALUE", ""),
        "bg_tier_reason": os.environ.get("RUNTIME_OVERLAY_SUMMARY_BG_TIER_REASON_VALUE", ""),
        "generated_files": list_from_env("RUNTIME_OVERLAY_ARRAY_GENERATED_FILES"),
        "mutated_files": list_from_env("RUNTIME_OVERLAY_ARRAY_MUTATED_FILES"),
        "warnings": list_from_env("RUNTIME_OVERLAY_ARRAY_WARNINGS"),
        "capabilities": list_from_env("RUNTIME_OVERLAY_ARRAY_CAPABILITIES"),
        "updated_at": os.environ.get("RUNTIME_OVERLAY_SUMMARY_UPDATED_AT", ""),
    }

    mutation_proven = coerce_bool(os.environ.get("RUNTIME_OVERLAY_SUMMARY_NATIVE_OUTPUT_MUTATION_PROVEN_VALUE", ""))
    hook_metrics_data = hook_metrics(state_dir, helper, mutation_proven)
    hook_metrics_data["native_hook_events"] = max(hook_events, hook_metrics_data.get("native_hook_events", 0))
    data.update(hook_metrics_data)
    if state_dir:
        data["overlay_state_dir"] = state_dir

    byte_savings_data = byte_savings_metrics(state_dir, helper)
    if byte_savings_data:
        data["byte_savings_by_path"] = byte_savings_data
    channel_savings_data = byte_savings_by_channel_metrics(state_dir, helper)
    if channel_savings_data:
        data["byte_savings_by_channel"] = channel_savings_data
    data["channel_activity_counts"] = channel_activity_counts_from_savings(
        channel_savings_data if channel_savings_data else {}
    )

    data["optimizations"] = {
        "native_hooks": optimization_entry(
            "native_hooks",
            (
                "cursor-hooks-merged",
                "claude-hooks-merged",
                "codex-hooks-injected-per-run",
                "opencode-plugin-local-load",
            ),
            "RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE_VALUE",
            ("RALPH_NATIVE_HOOKS",),
            capabilities,
        ),
        "native_shell_wrapper": optimization_entry(
            "native_shell_wrapper",
            (
                "cursor-native-shell-wrapper-compact",
                "codex-native-shell-wrapper-compact",
            ),
            "RUNTIME_OVERLAY_SUMMARY_NATIVE_SHELL_WRAPPER_EFFECTIVE_VALUE",
            ("RALPH_NATIVE_SHELL_WRAPPER",),
            capabilities,
        ),
        "proxy_shell_compact": optimization_entry(
            "proxy_shell_compact",
            ("cursor-mcp-proxy-shell-compact",),
            "RUNTIME_OVERLAY_SUMMARY_PROXY_SHELL_COMPACT_EFFECTIVE_VALUE",
            ("RALPH_PROXY_SHELL_COMPACT",),
            capabilities,
        ),
        "mcp_optimization": optimization_entry(
            "mcp_optimization",
            ("cursor-mcp-optimization",),
            "RUNTIME_OVERLAY_SUMMARY_OVERLAY_MODE_VALUE",
            (),
            capabilities,
        ),
    }

    if native_hooks_configured:
        observed_hook_events = int(hook_metrics_data.get("native_hook_events", 0))
        data["native_hooks_used_on_run"] = observed_hook_events > 0
        if observed_hook_events == 0:
            data["native_hooks_observed_effect"] = "configured_but_no_surface_observed"
            if not data.get("native_hooks_observed_reason"):
                data["native_hooks_observed_reason"] = "hook active but no hook surface observed"

    return data


def write_json(path: str, data: dict[str, object]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def main() -> int:
    if len(sys.argv) < 3:
        return 2

    aggregate_path = sys.argv[1]
    helper = sys.argv[2]
    state_dir = os.environ.get("RUNTIME_OVERLAY_STATE_DIR_VALUE", "") or os.path.dirname(aggregate_path)
    runtime = str(os.environ.get("RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE", "")).strip()
    if not runtime:
        print("runtime-overlay-write-summary: RUNTIME_OVERLAY_SUMMARY_RUNTIME_VALUE is required", file=sys.stderr)
        return 1

    per_runtime_path = os.path.join(state_dir, "summaries", f"{runtime}.json")
    per_runtime_data = build_runtime_summary(state_dir, helper, runtime)
    per_runtime_data["runtime"] = runtime
    write_json(per_runtime_path, per_runtime_data)

    plan_key = str(os.environ.get("RUNTIME_OVERLAY_SUMMARY_PLAN_KEY_VALUE", "")).strip()
    aggregate = merge_runtime_overlay_summaries(state_dir, plan_key=plan_key)
    if not aggregate:
        aggregate = dict(per_runtime_data)
        aggregate["runtimes_present"] = [runtime]
    write_json(aggregate_path, aggregate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
