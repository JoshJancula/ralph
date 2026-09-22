#!/usr/bin/env bash
# Read-only introspection for reusable workflow sources.
#
# `ralph workflow inspect` answers "what would this workflow do?" without
# starting anything: it validates the source, resolves mode and routing
# provenance, and reports the runnable schedule, the plan-handoff topology
# (which stages generate, accept, and execute Ralph plans TODO by TODO),
# approval gates, and how a supplied plan would bind.
#
# Nothing here writes state. No run registry, control plan, compile cache,
# log, or agent workspace is created, and no runtime is invoked.

if [[ -n "${RALPH_WORKFLOW_INSPECT_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
RALPH_WORKFLOW_INSPECT_LOADED=1

# workflow_inspect_sha256_file <path>
# Lowercase hex sha256 of a regular file, or empty when no tool is available.
workflow_inspect_sha256_file() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    return 1
  fi
}

# workflow_inspect_report <workflow_path> <format> <scope> <plan_json>
#
# Emits the report on stdout. plan_json is a compact JSON object describing the
# supplied-plan preview (or the literal "null" when no --plan was given).
workflow_inspect_report() {
  local wf_path="$1"
  local format="$2"
  local scope="$3"
  local plan_json="${4:-null}"
  # context: "inspect" (default) or "start". The closing run-state note and the
  # unpinned-routing line differ; start is about to create a run and resolve
  # routing, inspect never will.
  local context="${5:-inspect}"
  # task_text: the operator-supplied --task text (start, task-entry only).
  # Empty for inspect and for plan-entry starts, where the supplied plan's
  # source path already appears in the "Supplied plan" section.
  local task_text="${6:-}"
  # resolved_id: the workflow id the operator addressed (filename-derived), the
  # same identity `list`, `path`, and the run registry use. Empty for --file
  # starts, which have no id; those fall back to the frontmatter name.
  local resolved_id="${7:-}"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: workflow inspect requires python3" >&2
    return 1
  fi

  python3 - "$wf_path" "$format" "$scope" "$plan_json" "$context" "$task_text" "$resolved_id" <<'PY'
import json
import os
import re
import sys

wf_path, fmt, scope, plan_raw, context, task_text, resolved_id = sys.argv[1:8]
plan_info = json.loads(plan_raw) if plan_raw and plan_raw != "null" else None

# Color mirrors bundle/.ralph/bash-lib/help-render.sh: TTY only, honors NO_COLOR
# and RALPH_INSTALL_NO_COLOR. Text output stays byte-identical off a terminal
# (bats `run` and any redirected/piped consumer), so this never affects an
# assertion on report content.
_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ and os.environ.get("RALPH_INSTALL_NO_COLOR") != "1"
_BOLD = "\033[1m" if _COLOR else ""
_DIM = "\033[2m" if _COLOR else ""
_RESET = "\033[0m" if _COLOR else ""


def _colorize_report(lines):
    if not _COLOR:
        return lines
    out = []
    for line in lines:
        if not line or line.startswith("  "):
            out.append(line)
        else:
            out.append("%s%s%s" % (_BOLD, line, _RESET))
    return out

text = open(wf_path, encoding="utf-8").read()


def frontmatter(body):
    if not body.startswith("---"):
        return ""
    end = body.find("\n---", 3)
    return body[3:end] if end != -1 else body[3:]


fm = frontmatter(text)
lines = fm.split("\n")


def scalar(key):
    m = re.search(r"(?m)^%s:[ \t]*(.*)$" % re.escape(key), fm)
    if not m:
        return ""
    return m.group(1).strip().strip('"').strip("'")


def block(start_re, indent):
    """Return the lines of the first block whose header matches start_re."""
    out = []
    inside = False
    for line in lines:
        if not inside:
            if re.match(start_re, line):
                inside = True
            continue
        if line.strip() == "":
            out.append(line)
            continue
        cur = len(line) - len(line.lstrip(" "))
        if cur <= indent:
            break
        out.append(line)
    return out


def parse_paths(entries):
    """Collect `- path: X` values with their required/schema flags."""
    out = []
    cur = None
    for line in entries:
        m = re.match(r"^\s*-\s+path:\s*(.+?)\s*$", line)
        if m:
            if cur:
                out.append(cur)
            cur = {"path": m.group(1), "required": False, "schema": None}
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*required:\s*(\S+)", line)
        if m:
            cur["required"] = m.group(1).strip().lower() == "true"
            continue
        m = re.match(r"^\s*schema:\s*(\S+)", line)
        if m:
            cur["schema"] = m.group(1).strip()
    if cur:
        out.append(cur)
    return out


# --- stages -----------------------------------------------------------------
stage_lines = block(r"^  stages:\s*$", 2)
stages = []
cur = None
sub = None
for line in stage_lines:
    m = re.match(r"^    -\s+id:\s*(\S+)\s*$", line)
    if m:
        if cur:
            stages.append(cur)
        cur = {
            "id": m.group(1),
            "type": "agent",
            "dependsOn": [],
            "requires": [],
            "produces": [],
            "planner": None,
            "planFrom": None,
            "planFile": None,
            "question": None,
            "changesTarget": None,
            "runtime": None,
            "model": None,
            "hasInstructions": False,
            "workspaceMode": None,
            "writeScopes": None,
            "agentGitAccess": None,
            "loopBackTo": None,
            "onExhausted": None,
        }
        sub = None
        continue
    if cur is None:
        continue
    m = re.match(r"^      (\w+):\s*(.*)$", line)
    if m:
        key, val = m.group(1), m.group(2).strip()
        sub = key if val == "" else None
        if key == "type" and val:
            cur["type"] = val
        elif key == "instructions":
            cur["hasInstructions"] = True
            sub = "instructions"
        elif key in ("planFrom", "planFile", "runtime", "model", "workspaceMode",
                     "agentGitAccess", "loopBackTo", "onExhausted", "changesTarget"):
            if val:
                cur[key] = val
        elif key == "question" and val:
            cur["question"] = val.strip('"').strip("'")
        elif key == "writeScopes" and val:
            cur["writeScopes"] = val
        elif key == "planner":
            cur["planner"] = {"outputMode": None, "maxTodos": None}
            sub = "planner"
        continue
    if sub == "instructions":
        continue
    if sub == "planner":
        m = re.match(r"^        (\w+):\s*(.+?)\s*$", line)
        if m:
            cur["planner"][m.group(1)] = m.group(2)
        continue
    if sub == "dependsOn":
        m = re.match(r"^        -\s*(\S+)\s*$", line)
        if m:
            cur["dependsOn"].append(m.group(1))
        continue
    if sub in ("requires", "produces"):
        cur.setdefault("_" + sub, []).append(line)
        continue
if cur:
    stages.append(cur)

for st in stages:
    st["requires"] = parse_paths(st.pop("_requires", []))
    st["produces"] = parse_paths(st.pop("_produces", []))

by_id = {s["id"]: s for s in stages}

# --- authored todos per stage ----------------------------------------------
todo_counts = {}
in_todos = False
for line in lines:
    if re.match(r"^todos:\s*$", line):
        in_todos = True
        continue
    if in_todos:
        m = re.match(r"^    stage:\s*(\S+)\s*$", line)
        if m:
            todo_counts[m.group(1)] = todo_counts.get(m.group(1), 0) + 1
for st in stages:
    st["authoredTodos"] = todo_counts.get(st["id"], 0)

# --- top level --------------------------------------------------------------
mode = scalar("mode") or "dependency"
engine_family = "orchestration" if mode == "sequential" else "graph"

plan_input = {"declared": False, "stage": None, "required": False}
if re.search(r"(?m)^planInput:\s*$", fm):
    plan_input["declared"] = True
    pi = block(r"^planInput:\s*$", 0)
    for line in pi:
        m = re.match(r"^\s*stage:\s*(\S+)", line)
        if m:
            plan_input["stage"] = m.group(1)
        m = re.match(r"^\s*required:\s*(\S+)", line)
        if m:
            plan_input["required"] = m.group(1).strip().lower() == "true"

# --- derived nodes ----------------------------------------------------------
derived = []
for st in stages:
    if st["loopBackTo"]:
        derived.append({"id": "%s-approved" % st["id"], "type": "join", "from": st["id"]})
derived_ids = {d["id"] for d in derived}

# --- schedule ---------------------------------------------------------------
authored_order = [s["id"] for s in stages]
known = set(authored_order) | derived_ids


def deps_of(sid):
    st = by_id.get(sid)
    if st is None:
        # Derived join: depends on the stage it was derived from.
        for d in derived:
            if d["id"] == sid:
                return [d["from"]]
        return []
    return [d for d in st["dependsOn"] if d in known]


depth = {}
cycles = []


def resolve_depth(sid, seen):
    if sid in depth:
        return depth[sid]
    if sid in seen:
        cycles.append(sid)
        return 0
    seen = seen | {sid}
    ds = deps_of(sid)
    value = 0 if not ds else 1 + max(resolve_depth(d, seen) for d in ds)
    depth[sid] = value
    return value


all_ids = authored_order + [d["id"] for d in derived]
for sid in all_ids:
    resolve_depth(sid, set())

waves = []
if depth:
    for level in range(max(depth.values()) + 1):
        members = [sid for sid in all_ids if depth.get(sid) == level]
        if members:
            waves.append(members)

# --- plan handoff roles -----------------------------------------------------
generate = [s["id"] for s in stages if s["planner"]]
accept = [plan_input["stage"]] if plan_input["declared"] and plan_input["stage"] else []
execute = [s["id"] for s in stages if s["planFrom"]] + list(accept)
static_plan_files = [{"id": s["id"], "planFile": s["planFile"]} for s in stages if s["planFile"]]

plan_from_edges = []
for s in stages:
    if not s["planFrom"]:
        continue
    producer = by_id.get(s["planFrom"])
    max_todos = None
    if producer and producer["planner"]:
        max_todos = producer["planner"].get("maxTodos")
    plan_from_edges.append({
        "from": s["planFrom"],
        "to": s["id"],
        "maxTodos": max_todos,
        "direct": s["planFrom"] in s["dependsOn"],
    })

approvals = [
    {
        "id": s["id"],
        "question": s["question"],
        "changesTarget": s["changesTarget"],
        "dependsOn": s["dependsOn"],
        "evidence": [r["path"] for r in s["requires"]],
    }
    for s in stages if s["type"] == "approval"
]

# --- routing provenance -----------------------------------------------------
def defaults_scalar(key):
    """Read defaults.<key>. Workflow-level routing lives in the defaults: block,
    never as a top-level runtime:/model: key."""
    for line in block(r"^defaults:", 0):
        m = re.match(r"^\s+%s:[ \t]*(.*)$" % re.escape(key), line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    return ""


wf_runtime = defaults_scalar("runtime")
wf_model = defaults_scalar("model")
pinned = [
    {"id": s["id"], "runtime": s["runtime"], "model": s["model"]}
    for s in stages if s["runtime"] or s["model"]
]
routing = {
    "workflowRuntime": wf_runtime or None,
    "workflowModel": wf_model or None,
    "pinnedStages": pinned,
    "neutral": not wf_runtime and not wf_model and not pinned,
}

# The addressable identity is the one the operator can actually type. `list`,
# `path`, and the run registry all derive it from the filename, so a workflow
# copied to a new name (the ordinary way to author your own) must not report
# the original's frontmatter `name` here -- doing so printed a "start with:"
# command that would run a different workflow.
_frontmatter_name = scalar("name")
_display_id = resolved_id or _frontmatter_name

model = {
    "name": _display_id,
    "frontmatterName": _frontmatter_name,
    "overview": scalar("overview"),
    "mode": mode,
    "engineFamily": engine_family,
    "source": {"path": wf_path, "scope": scope},
    "routing": routing,
    "planInput": plan_input,
    "stages": stages,
    "derivedNodes": derived,
    "authoredOrder": authored_order,
    "schedule": {
        "kind": "authored-order" if mode == "sequential" else "waves",
        "waves": waves,
    },
    "planStages": {"generate": generate, "accept": accept, "execute": execute},
    "planFromEdges": plan_from_edges,
    "staticPlanFileStages": static_plan_files,
    "approvals": approvals,
    "cycles": sorted(set(cycles)),
    "task": task_text or None,
    "providedPlan": plan_info,
    "runState": {
        "runId": None,
        "registryPath": None,
        "controlPlanPath": None,
        "note": "no run exists; inspect never creates a registry entry or control plan",
    },
}

# --- renderers --------------------------------------------------------------


def render_json():
    print(json.dumps(model, indent=2, sort_keys=True))


def stage_role(s):
    roles = []
    if s["planner"]:
        roles.append("generates a Ralph plan")
    if plan_input["declared"] and s["id"] == plan_input["stage"]:
        roles.append("accepts the supplied Ralph plan")
    if s["planFrom"]:
        roles.append("executes the generated plan from %s TODO by TODO" % s["planFrom"])
    elif plan_input["declared"] and s["id"] == plan_input["stage"]:
        roles.append("executes the supplied plan TODO by TODO")
    if s["planFile"]:
        roles.append("executes the static plan file %s" % s["planFile"])
    return roles


def render_text():
    out = []
    a = out.append
    a("Workflow: %s" % (model["name"] or "<unnamed>"))
    if model["overview"]:
        a("  %s" % model["overview"])
    a("")
    a("Source:   %s" % wf_path)
    a("Scope:    %s" % scope)
    a("Mode:     %s (%s engine)" % (mode, engine_family))
    a("Valid:    yes (source validated read-only)")
    if model["frontmatterName"] and model["frontmatterName"] != model["name"]:
        a("Note:     frontmatter name is %s; this workflow is addressed as %s"
          % (model["frontmatterName"], model["name"]))
    a("")

    if task_text:
        a("Task")
        a("  %s" % task_text)
        a("")

    a("Routing provenance")
    if routing["neutral"]:
        if context == "start":
            a("  runtime/model: unpinned; resolving below from --runtime/--model or a prompt")
        else:
            a("  runtime/model: unpinned; resolved at start from --runtime/--model or a prompt")
    else:
        a("  workflow runtime: %s" % (routing["workflowRuntime"] or "-"))
        a("  workflow model:   %s" % (routing["workflowModel"] or "-"))
        for p in pinned:
            a("  stage %s pinned runtime=%s model=%s"
              % (p["id"], p["runtime"] or "-", p["model"] or "-"))
    a("")

    label = "Authored order" if mode == "sequential" else "Runnable waves"
    suffix = ""
    if derived:
        suffix = ", %d derived node%s" % (len(derived), "" if len(derived) == 1 else "s")
    a("%s (%d authored stage%s%s)"
      % (label, len(stages), "" if len(stages) == 1 else "s", suffix))
    for i, wave in enumerate(waves):
        marks = []
        for sid in wave:
            st = by_id.get(sid)
            kind = "join(derived)" if sid in derived_ids else (st["type"] if st else "?")
            marks.append("%s [%s]" % (sid, kind))
        a("  %d. %s" % (i + 1, ", ".join(marks)))
    if model["cycles"]:
        a("  WARNING cycle through: %s" % ", ".join(model["cycles"]))
    a("")

    a("Ralph plan handoff")
    if not generate and not accept and not static_plan_files:
        a("  none; every stage runs its authored TODOs")
    for s in stages:
        roles = stage_role(s)
        if not roles:
            continue
        a("  %s: %s" % (s["id"], "; ".join(roles)))
        if s["planner"]:
            a("      planner outputMode=%s maxTodos=%s"
              % (s["planner"].get("outputMode") or "-", s["planner"].get("maxTodos") or "-"))
        if s["authoredTodos"] == 0 and (s["planFrom"] or (
                plan_input["declared"] and s["id"] == plan_input["stage"])):
            a("      no authored TODOs: the whole plan is the work")
    for e in plan_from_edges:
        a("  handoff %s -> %s (ceiling %s TODOs%s)"
          % (e["from"], e["to"], e["maxTodos"] or "-",
             "" if e["direct"] else ", NOT a direct dependency"))
    a("")

    a("Supplied plan")
    if not plan_input["declared"]:
        a("  not accepted; this workflow starts from a task only")
        a("  start with: ralph workflow start %s --task <text>" % (model["name"] or "<id>"))
    else:
        a("  accepted by stage: %s" % plan_input["stage"])
        a("  requiredness:      %s" % ("required" if plan_input["required"] else "optional"))
        if plan_info is None:
            if plan_input["required"]:
                a("  no --plan supplied; this workflow refuses a task-only start")
            else:
                a("  no --plan supplied; a task-only start is allowed")
            a("  supply one with: ralph workflow start %s --plan <leaf-plan>"
              % (model["name"] or "<id>"))
        else:
            a("  entry kind:      %s" % plan_info.get("entryKind"))
            a("  source path:     %s" % plan_info.get("path"))
            a("  source sha256:   %s" % (plan_info.get("sha256") or "<unavailable>"))
            a("  format:          %s" % plan_info.get("shape"))
            a("  TODOs:           %s total, %s open"
              % (plan_info.get("total"), plan_info.get("open")))
            a("  task provenance: %s" % plan_info.get("taskProvenance"))
            a("  the source is previewed in place and never copied by inspect")
    a("")

    if approvals:
        a("Approval gates (%d)" % len(approvals))
        for g in approvals:
            a("  %s" % g["id"])
            a("      question:      %s" % (g["question"] or "-"))
            a("      changesTarget: %s" % (g["changesTarget"] or "-"))
            a("      dependsOn:     %s" % (", ".join(g["dependsOn"]) or "-"))
            for path in g["evidence"]:
                a("      evidence:      %s" % path)
    else:
        a("Approval gates: none; this workflow runs autonomously to completion")
    a("")

    if context == "start":
        a("Run state")
        a("  no run exists yet; confirming below creates the registry entry first,")
        a("  then imports any supplied plan, then dispatches the engine.")
    else:
        a("Run state")
        a("  none; no run id, registry entry, or control plan exists until")
        a("  `ralph workflow start` creates one. inspect is read-only.")
    print("\n".join(_colorize_report(out)))


def mermaid_id(sid):
    return re.sub(r"[^A-Za-z0-9_]", "_", sid)


def render_mermaid():
    print("%%%% Workflow: %s (%s)" % (model["name"] or "workflow", mode))
    print("flowchart TD")
    for sid in all_ids:
        st = by_id.get(sid)
        kind = "join" if sid in derived_ids else (st["type"] if st else "stage")
        label = "%s<br/>%s" % (sid, kind)
        if st and st["planner"]:
            label += "<br/>generates plan"
        if plan_input["declared"] and sid == plan_input["stage"]:
            label += "<br/>accepts supplied plan"
        if st and st["planFrom"]:
            label += "<br/>executes plan"
        if kind == "approval":
            print('  %s{{"%s"}}' % (mermaid_id(sid), label))
        elif kind in ("join", "integrate"):
            print("  %s[/%s/]" % (mermaid_id(sid), label))
        else:
            print("  %s[%s]" % (mermaid_id(sid), label))
    if mode == "sequential":
        # Authored order plus the waves the engine may run together.
        for i in range(len(waves) - 1):
            for a_id in waves[i]:
                for b_id in waves[i + 1]:
                    print("  %s --> %s" % (mermaid_id(a_id), mermaid_id(b_id)))
    else:
        for sid in all_ids:
            for dep in deps_of(sid):
                print("  %s --> %s" % (mermaid_id(dep), mermaid_id(sid)))
        for e in plan_from_edges:
            print('  %s -.->|"plan handoff"| %s'
                  % (mermaid_id(e["from"]), mermaid_id(e["to"])))
        for g in approvals:
            if g["changesTarget"]:
                print('  %s -.->|"request-changes"| %s'
                      % (mermaid_id(g["id"]), mermaid_id(g["changesTarget"])))


def dot_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def render_dot():
    print('digraph "%s" {' % dot_escape(model["name"] or "workflow"))
    print("  rankdir=TD;")
    print("  node [shape=box];")
    for sid in all_ids:
        st = by_id.get(sid)
        kind = "join" if sid in derived_ids else (st["type"] if st else "stage")
        shape = "box"
        if kind == "approval":
            shape = "hexagon"
        elif kind in ("join", "integrate"):
            shape = "parallelogram"
        label = "%s\\n%s" % (sid, kind)
        if st and st["planner"]:
            label += "\\ngenerates plan"
        if plan_input["declared"] and sid == plan_input["stage"]:
            label += "\\naccepts supplied plan"
        if st and st["planFrom"]:
            label += "\\nexecutes plan"
        print('  "%s" [shape=%s,label="%s"];' % (dot_escape(sid), shape, dot_escape(label)))
    if mode == "sequential":
        for i in range(len(waves) - 1):
            for a_id in waves[i]:
                for b_id in waves[i + 1]:
                    print('  "%s" -> "%s";' % (dot_escape(a_id), dot_escape(b_id)))
    else:
        for sid in all_ids:
            for dep in deps_of(sid):
                print('  "%s" -> "%s";' % (dot_escape(dep), dot_escape(sid)))
        for e in plan_from_edges:
            print('  "%s" -> "%s" [style=dashed,label="plan handoff"];'
                  % (dot_escape(e["from"]), dot_escape(e["to"])))
        for g in approvals:
            if g["changesTarget"]:
                print('  "%s" -> "%s" [style=dotted,label="request-changes"];'
                      % (dot_escape(g["id"]), dot_escape(g["changesTarget"])))
    print("}")


if fmt == "json":
    render_json()
elif fmt == "mermaid":
    render_mermaid()
elif fmt == "dot":
    render_dot()
else:
    render_text()
PY
}
