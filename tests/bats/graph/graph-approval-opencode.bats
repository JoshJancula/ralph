#!/usr/bin/env bats
# OpenCode serve approval request capture against a localhost fake server.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../run-plan/run-plan-invoke-test-helper.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"

setup() {
  run_plan_invoke_test_setup_common
  export RALPH_GRAPH_NODE_ID="node-approval-1"
  export RALPH_OPENCODE_SERVE_CAPTURE_TIMEOUT=3
  export RALPH_OPENCODE_SERVE_REGISTRY="$TEST_TMPDIR/opencode-serve.sessions"
}

teardown() {
  run_plan_invoke_opencode_serve_cleanup 2>/dev/null || true
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL RALPH_OPENCODE_SERVE_CAPTURE_TIMEOUT
  unset RALPH_OPENCODE_SERVE_REGISTRY OPENCODE_PLAN_PERMISSION_CONFIG_PATH
  unset XDG_CONFIG_HOME OPENCODE_CONFIG OPENCODE_REMOTE_CONFIG OPENCODE_DIRECTORY_CONFIG
  run_plan_invoke_test_teardown_common
}

write_opencode_serve_help_stub() {
  local mode="${1:-supported}"
  local launched_marker="${2:-}"
  cat >"$BIN_DIR/opencode" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "serve" && "\${2:-}" == "--help" ]]; then
  if [[ "$mode" == "supported" ]]; then
    printf '%s\n' "Usage: opencode serve" "Start a headless OpenCode server." "--hostname  Hostname to listen on" "--port      Port to listen on" "GET /event  Server-sent events stream"
    exit 0
  fi
  if [[ "$mode" == "empty-help" ]]; then
    printf '%s\n' "ok"
    exit 0
  fi
  printf '%s\n' "unknown command" >&2
  exit 2
fi
if [[ "\$1" == "serve" ]]; then
  if [[ -n "$launched_marker" ]]; then
    printf 'launched\n' >"$launched_marker"
  fi
  printf '%s\n' "serve should not start during feature detect" >&2
  exit 3
fi
if [[ "\$1" == "run" ]]; then
  printf '%s\n' "\$@" >>"${launched_marker:-/dev/null}"
  exit 0
fi
if [[ "\$1" == "--help" || "\$1" == "help" ]]; then
  printf '%s\n' "Usage: opencode" "  run" "  serve"
  exit 0
fi
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
}

