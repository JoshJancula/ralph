#!/usr/bin/env bash
set -euo pipefail

# Shared plugin execution gate (P08).
# preview is read-only: resolve and print the invocation tuple. It never runs Ralph.
# execute recomputes the tuple, requires an explicit current-user request plus a
# separate immediate confirmation, and is the sole path that may invoke Ralph.

SCHEMA_VERSION=1
RALPH_COMMAND_NAME="ralph"
COMMAND=""
RALPH_EXECUTED=0

KIND=""
PLAN_PATH=""
RUNTIME=""
MODEL=""
MODEL_SOURCE=""
NATIVE_SUBAGENTS="inherit"
PROJECT_ROOT=""
STATE_ROOT=""
AGENT_ROOT=""
TASK=""
INPUT_PLAN=""
RUN_ID=""
CONFIRMATION_ID=""
REQUEST=""
INSTALL_CONSENT=""
EXECUTION_CONSENT="not-offered"

usage() {
  cat <<'USAGE'
Usage: ralph-plugin-exec.sh preview --kind plan|workflow-start|workflow-resume [options]
       ralph-plugin-exec.sh execute --confirmation-id <sha256> --request <text> [options]

preview options:
  --kind <kind>                 plan, workflow-start, or workflow-resume
  --plan <path>                 Leaf plan (kind=plan) or workflow file (kind=workflow-start)
  --task <text>                 Optional task for workflow-start
  --input-plan <path>           Optional supplied leaf plan for workflow-start (--plan on CLI)
  --runtime <name>              Runtime when resolved
  --model <name>                Model when resolved
  --native-subagents <mode>     Native runtime subagents: off or inherit
  --workspace <path>            Project root (alias: --project-root)
  --project-root <path>         Alias for --workspace
  --workspace-root <path>       State root (.ralph-workspace)
  --agent-workspace <path>      Agent workspace root
  --run <id>                    Workflow run id (workflow-resume)

execute options:
  all preview options, plus:
  --confirmation-id <sha256>    Required. Must match the recomputed tuple id
  --request <text>              Required. Explicit current-user execution request
  --install-consent <value>     Install consent only; never authorizes execute
USAGE
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

trim_ws() {
  local s=${1-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_consent_answer() {
  local raw
  raw="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  raw="$(trim_ws "$raw")"
  printf '%s' "$raw"
}

absolutize() {
  local path=${1-}
  local parent base
  [[ -n "$path" ]] || return 0
  if [[ "$path" != /* ]]; then
    path="${PWD%/}/$path"
  fi
  parent=$(dirname "$path")
  base=$(basename "$path")
  if [[ -d "$parent" ]]; then
    parent=$(cd "$parent" && pwd)
  fi
  printf '%s/%s' "$parent" "$base"
}

shell_quote() {
  local s=${1-}
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

sha256_hex() {
  local text=$1 digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$text" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
  else
    die "ralph-plugin-exec: sha256sum or shasum is required"
  fi
  printf '%s' "$digest"
}

cmd_push() {
  if [[ -z "$COMMAND" ]]; then
    COMMAND=$1
  else
    COMMAND="$COMMAND $1"
  fi
}

cmd_push_quoted() {
  cmd_push "$(shell_quote "$1")"
}

build_command() {
  COMMAND=""
  cmd_push "$RALPH_COMMAND_NAME"
  case "$KIND" in
    plan)
      cmd_push "run"
      cmd_push "--plan"
      cmd_push_quoted "$PLAN_PATH"
      if [[ -n "$RUNTIME" ]]; then
        cmd_push "--runtime"
        cmd_push_quoted "$RUNTIME"
      fi
      if [[ -n "$MODEL" ]]; then
        cmd_push "--model"
        cmd_push_quoted "$MODEL"
      fi
      cmd_push "--workspace"
      cmd_push_quoted "$PROJECT_ROOT"
      cmd_push "--workspace-root"
      cmd_push_quoted "$STATE_ROOT"
      cmd_push "--agent-workspace"
      cmd_push_quoted "$AGENT_ROOT"
      ;;
    workflow-start)
      cmd_push "workflow"
      cmd_push "start"
      cmd_push "--file"
      cmd_push_quoted "$PLAN_PATH"
      if [[ -n "$TASK" ]]; then
        cmd_push "--task"
        cmd_push_quoted "$TASK"
      fi
      if [[ -n "$INPUT_PLAN" ]]; then
        cmd_push "--plan"
        cmd_push_quoted "$INPUT_PLAN"
      fi
      if [[ -n "$RUNTIME" ]]; then
        cmd_push "--runtime"
        cmd_push_quoted "$RUNTIME"
      fi
      if [[ -n "$MODEL" ]]; then
        cmd_push "--model"
        cmd_push_quoted "$MODEL"
      fi
      cmd_push "--workspace"
      cmd_push_quoted "$PROJECT_ROOT"
      ;;
    workflow-resume)
      cmd_push "workflow"
      cmd_push "resume"
      cmd_push_quoted "$RUN_ID"
      cmd_push "--workspace"
      cmd_push_quoted "$PROJECT_ROOT"
      ;;
  esac
}

canonical_tuple() {
  printf '%s\n' \
    "schemaVersion=${SCHEMA_VERSION}" \
    "kind=${KIND}" \
    "planPath=${PLAN_PATH}" \
    "projectRoot=${PROJECT_ROOT}" \
    "stateRoot=${STATE_ROOT}" \
    "agentRoot=${AGENT_ROOT}" \
    "runtime=${RUNTIME}" \
    "model=${MODEL}" \
    "modelSource=${MODEL_SOURCE}" \
    "nativeSubagents=${NATIVE_SUBAGENTS}" \
    "task=${TASK}" \
    "inputPlan=${INPUT_PLAN}" \
    "runId=${RUN_ID}" \
    "command=${COMMAND}"
}

emit_preview() {
  local confirmation_id=$1
  printf 'kind: %s\n' "$KIND"
  printf 'planPath: %s\n' "$PLAN_PATH"
  printf 'projectRoot: %s\n' "$PROJECT_ROOT"
  printf 'stateRoot: %s\n' "$STATE_ROOT"
  printf 'agentRoot: %s\n' "$AGENT_ROOT"
  printf 'runtime: %s\n' "$RUNTIME"
  printf 'model: %s\n' "$MODEL"
  printf 'model source: %s\n' "$MODEL_SOURCE"
  printf 'native subagents: %s\n' "$NATIVE_SUBAGENTS"
  printf 'task: %s\n' "${TASK:-none}"
  printf 'inputPlan: %s\n' "${INPUT_PLAN:-none}"
  printf 'runId: %s\n' "${RUN_ID:-none}"
  printf 'command: %s\n' "$COMMAND"
  printf 'confirmationId: %s\n' "$confirmation_id"
  printf '{'
  printf '"schemaVersion":%s,' "$SCHEMA_VERSION"
  printf '"kind":"%s",' "$(json_escape "$KIND")"
  printf '"planPath":"%s",' "$(json_escape "$PLAN_PATH")"
  printf '"projectRoot":"%s",' "$(json_escape "$PROJECT_ROOT")"
  printf '"stateRoot":"%s",' "$(json_escape "$STATE_ROOT")"
  printf '"agentRoot":"%s",' "$(json_escape "$AGENT_ROOT")"
  printf '"runtime":"%s",' "$(json_escape "$RUNTIME")"
  printf '"model":"%s",' "$(json_escape "$MODEL")"
  printf '"modelSource":"%s",' "$(json_escape "$MODEL_SOURCE")"
  printf '"nativeSubagents":"%s",' "$(json_escape "$NATIVE_SUBAGENTS")"
  printf '"task":"%s",' "$(json_escape "$TASK")"
  printf '"inputPlan":"%s",' "$(json_escape "$INPUT_PLAN")"
  printf '"runId":"%s",' "$(json_escape "$RUN_ID")"
  printf '"command":"%s",' "$(json_escape "$COMMAND")"
  printf '"confirmationId":"%s"' "$(json_escape "$confirmation_id")"
  printf '}\n'
}

parse_args() {
  local mode=$1
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --kind)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --kind requires a value"
        KIND=$2
        shift 2
        ;;
      --plan)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --plan requires a path"
        PLAN_PATH=$2
        shift 2
        ;;
      --task)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --task requires a value"
        TASK=$2
        shift 2
        ;;
      --input-plan)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --input-plan requires a path"
        INPUT_PLAN=$2
        shift 2
        ;;
      --runtime)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --runtime requires a value"
        RUNTIME=$2
        shift 2
        ;;
      --role|--agent)
        die "ralph-plugin-exec: --role was removed; Ralph plugins no longer ship roles"
        ;;
      --model)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --model requires a value"
        MODEL=$2
        shift 2
        ;;
      --native-subagents)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --native-subagents requires a value"
        NATIVE_SUBAGENTS=$2
        shift 2
        ;;
      --workspace|--project-root)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: $1 requires a path"
        PROJECT_ROOT=$2
        shift 2
        ;;
      --workspace-root)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --workspace-root requires a path"
        STATE_ROOT=$2
        shift 2
        ;;
      --agent-workspace)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --agent-workspace requires a path"
        AGENT_ROOT=$2
        shift 2
        ;;
      --namespace)
        die "ralph-plugin-exec: --namespace was removed; use workflow run ids"
        ;;
      --run)
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --run requires a value"
        RUN_ID=$2
        shift 2
        ;;
      --confirmation-id)
        if [[ "$mode" != "execute" ]]; then
          die "ralph-plugin-exec: preview does not accept $1"
        fi
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --confirmation-id requires a value"
        CONFIRMATION_ID=$2
        shift 2
        ;;
      --request)
        if [[ "$mode" != "execute" ]]; then
          die "ralph-plugin-exec: preview does not accept $1"
        fi
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --request requires a value"
        REQUEST=$2
        shift 2
        ;;
      --install-consent)
        if [[ "$mode" != "execute" ]]; then
          die "ralph-plugin-exec: preview does not accept $1"
        fi
        [[ -n "${2-}" ]] || die "ralph-plugin-exec: --install-consent requires a value"
        INSTALL_CONSENT=$2
        shift 2
        ;;
      *)
        die "ralph-plugin-exec: unknown argument: $1"
        ;;
    esac
  done
}

resolve_tuple() {
  case "$KIND" in
    plan|workflow-start|workflow-resume) ;;
    "") die "ralph-plugin-exec: --kind is required" ;;
    *) die "ralph-plugin-exec: unknown kind: $KIND" ;;
  esac

  case "$KIND" in
    plan|workflow-start)
      [[ -n "$PLAN_PATH" ]] || die "ralph-plugin-exec: --plan is required"
      [[ -f "$PLAN_PATH" ]] || die "ralph-plugin-exec: plan file not found: $PLAN_PATH"
      ;;
    workflow-resume)
      [[ -n "$RUN_ID" ]] || die "ralph-plugin-exec: workflow-resume requires --run"
      ;;
  esac

  if [[ -n "$INPUT_PLAN" ]]; then
    [[ -f "$INPUT_PLAN" ]] || die "ralph-plugin-exec: input plan file not found: $INPUT_PLAN"
  fi

  if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT=$PWD
  fi
  if [[ -z "$STATE_ROOT" ]]; then
    STATE_ROOT="${PROJECT_ROOT%/}/.ralph-workspace"
  fi
  if [[ -z "$AGENT_ROOT" ]]; then
    AGENT_ROOT=$PWD
  fi

  if [[ -n "$PLAN_PATH" ]]; then
    PLAN_PATH=$(absolutize "$PLAN_PATH")
  fi
  if [[ -n "$INPUT_PLAN" ]]; then
    INPUT_PLAN=$(absolutize "$INPUT_PLAN")
  fi
  PROJECT_ROOT=$(absolutize "$PROJECT_ROOT")
  STATE_ROOT=$(absolutize "$STATE_ROOT")
  AGENT_ROOT=$(absolutize "$AGENT_ROOT")

  case "$NATIVE_SUBAGENTS" in
    off|inherit) ;;
    *) die "ralph-plugin-exec: --native-subagents must be off or inherit" ;;
  esac

  if [[ -n "$MODEL" ]]; then
    MODEL_SOURCE="explicit override"
  else
    MODEL_SOURCE="runtime saved/default"
  fi

  COMMAND=""
  build_command
}

classify_user_request() {
  local raw=$1
  local n
  n="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  n="$(trim_ws "$n")"

  if [[ -z "$n" ]]; then
    printf '%s' "ambiguous"
    return 0
  fi

  if [[ "$n" == \"*\" || "$n" == \'*\' ]]; then
    printf '%s' "quoted"
    return 0
  fi
  if printf '%s' "$n" | grep -Eq "['\"].*(run|execute|resume).*['\"]"; then
    printf '%s' "quoted"
    return 0
  fi

  if printf '%s' "$n" | grep -Eiq '(^|[[:space:]])(would|could|should|might|hypothetically|imagine|what if|if i|if we)([[:space:]]|$)'; then
    printf '%s' "hypothetical"
    return 0
  fi

  if printf '%s' "$n" | grep -Eiq '(previous run|last run|already ran|already run|we ran|earlier run|that run|prior run|yesterday)'; then
    printf '%s' "historical"
    return 0
  fi

  if printf '%s' "$n" | grep -Eiq '(^|[[:space:]])(install|upgrade|bootstrap)([[:space:]]|$)'; then
    if ! printf '%s' "$n" | grep -Eiq '(^|[[:space:]])(run|execute|resume)([[:space:]]|$)'; then
      printf '%s' "install-only"
      return 0
    fi
  fi

  if printf '%s' "$n" | grep -Eq '^(please[[:space:]]+)?(run|execute|resume)([[:space:]]|$)'; then
    printf '%s' "accepted"
    return 0
  fi

  printf '%s' "ambiguous"
}

reject_request() {
  local class=$1
  EXECUTION_CONSENT="rejected"
  case "$class" in
    quoted)
      printf '%s\n' "ralph-plugin-exec: request is quoted; not an execution request" >&2
      ;;
    hypothetical)
      printf '%s\n' "ralph-plugin-exec: request is hypothetical; not an execution request" >&2
      ;;
    historical)
      printf '%s\n' "ralph-plugin-exec: request is historical; not an execution request" >&2
      ;;
    install-only)
      printf '%s\n' "ralph-plugin-exec: installation consent does not authorize plan execution" >&2
      ;;
    *)
      printf '%s\n' "ralph-plugin-exec: request is ambiguous; not an execution request" >&2
      ;;
  esac
  exit 1
}

read_execution_confirmation() {
  local expected_id=$1
  local answer=""
  if [[ -n "$INSTALL_CONSENT" ]]; then
    EXECUTION_CONSENT="install-only"
    printf '%s\n' "ralph-plugin-exec: installation consent does not authorize plan execution" >&2
    return 1
  fi
  if [[ -t 0 && -t 1 ]]; then
    printf 'Execute the command above? Type the full confirmation id:\n' >&2
    IFS= read -r answer || answer=""
    answer="$(normalize_consent_answer "$answer")"
    if [[ "$answer" == "$expected_id" ]]; then
      EXECUTION_CONSENT="accepted"
      return 0
    fi
    EXECUTION_CONSENT="declined"
    return 1
  fi
  EXECUTION_CONSENT="blocked-noninteractive"
  printf '%s\n' "ralph-plugin-exec: execution requires a real terminal; copy the displayed command to the operator terminal" >&2
  return 1
}

# Sole executing path. Ralph is invoked at most once, and only after acceptance.
invoke_ralph_once() {
  if [[ "$RALPH_EXECUTED" -eq 1 ]]; then
    die "ralph-plugin-exec: Ralph already invoked"
  fi
  RALPH_EXECUTED=1
  eval "$COMMAND"
}

preview() {
  parse_args preview "$@"
  resolve_tuple
  emit_preview "$(sha256_hex "$(canonical_tuple)")"
}

execute() {
  local request_class computed_id
  parse_args execute "$@"

  [[ -n "$CONFIRMATION_ID" ]] || die "ralph-plugin-exec: execute requires --confirmation-id"
  [[ -n "$REQUEST" ]] || die "ralph-plugin-exec: execute requires --request with an explicit current-user request"

  request_class="$(classify_user_request "$REQUEST")"
  if [[ "$request_class" != "accepted" ]]; then
    reject_request "$request_class"
  fi

  resolve_tuple
  computed_id="$(sha256_hex "$(canonical_tuple)")"
  emit_preview "$computed_id"

  if [[ "$CONFIRMATION_ID" != "$computed_id" ]]; then
    EXECUTION_CONSENT="mismatch"
    printf '%s\n' "ralph-plugin-exec: confirmation id mismatch; showing updated preview" >&2
    printf 'executionConsent: mismatch\n'
    exit 1
  fi

  if ! read_execution_confirmation "$computed_id"; then
    if [[ "$EXECUTION_CONSENT" == "declined" ]]; then
      printf '%s\n' "ralph-plugin-exec: confirmation declined; nothing was executed" >&2
    fi
    printf 'executionConsent: %s\n' "$EXECUTION_CONSENT"
    exit 1
  fi

  printf 'executionConsent: accepted\n'
  invoke_ralph_once
}

op=${1-}
if [[ -z "$op" || "$op" == "-h" || "$op" == "--help" ]]; then
  usage
  exit 0
fi
shift

case "$op" in
  preview)
    preview "$@"
    ;;
  execute)
    execute "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
