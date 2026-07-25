#!/usr/bin/env python3
"""
Shared helper for estimating opencode cache-read savings.

This module is intentionally dependency-free (stdlib only) so it can be
imported in verification contexts without installing extra packages.
"""

from __future__ import annotations

from typing import Any


def estimate_opencode_cache_read(invocations: list[dict[str, Any]]) -> dict[str, Any]:
    """
    Estimate opencode cache-read input tokens via prefix stability.

    Logic (see PLAN8.plan.md shared-estimator-helper todo):
    - Consider only invocations where runtime == "opencode".
    - If sum(cache_read_input_tokens) > 0 OR opencode_cache_key_injected is
      falsy on any (filtered) invocation, return {estimated: 0, method: "none"}.
    - Otherwise:
      baseline_prefix = min(input_tokens)
      estimated = baseline_prefix * (n - 1) where n is invocation count.
    - Single invocation -> estimated 0.
    """

    filtered = [i for i in invocations if i.get("runtime") == "opencode"]
    invocation_count = len(filtered)

    if invocation_count == 0:
        # Nothing to estimate.
        return {
            "estimated": 0,
            "baseline_prefix": 0,
            "invocation_count": 0,
            "method": "none",
        }

    measured_cache_read_total = 0
    key_injected_all = True
    input_tokens: list[int] = []

    for inv in filtered:
        measured_cache_read_total += int(inv.get("cache_read_input_tokens") or 0)
        if not inv.get("opencode_cache_key_injected", False):
            key_injected_all = False
        input_tokens.append(int(inv.get("input_tokens") or 0))

    if measured_cache_read_total > 0 or not key_injected_all:
        baseline_prefix = min(input_tokens) if input_tokens else 0
        return {
            "estimated": 0,
            "baseline_prefix": baseline_prefix,
            "invocation_count": invocation_count,
            "method": "none",
        }

    baseline_prefix = min(input_tokens) if input_tokens else 0
    if invocation_count <= 1:
        estimated = 0
    else:
        estimated = baseline_prefix * (invocation_count - 1)

    return {
        "estimated": estimated,
        "baseline_prefix": baseline_prefix,
        "invocation_count": invocation_count,
        "method": "prefix-stability",
    }


__all__ = ["estimate_opencode_cache_read"]