write_fake_opencode_serve() {
  local events_file="$1"
  local argv_record="${2:-}"
  local launched_marker="${3:-}"
  local reply_file="${4:-}"
  cat >"$BIN_DIR/fake-opencode-serve.py" <<'PY'
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

events_file = os.environ["OPENCODE_FAKE_EVENTS_FILE"]
reply_file = os.environ.get("OPENCODE_FAKE_REPLY_FILE", "")
with open(events_file, encoding="utf-8") as fh:
    events = []
    for line in fh:
        line = line.strip()
        if line:
            events.append(json.loads(line))

host = "127.0.0.1"
port = 0
args = sys.argv[1:]
i = 0
while i < len(args):
    arg = args[i]
    if arg in ("--auto", "auto"):
        raise SystemExit("fake opencode serve must not receive --auto")
    if arg.startswith("--hostname="):
        host = arg.split("=", 1)[1]
    elif arg == "--hostname" and i + 1 < len(args):
        i += 1
        host = args[i]
    elif arg.startswith("--port="):
        port = int(arg.split("=", 1)[1])
    elif arg == "--port" and i + 1 < len(args):
        i += 1
        port = int(args[i])
    i += 1

if host not in ("127.0.0.1", "localhost"):
    raise SystemExit("fake opencode serve binds loopback only, got %s" % host)

REPLY_PATHS = (
    re.compile(r"^/permission/([^/]+)/reply$"),
    re.compile(r"^/session/([^/]+)/permission/([^/]+)/reply$"),
    re.compile(r"^/api/session/([^/]+)/permission/([^/]+)/reply$"),
)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path.split("?", 1)[0] in ("/global/health", "/health"):
            body = json.dumps({"healthy": True, "version": "fake"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.split("?", 1)[0] not in ("/event", "/global/event"):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        connected = {"type": "server.connected", "properties": {}}
        stream = [connected] + events
        wrap = self.path.startswith("/global/event")
        for event in stream:
            payload = {"payload": event} if wrap else event
            chunk = "data: %s\n\n" % json.dumps(payload, separators=(",", ":"))
            self.wfile.write(chunk.encode("utf-8"))
            self.wfile.flush()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        request_id = ""
        session = ""
        matched = False
        for idx, pattern in enumerate(REPLY_PATHS):
            found = pattern.match(path)
            if not found:
                continue
            matched = True
            if idx == 0:
                request_id = found.group(1)
            else:
                session = found.group(1)
                request_id = found.group(2)
            break
        if not matched:
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            self.send_error(400)
            return
        if not isinstance(payload, dict):
            self.send_error(400)
            return
        reply = payload.get("reply")
        if reply not in ("once", "always", "reject"):
            self.send_error(400)
            return
        if reply_file:
            record = {
                "path": path,
                "requestId": request_id,
                "session": session,
                "body": payload,
            }
            with open(reply_file, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, separators=(",", ":")) + "\n")
        body = b"true"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class LoopbackServer(HTTPServer):
    allow_reuse_address = True


httpd = LoopbackServer((host, port), Handler)
actual_host, actual_port = httpd.server_address
if actual_host not in ("127.0.0.1", "localhost"):
    raise SystemExit("refusing non-loopback bind %s" % actual_host)
print("opencode server listening on http://%s:%s" % (actual_host, actual_port), flush=True)
try:
    httpd.serve_forever()
finally:
    httpd.server_close()
PY
  cat >"$BIN_DIR/opencode" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "serve" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: opencode serve" "Start a headless OpenCode server." "--hostname" "--port" "GET /event" "POST /permission/:requestID/reply"
  exit 0
fi
if [[ "\$1" == "serve" ]]; then
  if [[ -n "$argv_record" ]]; then
    printf '%s\n' "\$@" >>"$argv_record"
  fi
  if [[ -n "$launched_marker" ]]; then
    printf 'launched\n' >"$launched_marker"
  fi
  export OPENCODE_FAKE_EVENTS_FILE="$events_file"
  if [[ -n "$reply_file" ]]; then
    export OPENCODE_FAKE_REPLY_FILE="$reply_file"
  fi
  exec python3 "$BIN_DIR/fake-opencode-serve.py" "\${@:2}"
fi
if [[ "\$1" == "run" ]]; then
  if [[ -n "$argv_record" ]]; then
    printf '%s\n' "\$@" >>"$argv_record"
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
}

write_run_and_serve_stub() {
  local record="$1"
  cat >"$BIN_DIR/opencode" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "serve" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: opencode serve" "--hostname" "--port"
  exit 0
fi
if [[ "\$1" == "serve" ]]; then
  printf 'serve\n' >>"$record"
  exit 3
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
}

permission_event_json() {
  local session="${1:-ses-1}"
  local request_id="${2:-perm-1}"
  local permission="${3:-read}"
  local resource="${4:-src/app.ts}"
  local tool="${5:-}"
  jq -nc \
    --arg session "$session" \
    --arg id "$request_id" \
    --arg permission "$permission" \
    --arg resource "$resource" \
    --arg tool "$tool" \
    '{
      type: "permission.asked",
      properties: {
        id: $id,
        sessionID: $session,
        permission: $permission,
        patterns: [$resource],
        always: [$resource],
        metadata: ({filepath: $resource} + (if $tool == "" then {} else {tool: $tool} end))
      }
    }'
}

write_events_file() {
  local dest="$1"
  shift
  : >"$dest"
  local event
  for event in "$@"; do
    printf '%s\n' "$event" >>"$dest"
  done
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
}

@test "opencode approval request feature-detects serve from cli help without a model call" {
  local launched="$TEST_TMPDIR/serve-launched"
  write_opencode_serve_help_stub supported "$launched"
  run run_plan_invoke_opencode_serve_supported "$BIN_DIR/opencode"
  [ "$status" -eq 0 ]
  [ ! -f "$launched" ]
}

@test "opencode approval request reports unsupported when serve is missing" {
  write_opencode_serve_help_stub missing
  run run_plan_invoke_opencode_serve_supported "$BIN_DIR/opencode"
  [ "$status" -ne 0 ]
  run _run_plan_invoke_opencode_serve_capability_missing "$BIN_DIR/opencode"
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode serve"* ]]
}

