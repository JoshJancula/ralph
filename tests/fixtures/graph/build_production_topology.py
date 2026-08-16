#!/usr/bin/env python3
"""Build the sanitized 27-node production topology used by the graph
production-acceptance replay.

The topology is synthetic. It is shaped like the historical production run but
contains none of its content: node ids, runtimes, and dependencies are written
here and nowhere else, and the historical run is never read.

Layout notes that the replay depends on:

* ``contract-1`` -> ``contract-child`` is a side branch hanging off ``root``.
  Keeping the plan-contract failure off the publish path is what lets the
  replay observe "independent branches drain" and "final publish readiness"
  as two separate properties instead of one confounded one.
* Every node declares a required output artifact under ``shared/``. The stub
  orchestrator writes that file inside its own node workspace, so a node that
  leaked into another node's workspace would fail artifact publication.
* ``resilience`` and ``budgets`` are deliberately absent here: they are not
  authorable pipeline fields, so the replay injects them into the compiled
  graph instead. Without them the retry limits default to zero and the
  bounded-retry property could not be observed at all.
* ``contract-1`` deliberately declares no ``writeScopes``. Its plan-contract
  failure comes from the stub's reported result (``kind: undeclared-path``),
  which is what the replay is exercising. A real restrictive scope here would
  also reject the node's own declared ``shared/contract-1.md`` output once the
  branch is repaired, so the node could never recover.

Usage: build_production_topology.py <plan_out_path>
"""

import sys

NODES = []


def add(node_id, runtime, depends_on):
    NODES.append({"id": node_id, "runtime": runtime, "dependsOn": depends_on})


def build():
    add("root", "cursor", [])
    add("infra-1", "claude", ["root"])
    add("infra-2", "codex", ["root"])
    add("backend-1", "claude", ["infra-1", "infra-2"])
    add("backend-2", "claude", ["infra-1"])
    add("backend-3", "codex", ["infra-2"])
    add("service-1", "codex", ["backend-1"])
    add("service-2", "claude", ["backend-1"])
    add("service-3", "codex", ["backend-2", "backend-3"])
    add("service-4", "claude", ["backend-2"])
    add("gate-1", "codex", ["service-1", "service-2"])
    add("gate-2", "claude", ["service-3", "service-4"])
    add("ui-1", "claude", ["gate-1"])
    add("ui-3", "codex", ["gate-2"])
    add("review-1", "codex", ["ui-1"])
    add("review-2", "claude", ["ui-3"])
    add("integrate-1", "claude", ["review-1", "review-2"])
    add("docs-1", "codex", ["root"])
    add("docs-2", "claude", ["root"])
    add("docs-3", "codex", ["docs-1", "docs-2"])
    add("test-1", "claude", ["backend-1"])
    add("test-2", "claude", ["service-1"])
    add("test-3", "codex", ["integrate-1", "docs-3"])
    add("publish-prep", "codex", ["test-1", "test-2", "test-3"])
    add("publish-final", "claude", ["publish-prep"])
    add("contract-1", "codex", ["root"])
    add("contract-child", "claude", ["contract-1"])
    return NODES


def render_plan(nodes):
    out = []
    out.append("---")
    out.append("name: production-hardening")
    out.append("namespace: production-hardening")
    out.append("execution: graph")
    out.append("pipeline:")
    out.append("  maxParallel: 8")
    out.append("  failurePolicy: drain")
    out.append("  publishMode: manual")
    out.append("  stages:")
    for node in nodes:
        out.append("    - id: %s" % node["id"])
        out.append("      runtime: %s" % node["runtime"])
        out.append("      agent: implementation")
        out.append("      workspaceMode: snapshot")
        if node["dependsOn"]:
            out.append("      dependsOn:")
            for dep in node["dependsOn"]:
                out.append("        - %s" % dep)
        out.append("      produces:")
        out.append("        - path: shared/%s.md" % node["id"])
    out.append("todos:")
    for node in nodes:
        out.append("  - id: %s-1" % node["id"])
        out.append("    stage: %s" % node["id"])
        out.append("    content: work %s" % node["id"])
        out.append("    verification: ok")
        out.append("    status: pending")
    out.append("---")
    out.append("")
    return "\n".join(out)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: build_production_topology.py <plan_out_path>\n")
        return 2
    nodes = build()
    if len(nodes) != 27:
        sys.stderr.write("expected 27 nodes, built %d\n" % len(nodes))
        return 1
    with open(argv[1], "w", encoding="utf-8") as handle:
        handle.write(render_plan(nodes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