@test "opencode approval request reports unsupported when serve help has no protocol surface" {
  write_opencode_serve_help_stub empty-help
  run run_plan_invoke_opencode_serve_supported "$BIN_DIR/opencode"
  [ "$status" -ne 0 ]
}

@test "opencode approval request captures session request identity and read effect" {
  local captured
  run run_plan_invoke_opencode_serve_capture_request "$(permission_event_json ses-read perm-read read src/app.ts)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.session')" = "ses-read" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestId')" = "perm-read" ]
  [ "$(printf '%s' "$captured" | jq -r '.permission')" = "read" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "src/app.ts" ]
}

@test "opencode approval request captures edit effect" {
  local captured
  run run_plan_invoke_opencode_serve_capture_request "$(permission_event_json ses-edit perm-edit edit src/app.ts)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.session')" = "ses-edit" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestId')" = "perm-edit" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" = "edit" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "src/app.ts" ]
}

@test "opencode approval request captures shell effect from bash permission" {
  local captured
  run run_plan_invoke_opencode_serve_capture_request "$(permission_event_json ses-sh perm-sh bash 'ls -la src')"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.session')" = "ses-sh" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestId')" = "perm-sh" ]
  [ "$(printf '%s' "$captured" | jq -r '.permission')" = "bash" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" = "shell" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "ls -la src" ]
}

@test "opencode approval request captures external_directory without treating it as the effect" {
  local captured
  run run_plan_invoke_opencode_serve_capture_request "$(permission_event_json ses-ext perm-ext external_directory /tmp/ws/src read)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.session')" = "ses-ext" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestId')" = "perm-ext" ]
  [ "$(printf '%s' "$captured" | jq -r '.permission')" = "external_directory" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" != "external_directory" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "/tmp/ws/src" ]
}

@test "opencode approval request keeps an external_directory read from becoming edit" {
  local captured
  run run_plan_invoke_opencode_serve_capture_request "$(permission_event_json ses-ext2 perm-ext2 external_directory /tmp/ws/notes.md read)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$captured" | jq -r '.effect')" != "edit" ]
  [ "$(printf '%s' "$captured" | jq -r '.permission')" = "external_directory" ]
}

@test "opencode G15 permission parser preserves actionable identity and rejects generics" {
  local repo_root fixture parsed
  repo_root="$BATS_TEST_DIRNAME/../../.."
  fixture="$repo_root/tests/fixtures/graph-mode-recovery/generic-opencode-request.json"
  [ -f "$fixture" ]

  # read
  run run_plan_invoke_opencode_graph_approval_parse_permission "$(permission_event_json ses-r perm-r read src/app.ts)"
  [ "$status" -eq 0 ]
  parsed="$output"
  [ "$(printf '%s' "$parsed" | jq -r '.actionable')" = "true" ]
  [ "$(printf '%s' "$parsed" | jq -r '.runtime')" = "opencode" ]
  [ "$(printf '%s' "$parsed" | jq -r '.sessionId')" = "ses-r" ]
  [ "$(printf '%s' "$parsed" | jq -r '.nativeRequestId')" = "perm-r" ]
  [ "$(printf '%s' "$parsed" | jq -r '.tool')" = "read" ]
  [ "$(printf '%s' "$parsed" | jq -r '.action')" = "read" ]
  [ "$(printf '%s' "$parsed" | jq -r '.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$parsed" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$parsed" | jq -r '.effect')" != "write" ]
  [ "$(printf '%s' "$parsed" | jq -c '.choices')" = '["allow-once","allow-run","allow-always","deny"]' ]
  [ "$(printf '%s' "$parsed" | jq -c '.lifetimes')" = '["once","run","always-policy"]' ]
  [ "$(printf '%s' "$parsed" | jq -r '.expiresAt')" = "null" ]
  [ -n "$(printf '%s' "$parsed" | jq -r '.reason')" ]
  [ "$(printf '%s' "$parsed" | jq -r '.reason | length')" -le 200 ]

  # edit -> write effect, never invents a broader resource
  run run_plan_invoke_opencode_graph_approval_parse_permission "$(permission_event_json ses-e perm-e edit src/app.ts)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.tool')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "src/app.ts" ]

  # bash -> execute/write with exact command
  run run_plan_invoke_opencode_graph_approval_parse_permission "$(permission_event_json ses-b perm-b bash 'npm test -- focused')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.tool')" = "bash" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "execute" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "npm test -- focused" ]

  # external_directory read must not broaden to write
  run run_plan_invoke_opencode_graph_approval_parse_permission "$(permission_event_json ses-x perm-x external_directory /tmp/ws/notes.md read)"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.sessionId')" = "ses-x" ]
  [ "$(printf '%s' "$output" | jq -r '.nativeRequestId')" = "perm-x" ]
  [ "$(printf '%s' "$output" | jq -r '.tool')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" != "write" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "/tmp/ws/notes.md" ]

  # generic permission/permission/write is non-actionable
  run run_plan_invoke_opencode_graph_approval_parse_permission '{"tool":"permission","action":"permission","effect":"write"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.classification')" = "unknown" ]

  # real generic failure fixture is non-actionable (no native identity)
  run run_plan_invoke_opencode_graph_approval_parse_permission "$(cat "$fixture")"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.classification')" = "unknown" ]
}

@test "opencode approval request ignores non-permission events" {
  run run_plan_invoke_opencode_serve_capture_request '{"type":"server.connected","properties":{}}'
  [ "$status" -ne 0 ]
  run run_plan_invoke_opencode_serve_capture_request '{"type":"session.status","properties":{"sessionID":"ses-1","status":{"type":"busy"}}}'
  [ "$status" -ne 0 ]
}

@test "opencode approval request consumes ordered permission events from a localhost fake server" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local argv_record="$TEST_TMPDIR/serve.args"
  write_events_file "$events_file" \
    '{"type":"session.status","properties":{"sessionID":"ses-ord","status":{"type":"busy"}}}' \
    "$(permission_event_json ses-ord perm-a read src/a.ts)" \
    '{"type":"message.part.updated","properties":{"sessionID":"ses-ord"}}' \
    "$(permission_event_json ses-ord perm-b edit src/b.ts)" \
    "$(permission_event_json ses-ord perm-c bash 'git status')"
  write_fake_opencode_serve "$events_file" "$argv_record"

  run run_plan_invoke_opencode_serve_capture_from_command "$BIN_DIR/opencode"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].requestId')" = "perm-a" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.[1].requestId')" = "perm-b" ]
  [ "$(printf '%s' "$output" | jq -r '.[1].effect')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.[2].requestId')" = "perm-c" ]
  [ "$(printf '%s' "$output" | jq -r '.[2].effect')" = "shell" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].session')" = "ses-ord" ]
  [ "$(printf '%s' "$output" | jq -r 'map(.requestId) | join(",")')" = "perm-a,perm-b,perm-c" ]
}

@test "opencode approval request starts serve on an ephemeral loopback port" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local argv_record="$TEST_TMPDIR/serve.args"
  local launched="$TEST_TMPDIR/serve-launched"
  local port_arg
  write_events_file "$events_file" "$(permission_event_json ses-bind perm-bind read src/app.ts)"
  write_fake_opencode_serve "$events_file" "$argv_record" "$launched"

  run run_plan_invoke_opencode_serve_capture_from_command "$BIN_DIR/opencode"
  [ "$status" -eq 0 ]
  [ -f "$launched" ]
  [ -s "$argv_record" ]
  [[ "$(cat "$argv_record")" == *"serve"* ]]
  [[ "$(cat "$argv_record")" == *"--hostname"* ]]
  [[ "$(cat "$argv_record")" == *"127.0.0.1"* ]]
  [[ "$(cat "$argv_record")" == *"--port"* ]]
  [[ "$(cat "$argv_record")" != *"0.0.0.0"* ]]
  [[ "$(cat "$argv_record")" != *"--auto"* ]]
  port_arg="$(awk 'prev == "--port" { print; exit } { prev = $0 }' "$argv_record")"
  [[ "$port_arg" =~ ^[1-9][0-9]*$ ]]
  [ "$port_arg" != "4096" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].session')" = "ses-bind" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].requestId')" = "perm-bind" ]
}

@test "opencode approval request talks to a localhost fake server only" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local launched="$TEST_TMPDIR/fake-launched"
  write_events_file "$events_file" "$(permission_event_json ses-fake perm-fake edit src/lib.ts)"
  write_fake_opencode_serve "$events_file" "" "$launched"

  run run_plan_invoke_opencode_serve_capture_from_command "$BIN_DIR/opencode"
  [ "$status" -eq 0 ]
  [ -f "$launched" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].session')" = "ses-fake" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].requestId')" = "perm-fake" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].effect')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].resource')" = "src/lib.ts" ]
}

@test "opencode approval request does not start serve with no operator and no graph node" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local launched="$TEST_TMPDIR/fake-launched"
  write_events_file "$events_file" "$(permission_event_json)"
  write_fake_opencode_serve "$events_file" "" "$launched"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  # Plan runs may also use this transport, but only when someone can answer;
  # bats has no terminal and no pre-set decision, so nothing may start.
  unset RALPH_PERMISSION_RESPONSE_DECISION

  run run_plan_invoke_opencode_serve_capture_from_command "$BIN_DIR/opencode"
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph mode or an interactive plan run"* ]]
  [ ! -f "$launched" ]
}

@test "opencode approval request leaves non-graph run invocation unchanged" {
  local record="$TEST_TMPDIR/opencode.args"
  write_run_and_serve_stub "$record"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  export PROMPT="opencode-nongraph-prompt"
  export RALPH_MODE=native
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [[ "$(cat "$record")" == *"run"* ]]
  [[ "$(cat "$record")" == *"opencode-nongraph-prompt"* ]]
  [[ "$(cat "$record")" != *"serve"* ]]
}

start_opencode_wait_session() {
  local events_file="$1"
  local reply_file="$2"
  local argv_record="${3:-}"
  local launched="${4:-}"
  write_fake_opencode_serve "$events_file" "$argv_record" "$launched" "$reply_file"
  run_plan_invoke_opencode_serve_session_start "$BIN_DIR/opencode"
}

@test "opencode approval response maps once to once" {
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-once perm-once read src/app.ts)" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.fallback')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.ralphDecision')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.lifetime')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.response.reply')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.endpoint')" = "/permission/perm-once/reply" ]
}

@test "opencode approval response maps run to always without converting read to write" {
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-run perm-run read src/app.ts)" run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ralphDecision')" = "run" ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "always" ]
  [ "$(printf '%s' "$output" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$output" | jq -r '.response.reply')" = "always" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission.read["src/app.ts"]')" = "allow" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission | has("edit")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission | has("write")')" = "false" ]
}

@test "opencode approval response maps project to always with a read-only overlay" {
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-proj perm-proj read src/app.ts)" project
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ralphDecision')" = "project" ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "always" ]
  [ "$(printf '%s' "$output" | jq -r '.lifetime')" = "project" ]
  [ "$(printf '%s' "$output" | jq -r '.response.reply')" = "always" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission.read["src/app.ts"]')" = "allow" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission | has("edit")')" = "false" ]
}

@test "opencode approval response maps deny to reject" {
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-deny perm-deny edit src/app.ts)" deny
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ralphDecision')" = "deny" ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "reject" ]
  [ "$(printf '%s' "$output" | jq -r '.response.reply')" = "reject" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay')" = "null" ]
}

@test "opencode approval response keeps an external_directory read from becoming write" {
  local extra='{"overlay":{"permission":{"external_directory":{"/tmp/ws/notes.md":"allow"},"edit":{"/tmp/ws/notes.md":"allow"}}}}'
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-ext perm-ext external_directory /tmp/ws/notes.md read)" project "$extra"
  [ "$status" -ne 0 ]
  [[ "$output" == *"write grant"* || "$output" == *"read request"* ]]
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-ext perm-ext external_directory /tmp/ws/notes.md read)" project
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(printf '%s' "$output" | jq -r '.permission')" = "external_directory" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission.read["/tmp/ws/notes.md"]')" = "allow" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission | has("edit")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.overlay.permission | has("external_directory")')" = "false" ]
}

@test "opencode approval response preserves existing config merge precedence" {
  local xdg="$TEST_TMPDIR/xdg"
  local global_cfg="$xdg/opencode/opencode.json"
  local project_cfg="$WORKSPACE/opencode.json"
  local merged overlay_path final mapped
  mkdir -p "$xdg/opencode" "$WORKSPACE"
  printf '%s\n' '{"model":"global-model","theme":"global","permission":{"edit":{"secret.ts":"ask"}}}' >"$global_cfg"
  printf '%s\n' '{"model":"project-model","plugin":["keep-me"]}' >"$project_cfg"
  export XDG_CONFIG_HOME="$xdg"
  unset OPENCODE_CONFIG OPENCODE_REMOTE_CONFIG OPENCODE_DIRECTORY_CONFIG

  merged="$(_run_plan_invoke_opencode_merge_config_layers "$WORKSPACE" "$xdg")"
  [ -n "$merged" ]
  [ "$(jq -r '.model' "$merged")" = "project-model" ]
  [ "$(jq -r '.theme' "$merged")" = "global" ]
  [ "$(jq -r '.plugin[0]' "$merged")" = "keep-me" ]
  [ "$(jq -r '.permission.edit["secret.ts"]' "$merged")" = "ask" ]

  mapped="$(run_plan_invoke_opencode_serve_map_decision "$(permission_event_json ses-cfg perm-cfg read src/app.ts)" project)"
  overlay_path="$(run_plan_invoke_opencode_serve_merge_permission_overlay "$merged" "$(printf '%s' "$mapped" | jq -c '.overlay')")"
  [ "$(jq -r '.model' "$overlay_path")" = "project-model" ]
  [ "$(jq -r '.theme' "$overlay_path")" = "global" ]
  [ "$(jq -r '.plugin[0]' "$overlay_path")" = "keep-me" ]
  [ "$(jq -r '.permission.edit["secret.ts"]' "$overlay_path")" = "ask" ]
  [ "$(jq -r '.permission.read["src/app.ts"]' "$overlay_path")" = "allow" ]
  [ "$(jq -r '.permission | has("edit")' "$overlay_path")" = "true" ]
  [ "$(cat "$global_cfg")" = '{"model":"global-model","theme":"global","permission":{"edit":{"secret.ts":"ask"}}}' ]
  [ "$(cat "$project_cfg")" = '{"model":"project-model","plugin":["keep-me"]}' ]
}

@test "opencode approval response rejects auto mode" {
  run run_plan_invoke_opencode_serve_map_decision "$(permission_event_json)" auto
  [ "$status" -ne 0 ]
  [[ "$output" == *"auto"* ]]
  run run_plan_invoke_opencode_serve_session_start "$BIN_DIR/opencode" --auto
  [ "$status" -ne 0 ]
  [[ "$output" == *"auto"* ]]
}

@test "opencode approval response falls back when serve is unsupported" {
  write_opencode_serve_help_stub missing
  run run_plan_invoke_opencode_serve_start_or_fallback "$BIN_DIR/opencode"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.fallback')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "unsupported" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "overlay" ]
}

@test "opencode approval response keeps the fake server alive while waiting" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local argv_record="$TEST_TMPDIR/serve.args"
  local session session_dir pid
  write_events_file "$events_file" "$(permission_event_json ses-wait perm-wait read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file" "$argv_record")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run run_plan_invoke_opencode_serve_session_alive "$session_dir"
  [ "$status" -eq 0 ]
  sleep 0.3
  run run_plan_invoke_opencode_serve_session_alive "$session_dir"
  [ "$status" -eq 0 ]
  kill -0 "$pid"
  [ ! -s "$reply_file" ]
  [[ "$(cat "$argv_record")" != *"--auto"* ]]
  run_plan_invoke_opencode_serve_close "$session_dir" supervisor >/dev/null
}

@test "opencode approval response sends once without converting read to write" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local session session_dir
  write_events_file "$events_file" "$(permission_event_json ses-send perm-send read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_opencode_serve_respond "$session_dir" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.duplicate')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.resolved')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(jq -s 'length' "$reply_file")" -eq 1 ]
  [ "$(jq -r '.path' "$reply_file")" = "/permission/perm-send/reply" ]
  [ "$(jq -r '.body.reply' "$reply_file")" = "once" ]
  [ "$(jq -r '.requestId' "$reply_file")" = "perm-send" ]
  run_plan_invoke_opencode_serve_close "$session_dir" completion >/dev/null
}

@test "opencode approval response sends project and writes a read-only overlay" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local overlay="$TEST_TMPDIR/opencode-permission-override.json"
  local session session_dir
  write_events_file "$events_file" "$(permission_event_json ses-ov perm-ov external_directory /tmp/ws/notes.md read)"
  export OPENCODE_PLAN_PERMISSION_CONFIG_PATH="$overlay"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_opencode_serve_respond "$session_dir" project
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.lifetime')" = "project" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "read" ]
  [ "$(jq -r '.body.reply' "$reply_file")" = "always" ]
  [ -f "$overlay" ]
  [ "$(jq -r '.permission.read["/tmp/ws/notes.md"]' "$overlay")" = "allow" ]
  [ "$(jq -r '.permission | has("edit")' "$overlay")" = "false" ]
  [ "$(jq -r '.permission | has("external_directory")' "$overlay")" = "false" ]
  [ ! -f "$WORKSPACE/opencode.json" ]
  run_plan_invoke_opencode_serve_close "$session_dir" completion >/dev/null
}

@test "opencode approval response handles duplicate resolution" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local session session_dir
  write_events_file "$events_file" "$(permission_event_json ses-dup perm-dup read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_opencode_serve_respond "$session_dir" run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "always" ]
  run run_plan_invoke_opencode_serve_respond "$session_dir" deny
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.duplicate')" = "true" ]
  [ "$(jq -s 'length' "$reply_file")" -eq 1 ]
  [ "$(jq -r '.body.reply' "$reply_file")" = "always" ]
  run_plan_invoke_opencode_serve_close "$session_dir" completion >/dev/null
}

@test "opencode approval response reconnects safely without enabling auto mode" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local argv_record="$TEST_TMPDIR/serve.args"
  local session session_dir
  write_events_file "$events_file" "$(permission_event_json ses-rc perm-rc read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file" "$argv_record")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_opencode_serve_reconnect "$session_dir"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reconnected')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.auto')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.request.requestId')" = "perm-rc" ]
  [ "$(printf '%s' "$output" | jq -r '.request.effect')" = "read" ]
  [[ "$(cat "$argv_record")" != *"--auto"* ]]
  [ "$(grep -c '^serve$' "$argv_record" || true)" -le 1 ]
  run run_plan_invoke_opencode_serve_respond "$session_dir" once
  [ "$status" -eq 0 ]
  [ "$(jq -r '.body.reply' "$reply_file")" = "once" ]
  run_plan_invoke_opencode_serve_close "$session_dir" completion >/dev/null
}

@test "opencode approval response closes on completion" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local session session_dir pid
  write_events_file "$events_file" "$(permission_event_json ses-done perm-done read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run_plan_invoke_opencode_serve_respond "$session_dir" deny >/dev/null
  run run_plan_invoke_opencode_serve_close "$session_dir" completion
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.closed')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "completion" ]
  ! kill -0 "$pid" 2>/dev/null
  run run_plan_invoke_opencode_serve_session_alive "$session_dir"
  [ "$status" -ne 0 ]
}

@test "opencode approval response closes on cancellation" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local session session_dir pid
  write_events_file "$events_file" "$(permission_event_json ses-can perm-can read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run run_plan_invoke_opencode_serve_close "$session_dir" cancellation
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "cancellation" ]
  ! kill -0 "$pid" 2>/dev/null
  if [[ -s "$reply_file" ]]; then
    [ "$(jq -r '.body.reply' "$reply_file")" = "reject" ]
  fi
}

@test "opencode approval response closes on supervisor cleanup" {
  require_python3
  local events_file="$TEST_TMPDIR/events.jsonl"
  local reply_file="$TEST_TMPDIR/replies.jsonl"
  local session session_dir pid
  write_events_file "$events_file" "$(permission_event_json ses-sup perm-sup read src/app.ts)"
  session="$(start_opencode_wait_session "$events_file" "$reply_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run run_plan_invoke_opencode_serve_cleanup
  [ "$status" -eq 0 ]
  ! kill -0 "$pid" 2>/dev/null
  [ "$(cat "$session_dir/state")" = "closed" ]
  [ "$(cat "$session_dir/close.reason")" = "supervisor" ]
}
