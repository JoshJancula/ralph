#!/usr/bin/env bash
# Resource-oriented workflow and managed-plan operations used by the public CLI.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/workflow/workflow-resource.sh
source "$script_dir/bash-lib/workflow/workflow-resource.sh"
# shellcheck source=bash-lib/workflow/workflow-inspect.sh
source "$script_dir/bash-lib/workflow/workflow-inspect.sh"
# shellcheck source=bash-lib/workflow/workflow-usage.sh
source "$script_dir/bash-lib/workflow/workflow-usage.sh"

workflow_cli_usage() {
  cat >&2 <<'USAGE'
Usage: workflow-cli.sh <list|show|path|edit|inspect|start|runs|status|watch|logs|handoff|resume|reset|recover|cancel|actions|list-plans> [args]

  list              Print winning workflows as a table (optional --tsv for <id><TAB><scope><TAB><overview>)
  show <id>         Print the workflow file byte-exact (optional --project|--global|--bundled)
  path <id>         Print one absolute path (optional --project|--global|--bundled)
  edit <id>         Edit project workflow (optional --project|--global); seeds a missing target from the winner
  inspect <id>      Read-only report of what a run would do (see: inspect --help)
  start             Start a workflow by id or --file (see: start --help)
  runs              List workflow runs (default 20 newest; see: runs --help)
  status <run-id>   Read-only status for one exact run id (optional --json)
  watch <run-id>    Read-only live status and normalized events (see: watch --help)
  logs <run-id>     Stage logs with public selectors (see: logs --help)
  handoff <run-id>  Print a standalone task-salvage report (optional --json)
  resume <run-id>   Resume a paused/retryable run (see: resume --help)
  reset <run-id>    Reset stages after human-requested changes (see: reset --help)
  recover <run-id>  Recover a proven stale/orphaned supervisor (see: recover --help)
  cancel <run-id>   Cancel a live or nonterminal run (see: cancel --help)
  actions           Operator action list/respond/request/approvals (see: actions --help)
  list-plans        List managed plans under .ralph-workspace/plans/ (optional --global)

Public workflow verbs never accept namespace or latest selectors. Publication
remains an automatic Dependency supervisor responsibility (no publish verb).

  show/path options:
    --project|--global|--bundled   Explicit scope (no fallthrough)
    --verbose                      Diagnostics on stderr only

  edit options:
    --project                      Write the state-root project workflow (default for this command)
    --global                       Write $RALPH_HOME/workflows/<id>.workflow.md
USAGE
}

workflow_cli_start_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow start <id> --task <text> [options]
   or: ralph workflow start <id> --plan <file> [--task <text>] [options]
   or: ralph workflow start --file <workflow-path> --task <text> [options]
   or: ralph workflow start --file <workflow-path> --plan <file> [--task <text>] [options]

  --task <text>              Concrete work request (inline text)
  --plan <file>              Any plain-text or Markdown file. If the file contains Ralph
                             TODOs (- [ ] items) it is used as a leaf plan (requires
                             planInput on the workflow). If it contains no TODOs, its
                             content becomes the task description — useful for passing a
                             requirements doc, design note, or AI-generated spec directly.
  --file <workflow-path>     Workflow definition path (mutually exclusive with <id>)
  --runtime <runtime>        Invocation runtime fallback
  --model <model>            Invocation model (paired with effective runtime)
  --workspace|--project-root Project root
  --workspace-root <path>    State root
  --agent-workspace <path>   Agent sandbox
  --yes                      Required for noninteractive confirmation (later dispatch)
  --ralph-mode <mode>        Shared Ralph tooling mode (no|native|ralph|hybrid)
  --session-strategy <s>     Shared session strategy (fresh|resume|reset|compact)
  --cli-resume|--no-cli-resume|--allow-unsafe-resume|--resume <id>
                             Shared CLI session flags

Engine-only graph/orchestration flags (--namespace, --node, --single-stage, --tui, ...) are rejected.
USAGE
}

# Roots for the resolver. Relative state is always <cwd>/.ralph-workspace unless
# RALPH_PLAN_WORKSPACE_ROOT is set. Bundle root is $RALPH_HOME/bundle.
workflow_cli_init_roots() {
  local project_root state_root ralph_home bundle_root
  project_root="${RALPH_PROJECT_ROOT:-$PWD}"
  state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$project_root/.ralph-workspace}"
  ralph_home="${RALPH_HOME:-${HOME:-}/.ralph}"
  bundle_root="$ralph_home/bundle"
  workflow_resource_init "$project_root" "$state_root" "$ralph_home" "$bundle_root"
}

# workflow_cli_read_overview <path>
# Print the YAML frontmatter `overview:` value of a workflow or leaf plan, or
# nothing when the file has no frontmatter or no overview key. Supports plain
# scalars, quoted scalars, and block scalars (| and >).
workflow_cli_read_overview() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || return 0
  awk '
    NR == 1 { if ($0 != "---") exit 0; in_fm = 1; next }
    in_fm && $0 == "---" { exit 0 }
    in_fm && block {
      if ($0 ~ /^[^[:space:]]/) { exit 0 }
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      if (out != "") out = out " "
      out = out line
      next
    }
    in_fm && /^overview:/ {
      value = substr($0, 10)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == "|" || value == ">" || value == "|-" || value == ">-") { block = 1; next }
      out = value
      exit 0
    }
    END {
      gsub(/^"|"$/, "", out)
      gsub(/^\x27|\x27$/, "", out)
      if (out != "") print out
    }
  ' "$path"
}

workflow_cli_overview_field() {
  local path="$1"
  local text=""
  if [[ -f "$path" ]]; then
    text="$(workflow_cli_read_overview "$path")"
  fi
  # Row format is tab-separated; collapse control characters in overview.
  text="${text//$'\t'/ }"
  text="${text%%$'\n'*}"
  printf '%s' "$text"
}

# Public mode: authored `mode:` frontmatter, defaulting to dependency (matches
# the default in bash-lib/workflow/workflow-inspect.sh).
workflow_cli_mode_field() {
  local path="$1" mode
  mode="$(awk '
    NR == 1 { if ($0 != "---") exit; next }
    /^---$/ { exit }
    /^mode:[[:space:]]*sequential[[:space:]]*$/ { print "sequential"; exit }
    /^mode:[[:space:]]*dependency[[:space:]]*$/ { print "dependency"; exit }
  ' "$path" 2>/dev/null)"
  printf '%s' "${mode:-dependency}"
}

workflow_cli_list_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow list [--tsv]

  Prints every winning workflow (project shadows global shadows bundled) as
  a table: ID, SCOPE, MODE, OVERVIEW.

  --tsv   Machine-readable output instead: <id><TAB><scope><TAB><overview>
USAGE
}

workflow_cli_cmd_list() {
  local format=table
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tsv) format=tsv; shift ;;
      -h|--help) workflow_cli_list_usage; exit 0 ;;
      *) echo "Error: unknown option for ralph workflow list: $1" >&2; exit 2 ;;
    esac
  done
  workflow_cli_init_roots || exit 1

  local id kind path text mode
  local -a rows_id=() rows_scope=() rows_mode=() rows_overview=()
  while IFS=$'\t' read -r id kind path; do
    [[ -n "$id" ]] || continue
    text="$(workflow_cli_overview_field "$path")"
    if [[ "$format" == "tsv" ]]; then
      printf '%s\t%s\t%s\n' "$id" "$kind" "$text"
      continue
    fi
    mode="$(workflow_cli_mode_field "$path")"
    rows_id+=("$id"); rows_scope+=("$kind"); rows_mode+=("$mode"); rows_overview+=("$text")
  done < <(workflow_resource_list_winning)

  [[ "$format" == "tsv" ]] && return 0

  if [[ ${#rows_id[@]} -eq 0 ]]; then
    printf 'No workflows found (checked project, global, and bundled scopes).\n'
    printf 'Create one with: ralph create workflow\n'
    return 0
  fi

  local -i id_w=2 scope_w=5 mode_w=4
  local -i overview_max=52
  local i n="${#rows_id[@]}" overview_w=0
  for ((i = 0; i < n; i++)); do
    ((${#rows_id[i]} > id_w)) && id_w=${#rows_id[i]}
    ((${#rows_scope[i]} > scope_w)) && scope_w=${#rows_scope[i]}
    ((${#rows_mode[i]} > mode_w)) && mode_w=${#rows_mode[i]}
    ((${#rows_overview[i]} > overview_w)) && overview_w=${#rows_overview[i]}
  done
  ((overview_w > overview_max)) && overview_w=$overview_max
  ((overview_w < 8)) && overview_w=8

  local bold="" dim="" reset=""
  if [[ -t 1 && "${NO_COLOR+x}" != x && "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
    bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
  fi

  local overview
  printf '%s%-*s  %-*s  %-*s  %-*s%s\n' \
    "$bold" "$id_w" "ID" "$scope_w" "SCOPE" "$mode_w" "MODE" "$overview_w" "OVERVIEW" "$reset"
  printf '%s%s  %s  %s  %s%s\n' \
    "$dim" "$(printf '%*s' "$id_w" '' | tr ' ' '-')" \
    "$(printf '%*s' "$scope_w" '' | tr ' ' '-')" \
    "$(printf '%*s' "$mode_w" '' | tr ' ' '-')" \
    "$(printf '%*s' "$overview_w" '' | tr ' ' '-')" "$reset"
  for ((i = 0; i < n; i++)); do
    overview="${rows_overview[i]}"
    if ((${#overview} > overview_w)); then
      overview="${overview:0:overview_w-3}..."
    fi
    printf '%-*s  %-*s  %s%-*s%s  %-*s\n' \
      "$id_w" "${rows_id[i]}" "$scope_w" "${rows_scope[i]}" \
      "$dim" "$mode_w" "${rows_mode[i]}" "$reset" "$overview_w" "$overview"
  done

  printf '\n%sExamples%s\n' "$bold" "$reset"
  printf '  ralph workflow inspect <id>                     Preview waves, plan handoffs, and approval gates (read-only)\n'
  printf '  ralph workflow start <id> --task "<text>"       Start a task-driven run\n'
  printf '  ralph workflow start <id> --plan <leaf-plan>    Start from an already-refined leaf plan\n'
}

# Parse show/path argv: one id, optional single scope, optional --verbose.
# Rejects invalid ids/scopes before any resolve/filesystem lookup beyond init.
workflow_cli_parse_show_path() {
  local verb="$1"
  shift
  WORKFLOW_CLI_ID=""
  WORKFLOW_CLI_SCOPE=""
  WORKFLOW_CLI_VERBOSE=0
  local arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --project|--global|--bundled)
        if [[ -n "$WORKFLOW_CLI_SCOPE" ]]; then
          echo "Error: use only one of --project, --global, --bundled" >&2
          exit 2
        fi
        WORKFLOW_CLI_SCOPE="${arg#--}"
        shift
        ;;
      --verbose)
        WORKFLOW_CLI_VERBOSE=1
        shift
        ;;
      -h|--help)
        workflow_cli_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow $verb: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$WORKFLOW_CLI_ID" ]]; then
          echo "Error: ralph workflow $verb accepts exactly one workflow id" >&2
          exit 2
        fi
        WORKFLOW_CLI_ID="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$WORKFLOW_CLI_ID" ]]; then
    echo "Error: ralph workflow $verb requires a workflow id" >&2
    exit 2
  fi

  # Reject invalid id/scope before init touches candidate paths on disk.
  if ! workflow_resource_id_valid "$WORKFLOW_CLI_ID"; then
    echo "Error: invalid workflow id: $WORKFLOW_CLI_ID" >&2
    exit 2
  fi
  if [[ -n "$WORKFLOW_CLI_SCOPE" ]] && ! workflow_resource_scope_valid "$WORKFLOW_CLI_SCOPE"; then
    echo "Error: invalid workflow scope: $WORKFLOW_CLI_SCOPE" >&2
    exit 2
  fi
}

workflow_cli_resolve_or_fail() {
  local id="$1"
  local scope="${2:-}"
  local verbose="${3:-0}"
  local resolved kind path

  if ! resolved="$(workflow_resource_resolve "$id" "$scope")"; then
    local ec=$?
    if [[ "$ec" -eq 2 ]]; then
      exit 2
    fi
    if [[ -n "$scope" ]]; then
      echo "Error: workflow not found in $scope: $id" >&2
    else
      echo "Error: workflow not found: $id" >&2
    fi
    exit 1
  fi

  kind="${resolved%%$'\t'*}"
  path="${resolved#*$'\t'}"
  if [[ "$verbose" == "1" ]]; then
    printf 'resolved scope: %s\n' "$kind" >&2
    printf 'resolved path: %s\n' "$path" >&2
  fi
  WORKFLOW_CLI_RESOLVED_KIND="$kind"
  WORKFLOW_CLI_RESOLVED_PATH="$path"
}

workflow_cli_cmd_show() {
  workflow_cli_parse_show_path show "$@"
  workflow_cli_init_roots || exit 1
  workflow_cli_resolve_or_fail "$WORKFLOW_CLI_ID" "$WORKFLOW_CLI_SCOPE" "$WORKFLOW_CLI_VERBOSE"
  # Byte-exact file contents on stdout; diagnostics already went to stderr.
  cat -- "$WORKFLOW_CLI_RESOLVED_PATH"
}

workflow_cli_cmd_path() {
  workflow_cli_parse_show_path path "$@"
  workflow_cli_init_roots || exit 1
  workflow_cli_resolve_or_fail "$WORKFLOW_CLI_ID" "$WORKFLOW_CLI_SCOPE" "$WORKFLOW_CLI_VERBOSE"
  printf '%s\n' "$WORKFLOW_CLI_RESOLVED_PATH"
}

# --- edit: project / --project / --global atomic editor --------------------

workflow_cli_select_editor() {
  if [[ -n "${VISUAL:-}" ]]; then
    printf '%s\n' "$VISUAL"
  elif [[ -n "${EDITOR:-}" ]]; then
    printf '%s\n' "$EDITOR"
  elif command -v nano >/dev/null 2>&1; then
    # nano over vi as the unset-env default: modal editors are the #1 way
    # operators get stuck unable to save/exit. Falls back to vi only where
    # nano genuinely is not installed (minimal/CI containers).
    printf 'nano\n'
  else
    printf 'vi\n'
  fi
}

# Tell the operator how to save and exit before the editor takes over the
# terminal. vi/vim/nvim's modal :wq is the classic trap for anyone who isn't
# already a vi user; other editors get a generic reminder for the same reason.
workflow_cli_editor_hint() {
  local editor="$1" base
  base="$(basename -- "${editor%% *}")"
  case "$base" in
    vi|vim|nvim)
      printf 'Opening %s to edit the workflow.\n' "$editor" >&2
      printf '  Save and exit: press Esc, then type :wq and press Enter.\n' >&2
      printf '  Discard changes instead: press Esc, then type :q! and press Enter.\n' >&2
      ;;
    nano)
      printf 'Opening %s to edit the workflow.\n' "$editor" >&2
      printf '  Save and exit: press Ctrl+O, then Enter, then Ctrl+X.\n' >&2
      printf '  Discard changes instead: press Ctrl+X, then answer N when asked to save.\n' >&2
      ;;
    *)
      printf 'Opening %s to edit the workflow. Save and close it to continue.\n' "$editor" >&2
      ;;
  esac
}

workflow_cli_file_fingerprint() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
  else
    # POSIX fallback: size + cksum is enough to detect concurrent mutation.
    printf '%s-%s\n' "$(wc -c <"$path" | tr -d ' ')" "$(cksum <"$path" | awk '{print $1}')"
  fi
}

# Parse edit argv: one id and optional --project|--global. --bundled is refused
# because bundle assets are immutable.
workflow_cli_parse_edit() {
  WORKFLOW_CLI_ID=""
  WORKFLOW_CLI_SCOPE=""
  local arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --project|--global)
        if [[ -n "$WORKFLOW_CLI_SCOPE" ]]; then
          echo "Error: use only one of --project, --global" >&2
          exit 2
        fi
        WORKFLOW_CLI_SCOPE="${arg#--}"
        shift
        ;;
      --bundled)
        echo "Error: bundled workflows are immutable; use --project to create a project shadow" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow edit: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$WORKFLOW_CLI_ID" ]]; then
          echo "Error: ralph workflow edit accepts exactly one workflow id" >&2
          exit 2
        fi
        WORKFLOW_CLI_ID="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$WORKFLOW_CLI_ID" ]]; then
    echo "Error: ralph workflow edit requires a workflow id" >&2
    exit 2
  fi
  if ! workflow_resource_id_valid "$WORKFLOW_CLI_ID"; then
    echo "Error: invalid workflow id: $WORKFLOW_CLI_ID" >&2
    exit 2
  fi
  # Default writable target is the project state-root workflow.
  if [[ -z "$WORKFLOW_CLI_SCOPE" ]]; then
    WORKFLOW_CLI_SCOPE="project"
  fi
}

# Cleanup/restore state for the edit session (trap-friendly).
WORKFLOW_CLI_EDIT_TMP=""
WORKFLOW_CLI_EDIT_BACKUP=""
WORKFLOW_CLI_EDIT_TARGET=""
WORKFLOW_CLI_EDIT_HAD_ORIGINAL=0
WORKFLOW_CLI_EDIT_DONE=0
# When set, failure cleanup removes temps only and never touches the live target
# (used for target-race refusals so a concurrent writer is preserved).
WORKFLOW_CLI_EDIT_KEEP_TARGET=0

workflow_cli_edit_cleanup() {
  local ec="${1:-1}"
  # Successful commit already renamed the temp into place.
  if [[ "$WORKFLOW_CLI_EDIT_DONE" -eq 1 ]]; then
    rm -f -- "${WORKFLOW_CLI_EDIT_BACKUP:-}" 2>/dev/null || true
    WORKFLOW_CLI_EDIT_TMP=""
    WORKFLOW_CLI_EDIT_BACKUP=""
    return 0
  fi
  if [[ "$WORKFLOW_CLI_EDIT_KEEP_TARGET" -eq 1 ]]; then
    rm -f -- "${WORKFLOW_CLI_EDIT_TMP:-}" "${WORKFLOW_CLI_EDIT_BACKUP:-}" 2>/dev/null || true
    WORKFLOW_CLI_EDIT_TMP=""
    WORKFLOW_CLI_EDIT_BACKUP=""
    return "$ec"
  fi
  # Restore pre-edit bytes when we still own them; for a failed shadow create,
  # ensure no partial target file remains.
  if [[ "$WORKFLOW_CLI_EDIT_HAD_ORIGINAL" -eq 1 && -n "${WORKFLOW_CLI_EDIT_BACKUP:-}" && -f "$WORKFLOW_CLI_EDIT_BACKUP" ]]; then
    if [[ -n "${WORKFLOW_CLI_EDIT_TARGET:-}" ]]; then
      cp -f -- "$WORKFLOW_CLI_EDIT_BACKUP" "$WORKFLOW_CLI_EDIT_TARGET" 2>/dev/null || true
    fi
  elif [[ "$WORKFLOW_CLI_EDIT_HAD_ORIGINAL" -eq 0 && -n "${WORKFLOW_CLI_EDIT_TARGET:-}" ]]; then
    rm -f -- "$WORKFLOW_CLI_EDIT_TARGET" 2>/dev/null || true
  fi
  rm -f -- "${WORKFLOW_CLI_EDIT_TMP:-}" "${WORKFLOW_CLI_EDIT_BACKUP:-}" 2>/dev/null || true
  WORKFLOW_CLI_EDIT_TMP=""
  WORKFLOW_CLI_EDIT_BACKUP=""
  return "$ec"
}

workflow_cli_edit_on_signal() {
  workflow_cli_edit_cleanup 1
  exit 1
}

# Resolve seed path for a missing writable target.
# Project: seed from global or bundled winner. Global: seed from project or bundled.
workflow_cli_edit_seed_for_missing() {
  local id="$1"
  local target_scope="$2"
  local resolved seed_kind seed_path
  local ec

  if ! resolved="$(workflow_resource_resolve "$id")"; then
    ec=$?
    if [[ "$ec" -eq 2 ]]; then
      return 2
    fi
    echo "Error: workflow not found: $id" >&2
    return 1
  fi
  seed_kind="${resolved%%$'\t'*}"
  seed_path="${resolved#*$'\t'}"

  case "$target_scope" in
    project)
      if [[ "$seed_kind" == "project" ]]; then
        # Resolver saw a project file we did not; treat as race/missing.
        echo "Error: workflow not found in project: $id" >&2
        return 1
      fi
      ;;
    global)
      if [[ "$seed_kind" == "global" ]]; then
        echo "Error: workflow not found in global: $id" >&2
        return 1
      fi
      if [[ "$seed_kind" != "project" && "$seed_kind" != "bundled" ]]; then
        echo "Error: workflow not found: $id" >&2
        return 1
      fi
      ;;
    *)
      echo "Error: unsupported edit scope: $target_scope" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$seed_path"
}

workflow_cli_cmd_edit() {
  workflow_cli_parse_edit "$@"
  workflow_cli_init_roots || exit 1

  # shellcheck source=bash-lib/plan-todo.sh
  source "$script_dir/bash-lib/plan-todo.sh"

  local id="$WORKFLOW_CLI_ID"
  local scope="$WORKFLOW_CLI_SCOPE"
  local target seed_path editor
  local target_dir had_original=0 pre_fp=""
  local scope_label dir_label

  case "$scope" in
    project)
      scope_label="project"
      dir_label="project workflows directory"
      ;;
    global)
      scope_label="global"
      dir_label="global workflows directory"
      ;;
    *)
      echo "Error: unsupported edit scope: $scope" >&2
      exit 2
      ;;
  esac

  target="$(workflow_resource_candidate_path "$id" "$scope")" || exit $?
  target_dir="$(dirname -- "$target")"

  if [[ -f "$target" || -L "$target" ]]; then
    had_original=1
    seed_path="$target"
  else
    # Seed a missing writable target from the current unscoped winner.
    if ! seed_path="$(workflow_cli_edit_seed_for_missing "$id" "$scope")"; then
      exit $?
    fi
  fi

  if ! plan_workflow_validate "$seed_path"; then
    echo "Error: workflow failed validation before edit: $seed_path" >&2
    exit 1
  fi

  mkdir -p -- "$target_dir" || {
    echo "Error: cannot create $dir_label: $target_dir" >&2
    exit 1
  }
  if [[ ! -w "$target_dir" ]]; then
    echo "Error: $dir_label is not writable: $target_dir" >&2
    exit 1
  fi

  WORKFLOW_CLI_EDIT_TARGET="$target"
  WORKFLOW_CLI_EDIT_HAD_ORIGINAL="$had_original"
  WORKFLOW_CLI_EDIT_DONE=0
  WORKFLOW_CLI_EDIT_KEEP_TARGET=0
  WORKFLOW_CLI_EDIT_TMP="$(mktemp "$target_dir/.workflow-edit-XXXXXX")" || {
    echo "Error: failed to create edit temp file in $target_dir" >&2
    exit 1
  }
  if [[ "$had_original" -eq 1 ]]; then
    WORKFLOW_CLI_EDIT_BACKUP="$(mktemp "$target_dir/.workflow-edit-bak-XXXXXX")" || {
      rm -f -- "$WORKFLOW_CLI_EDIT_TMP"
      echo "Error: failed to create edit backup in $target_dir" >&2
      exit 1
    }
    # Copy through symlinks so the backup holds file bytes, not a link.
    cp -f -- "$seed_path" "$WORKFLOW_CLI_EDIT_BACKUP" || {
      workflow_cli_edit_cleanup 1
      echo "Error: failed to back up original workflow: $target" >&2
      exit 1
    }
    pre_fp="$(workflow_cli_file_fingerprint "$target")" || pre_fp=""
  fi

  cp -f -- "$seed_path" "$WORKFLOW_CLI_EDIT_TMP" || {
    workflow_cli_edit_cleanup 1
    echo "Error: failed to seed edit buffer from $seed_path" >&2
    exit 1
  }

  # Ensure failure/signal paths restore the original and remove temps.
  trap 'workflow_cli_edit_on_signal' INT TERM HUP
  trap 'workflow_cli_edit_cleanup $?' EXIT

  editor="$(workflow_cli_select_editor)"
  workflow_cli_editor_hint "$editor"
  if ! "$editor" "$WORKFLOW_CLI_EDIT_TMP"; then
    echo "Error: editor failed: $editor" >&2
    workflow_cli_edit_cleanup 1
    trap - INT TERM HUP EXIT
    exit 1
  fi

  if ! plan_workflow_validate "$WORKFLOW_CLI_EDIT_TMP"; then
    echo "Error: edited workflow failed validation; original preserved" >&2
    workflow_cli_edit_cleanup 1
    trap - INT TERM HUP EXIT
    exit 1
  fi

  # Target race: refuse to clobber a concurrent create or content change.
  if [[ "$had_original" -eq 1 ]]; then
    if [[ ! -f "$target" && ! -L "$target" ]]; then
      echo "Error: workflow target changed during edit (removed); refusing to write" >&2
      WORKFLOW_CLI_EDIT_KEEP_TARGET=1
      workflow_cli_edit_cleanup 1
      trap - INT TERM HUP EXIT
      exit 1
    fi
    local now_fp
    now_fp="$(workflow_cli_file_fingerprint "$target")" || now_fp=""
    if [[ -n "$pre_fp" && -n "$now_fp" && "$pre_fp" != "$now_fp" ]]; then
      echo "Error: workflow target changed during edit (race); refusing to overwrite" >&2
      WORKFLOW_CLI_EDIT_KEEP_TARGET=1
      workflow_cli_edit_cleanup 1
      trap - INT TERM HUP EXIT
      exit 1
    fi
  else
    if [[ -e "$target" ]]; then
      echo "Error: workflow target appeared during edit (race); refusing to overwrite" >&2
      WORKFLOW_CLI_EDIT_KEEP_TARGET=1
      workflow_cli_edit_cleanup 1
      trap - INT TERM HUP EXIT
      exit 1
    fi
  fi

  # Atomic publish: same-directory rename replaces a symlink entry without
  # mutating its former referent (bundle stays immutable when seeding global).
  if ! mv -f -- "$WORKFLOW_CLI_EDIT_TMP" "$target"; then
    echo "Error: failed to publish edited workflow to $target" >&2
    workflow_cli_edit_cleanup 1
    trap - INT TERM HUP EXIT
    exit 1
  fi
  WORKFLOW_CLI_EDIT_TMP=""
  WORKFLOW_CLI_EDIT_DONE=1
  rm -f -- "${WORKFLOW_CLI_EDIT_BACKUP:-}" 2>/dev/null || true
  WORKFLOW_CLI_EDIT_BACKUP=""
  trap - INT TERM HUP EXIT

  printf 'Edited %s workflow: %s\n' "$scope_label" "$target"
}

plan_kind() {
  local path="$1"
  [[ "$path" == *.graph.json ]] && { printf graph; return; }
  [[ "$path" == *.json ]] && { printf orchestration; return; }
  if awk 'NR == 1 { if ($0 != "---") exit 1; next } /^---$/ { exit } /^execution:[[:space:]]*graph/ || /^mode:[[:space:]]*dependency/ { found=1 } END { exit !found }' "$path"; then printf graph
  elif awk 'NR == 1 { if ($0 != "---") exit 1; next } /^---$/ { exit } /^[[:space:]]*pipeline:/ || /^execution:[[:space:]]*orchestration/ || /^mode:[[:space:]]*sequential/ { found=1 } END { exit !found }' "$path"; then printf orchestration
  else printf standard; fi
}

# Public label for a plan_kind() value. Public vocabulary is mode: sequential|dependency
# (see AGENTS.md); "graph"/"orchestration" only persist as internal engine names.
plan_kind_label() {
  case "$1" in
    graph) printf 'Dependency plans' ;;
    orchestration) printf 'Sequential plans' ;;
    *) printf 'Standard plans' ;;
  esac
}

# Find plans directories for the "local" scope: this workspace (cwd is or
# directly contains a .ralph-workspace) plus any child workspaces nested
# under cwd (bounded depth; skips .git and node_modules). Mirrors the local
# discovery `ralph usage` uses for logs, applied to plans dirs.
list_plans_find_local_dirs() {
  local root
  root="$(pwd -P)"
  local -a dirs=()
  if [[ "$(basename "$root")" == ".ralph-workspace" ]]; then
    dirs+=("$root/plans")
  elif [[ -d "$root/.ralph-workspace" ]]; then
    dirs+=("$root/.ralph-workspace/plans")
  fi
  while IFS= read -r found; do
    [[ -n "$found" ]] || continue
    dirs+=("$found/plans")
  done < <(find "$root" -mindepth 2 -maxdepth 6 \
    \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
    -type d -name '.ralph-workspace' -print 2>/dev/null | sort)
  printf '%s\n' "${dirs[@]+"${dirs[@]}"}"
}

# Find plans directories for the "--global" scope: every workspace in the
# user's workspace registry, plus a bounded scan of $HOME. Mirrors
# `ralph usage --full`.
list_plans_find_global_dirs() {
  local registry_py="$script_dir/python/workspace-registry.py"
  local registry_file="${RALPH_WORKSPACES_FILE:-}"
  if [[ -z "$registry_file" ]]; then
    local config_home="${XDG_CONFIG_HOME:-}"
    [[ -z "$config_home" && -n "${HOME:-}" ]] && config_home="$HOME/.config"
    registry_file="$config_home/ralph/workspaces.json"
  fi
  if [[ -f "$registry_file" ]] && command -v python3 >/dev/null 2>&1; then
    while IFS= read -r ws_path; do
      [[ -n "$ws_path" ]] || continue
      printf '%s/.ralph-workspace/plans\n' "$ws_path"
    done < <(python3 "$registry_py" paths "$registry_file" 2>/dev/null)
  fi
  local home_dir="${HOME:-}"
  [[ -z "$home_dir" ]] || \
    find "$home_dir" -maxdepth 5 \
      \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
      -type d -name '.ralph-workspace' -print 2>/dev/null | sort | \
      while IFS= read -r found; do printf '%s/plans\n' "$found"; done
}

list_plans() {
  local global=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global) global=1; shift ;;
      -h|--help) echo "Usage: ralph list plans [--global]" >&2; return 0 ;;
      *) echo "Error: unknown ralph list plans argument: $1" >&2; return 1 ;;
    esac
  done

  local -a plans_dirs=()
  local seen=$'\n' d
  add_plans_dir() {
    if [[ -z "$1" || ! -d "$1" ]]; then return 0; fi
    case "$seen" in *$'\n'"$1"$'\n'*) return 0 ;; esac
    seen+="$1"$'\n'
    plans_dirs+=("$1")
  }
  if [[ "$global" -eq 1 ]]; then
    while IFS= read -r d; do add_plans_dir "$d"; done < <(list_plans_find_global_dirs)
  else
    while IFS= read -r d; do add_plans_dir "$d"; done < <(list_plans_find_local_dirs)
  fi

  if [[ ${#plans_dirs[@]} -eq 0 ]]; then
    if [[ "$global" -eq 1 ]]; then
      printf 'No registered workspaces with managed plans found.\n'
    else
      printf 'No .ralph-workspace found here or in child directories. Use --global to search all registered workspaces.\n'
    fi
    return 0
  fi

  local root file kind found
  for root in "${plans_dirs[@]}"; do
    printf 'Managed plans (%s)\n' "$root"
    for kind in standard graph orchestration; do
      printf '\n%s\n' "$(plan_kind_label "$kind")"
      found=0
      while IFS= read -r -d '' file; do
        [[ "$(plan_kind "$file")" == "$kind" ]] || continue
        printf '  %s\n' "$file"; found=1
      done < <(find "$root" -type f \( -name '*.md' -o -name '*.json' \) -print0 2>/dev/null | sort -z)
      [[ "$found" -eq 1 ]] || printf '  (none)\n'
    done
    printf '\n'
  done
  printf 'Arbitrary plan files elsewhere are run by path and are not discovered automatically.\n'
}

# --- start: strict public parser + dry dispatch tuple (test hook) -----------

workflow_cli_abs_path() {
  local path="${1:-}"
  local parent base abs_parent
  [[ -n "$path" ]] || return 1
  if [[ "$path" != /* ]]; then
    path="$(pwd -P)/$path"
  fi
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$parent" ]]; then
    abs_parent="$(cd -- "$parent" && pwd -P)" || return 1
    printf '%s/%s\n' "$abs_parent" "$base"
  else
    printf '%s\n' "$path"
  fi
}

workflow_cli_realpath() {
  local path="${1:-}"
  [[ -n "$path" && -e "$path" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null && return 0
  fi
  workflow_cli_abs_path "$path"
}

workflow_cli_file_is_workflow() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    /^---$/ { exit }
    /^kind:[[:space:]]*workflow[[:space:]]*$/ { found = 1 }
    END { exit !found }
  ' "$path"
}

# Classify a candidate --plan path: leaf|workflow|graph|orchestration|missing
workflow_cli_plan_shape() {
  local path="$1"
  [[ -f "$path" ]] || { printf 'missing'; return 0; }
  if workflow_cli_file_is_workflow "$path"; then
    printf 'workflow'
    return 0
  fi
  case "$path" in
    *.graph.json) printf 'graph'; return 0 ;;
    *.json) printf 'orchestration'; return 0 ;;
  esac
  # awk runs END even after exit, so gate the END block instead of printing twice.
  awk '
    NR == 1 { if ($0 != "---") { done = 1; exit 0 } in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0 }
    in_fm && /^execution:[[:space:]]*graph([[:space:]]|$)/ { is_graph = 1 }
    in_fm && /^execution:[[:space:]]*orchestration([[:space:]]|$)/ { is_orch = 1 }
    in_fm && /^mode:[[:space:]]*dependency([[:space:]]|$)/ { is_graph = 1 }
    in_fm && /^mode:[[:space:]]*sequential([[:space:]]|$)/ { is_orch = 1 }
    in_fm && /^[[:space:]]*pipeline:[[:space:]]*$/ { is_pipeline = 1 }
    END {
      if (done) { print "leaf"; exit 0 }
      if (is_graph) print "graph"
      else if (is_pipeline || is_orch) print "orchestration"
      else print "leaf"
    }
  ' "$path"
}

# planInput presence: absent|optional|required
workflow_cli_plan_input_mode() {
  local path="$1"
  awk '
    NR == 1 { if ($0 != "---") { print "absent"; exit 0 } next }
    /^---$/ { exit }
    /^planInput:[[:space:]]*$/ { in_pi = 1; present = 1; next }
    in_pi && /^[^[:space:]#]/ { in_pi = 0 }
    in_pi && /^[[:space:]]+required:[[:space:]]*true([[:space:]]|$)/ { required = 1 }
    END {
      if (!present) print "absent"
      else if (required) print "required"
      else print "optional"
    }
  ' "$path"
}

workflow_cli_leaf_plan_counts() {
  # Prints: total open  (classic checkboxes and/or yaml todos)
  local path="$1"
  python3 - "$path" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
total = open_n = 0
# Classic markdown checkboxes anywhere in the file body.
for m in re.finditer(r"(?m)^[ \t]*-[ \t]+\[[ \txX]\]", text):
    total += 1
    if m.group(0).rstrip().endswith("[ ]"):
        open_n += 1
# YAML frontmatter todos (count even when classic also present).
if text.startswith("---"):
    end = text.find("\n---", 3)
    if end != -1:
        fm = text[3:end]
        # Rough todo entries: "- id:" under todos
        todo_blocks = re.findall(
            r"(?m)^[ \t]*-[ \t]+id:[ \t]*.+(?:\n(?:[ \t]+.+)*)*",
            fm,
        )
        # Only count when a todos: key exists.
        if re.search(r"(?m)^todos:", fm):
            y_total = 0
            y_open = 0
            for block in todo_blocks:
                # Skip non-todo list items that happen to have id (stages etc.)
                if "content:" not in block and "status:" not in block:
                    continue
                y_total += 1
                st = re.search(r"(?m)^[ \t]*status:[ \t]*(\S+)", block)
                status = (st.group(1) if st else "pending").strip().lower()
                if status in ("pending", "open", ""):
                    y_open += 1
            if y_total:
                total = y_total
                open_n = y_open
print(f"{total} {open_n}")
PY
}

workflow_cli_plan_under_allowed_root() {
  local plan_real="$1"
  local project_root="$2"
  local state_root="$3"
  local root real_root
  for root in "$project_root" "$state_root" "${HOME:-}/.cursor/plans" "${HOME:-}/.claude/plans"; do
    [[ -n "$root" ]] || continue
    if [[ -d "$root" ]]; then
      real_root="$(workflow_cli_realpath "$root" 2>/dev/null || workflow_cli_abs_path "$root")"
    else
      real_root="$(workflow_cli_abs_path "$root")"
    fi
    case "$plan_real" in
      "$real_root"|"$real_root"/*) return 0 ;;
    esac
  done
  return 1
}

workflow_cli_require_flag_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Error: $flag requires a value" >&2
    exit 2
  fi
}

workflow_cli_reject_duplicate() {
  local flag="$1"
  local already="$2"
  if [[ -n "$already" ]]; then
    echo "Error: duplicate $flag" >&2
    exit 2
  fi
}

workflow_cli_reject_engine_only() {
  local flag="$1"
  echo "Error: engine-only flag not allowed on ralph workflow start: $flag" >&2
  exit 2
}

# Parse start argv into WORKFLOW_CLI_START_* globals. Exit 2 on usage errors.
workflow_cli_parse_start() {
  WORKFLOW_CLI_START_ID=""
  WORKFLOW_CLI_START_FILE=""
  WORKFLOW_CLI_START_TASK=""
  WORKFLOW_CLI_START_TASK_FILE=""
  WORKFLOW_CLI_START_TASK_SET=0
  WORKFLOW_CLI_START_PLAN=""
  WORKFLOW_CLI_START_RUNTIME=""
  WORKFLOW_CLI_START_MODEL=""
  WORKFLOW_CLI_START_WORKSPACE=""
  WORKFLOW_CLI_START_WORKSPACE_ROOT=""
  WORKFLOW_CLI_START_AGENT_WORKSPACE=""
  WORKFLOW_CLI_START_YES=0
  WORKFLOW_CLI_START_RALPH_MODE=""
  WORKFLOW_CLI_START_SESSION_STRATEGY=""
  WORKFLOW_CLI_START_CLI_RESUME=""
  WORKFLOW_CLI_START_RESUME_ID=""
  WORKFLOW_CLI_START_ALLOW_UNSAFE_RESUME=0

  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -h|--help)
        workflow_cli_start_usage
        exit 0
        ;;
      --task)
        if [[ "$WORKFLOW_CLI_START_TASK_SET" -eq 1 ]]; then
          echo "Error: duplicate --task" >&2
          exit 2
        fi
        workflow_cli_require_flag_value "--task" "${2:-}"
        WORKFLOW_CLI_START_TASK="$2"
        WORKFLOW_CLI_START_TASK_SET=1
        shift 2
        ;;
      --plan)
        workflow_cli_reject_duplicate "--plan" "$WORKFLOW_CLI_START_PLAN"
        workflow_cli_require_flag_value "--plan" "${2:-}"
        WORKFLOW_CLI_START_PLAN="$2"
        shift 2
        ;;
      --file)
        workflow_cli_reject_duplicate "--file" "$WORKFLOW_CLI_START_FILE"
        workflow_cli_require_flag_value "--file" "${2:-}"
        WORKFLOW_CLI_START_FILE="$2"
        shift 2
        ;;
      --runtime)
        workflow_cli_reject_duplicate "--runtime" "$WORKFLOW_CLI_START_RUNTIME"
        workflow_cli_require_flag_value "--runtime" "${2:-}"
        WORKFLOW_CLI_START_RUNTIME="$2"
        shift 2
        ;;
      --model)
        workflow_cli_reject_duplicate "--model" "$WORKFLOW_CLI_START_MODEL"
        workflow_cli_require_flag_value "--model" "${2:-}"
        WORKFLOW_CLI_START_MODEL="$2"
        shift 2
        ;;
      --workspace|--project-root)
        workflow_cli_reject_duplicate "--workspace/--project-root" "$WORKFLOW_CLI_START_WORKSPACE"
        workflow_cli_require_flag_value "$arg" "${2:-}"
        WORKFLOW_CLI_START_WORKSPACE="$2"
        shift 2
        ;;
      --workspace-root)
        workflow_cli_reject_duplicate "--workspace-root" "$WORKFLOW_CLI_START_WORKSPACE_ROOT"
        workflow_cli_require_flag_value "--workspace-root" "${2:-}"
        WORKFLOW_CLI_START_WORKSPACE_ROOT="$2"
        shift 2
        ;;
      --agent-workspace)
        workflow_cli_reject_duplicate "--agent-workspace" "$WORKFLOW_CLI_START_AGENT_WORKSPACE"
        workflow_cli_require_flag_value "--agent-workspace" "${2:-}"
        WORKFLOW_CLI_START_AGENT_WORKSPACE="$2"
        shift 2
        ;;
      --yes|-y)
        if [[ "$WORKFLOW_CLI_START_YES" -eq 1 ]]; then
          echo "Error: duplicate --yes" >&2
          exit 2
        fi
        WORKFLOW_CLI_START_YES=1
        shift
        ;;
      --ralph-mode)
        workflow_cli_reject_duplicate "--ralph-mode" "$WORKFLOW_CLI_START_RALPH_MODE"
        workflow_cli_require_flag_value "--ralph-mode" "${2:-}"
        WORKFLOW_CLI_START_RALPH_MODE="$2"
        shift 2
        ;;
      --session-strategy)
        workflow_cli_reject_duplicate "--session-strategy" "$WORKFLOW_CLI_START_SESSION_STRATEGY"
        workflow_cli_require_flag_value "--session-strategy" "${2:-}"
        WORKFLOW_CLI_START_SESSION_STRATEGY="$2"
        shift 2
        ;;
      --cli-resume)
        [[ -z "$WORKFLOW_CLI_START_CLI_RESUME" ]] || { echo "Error: duplicate --cli-resume" >&2; exit 2; }
        WORKFLOW_CLI_START_CLI_RESUME=1
        shift
        ;;
      --no-cli-resume)
        [[ -z "$WORKFLOW_CLI_START_CLI_RESUME" ]] || { echo "Error: duplicate CLI resume flag" >&2; exit 2; }
        WORKFLOW_CLI_START_CLI_RESUME=0
        shift
        ;;
      --allow-unsafe-resume)
        [[ "$WORKFLOW_CLI_START_ALLOW_UNSAFE_RESUME" -eq 0 ]] || { echo "Error: duplicate --allow-unsafe-resume" >&2; exit 2; }
        WORKFLOW_CLI_START_ALLOW_UNSAFE_RESUME=1
        shift
        ;;
      --resume)
        workflow_cli_reject_duplicate "--resume" "$WORKFLOW_CLI_START_RESUME_ID"
        workflow_cli_require_flag_value "--resume" "${2:-}"
        WORKFLOW_CLI_START_RESUME_ID="$2"
        shift 2
        ;;
      --namespace|--node|--max-parallel|--tui|--no-tui|--attach|--compile|--preflight|--render|--successor|--publish|--single-stage|--orchestration|--run-id|--attempt-id|--accept-graph-change|--from|--follow|--stream|--attempt|--tail|--format|--lanes|--workspace-mode|--acknowledge-shared-mutation-risk|--publish-checkpoint|--preset|--create|--dry-run|--all|--state|--json|--stage)
        workflow_cli_reject_engine_only "$arg"
        ;;
      --namespace=*|--node=*|--max-parallel=*|--single-stage=*|--orchestration=*|--run-id=*|--attempt-id=*|--from=*|--stream=*|--attempt=*|--tail=*|--format=*|--lanes=*|--workspace-mode=*|--preset=*|--stage=*|--runtime=*|--model=*|--task=*|--plan=*|--file=*|--ralph-mode=*|--session-strategy=*|--resume=*|--workspace=*|--project-root=*|--workspace-root=*|--agent-workspace=*)
        # Keep =form consistent: value-bearing engine flags still rejected; allowed flags need space form.
        case "$arg" in
          --namespace=*|--node=*|--max-parallel=*|--single-stage=*|--orchestration=*|--run-id=*|--attempt-id=*|--from=*|--stream=*|--attempt=*|--tail=*|--format=*|--lanes=*|--workspace-mode=*|--preset=*|--stage=*|--create=*|--dry-run=*)
            workflow_cli_reject_engine_only "${arg%%=*}"
            ;;
          *)
            echo "Error: use '$arg' as --flag value (space-separated), not --flag=value" >&2
            exit 2
            ;;
        esac
        ;;
      --*)
        echo "Error: unknown option for ralph workflow start: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$WORKFLOW_CLI_START_ID" ]]; then
          echo "Error: ralph workflow start accepts at most one workflow id" >&2
          exit 2
        fi
        WORKFLOW_CLI_START_ID="$arg"
        shift
        ;;
    esac
  done

  if [[ -n "$WORKFLOW_CLI_START_ID" && -n "$WORKFLOW_CLI_START_FILE" ]]; then
    echo "Error: workflow id and --file are mutually exclusive" >&2
    exit 2
  fi
  if [[ -z "$WORKFLOW_CLI_START_ID" && -z "$WORKFLOW_CLI_START_FILE" ]]; then
    echo "Error: ralph workflow start requires a workflow id or --file <path>" >&2
    exit 2
  fi
  if [[ -n "$WORKFLOW_CLI_START_ID" ]] && ! workflow_resource_id_valid "$WORKFLOW_CLI_START_ID"; then
    echo "Error: invalid workflow id: $WORKFLOW_CLI_START_ID" >&2
    exit 2
  fi
  if [[ "$WORKFLOW_CLI_START_TASK_SET" -eq 1 ]]; then
    # Empty task after a present --task is a missing value (usage).
    if [[ -z "${WORKFLOW_CLI_START_TASK//[[:space:]]/}" ]]; then
      echo "Error: --task requires non-empty text" >&2
      exit 2
    fi
    workflow_cli_validate_inline_task "$WORKFLOW_CLI_START_TASK"
  fi
}

# Inline --task text is a single-line work request typed by an operator. Text
# arriving with embedded newlines or control characters is almost always the
# caller's shell having expanded a backtick, $(...), or a variable inside a
# double-quoted argument, substituting command output into the request before
# Ralph ever ran. Ralph cannot see the pre-expansion string, so it refuses the
# corrupted text instead of instantiating a plan around it and spending a run.
workflow_cli_validate_inline_task() {
  local task="$1"
  local bad=""
  case "$task" in
    *$'\n'*|*$'\r'*) bad="newline" ;;
    *$'\t'*) : ;;
  esac
  if [[ -z "$bad" && "$task" =~ [[:cntrl:]] ]]; then
    # Tabs are legitimate inline whitespace; any other control byte is not.
    local stripped="${task//$'\t'/ }"
    [[ "$stripped" =~ [[:cntrl:]] ]] && bad="control character"
  fi
  [[ -z "$bad" ]] && return 0

  echo "Error: --task text contains an embedded $bad" >&2
  echo "  Inline --task must be a single line of text." >&2
  echo "  This usually means your shell expanded a backtick, \$(...), or a" >&2
  echo "  variable inside the double-quoted argument and substituted command" >&2
  echo "  output into the request. Ralph receives only the expanded string." >&2
  echo "  Ralph received:" >&2
  printf '%s\n' "$task" | sed -n '1,6p' | sed 's/^/    | /' >&2
  local _lines
  _lines="$(printf '%s\n' "$task" | wc -l | tr -d ' ')"
  [[ "$_lines" -gt 6 ]] && echo "    | ... ($_lines lines total)" >&2
  echo "  Fix: single-quote the text, or escape the metacharacters:" >&2
  echo "    ralph workflow start <id> --task 'text with \`backticks\` kept literal'" >&2
  echo "  For genuinely multi-line requests, pass a file path instead:" >&2
  echo "    ralph workflow start <id> --task ./request.md" >&2
  exit 2
}

workflow_cli_inspect_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow inspect <id> [options]
   or: ralph workflow inspect --file <workflow-path> [options]

  --file <workflow-path>     Workflow definition path (mutually exclusive with <id>)
  --plan <leaf-plan>         Preview how an operator-supplied leaf plan would bind
  --format <fmt>             text (default), json, mermaid, or dot
  --project|--global|--bundled
                             Explicit resolver scope (no fallthrough)
  --verbose                  Resolver diagnostics on stderr only

inspect is read-only: it validates the workflow and reports what a run would do.
It never creates a run, registry entry, control plan, cache, log, or workspace,
and never invokes a runtime.
USAGE
}

# Parse inspect argv into WORKFLOW_CLI_INSPECT_* globals. Exit 2 on usage errors.
workflow_cli_parse_inspect() {
  WORKFLOW_CLI_INSPECT_ID=""
  WORKFLOW_CLI_INSPECT_FILE=""
  WORKFLOW_CLI_INSPECT_PLAN=""
  WORKFLOW_CLI_INSPECT_FORMAT=""
  WORKFLOW_CLI_INSPECT_SCOPE=""
  WORKFLOW_CLI_INSPECT_VERBOSE=0

  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "$arg" in
      --file)
        workflow_cli_reject_duplicate --file "$WORKFLOW_CLI_INSPECT_FILE"
        workflow_cli_require_flag_value --file "${2:-}"
        WORKFLOW_CLI_INSPECT_FILE="$2"
        shift 2
        ;;
      --plan)
        workflow_cli_reject_duplicate --plan "$WORKFLOW_CLI_INSPECT_PLAN"
        workflow_cli_require_flag_value --plan "${2:-}"
        WORKFLOW_CLI_INSPECT_PLAN="$2"
        shift 2
        ;;
      --format)
        workflow_cli_reject_duplicate --format "$WORKFLOW_CLI_INSPECT_FORMAT"
        workflow_cli_require_flag_value --format "${2:-}"
        WORKFLOW_CLI_INSPECT_FORMAT="$2"
        shift 2
        ;;
      --project|--global|--bundled)
        if [[ -n "$WORKFLOW_CLI_INSPECT_SCOPE" ]]; then
          echo "Error: duplicate scope flag" >&2
          exit 2
        fi
        WORKFLOW_CLI_INSPECT_SCOPE="${arg#--}"
        shift
        ;;
      --verbose)
        WORKFLOW_CLI_INSPECT_VERBOSE=1
        shift
        ;;
      -h|--help)
        workflow_cli_inspect_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown inspect option: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$WORKFLOW_CLI_INSPECT_ID" ]]; then
          echo "Error: unexpected argument: $arg" >&2
          exit 2
        fi
        WORKFLOW_CLI_INSPECT_ID="$arg"
        shift
        ;;
    esac
  done

  case "${WORKFLOW_CLI_INSPECT_FORMAT:=text}" in
    text|json|mermaid|dot) ;;
    *)
      echo "Error: --format must be text, json, mermaid, or dot" >&2
      exit 2
      ;;
  esac

  if [[ -n "$WORKFLOW_CLI_INSPECT_ID" && -n "$WORKFLOW_CLI_INSPECT_FILE" ]]; then
    echo "Error: <id> and --file are mutually exclusive" >&2
    exit 2
  fi
  if [[ -z "$WORKFLOW_CLI_INSPECT_ID" && -z "$WORKFLOW_CLI_INSPECT_FILE" ]]; then
    echo "Error: ralph workflow inspect requires <id> or --file <workflow-path>" >&2
    exit 2
  fi
  if [[ -n "$WORKFLOW_CLI_INSPECT_FILE" && -n "$WORKFLOW_CLI_INSPECT_SCOPE" ]]; then
    echo "Error: scope flags apply to <id> only, not --file" >&2
    exit 2
  fi
}

# Build the compact supplied-plan preview JSON for --plan, or print "null".
# Validates the plan the same way start does, but never copies it.
workflow_cli_inspect_plan_preview() {
  local plan_arg="$1"
  local plan_input_mode="$2"
  local plan_abs plan_real plan_shape counts total open_n sha

  if [[ "$plan_input_mode" == "absent" ]]; then
    echo "Error: workflow does not declare planInput and rejects --plan; inspect it without --plan" >&2
    exit 1
  fi
  plan_abs="$(workflow_cli_abs_path "$plan_arg")" || {
    echo "Error: invalid --plan path: $plan_arg" >&2
    exit 1
  }
  if [[ ! -f "$plan_abs" ]]; then
    echo "Error: provided plan not found: $plan_arg" >&2
    exit 1
  fi
  plan_real="$(workflow_cli_realpath "$plan_abs")" || {
    echo "Error: cannot resolve --plan path: $plan_arg" >&2
    exit 1
  }
  if ! workflow_cli_plan_under_allowed_root "$plan_real" \
    "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" "${_WORKFLOW_RESOURCE_STATE_ROOT}"; then
    echo "Error: --plan must be under the project root, state root, \$HOME/.cursor/plans, or \$HOME/.claude/plans" >&2
    exit 1
  fi
  plan_shape="$(workflow_cli_plan_shape "$plan_real")"
  case "$plan_shape" in
    workflow|graph|orchestration)
      echo "Error: unsupported plan for --plan ($plan_shape); supply a classic or YAML Ralph leaf plan" >&2
      exit 1
      ;;
    missing)
      echo "Error: provided plan not found: $plan_arg" >&2
      exit 1
      ;;
  esac
  counts="$(workflow_cli_leaf_plan_counts "$plan_real")"
  total="${counts%% *}"
  open_n="${counts##* }"
  if [[ "${total:-0}" -lt 1 ]]; then
    echo "Error: provided plan has no TODOs" >&2
    exit 1
  fi
  if [[ "${open_n:-0}" -lt 1 ]]; then
    echo "Error: provided plan has no pending TODOs" >&2
    exit 1
  fi
  sha="$(workflow_inspect_sha256_file "$plan_real" 2>/dev/null || true)"

  local task_provenance="plan-filename"
  local overview_text
  overview_text="$(workflow_cli_read_overview "$plan_real" 2>/dev/null || true)"
  if [[ -n "${overview_text//[[:space:]]/}" ]]; then
    task_provenance="plan-overview"
  fi

  python3 - "$plan_real" "$plan_shape" "$total" "$open_n" "$sha" "$task_provenance" <<'PY'
import json, sys
path, shape, total, open_n, sha, prov = sys.argv[1:7]
print(json.dumps({
    "entryKind": "plan",
    "path": path,
    "shape": shape,
    "total": int(total),
    "open": int(open_n),
    "sha256": sha or None,
    "taskProvenance": prov,
    "copied": False,
}, sort_keys=True))
PY
}

workflow_cli_cmd_inspect() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_inspect_usage
    exit 0
  fi

  workflow_cli_parse_inspect "$@"
  workflow_cli_init_roots || exit 1

  local wf_path="" wf_scope=""
  if [[ -n "$WORKFLOW_CLI_INSPECT_FILE" ]]; then
    wf_path="$(workflow_cli_abs_path "$WORKFLOW_CLI_INSPECT_FILE")" || {
      echo "Error: invalid --file path: $WORKFLOW_CLI_INSPECT_FILE" >&2
      exit 1
    }
    if [[ ! -f "$wf_path" ]]; then
      echo "Error: workflow file not found: $WORKFLOW_CLI_INSPECT_FILE" >&2
      exit 1
    fi
    if ! workflow_cli_file_is_workflow "$wf_path"; then
      echo "Error: --file must point to a workflow definition (kind: workflow)" >&2
      exit 1
    fi
    wf_scope="file"
  else
    workflow_cli_resolve_or_fail "$WORKFLOW_CLI_INSPECT_ID" \
      "$WORKFLOW_CLI_INSPECT_SCOPE" "$WORKFLOW_CLI_INSPECT_VERBOSE"
    wf_path="$WORKFLOW_CLI_RESOLVED_PATH"
    wf_scope="$WORKFLOW_CLI_RESOLVED_KIND"
  fi

  # shellcheck source=bash-lib/plan-todo.sh
  source "$script_dir/bash-lib/plan-todo.sh"
  # Read-only validation: the same authored-source check start performs. For a
  # Sequential workflow this is the orchestration validation path.
  if ! plan_workflow_validate "$wf_path" >/dev/null; then
    echo "Error: invalid workflow: $wf_path" >&2
    exit 1
  fi

  local plan_input_mode plan_json="null"
  plan_input_mode="$(workflow_cli_plan_input_mode "$wf_path")"
  if [[ -n "$WORKFLOW_CLI_INSPECT_PLAN" ]]; then
    plan_json="$(workflow_cli_inspect_plan_preview \
      "$WORKFLOW_CLI_INSPECT_PLAN" "$plan_input_mode")"
  fi

  workflow_inspect_report "$wf_path" "$WORKFLOW_CLI_INSPECT_FORMAT" \
    "$wf_scope" "$plan_json" inspect "" "$WORKFLOW_CLI_INSPECT_ID"
}

# --- start: source classification -------------------------------------------

# Classify a --file argument into <source_kind> <mode> on stdout.
# Workflows carry their own `mode:`. Legacy graph/orchestration files are
# accepted directly and map to dependency/sequential respectively.
workflow_cli_start_classify_file() {
  local path="$1"
  local shape mode
  if workflow_cli_file_is_workflow "$path"; then
    mode="$(awk '
      NR == 1 { if ($0 != "---") exit 0; next }
      /^---$/ { exit }
      /^mode:[[:space:]]*/ { sub(/^mode:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit }
    ' "$path")"
    printf 'file %s\n' "${mode:-dependency}"
    return 0
  fi
  case "$path" in
    *.graph.json) printf 'legacy-orchestration dependency\n'; return 0 ;;
    *.orch.json) printf 'legacy-orchestration sequential\n'; return 0 ;;
  esac
  shape="$(workflow_cli_plan_shape "$path")"
  case "$shape" in
    graph) printf 'legacy-orchestration dependency\n'; return 0 ;;
    orchestration) printf 'legacy-orchestration sequential\n'; return 0 ;;
  esac
  echo "Error: --file must be a workflow definition (kind: workflow) or a legacy graph/orchestration plan" >&2
  return 1
}

# --- start: operator summary and confirmation -------------------------------

# Prominent supplied-plan counts plus the prechecked-TODO trust warning.
workflow_cli_start_plan_counts_notice() {
  local plan_real="$1"
  local counts total open_n completed
  counts="$(workflow_cli_leaf_plan_counts "$plan_real")"
  total="${counts%% *}"
  open_n="${counts##* }"
  completed=$((total - open_n))
  printf '\nSupplied plan TODOs\n'
  printf '  total:     %s\n' "$total"
  printf '  completed: %s\n' "$completed"
  printf '  open:      %s\n' "$open_n"
  if [[ "$completed" -gt 0 ]]; then
    printf '\n  WARNING: %s TODO(s) are already checked in the supplied plan.\n' "$completed"
    printf '  Ralph trusts those as done and will not rerun or reverify them.\n'
    printf '  Uncheck any TODO you want executed before starting this run.\n'
  fi
}

# --- start: interactive routing resolution ---------------------------------
#
# A workflow source may leave runtime/model unset on every stage ("routing
# neutral"). The materializer then emits a plan whose agent stages carry no
# runtime, which the concrete validator rejects with "missing runtime". Before
# this resolution step existed, that surfaced only at engine dispatch -- after
# the run registry entry had been created -- as "engine-dispatch-failed".
#
# Populates, for the caller:
#   WORKFLOW_CLI_START_RUNTIME / WORKFLOW_CLI_START_MODEL  (all-stages choice)
#   WORKFLOW_CLI_START_STAGE_ROUTING                       (per-stage kv args)
#   WORKFLOW_CLI_START_ROUTING_SUMMARY                     (operator display)
WORKFLOW_CLI_START_STAGE_ROUTING=()
WORKFLOW_CLI_START_ROUTING_SUMMARY=""

# True when the start is attended and may prompt.
#
# RALPH_WORKFLOW_START_ASSUME_TTY is a test-only seam, the same shape as
# RALPH_WORKFLOW_START_ENGINE_STUB: it lets the Bats suite drive the prompts
# over a pipe, which is otherwise indistinguishable from a CI start.
workflow_cli_start_is_attended() {
  [[ "${RALPH_WORKFLOW_START_ASSUME_TTY:-0}" == "1" ]] && return 0
  [[ -t 0 ]]
}

# Print the id of every stage that still needs routing, one per line.
# Supervisors and consensus containers never take runtime/model, so they are
# excluded the same way apply_materialized_stage_routing excludes them.
workflow_cli_start_unresolved_stages() {
  local wf_path="$1" scope="$2"
  local model_json
  model_json="$(workflow_inspect_report "$wf_path" json "$scope" 2>/dev/null)" || return 1
  printf '%s' "$model_json" | jq -r '
    if ((.routing.workflowRuntime // "") != "") then empty
    else
      .stages[]
      | select((.type // "") == "" or (.type // "") == "agent")
      | select(((.runtime // "") == ""))
      | .id
    end
  ' 2>/dev/null
}

# Print the id of every agent stage that has no model, one per line. A model
# pinned workflow-wide settles every stage, so that short-circuits.
workflow_cli_start_unresolved_model_stages() {
  local wf_path="$1" scope="$2"
  local model_json
  model_json="$(workflow_inspect_report "$wf_path" json "$scope" 2>/dev/null)" || return 1
  printf '%s' "$model_json" | jq -r '
    if ((.routing.workflowModel // "") != "") then empty
    else
      .stages[]
      | select((.type // "") == "" or (.type // "") == "agent")
      | select(((.model // "") == ""))
      | .id
    end
  ' 2>/dev/null
}

# Runtime is pinned, model is not. Offer the same "runtime default or pick one"
# question the fully-unresolved path asks; fall back to a warning when the start
# is unattended or --yes. Never fatal: the operator asked for this runtime, and
# some runtimes do resolve a default on their own.
workflow_cli_start_resolve_model_for_pinned_runtime() {
  local wf_path="$1" scope="$2" yes_flag="$3"
  local -a stage_ids=()
  local sid stage_list out line picked=""

  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    stage_ids+=("$sid")
  done < <(workflow_cli_start_unresolved_model_stages "$wf_path" "$scope")
  [[ ${#stage_ids[@]} -eq 0 ]] && return 0

  stage_list="$(printf '%s, ' "${stage_ids[@]}")"
  stage_list="${stage_list%, }"

  if [[ "$yes_flag" == "1" ]] || ! workflow_cli_start_is_attended; then
    {
      echo "Warning: no model is pinned for these stages:"
      echo "           $stage_list"
      echo "         They will run on the $WORKFLOW_CLI_START_RUNTIME default. Runtimes with no"
      echo "         saved-model store (cursor, opencode, antigravity) have no default to fall"
      echo "         back on and the stage will fail at dispatch; pass --model <id>, or add a"
      echo "         defaults: block with runtime/model to the workflow, to avoid that."
    } >&2
    return 0
  fi

  # shellcheck source=bash-lib/workflow/workflow-routing.sh
  source "$script_dir/bash-lib/workflow/workflow-routing.sh"
  printf '\n--- model for %s (stages: %s) ---\n' "$WORKFLOW_CLI_START_RUNTIME" "$stage_list" >&2
  out="$(workflow_routing_prompt_model_for_runtime "$WORKFLOW_CLI_START_RUNTIME")" || return 0
  while IFS= read -r line; do
    case "$line" in
      model=*) picked="${line#model=}" ;;
      cancelled=1) return 0 ;;
    esac
  done <<<"$out"
  if [[ -n "$picked" ]]; then
    WORKFLOW_CLI_START_MODEL="$picked"
    WORKFLOW_CLI_START_ROUTING_SUMMARY="$(printf '  all stages: runtime=%s model=%s' \
      "$WORKFLOW_CLI_START_RUNTIME" "$picked")"
  fi
  return 0
}

# Prompt for one runtime+model pair. $1 is a label used in the header.
# An empty model is a valid answer ("Use <runtime> default"): the stage is
# written with a runtime only and the runtime picks its own model at invoke
# time. Only the runtime is required.
# Prints "<runtime>\t<model>"; returns 1 on error, 2 on cancellation.
workflow_cli_start_prompt_pair() {
  local label="$1"
  local out ec=0 rt="" model=""

  # The routing prompt prints a generic header, so name what is being routed
  # first; in the per-stage loop that is the only thing distinguishing one
  # round of prompts from the next.
  printf '\n--- routing for %s ---\n' "$label" >&2
  out="$(workflow_routing_prompt_unresolved_fallback)" || ec=$?
  if [[ "$ec" -ne 0 ]]; then
    return "$ec"
  fi
  local line
  while IFS= read -r line; do
    case "$line" in
      runtime=*) rt="${line#runtime=}" ;;
      model=*) model="${line#model=}" ;;
      cancelled=1) return 2 ;;
    esac
  done <<<"$out"
  if [[ -z "$rt" ]]; then
    return 2
  fi
  printf '%s\t%s\n' "$rt" "$model"
}

# Offer to write the resolved routing back into the workflow source.
# Never fatal: a decline, an unwritable source, or a validation failure leaves
# the run going ahead with the in-memory selections.
workflow_cli_start_offer_persist() {
  local wf_path="$1" scope="$2"
  shift 2
  local -a persist_args=("$@")
  local reply="" tmp_out backup

  if ! workflow_cli_start_is_attended; then
    return 0
  fi
  printf '\nSave this routing into %s for future runs? [y/N] ' "$(basename -- "$wf_path")" >&2
  # Read from stdin, matching workflow_cli_start_confirm, so both prompts in
  # this flow answer from the same stream.
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) return 0 ;;
  esac

  # Bundled sources are installer-owned and global ones are shared across
  # projects; only a project copy (or an explicit --file path) is ours to edit.
  if [[ "$scope" != "project" && "$scope" != "file" ]]; then
    local wf_id
    wf_id="$(basename -- "$wf_path")"
    wf_id="${wf_id%.workflow.md}"
    echo "Not saved: $scope-scoped workflow sources are not writable." >&2
    echo "Run 'ralph workflow edit $wf_id --project' to create a project copy first." >&2
    return 0
  fi
  if [[ ! -w "$wf_path" ]]; then
    echo "Not saved: $wf_path is not writable." >&2
    return 0
  fi

  tmp_out="$(mktemp "${TMPDIR:-/tmp}/ralph-workflow-routing.XXXXXX")" || return 0
  if ! python3 "$script_dir/python/workflow-routing-persist.py" \
    "$wf_path" "$tmp_out" "${persist_args[@]}" >&2; then
    rm -f "$tmp_out"
    echo "Not saved: could not write the routing into the workflow source." >&2
    return 0
  fi
  # Never publish a source the validator would reject on the next run.
  if ! plan_workflow_validate "$tmp_out" >/dev/null 2>&1; then
    rm -f "$tmp_out"
    echo "Not saved: the updated workflow source failed validation; left unchanged." >&2
    return 0
  fi

  # Copy over the original rather than renaming, so the file keeps its inode,
  # permissions, and any symlink pointing at it. That truncates first, so keep a
  # backup to restore from if the copy does not complete.
  backup="$(mktemp "${TMPDIR:-/tmp}/ralph-workflow-routing-backup.XXXXXX")" || {
    rm -f "$tmp_out"
    return 0
  }
  if ! cat "$wf_path" >"$backup"; then
    rm -f "$tmp_out" "$backup"
    echo "Not saved: could not back up $wf_path." >&2
    return 0
  fi
  if ! cat "$tmp_out" >"$wf_path"; then
    cat "$backup" >"$wf_path" 2>/dev/null || \
      echo "Warning: $wf_path may be incomplete; a copy is at $backup" >&2
    rm -f "$tmp_out"
    echo "Not saved: could not update $wf_path." >&2
    return 0
  fi
  rm -f "$tmp_out" "$backup"
  echo "Saved routing into $wf_path" >&2
  return 0
}

# Resolve routing for a routing-neutral workflow source before any run exists.
workflow_cli_start_resolve_routing() {
  # scope doubles as the source kind: an id-resolved workflow reports
  # project/global/bundled, a --file one reports "file", and legacy
  # graph/orchestration artifacts report "legacy-orchestration".
  local wf_path="$1" scope="$2" yes_flag="$3"
  local wf_source_kind="$scope"
  WORKFLOW_CLI_START_STAGE_ROUTING=()
  WORKFLOW_CLI_START_ROUTING_SUMMARY=""

  # Legacy graph/orch sources are already-compiled artifacts with no workflow
  # frontmatter to resolve.
  [[ "$wf_source_kind" == "legacy-orchestration" ]] && return 0
  # An explicit --runtime settles the runtime but not necessarily the model.
  # A stage that reaches the runner with no model at all is refused there
  # ("--non-interactive requires --model"), which happens only after the run
  # exists and a stage has been dispatched -- the operator waits for a failure
  # that was knowable at start. Ask about the model here while they are still
  # present, and warn when there is nobody to ask.
  if [[ -n "$WORKFLOW_CLI_START_RUNTIME" ]]; then
    [[ -n "$WORKFLOW_CLI_START_MODEL" ]] && return 0
    workflow_cli_start_resolve_model_for_pinned_runtime "$wf_path" "$scope" "$yes_flag"
    return 0
  fi

  local -a stage_ids=()
  local sid
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    stage_ids+=("$sid")
  done < <(workflow_cli_start_unresolved_stages "$wf_path" "$scope")

  [[ ${#stage_ids[@]} -eq 0 ]] && return 0

  local stage_list
  stage_list="$(printf '%s, ' "${stage_ids[@]}")"
  stage_list="${stage_list%, }"

  if [[ "$yes_flag" == "1" ]] || ! workflow_cli_start_is_attended; then
    {
      echo "Error: this workflow pins no runtime and these stages are unresolved:"
      echo "         $stage_list"
      echo "       Pass --runtime <runtime> (and --model <model>), or add a"
      echo "       defaults: block with runtime/model to $wf_path."
      echo "       Interactive starts prompt for both; --yes and non-TTY starts cannot."
    } >&2
    exit 2
  fi

  # shellcheck source=bash-lib/workflow/workflow-routing.sh
  source "$script_dir/bash-lib/workflow/workflow-routing.sh"
  # The routing prompt runs inside a command substitution, so the menu helpers
  # it sources there do not survive into this shell. Load them here too, for
  # the apply-scope menu below.
  if ! _workflow_routing_ensure_interactive; then
    echo "Error: interactive menu helpers unavailable for workflow runtime prompt." >&2
    exit 1
  fi

  local pair ec=0 idx
  # This first pick is the first unresolved stage's routing; the next question
  # decides whether it also covers the remaining stages.
  pair="$(workflow_cli_start_prompt_pair \
    "stage ${stage_ids[0]} (you can apply it to every stage next)")" || ec=$?
  if [[ "$ec" -eq 2 ]]; then
    echo "Routing selection cancelled; no run was created." >&2
    exit 1
  fi
  if [[ "$ec" -ne 0 ]]; then
    echo "Error: could not resolve a runtime for the unresolved stages." >&2
    exit 1
  fi
  local first_runtime="${pair%%$'\t'*}" first_model="${pair#*$'\t'}"

  local n="${#stage_ids[@]}"
  local all_label="Use $first_runtime/${first_model:-default} for all $n stage(s)"
  local per_label="Choose a runtime and model per stage"
  local scope_choice=""
  echo "" >&2
  scope_choice="$(
    RALPH_SKIP_FZF_HINT="${RALPH_SKIP_FZF_HINT:-1}" \
      ralph_menu_select --prompt "Apply this routing to every stage?" --default 1 -- \
      "$all_label" "$per_label"
  )" || scope_choice=""

  if [[ -z "$scope_choice" || "$scope_choice" == "$all_label" ]]; then
    WORKFLOW_CLI_START_RUNTIME="$first_runtime"
    WORKFLOW_CLI_START_MODEL="$first_model"
    WORKFLOW_CLI_START_ROUTING_SUMMARY="$(printf '  all unresolved stages: runtime=%s model=%s' \
      "$first_runtime" "${first_model:--}")"
    workflow_cli_start_offer_persist "$wf_path" "$scope" defaults "$first_runtime" "$first_model"
    return 0
  fi

  # Per-stage: the first pick lands on the first unresolved stage, then each
  # remaining stage is prompted for on its own.
  local -a persist_specs=()
  local summary=""
  local rt="$first_runtime" model="$first_model"
  for idx in "${!stage_ids[@]}"; do
    sid="${stage_ids[$idx]}"
    if [[ "$idx" -ne 0 ]]; then
      ec=0
      pair="$(workflow_cli_start_prompt_pair "stage $sid")" || ec=$?
      if [[ "$ec" -eq 2 ]]; then
        echo "Routing selection cancelled; no run was created." >&2
        exit 1
      fi
      if [[ "$ec" -ne 0 ]]; then
        echo "Error: could not resolve a runtime for stage $sid." >&2
        exit 1
      fi
      rt="${pair%%$'\t'*}"
      model="${pair#*$'\t'}"
    fi
    WORKFLOW_CLI_START_STAGE_ROUTING+=("stage_runtime.$sid=$rt")
    [[ -n "$model" ]] && WORKFLOW_CLI_START_STAGE_ROUTING+=("stage_model.$sid=$model")
    persist_specs+=("$sid=$rt${model:+,$model}")
    summary+="$(printf '  %s: runtime=%s model=%s' "$sid" "$rt" "${model:--}")"$'\n'
  done
  WORKFLOW_CLI_START_ROUTING_SUMMARY="${summary%$'\n'}"
  workflow_cli_start_offer_persist "$wf_path" "$scope" stages "${persist_specs[@]}"
  return 0
}

# Interactive confirmation. Noninteractive runs require --yes.
workflow_cli_start_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    return 0
  fi
  if ! workflow_cli_start_is_attended; then
    echo "Error: ralph workflow start requires --yes to confirm noninteractively" >&2
    exit 1
  fi
  printf '\nStart this workflow run? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no run was created." >&2
      exit 1
      ;;
  esac
}

# --- start: materialization -------------------------------------------------

# Materialize the run input for the registry. Prints the temp path.
# Dependency workflows produce a plan file; Sequential workflows produce the
# orchestration JSON the engine seeds from. Legacy sources are used as-is.
workflow_cli_start_materialize_input() {
  local wf_path="$1" source_kind="$2" mode="$3" task_text="$4"
  local runtime="$5" model="$6" tmp_dir="$7" input_plan="${8:-}"
  shift 8 2>/dev/null || shift $#
  # Remaining args are per-stage overrides (stage_runtime.<id>=<rt>,
  # stage_model.<id>=<model>) from an operator's per-stage selection.
  local -a stage_kv=("$@")
  local plan_out orch_out
  local -a inst_kv=()

  if [[ "$source_kind" == "legacy-orchestration" ]]; then
    if [[ "$mode" == "sequential" && "$wf_path" == *.orch.json ]]; then
      printf '%s\n' "$wf_path"
      return 0
    fi
    if [[ "$mode" == "dependency" && "$wf_path" == *.graph.json ]]; then
      printf '%s\n' "$wf_path"
      return 0
    fi
    plan_out="$wf_path"
  else
    plan_out="$tmp_dir/materialized.plan.md"
    [[ -n "$runtime" ]] && inst_kv+=("fallback_runtime=$runtime")
    [[ -n "$model" ]] && inst_kv+=("fallback_model=$model")
    inst_kv+=(${stage_kv[@]+"${stage_kv[@]}"})
    if [[ -n "$input_plan" ]]; then
      # Plan entry. {{INPUT_PLAN}} resolves to the operator's supplied source so
      # the emitted plan is concrete before the run id exists; the engine still
      # binds the frozen control copy published by the import step.
      inst_kv+=("provided_plan_path=$input_plan")
      if ! plan_workflow_instantiate_provided "$wf_path" "$task_text" "$plan_out" \
        ${inst_kv[@]+"${inst_kv[@]}"} >/dev/null; then
        echo "Error: workflow materialization failed" >&2
        return 1
      fi
    elif ! plan_workflow_instantiate "$wf_path" "$task_text" "$plan_out" \
      ${inst_kv[@]+"${inst_kv[@]}"} >/dev/null; then
      echo "Error: workflow materialization failed" >&2
      return 1
    fi
  fi

  if [[ "$mode" == "sequential" ]]; then
    orch_out="$tmp_dir/materialized.orch.json"
    if ! plan_pipeline_orch_json "$plan_out" >"$orch_out"; then
      echo "Error: orchestration compilation failed" >&2
      return 1
    fi
    printf '%s\n' "$orch_out"
    return 0
  fi
  printf '%s\n' "$plan_out"
}

# --- start: failure handling ------------------------------------------------

# Preserve an auditable failed run.
#
# A partial input manifest is impossible here: workflow_state_import_provided_plan
# publishes manifest.json last and cleans its own temp files, so either the
# publication completed or nothing was published. What this must not leave behind
# is a control plan, which no successful start has created at this point either.
# run.json, the immutable source copy, and a completed manifest all stay for audit.
workflow_cli_start_fail_run() {
  local state_root="$1" run_id="$2" reason="$3"
  local run_dir control
  run_dir="$(workflow_state_run_dir "$state_root" "$run_id" 2>/dev/null || true)"
  if [[ -n "$run_dir" && -d "$run_dir" ]]; then
    control="$run_dir/plans/input/control.plan.md"
    [[ -e "$control" && ! -L "$control" ]] && rm -f "$control"
  fi
  # run.json has no reason field (additionalProperties: false); the reason is
  # reported to the operator and the run is left in the failed state for audit.
  if ! workflow_state_update "$state_root" "$run_id" '.state = "failed"' >/dev/null 2>&1; then
    echo "Warning: could not mark run $run_id failed" >&2
  fi
  echo "Error: workflow start failed: $reason (run $run_id preserved as failed)" >&2
}

# --- start: engine dispatch -------------------------------------------------
# workflow_cli_start_artifact_namespace <run-dir> <input-path> <run-id>
# Print the artifact namespace for this run, or nothing when one cannot be
# derived (the caller then leaves the compiler's own rule alone).
#
# Shape: <declared-namespace-or-workflow-id>-<run-token>. The prefix keeps
# related runs grouped and readable; the token is the run id's own unique
# suffix, so two runs of the same workflow never share a directory. An already
# persisted value always wins, so a resumed run keeps the namespace it started
# with instead of recomputing a new one.
workflow_cli_start_artifact_namespace() {
  local run_dir="${1:-}" input_path="${2:-}" run_id="${3:-}"
  local existing declared prefix token

  existing="$(jq -r '.artifactNamespace // empty' "$run_dir/run.json" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
    return 0
  fi

  # A namespace declared on the workflow rides along in the materialized input.
  declared="$(awk '
    NR == 1 { if ($0 != "---") exit 0; next }
    /^---$/ { exit 0 }
    /^namespace:[[:space:]]*/ {
      sub(/^namespace:[[:space:]]*/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      print
      exit 0
    }
  ' "$input_path" 2>/dev/null || true)"

  prefix="$declared"
  if [[ -z "$prefix" ]]; then
    prefix="$(jq -r '.workflowId // empty' "$run_dir/run.json" 2>/dev/null || true)"
  fi
  [[ -n "$prefix" ]] || return 1

  # run-<timestamp>-<seq>-<token>: the trailing token is the unique part.
  token="${run_id##*-}"
  [[ -n "$token" && "$token" != "$run_id" ]] || return 1

  printf '%s-%s\n' "$prefix" "$token"
}


# Dispatch the mapped engine for this run.
#
# RALPH_WORKFLOW_START_ENGINE_STUB is a test-only seam: when set to a writable
# path, the dispatch tuple is appended there and no engine is launched. It
# exists so the entry-point Bats file can assert argv, ordering, and registry
# effects without starting graph-run, the orchestrator, or a runtime.
workflow_cli_start_dispatch_engine() {
  local mode="$1" state_root="$2" run_id="$3" workspace="$4" input_path="$5"
  local plan_input_stage="$6" max_parallel="$7"
  local run_dir graph_json

  if [[ -n "${RALPH_WORKFLOW_START_ENGINE_STUB:-}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$mode" "$run_id" "$input_path" "${plan_input_stage:--}" \
      >>"$RALPH_WORKFLOW_START_ENGINE_STUB" || return 1
    return 0
  fi

  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1

  # Give this run its own artifact namespace before anything compiles. See
  # workflow_cli_start_artifact_namespace: without it every run in a project
  # shares artifacts/input/.
  local artifact_ns
  artifact_ns="$(workflow_cli_start_artifact_namespace "$run_dir" "$input_path" "$run_id")" || artifact_ns=""
  if [[ -n "$artifact_ns" ]]; then
    export RALPH_ARTIFACT_NS_OVERRIDE="$artifact_ns"
    # Persist it: the namespace must be read back on resume, never recomputed,
    # or a resumed run would walk away from its own artifacts.
    workflow_state_update "$state_root" "$run_id" '.artifactNamespace = $ns' \
      --arg ns "$artifact_ns" >/dev/null 2>&1 || true
  fi

  if [[ "$mode" == "sequential" ]]; then
    workflow_seq_init_engine --registry-run "$run_dir" --input-file "$input_path" \
      --run-id "$run_id" >/dev/null || return 1
    return 0
  fi

  graph_json="$run_dir/engine-graph.json"
  if [[ -n "$plan_input_stage" ]]; then
    RALPH_WORKFLOW_PLAN_INPUT_STAGE="$plan_input_stage" \
      graph_compile_plan "$input_path" "$graph_json" 1 >/dev/null || return 1
  else
    graph_compile_plan "$input_path" "$graph_json" 1 >/dev/null || return 1
  fi
  workflow_dep_start_engine --state-root "$state_root" --run-id "$run_id" \
    --workspace "$workspace" --plan-path "$input_path" --graph-json "$graph_json" \
    --max-parallel "$max_parallel" >/dev/null || return 1
}

workflow_cli_cmd_start() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_start_usage
    exit 0
  fi

  workflow_cli_parse_start "$@"

  # If --task looks like a file path, redirect to --plan so the smart
  # detection (no TODOs = task text, has TODOs = leaf plan) applies.
  if [[ "$WORKFLOW_CLI_START_TASK_SET" -eq 1 ]]; then
    local _task_as_path="$WORKFLOW_CLI_START_TASK"
    case "$_task_as_path" in
      ./*|../*|/*|~/*) : ;;
      *) _task_as_path="" ;;
    esac
    if [[ -n "$_task_as_path" ]]; then
      if [[ -n "$WORKFLOW_CLI_START_PLAN" ]]; then
        echo "Error: --task <file> and --plan are mutually exclusive" >&2
        exit 2
      fi
      WORKFLOW_CLI_START_PLAN="$_task_as_path"
      WORKFLOW_CLI_START_TASK=""
      WORKFLOW_CLI_START_TASK_SET=0
    fi
  fi

  # Apply root overrides before resolver init.
  if [[ -n "$WORKFLOW_CLI_START_WORKSPACE" ]]; then
    export RALPH_PROJECT_ROOT="$WORKFLOW_CLI_START_WORKSPACE"
  fi
  if [[ -n "$WORKFLOW_CLI_START_WORKSPACE_ROOT" ]]; then
    export RALPH_PLAN_WORKSPACE_ROOT="$WORKFLOW_CLI_START_WORKSPACE_ROOT"
  fi
  if [[ -n "$WORKFLOW_CLI_START_AGENT_WORKSPACE" ]]; then
    export RALPH_AGENT_WORKSPACE="$WORKFLOW_CLI_START_AGENT_WORKSPACE"
  fi

  workflow_cli_init_roots || exit 1

  local wf_path="" wf_source_kind="" wf_mode="" classified
  if [[ -n "$WORKFLOW_CLI_START_FILE" ]]; then
    wf_path="$(workflow_cli_abs_path "$WORKFLOW_CLI_START_FILE")" || {
      echo "Error: invalid --file path: $WORKFLOW_CLI_START_FILE" >&2
      exit 1
    }
    if [[ ! -f "$wf_path" ]]; then
      echo "Error: workflow file not found: $WORKFLOW_CLI_START_FILE" >&2
      exit 1
    fi
    classified="$(workflow_cli_start_classify_file "$wf_path")" || exit 1
    wf_source_kind="${classified%% *}"
    wf_mode="${classified##* }"
  else
    workflow_cli_resolve_or_fail "$WORKFLOW_CLI_START_ID" "" 0
    wf_path="$WORKFLOW_CLI_RESOLVED_PATH"
    classified="$(workflow_cli_start_classify_file "$wf_path")" || exit 1
    wf_mode="${classified##* }"
    wf_source_kind="$WORKFLOW_CLI_RESOLVED_KIND"
    if [[ "${classified%% *}" == "legacy-orchestration" ]]; then
      wf_source_kind="legacy-orchestration"
    fi
  fi

  # shellcheck source=bash-lib/plan-todo.sh
  source "$script_dir/bash-lib/plan-todo.sh"
  # shellcheck source=bash-lib/workflow/workflow-state.sh
  source "$script_dir/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-dependency.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-dependency.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-sequential.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-sequential.sh"
  # shellcheck source=bash-lib/graph/graph-compile.sh
  source "$script_dir/bash-lib/graph/graph-compile.sh"

  # Validate the authored workflow. Legacy graph/orchestration sources are
  # already-compiled artifacts and carry no workflow frontmatter to validate.
  if [[ "$wf_source_kind" != "legacy-orchestration" ]]; then
    if ! plan_workflow_validate "$wf_path"; then
      echo "Error: invalid workflow: $wf_path" >&2
      exit 1
    fi
  fi

  local plan_input_mode
  if [[ "$wf_source_kind" == "legacy-orchestration" ]]; then
    # A legacy file has no authored workflow wrapper, so it declares no
    # planInput and cannot accept a supplied plan.
    plan_input_mode="absent"
  else
    plan_input_mode="$(workflow_cli_plan_input_mode "$wf_path")"
  fi

  local entry_kind="" task_text="" task_provenance="" input_plan_path=""
  local plan_abs="" plan_real="" plan_shape="" counts total open_n

  if [[ -n "$WORKFLOW_CLI_START_PLAN" ]]; then
    plan_abs="$(workflow_cli_abs_path "$WORKFLOW_CLI_START_PLAN")" || {
      echo "Error: invalid --plan path: $WORKFLOW_CLI_START_PLAN" >&2
      exit 1
    }
    if [[ ! -f "$plan_abs" ]]; then
      echo "Error: provided plan not found: $WORKFLOW_CLI_START_PLAN" >&2
      exit 1
    fi
    plan_real="$(workflow_cli_realpath "$plan_abs")" || {
      echo "Error: cannot resolve --plan path: $WORKFLOW_CLI_START_PLAN" >&2
      exit 1
    }
    if ! workflow_cli_plan_under_allowed_root "$plan_real" \
      "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" "${_WORKFLOW_RESOURCE_STATE_ROOT}"; then
      echo "Error: --plan must be under the project root, state root, \$HOME/.cursor/plans, or \$HOME/.claude/plans" >&2
      exit 1
    fi
    plan_shape="$(workflow_cli_plan_shape "$plan_real")"
    case "$plan_shape" in
      workflow|graph|orchestration)
        # Name the actual shape: "workflow or orchestration" was inaccurate for a
        # graph plan, and the shape is the one thing the user needs to see.
        echo "Error: --plan received an unsupported plan shape ($plan_shape), not a leaf plan; use ralph workflow start --file for workflow files" >&2
        exit 1
        ;;
      missing)
        echo "Error: provided plan not found: $WORKFLOW_CLI_START_PLAN" >&2
        exit 1
        ;;
    esac
    counts="$(workflow_cli_leaf_plan_counts "$plan_real")"
    total="${counts%% *}"
    open_n="${counts##* }"

    if [[ "${total:-0}" -eq 0 ]]; then
      # No Ralph TODOs found: treat as a free-form task description file.
      # The file content becomes the task text; no planInput is required.
      local file_content
      file_content="$(cat -- "$plan_real")"
      if [[ -z "${file_content//[[:space:]]/}" ]]; then
        echo "Error: --plan file has no content: $WORKFLOW_CLI_START_PLAN" >&2
        exit 1
      fi
      entry_kind="task"
      task_text="$file_content"
      task_provenance="task-file"
      WORKFLOW_CLI_START_TASK_FILE="$WORKFLOW_CLI_START_PLAN"
      input_plan_path=""
    else
      # Has Ralph TODOs: treat as a leaf plan. Requires planInput on the workflow.
      if [[ "$plan_input_mode" == "absent" ]]; then
        # Name the rejected flag: the user passed --plan, so say so.
        echo "Error: --plan received a file with Ralph TODOs but the workflow does not declare planInput; use --task for a task description or use a planInput workflow" >&2
        exit 1
      fi
      if [[ "${open_n:-0}" -lt 1 ]]; then
        echo "Error: provided plan has no pending TODOs" >&2
        exit 1
      fi
      entry_kind="plan"
      input_plan_path="$plan_real"
      if [[ "$WORKFLOW_CLI_START_TASK_SET" -eq 1 ]]; then
        task_text="$WORKFLOW_CLI_START_TASK"
        task_provenance="explicit"
      else
        task_text="$(workflow_cli_read_overview "$plan_real" || true)"
        if [[ -n "${task_text//[[:space:]]/}" ]]; then
          task_provenance="plan-overview"
        else
          task_text="$(basename -- "$plan_real")"
          task_text="${task_text%.md}"
          task_text="${task_text%.plan}"
          task_provenance="plan-filename"
        fi
      fi
    fi
  else
    if [[ "$plan_input_mode" == "required" ]]; then
      echo "Error: required planInput rejects task-only start; supply a file with --plan" >&2
      exit 1
    fi
    if [[ "$WORKFLOW_CLI_START_TASK_SET" -ne 1 ]]; then
      echo "Error: ralph workflow start requires --task <text> or --plan <file>" >&2
      exit 2
    fi
    entry_kind="task"
    task_text="$WORKFLOW_CLI_START_TASK"
    task_provenance="explicit"
    input_plan_path=""
  fi

  # Parser-only dry hook: resolve + materialize (task entry) and print the
  # dispatch tuple. Kept for the resolver-level argv tests; creates no run.
  if [[ "${RALPH_WORKFLOW_START_DRY:-0}" == "1" ]]; then
    if [[ "$entry_kind" == "task" && "$wf_source_kind" != "legacy-orchestration" ]]; then
      local dry_out dry_dir
      dry_dir="${_WORKFLOW_RESOURCE_STATE_ROOT}/plans"
      mkdir -p "$dry_dir"
      dry_out="$dry_dir/.workflow-start-dry-$$-$RANDOM.plan.md"
      local -a inst_kv=()
      [[ -n "$WORKFLOW_CLI_START_RUNTIME" ]] && inst_kv+=("fallback_runtime=$WORKFLOW_CLI_START_RUNTIME")
      [[ -n "$WORKFLOW_CLI_START_MODEL" ]] && inst_kv+=("fallback_model=$WORKFLOW_CLI_START_MODEL")
      if ! plan_workflow_instantiate "$wf_path" "$task_text" "$dry_out" ${inst_kv[@]+"${inst_kv[@]}"} >/dev/null; then
        rm -f "$dry_out"
        echo "Error: workflow materialization failed" >&2
        exit 1
      fi
      rm -f "$dry_out"
    fi
    printf '%s\t%s\t%s\n' "$entry_kind" "$task_provenance" "${input_plan_path:--}"
    exit 0
  fi

  # --- operator summary -----------------------------------------------------
  # The same report `inspect` prints, so plan handoffs and approval boundaries
  # are visible before anything is created.
  local summary_plan_json="null"
  if [[ "$entry_kind" == "plan" ]]; then
    summary_plan_json="$(workflow_cli_inspect_plan_preview "$input_plan_path" "$plan_input_mode")"
  fi
  if [[ "$wf_source_kind" != "legacy-orchestration" ]]; then
    local report_task_text=""
    [[ "$entry_kind" == "task" ]] && report_task_text="$task_text"
    workflow_inspect_report "$wf_path" text "$wf_source_kind" "$summary_plan_json" start "$report_task_text" "${WORKFLOW_CLI_START_ID:-}" || exit 1
  else
    printf 'Legacy %s source: %s\n' "$wf_mode" "$wf_path"
  fi
  if [[ "$entry_kind" == "plan" ]]; then
    workflow_cli_start_plan_counts_notice "$input_plan_path"
  fi

  # Resolve unpinned runtime/model before anything is created, so the operator
  # confirms a routing the engine can actually dispatch.
  workflow_cli_start_resolve_routing "$wf_path" "$wf_source_kind" \
    "$WORKFLOW_CLI_START_YES"
  if [[ -n "$WORKFLOW_CLI_START_ROUTING_SUMMARY" ]]; then
    printf '\nResolved routing\n' >&2
    printf '%s\n' "$WORKFLOW_CLI_START_ROUTING_SUMMARY" >&2
  fi

  workflow_cli_start_confirm "$WORKFLOW_CLI_START_YES"

  # --- materialize the immutable run input ----------------------------------
  local tmp_dir input_src
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-workflow-start.XXXXXX")" || exit 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" EXIT
  if ! input_src="$(workflow_cli_start_materialize_input "$wf_path" "$wf_source_kind" \
    "$wf_mode" "$task_text" "$WORKFLOW_CLI_START_RUNTIME" "$WORKFLOW_CLI_START_MODEL" \
    "$tmp_dir" "$input_plan_path" \
    ${WORKFLOW_CLI_START_STAGE_ROUTING[@]+"${WORKFLOW_CLI_START_STAGE_ROUTING[@]}"})"; then
    exit 1
  fi

  # Validate the materialized plan as a concrete (non-workflow) plan before the
  # registry entry exists. Routing errors used to surface only at engine
  # dispatch, leaving an undispatchable run preserved as failed.
  if [[ "$wf_source_kind" != "legacy-orchestration" && "$wf_mode" != "sequential" ]]; then
    local materialize_err
    if ! materialize_err="$(plan_pipeline_validate_plan "$input_src" 2>&1)"; then
      echo "Error: the materialized workflow plan is not runnable:" >&2
      printf '%s\n' "$materialize_err" >&2
      echo "No run was created." >&2
      exit 1
    fi
  fi

  # --- registry first -------------------------------------------------------
  # The outer run exists before any planner stage can generate a plan, and
  # before either engine is initialized.
  local run_id
  if ! run_id="$(workflow_state_create \
    --state-root "${_WORKFLOW_RESOURCE_STATE_ROOT}" \
    --source-path "$wf_path" \
    --source-kind "$wf_source_kind" \
    --mode "$wf_mode" \
    --entry-kind "$entry_kind" \
    --task "$task_text" \
    --task-provenance "$task_provenance" \
    ${WORKFLOW_CLI_START_TASK_FILE:+--task-file "$WORKFLOW_CLI_START_TASK_FILE"} \
    --input-file "$input_src" \
    ${WORKFLOW_CLI_START_ID:+--workflow-id "$WORKFLOW_CLI_START_ID"})"; then
    echo "Error: could not create the workflow run registry entry" >&2
    exit 1
  fi

  # --- import the supplied plan before the engine sees the run --------------
  if [[ "$entry_kind" == "plan" ]]; then
    local -a import_kv=()
    if [[ "$WORKFLOW_CLI_START_TASK_SET" -eq 1 ]]; then
      import_kv+=(--explicit-task "$WORKFLOW_CLI_START_TASK")
    fi
    if ! workflow_state_import_provided_plan \
      --state-root "${_WORKFLOW_RESOURCE_STATE_ROOT}" \
      --run-id "$run_id" \
      --plan "$input_plan_path" \
      --project-root "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" \
      ${import_kv[@]+"${import_kv[@]}"} >/dev/null; then
      workflow_cli_start_fail_run "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" \
        "provided-plan-import-failed"
      exit 1
    fi
  fi

  # --- dispatch the mapped engine ------------------------------------------
  local plan_input_stage="" run_dir engine_input
  if [[ "$entry_kind" == "plan" ]]; then
    plan_input_stage="$(awk '
      NR == 1 { if ($0 != "---") exit 0; next }
      /^---$/ { exit }
      /^planInput:[[:space:]]*$/ { in_pi = 1; next }
      in_pi && /^[^[:space:]#]/ { in_pi = 0 }
      in_pi && /^[[:space:]]+stage:[[:space:]]*/ {
        sub(/^[[:space:]]+stage:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit
      }
    ' "$wf_path")"
  fi
  run_dir="$(workflow_state_run_dir "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id")" || exit 1
  engine_input="$run_dir/$(basename -- "$(workflow_state_read_input_path \
    "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id")")"

  if ! workflow_cli_start_dispatch_engine "$wf_mode" \
    "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" \
    "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" "$engine_input" \
    "$plan_input_stage" "${WORKFLOW_CLI_START_MAX_PARALLEL:-2}"; then
    workflow_cli_start_fail_run "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" \
      "engine-dispatch-failed"
    exit 1
  fi

  # --- synchronize outer state and supervise --------------------------------
  if ! workflow_state_update "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" \
    '.state = "running"' >/dev/null 2>&1; then
    echo "Warning: could not synchronize outer run state to running" >&2
  fi

  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"
  # shellcheck source=bash-lib/workflow/workflow-start-supervise.sh
  source "$script_dir/bash-lib/workflow/workflow-start-supervise.sh"

  # Clear the temp-dir EXIT trap before supervising: the immutable input is
  # already under the registry run, and a long-running supervisor must not
  # inherit a trap that deletes an unrelated temp path on signal noise.
  trap - EXIT
  rm -rf "$tmp_dir" 2>/dev/null || true

  local start_rc=0
  workflow_cli_start_after_dispatch \
    "$wf_mode" \
    "${_WORKFLOW_RESOURCE_STATE_ROOT}" \
    "$run_id" \
    "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" \
    "$engine_input" \
    "$entry_kind" \
    "$task_text" \
    "$task_provenance" \
    "${WORKFLOW_CLI_START_ID:-}" || start_rc=$?
  exit "$start_rc"
}

workflow_cli_runs_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow runs [--all] [--state <state>] [--workflow <id>] [--limit N]
                          [--json | --tsv]

  --all           List every run (newest first)
  --state <state> Filter by outer run state
  --workflow <id> Filter by workflow id
  --limit <N>     Cap the listing (default 20 when --all is absent)
  --json          Emit a JSON array of outer run summaries
  --tsv           Emit machine-readable TSV:
                  <runId><TAB><workflowId><TAB><mode><TAB><entryKind><TAB><state><TAB><createdAt>

On a suitable TTY, runs prints an aligned ID / WORKFLOW / MODE / STATE / AGE /
TASK table. Redirected stdout and --tsv keep the stable TSV schema. --json is
unchanged. JSON and TSV never include ANSI escapes.
USAGE
}

workflow_cli_status_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow status <exact-run-id> [--json]

  --json          Emit {schemaVersion,run,stages,diagnosis,nextAction}

status is read-only: it never mutates, adopts, or recovers a run.
USAGE
}

workflow_cli_handoff_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow handoff <exact-run-id> [--json]

Prints a standalone task-salvage report containing the original task, failure,
review feedback, recorded code workspace/worktree, captured changeset, changed
files, same-run retry commands, and frozen-routing warning.

  --json          Emit the public workflow status object used by the report

handoff is read-only. From another process, run it in the same project with the
same state root. Moving a run to another checkout or machine is not implied.
USAGE
}

workflow_cli_watch_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow watch <exact-run-id> [--plain]

watch is read-only: it follows public status until the run reaches a terminal
or persisted-wait state, or until you detach. Ctrl-C exits the viewer only
(exit 130); it never cancels the workflow. q detaches without mutation.

Interactive curses is selected automatically when stdin and stdout are a
suitable TTY and accessibility/plain/CI overrides permit it; otherwise watch
streams deterministic text.

  --plain  Force deterministic line-oriented streaming output.

Exact run IDs only. Namespace, latest, node, internal paths, and engine TUI
flags are refused.
USAGE
}

workflow_cli_logs_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow logs <exact-run-id> [--stage <id>] [--attempt <n>]
                                  [--stream agent|supervisor|combined]
                                  [--tail N] [--follow] [--no-follow]

  --stage <id>    Public stage id (defaults to the current blocker/active stage)
  --attempt <n>   Attempt number (defaults to the stage ledger attempt)
  --stream        agent (default), supervisor, or combined
  --tail N        Print only the last N log lines (default 80)
  --follow        Wait for new log bytes until the stage is terminal
  --no-follow     Print the current tail and exit even when the stage is running

logs is read-only and never accepts internal namespace/node/path selectors.
USAGE
}

workflow_cli_cmd_runs() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_runs_usage
    exit 0
  fi
  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-state.sh
  source "$script_dir/bash-lib/workflow/workflow-state.sh"
  workflow_state_list "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$@"
}

workflow_cli_cmd_status() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_status_usage
    exit 0
  fi

  local run_id="" as_json=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --json) as_json=1; shift ;;
      --*)
        echo "Error: unknown option for ralph workflow status: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow status accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow status requires <exact-run-id>" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"

  local status_json
  if ! status_json="$(workflow_operator_view_load "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id")"; then
    exit 1
  fi

  if [[ "$as_json" -eq 1 ]]; then
    printf '%s\n' "$status_json"
    exit 0
  fi
  workflow_operator_view_format_text "$status_json"
  exit 0
}

workflow_cli_cmd_handoff() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_handoff_usage
    exit 0
  fi

  local run_id="" as_json=0 arg status_json
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --json) as_json=1; shift ;;
      --*)
        echo "Error: unknown option for ralph workflow handoff: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow handoff accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done
  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow handoff requires <exact-run-id>" >&2
    exit 2
  fi
  if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
    echo "Error: ralph workflow handoff requires an exact run id, not a path" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"
  status_json="$(workflow_operator_view_load "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id")" || exit 1
  if [[ "$as_json" -eq 1 ]]; then
    printf '%s\n' "$status_json"
    exit 0
  fi
  if command -v python3 >/dev/null 2>&1 \
    && [[ -f "$script_dir/python/workflow_static.py" ]] \
    && printf '%s' "$status_json" | python3 "$script_dir/python/workflow_static.py" handoff; then
    exit 0
  fi
  workflow_operator_view_format_text "$status_json"
  exit 0
}

workflow_cli_cmd_watch() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_watch_usage
    exit 0
  fi

  local run_id="" plain=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --plain)
        plain=1
        shift
        ;;
      --namespace|--node|--namespace=*|--node=*)
        echo "Error: workflow watch does not accept namespace/node selectors; use <exact-run-id> only" >&2
        echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
        exit 2
        ;;
      --tui|--no-tui|--attach|--tui=*|--no-tui=*|--attach=*)
        echo "Error: workflow watch does not accept engine TUI flags; interactive mode is selected automatically" >&2
        echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
        exit 2
        ;;
      --run|--run=*|--orchestration|--orchestration=*|--from|--from=*)
        echo "Error: workflow watch does not accept internal engine path selectors; use <exact-run-id> only" >&2
        echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
        exit 2
        ;;
      --latest|latest)
        echo "Error: workflow watch requires an exact run id (latest is refused)" >&2
        echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
        exit 2
        ;;
      --*)
        echo "Error: unknown option for ralph workflow watch: $arg" >&2
        echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow watch accepts exactly one run id" >&2
          echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow watch requires <exact-run-id>" >&2
    echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
    exit 2
  fi
  if [[ "$run_id" == "latest" || "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
    echo "Error: workflow watch requires an exact run id (latest and paths are refused)" >&2
    echo "Use: ralph workflow watch <exact-run-id> [--plain]" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"
  local watch_rc=0
  workflow_operator_watch "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" "$plain" || watch_rc=$?
  workflow_usage_print_run_report \
    "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" "${_WORKFLOW_RESOURCE_PROJECT_ROOT}" || true
  exit "$watch_rc"
}

workflow_cli_cmd_logs() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_logs_usage
    exit 0
  fi

  local run_id="" arg
  local -a log_args=()

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --stage|--attempt|--stream|--tail)
        if [[ $# -lt 2 ]]; then
          echo "Error: $arg requires a value" >&2
          exit 2
        fi
        log_args+=("$arg" "$2")
        shift 2
        ;;
      --follow|--no-follow)
        log_args+=("$arg")
        shift
        ;;
      --namespace|--node|--namespace=*|--node=*)
        echo "Error: workflow logs does not accept internal namespace/node selectors" >&2
        exit 2
        ;;
      --*)
        echo "Error: unknown option for ralph workflow logs: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow logs accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow logs requires <exact-run-id>" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"
  workflow_operator_logs "${_WORKFLOW_RESOURCE_STATE_ROOT}" "$run_id" "${log_args[@]+"${log_args[@]}"}"
  exit $?
}

workflow_cli_resume_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow resume <exact-run-id> [--yes]

  --yes           Required to confirm noninteractively (no TTY)

Resolves immutable input and the stored engine from the common registry run.
Previews the retry set, action consumption, and current plan/TODO progress,
then requires confirmation before mutating. Never accepts plan, namespace,
node, or engine-internal selectors. Refuses terminal and live-running runs;
refuses unresolved approval/input/permission (use actions list); keeps
changes-requested blocked with its exact reset action.
USAGE
}

# Format a resume plan JSON for operator preview (stderr-friendly text).
workflow_cli_resume_preview_text() {
  local plan_json="${1:-}"
  printf '%s' "$plan_json" | jq -r '
    "Operation: resume",
    "Run: \(.runId // "")",
    (if .mode then "Mode: \(.mode)" else empty end),
    "Retry set: \(.retryCount // 0)  skip: \(.skipCount // 0)  refuse: \(.refuseCount // 0)",
    "",
    "Stages:",
    (.stages // [] | map(
      "  \(.stageId)\t\(.priorState // .graphStatus // "?")\t\(.action)"
      + (if .waitingClass then " (\(.waitingClass))" else "" end)
      + (if .reasonCode then " reason=\(.reasonCode)" else "" end)
      + (if .controlPlanPath then "\n    control=\(.controlPlanPath)" else "" end)
      + (if .currentTodoId then " todo=\(.currentTodoId)" else "" end)
      + (if (.completedTodos != null and .totalTodos != null and .totalTodos > 0)
          then " progress=\(.completedTodos)/\(.totalTodos)" else "" end)
    ) | .[])
  '
}

# Interactive confirmation for resume. Noninteractive runs require --yes.
workflow_cli_resume_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: resume (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow resume requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\nResume this workflow run? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no resume was applied." >&2
      return 1
      ;;
  esac
}

# RALPH_WORKFLOW_RESUME_ENGINE_STUB: when set to a writable path, records the
# dispatch tuple and does not launch graph-run / orchestrator / runtime.
workflow_cli_resume_dispatch_engine() {
  local mode="$1" state_root="$2" run_id="$3" workspace="$4"

  if [[ -n "${RALPH_WORKFLOW_RESUME_ENGINE_STUB:-}" ]]; then
    printf '%s\t%s\t%s\n' "$mode" "$run_id" "$state_root" \
      >>"$RALPH_WORKFLOW_RESUME_ENGINE_STUB" || return 1
    return 0
  fi

  if [[ "$mode" == "sequential" ]]; then
    if [[ -n "${RALPH_WORKFLOW_RESUME_SEQUENTIAL_CONTINUE:-}" ]]; then
      # shellcheck disable=SC2086
      eval "$RALPH_WORKFLOW_RESUME_SEQUENTIAL_CONTINUE" || return 1
    fi
    return 0
  fi

  if declare -F workflow_dep_continue_after_resume >/dev/null 2>&1; then
    workflow_dep_continue_after_resume \
      --state-root "$state_root" \
      --run-id "$run_id" \
      --workspace "$workspace" || return 1
    return 0
  fi
  echo "Error: Dependency resume dispatch unavailable" >&2
  return 1
}

workflow_cli_cmd_resume() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_resume_usage
    exit 0
  fi

  local run_id="" yes_flag=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --yes|-y) yes_flag=1; shift ;;
      --plan|--namespace|--node|--plan=*|--namespace=*|--node=*|--orchestration=*|--run=*|--from=*)
        echo "Error: workflow resume does not accept plan/namespace/node selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --latest|latest)
        echo "Error: workflow resume requires an exact run id (latest is refused)" >&2
        exit 2
        ;;
      --*)
        echo "Error: unknown option for ralph workflow resume: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow resume accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow resume requires <exact-run-id>" >&2
    exit 2
  fi
  if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
    echo "Error: ralph workflow resume requires an exact run id, not a path" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  local workspace="${RALPH_AGENT_WORKSPACE:-${_WORKFLOW_RESOURCE_PROJECT_ROOT}}"

  # shellcheck source=bash-lib/workflow/workflow-state.sh
  source "$script_dir/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-dependency.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-dependency.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-sequential.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-sequential.sh"
  # shellcheck source=bash-lib/workflow/workflow-actions.sh
  source "$script_dir/bash-lib/workflow/workflow-actions.sh"

  local registry_run outer mode plan_json plan_rc=0
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"

  case "$mode" in
    sequential)
      plan_rc=0
      plan_json="$(workflow_seq_resume_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    dependency)
      plan_rc=0
      plan_json="$(workflow_dep_resume_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    *)
      echo "Error: unsupported workflow mode for resume: ${mode:-<empty>}" >&2
      exit 1
      ;;
  esac

  if [[ -n "$plan_json" ]]; then
    workflow_cli_resume_preview_text "$plan_json" >&2
    printf '\n' >&2
  fi

  if [[ "$plan_rc" -ne 0 ]]; then
    local refuse_action
    refuse_action="$(printf '%s' "$plan_json" | jq -r '
      [.stages[]? | select(.action=="refuse") | .reasonCode // empty][0] // empty
    ' 2>/dev/null || true)"
    case "$refuse_action" in
      human-approval|operator-input|operator-request)
        printf 'Next: ralph workflow actions list %s\n' "$run_id" >&2
        ;;
      human-changes-requested)
        printf 'Next: ralph workflow reset %s --stage <changesTarget>\n' "$run_id" >&2
        ;;
    esac
    exit 1
  fi

  workflow_cli_resume_confirm "$yes_flag" || exit 1

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_resume_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_resume_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
  esac
  if [[ "$plan_rc" -ne 0 ]]; then
    echo "Error: workflow resume apply failed for $run_id" >&2
    [[ -n "$plan_json" ]] && printf '%s\n' "$plan_json" >&2
    exit 1
  fi

  if ! workflow_cli_resume_dispatch_engine "$mode" "$state_root" "$run_id" "$workspace"; then
    echo "Error: workflow resume engine dispatch failed for $run_id" >&2
    workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
    exit 1
  fi

  printf 'Resumed workflow run %s\n' "$run_id"
  workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
  exit 0
}

workflow_cli_reset_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow reset <exact-run-id> [--stage <id>|--all] [--dry-run] [--yes]

  --stage <id>    Reset one executable/planner stage plus downstream closure
  --all           Reset every executable/planner stage; invalidate supervisors
  --dry-run       Preview only; never mutates files
  --yes           Required to confirm noninteractively (no TTY)

Resolves immutable input and the stored engine from the common registry run.
When --stage/--all is omitted, infers the sole human changesTarget or sole
actionable blocker; multiple candidates require an interactive TTY or --stage.
Refuses live-running, succeeded, and cancelled runs, direct supervisor
selection, and unknown flags/stages. A failed run with an actionable repair
stage (including exhausted review rework) may be reset for another manual
repair cycle. Leaves the run blocked-ready; resume is the next step.
USAGE
}

workflow_cli_reset_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: reset (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow reset requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\nReset this workflow run? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no reset was applied." >&2
      return 1
      ;;
  esac
}

workflow_cli_cmd_reset() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_reset_usage
    exit 0
  fi

  local run_id="" stage_id="" yes_flag=0 dry_run=0 reset_all=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --yes|-y) yes_flag=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --all) reset_all=1; shift ;;
      --stage)
        if [[ $# -lt 2 ]]; then
          echo "Error: --stage requires a value" >&2
          exit 2
        fi
        stage_id="$2"
        shift 2
        ;;
      --plan|--namespace|--node|--plan=*|--namespace=*|--node=*|--orchestration=*|--run=*|--from=*)
        echo "Error: workflow reset does not accept plan/namespace/node selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --latest|latest)
        echo "Error: workflow reset requires an exact run id (latest is refused)" >&2
        exit 2
        ;;
      --*)
        echo "Error: unknown option for ralph workflow reset: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow reset accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow reset requires <exact-run-id>" >&2
    exit 2
  fi
  if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
    echo "Error: ralph workflow reset requires an exact run id, not a path" >&2
    exit 2
  fi
  if [[ "$reset_all" -eq 1 && -n "$stage_id" ]]; then
    echo "Error: --stage and --all are mutually exclusive" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  local workspace="${RALPH_AGENT_WORKSPACE:-${_WORKFLOW_RESOURCE_PROJECT_ROOT}}"

  # shellcheck source=bash-lib/workflow/workflow-state.sh
  source "$script_dir/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-dependency.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-dependency.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-sequential.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-sequential.sh"
  # shellcheck source=bash-lib/workflow/workflow-actions.sh
  source "$script_dir/bash-lib/workflow/workflow-actions.sh"
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"

  local registry_run outer mode observation_json plan_json plan_rc=0
  local -a reset_args=()

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"

  if [[ "$reset_all" -eq 0 && -z "$stage_id" ]]; then
    case "$mode" in
      sequential)
        observation_json="$(workflow_seq_build_observation "$state_root" "$run_id" 2>/dev/null || true)"
        ;;
      dependency)
        observation_json="$(workflow_dep_build_observation "$state_root" "$run_id" 2>/dev/null || true)"
        ;;
      *)
        echo "Error: unsupported workflow mode for reset: ${mode:-<empty>}" >&2
        exit 1
        ;;
    esac
    if [[ -z "$observation_json" ]]; then
      echo "Error: could not build workflow observation for reset inference" >&2
      exit 1
    fi
    if ! stage_id="$(workflow_reset_infer_stage_id "$registry_run" "$observation_json" --interactive)"; then
      exit 1
    fi
  fi

  reset_args=(--state-root "$state_root" --run-id "$run_id" --workspace "$workspace")
  if [[ "$reset_all" -eq 1 ]]; then
    reset_args+=(--all)
  else
    reset_args+=(--stage "$stage_id")
  fi

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_reset_by_run_id "${reset_args[@]}" --dry-run)" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_reset_by_run_id "${reset_args[@]}" --dry-run)" || plan_rc=$?
      ;;
    *)
      echo "Error: unsupported workflow mode for reset: ${mode:-<empty>}" >&2
      exit 1
      ;;
  esac

  if [[ -n "$plan_json" ]]; then
    if declare -F workflow_reset_preview_text >/dev/null 2>&1; then
      workflow_reset_preview_text "$plan_json" >&2
    else
      workflow_cli_resume_preview_text "$plan_json" >&2
    fi
    printf '\n' >&2
  fi

  if [[ "$plan_rc" -ne 0 ]]; then
    exit 1
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    printf 'Dry run complete; no files were changed.\n'
    exit 0
  fi

  workflow_cli_reset_confirm "$yes_flag" || exit 1

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_reset_by_run_id "${reset_args[@]}")" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_reset_by_run_id "${reset_args[@]}")" || plan_rc=$?
      ;;
  esac
  if [[ "$plan_rc" -ne 0 ]]; then
    echo "Error: workflow reset apply failed for $run_id" >&2
    [[ -n "$plan_json" ]] && printf '%s\n' "$plan_json" >&2
    exit 1
  fi

  printf 'Reset workflow run %s\n' "$run_id"
  printf 'Next: ralph workflow resume %s\n' "$run_id"
  exit 0
}

workflow_cli_recover_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow recover <exact-run-id> [--yes]

  --yes           Required to confirm noninteractively (no TTY)

Applies only to a proven stale/orphaned supervisor. Resolves immutable input
and the stored engine from the common registry. Shows diagnosis/action state
and the exact transition preview, then requires confirmation. Never accepts
latest, paths, namespaces, node selectors, or engine-specific flags. Never
manufactures or consumes a human decision. Ends blocked-ready or waiting on
persisted actions. Preserves definitions, immutable input, logs, attempts,
artifacts, requests/decisions, and audit history.
USAGE
}

workflow_cli_cancel_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow cancel <exact-run-id> [--yes]

  --yes           Required to confirm noninteractively (no TTY)

Signals only a proven owned live supervisor, or cancels a non-running
cancellable run. Writes cancel intent, cancels outstanding common actions
without deleting them, and ends cancelled. Never accepts latest, paths,
namespaces, node selectors, or engine-specific flags. Preserves definitions,
immutable input, logs, attempts, artifacts, requests/decisions, and audit
history.
USAGE
}

workflow_cli_recover_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: recover (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow recover requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\nRecover this workflow run? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no recover was applied." >&2
      return 1
      ;;
  esac
}

workflow_cli_cancel_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: cancel (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow cancel requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\nCancel this workflow run? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no cancel was applied." >&2
      return 1
      ;;
  esac
}

# Print Next: line from recover/cancel result JSON when nextAction.argv is set.
workflow_cli_print_next_action() {
  local result_json="${1:-}"
  local next=""
  next="$(printf '%s' "$result_json" | jq -r '
    if .nextAction == null then empty
    elif (.nextAction.argv | type) == "array" and ((.nextAction.argv | length) > 0)
      then (.nextAction.argv | join(" "))
    else empty end
  ' 2>/dev/null || true)"
  if [[ -n "$next" ]]; then
    printf 'Next: %s\n' "$next"
  fi
}

# Shared exact-run-id argv parse for recover/cancel. Sets globals:
# WORKFLOW_CLI_LIFECYCLE_RUN_ID WORKFLOW_CLI_LIFECYCLE_YES
# Verb name is $1; remaining args follow. Exit 2 on parse errors.
workflow_cli_parse_exact_run_id_yes() {
  local verb="$1"
  shift
  local run_id="" yes_flag=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --yes|-y) yes_flag=1; shift ;;
      --plan|--namespace|--node|--stage|--all|--dry-run|--orchestration|--run|--from|--max-parallel|--attempt|--stream|--follow|--tui|--attach|--compile|--preflight|--render|--successor|--publish|--single-stage)
        echo "Error: workflow ${verb} does not accept plan/namespace/node selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --plan=*|--namespace=*|--node=*|--stage=*|--orchestration=*|--run=*|--from=*|--max-parallel=*|--attempt=*|--stream=*|--single-stage=*)
        echo "Error: workflow ${verb} does not accept plan/namespace/node selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --latest|latest)
        echo "Error: workflow ${verb} requires an exact run id (latest is refused)" >&2
        exit 2
        ;;
      --*)
        echo "Error: unknown option for ralph workflow ${verb}: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow ${verb} accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow ${verb} requires <exact-run-id>" >&2
    exit 2
  fi
  if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." ]]; then
    echo "Error: ralph workflow ${verb} requires an exact run id, not a path" >&2
    exit 2
  fi

  WORKFLOW_CLI_LIFECYCLE_RUN_ID="$run_id"
  WORKFLOW_CLI_LIFECYCLE_YES="$yes_flag"
}

# Source libs shared by recover/cancel.
workflow_cli_source_lifecycle_libs() {
  # shellcheck source=bash-lib/workflow/workflow-state.sh
  source "$script_dir/bash-lib/workflow/workflow-state.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-dependency.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-dependency.sh"
  # shellcheck source=bash-lib/workflow/workflow-engine-sequential.sh
  source "$script_dir/bash-lib/workflow/workflow-engine-sequential.sh"
  # shellcheck source=bash-lib/workflow/workflow-actions.sh
  source "$script_dir/bash-lib/workflow/workflow-actions.sh"
  # shellcheck source=bash-lib/workflow/workflow-diagnose.sh
  source "$script_dir/bash-lib/workflow/workflow-diagnose.sh"
  # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
  source "$script_dir/bash-lib/workflow/workflow-operator-view.sh"
}

workflow_cli_cmd_recover() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_recover_usage
    exit 0
  fi

  workflow_cli_parse_exact_run_id_yes recover "$@"
  local run_id="$WORKFLOW_CLI_LIFECYCLE_RUN_ID"
  local yes_flag="$WORKFLOW_CLI_LIFECYCLE_YES"

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  local workspace="${RALPH_AGENT_WORKSPACE:-${_WORKFLOW_RESOURCE_PROJECT_ROOT}}"

  workflow_cli_source_lifecycle_libs

  local registry_run outer mode plan_json plan_rc=0 status_json=""
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"

  # Status/diagnosis is optional enrichment; recover plan JSON already carries
  # outstanding action + nextAction. Skip when RALPH_WORKFLOW_SKIP_STATUS_PREVIEW=1.
  if [[ "${RALPH_WORKFLOW_SKIP_STATUS_PREVIEW:-0}" != "1" ]] \
    && declare -F workflow_operator_view_load >/dev/null 2>&1; then
    status_json="$(workflow_operator_view_load "$state_root" "$run_id" 2>/dev/null || true)"
  fi

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_recover_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_recover_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    *)
      echo "Error: unsupported workflow mode for recover: ${mode:-<empty>}" >&2
      exit 1
      ;;
  esac

  if [[ -n "$plan_json" ]]; then
    if declare -F workflow_recover_preview_text >/dev/null 2>&1; then
      workflow_recover_preview_text "$plan_json" "$status_json" >&2
    else
      printf '%s\n' "$plan_json" >&2
    fi
    printf '\n' >&2
  fi

  if [[ "$plan_rc" -ne 0 ]]; then
    exit 1
  fi

  workflow_cli_recover_confirm "$yes_flag" || exit 1

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_recover_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_recover_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
  esac
  if [[ "$plan_rc" -ne 0 ]]; then
    echo "Error: workflow recover apply failed for $run_id" >&2
    [[ -n "$plan_json" ]] && printf '%s\n' "$plan_json" >&2
    exit 1
  fi

  local outcome
  outcome="$(printf '%s' "$plan_json" | jq -r '.outcome // empty')"
  case "$outcome" in
    unchanged-intentional-wait)
      printf 'Recovered workflow run %s (unchanged; intentional action wait)\n' "$run_id"
      ;;
    *)
      printf 'Recovered workflow run %s\n' "$run_id"
      ;;
  esac
  workflow_cli_print_next_action "$plan_json"
  exit 0
}

workflow_cli_cmd_cancel() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    workflow_cli_cancel_usage
    exit 0
  fi

  workflow_cli_parse_exact_run_id_yes cancel "$@"
  local run_id="$WORKFLOW_CLI_LIFECYCLE_RUN_ID"
  local yes_flag="$WORKFLOW_CLI_LIFECYCLE_YES"

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  local workspace="${RALPH_AGENT_WORKSPACE:-${_WORKFLOW_RESOURCE_PROJECT_ROOT}}"

  workflow_cli_source_lifecycle_libs

  local registry_run outer mode plan_json plan_rc=0 status_json=""
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"

  if [[ "${RALPH_WORKFLOW_SKIP_STATUS_PREVIEW:-0}" != "1" ]] \
    && declare -F workflow_operator_view_load >/dev/null 2>&1; then
    status_json="$(workflow_operator_view_load "$state_root" "$run_id" 2>/dev/null || true)"
  fi

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_cancel_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_cancel_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace" --dry-run)" || plan_rc=$?
      ;;
    *)
      echo "Error: unsupported workflow mode for cancel: ${mode:-<empty>}" >&2
      exit 1
      ;;
  esac

  if [[ -n "$plan_json" ]]; then
    if declare -F workflow_cancel_preview_text >/dev/null 2>&1; then
      workflow_cancel_preview_text "$plan_json" "$status_json" >&2
    else
      printf '%s\n' "$plan_json" >&2
    fi
    printf '\n' >&2
  fi

  if [[ "$plan_rc" -ne 0 ]]; then
    exit 1
  fi

  workflow_cli_cancel_confirm "$yes_flag" || exit 1

  plan_rc=0
  case "$mode" in
    sequential)
      plan_json="$(workflow_seq_cancel_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
    dependency)
      plan_json="$(workflow_dep_cancel_by_run_id --state-root "$state_root" --run-id "$run_id" \
        --workspace "$workspace")" || plan_rc=$?
      ;;
  esac
  if [[ "$plan_rc" -ne 0 ]]; then
    echo "Error: workflow cancel apply failed for $run_id" >&2
    [[ -n "$plan_json" ]] && printf '%s\n' "$plan_json" >&2
    exit 1
  fi

  printf 'Cancelled workflow run %s\n' "$run_id"
  workflow_cli_print_next_action "$plan_json"
  workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
  exit 0
}

# --- actions -----------------------------------------------------------------

workflow_cli_actions_usage() {
  cat >&2 <<'USAGE'
Usage: ralph workflow actions list <exact-run-id> [--json]
       ralph workflow actions respond <exact-run-id> <request-id>
           --decision <choice> [--message <text>] [--yes]
       ralph workflow actions request --question <text> [--details <text>]
       ralph workflow actions approvals list [--workspace <path>] [--json]
       ralph workflow actions approvals revoke --runtime <runtime>
           --action <name> --resource <path> --effect <effect> [--yes]

  list       Normalized request-kind-aware JSON array for one exact common run ID.
             Dependency merges common approval/input with adapted permission
             records and never exposes namespace. Sequential lists common records.
  respond    Persist one decision for an exact run/request ID. Decision enums:
             permission: allow-once|allow-run|allow-always|deny
             approval:   approve|request-changes|cancel
             input:      answer|cancel
             answer and request-changes require --message. Requires confirmation
             (--yes noninteractive). Prints resume, reset --stage <changesTarget>,
             or terminal cancellation as the next action.
  request    Stage-only OPERATOR_INPUT. Accepted only with supervisor-issued
             run/stage/attempt identity and an active attempt-bound capability
             nonce. Never prints or persists the nonce. At most one outstanding
             input per attempt. Refuses credential-looking text and
             standalone/spoofed/stale/cross-run calls.
  approvals  Project permission policy list/revoke (mode-independent).

Exact run IDs only. Public help never advertises namespace or latest selectors.
Publication remains automatic (no publish verb).
USAGE
}

workflow_cli_actions_confirm() {
  local yes="$1" label="${2:-Respond to this workflow action}"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: actions (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow actions respond requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\n%s? [y/N] ' "$label" >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no decision was written." >&2
      return 1
      ;;
  esac
}

workflow_cli_actions_approvals_confirm() {
  local yes="$1"
  local reply=""
  if [[ "$yes" == "1" ]]; then
    printf 'Operation: approvals revoke (confirmed-noninteractive)\n' >&2
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: ralph workflow actions approvals revoke requires --yes to confirm noninteractively" >&2
    return 1
  fi
  printf '\nRevoke this project approval rule? [y/N] ' >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)
      echo "Aborted; no approval was revoked." >&2
      return 1
      ;;
  esac
}

workflow_cli_cmd_actions_list() {
  local run_id="" json=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --json) json=1; shift ;;
      --namespace|--node|--namespace=*|--node=*|--run|--run=*|--latest|latest)
        echo "Error: workflow actions list does not accept namespace/latest selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --publish|publish)
        echo "Error: workflow actions has no publish verb; publication is automatic" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_actions_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow actions list: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          echo "Error: ralph workflow actions list accepts exactly one run id" >&2
          exit 2
        fi
        run_id="$arg"
        shift
        ;;
    esac
  done
  if [[ -z "$run_id" ]]; then
    echo "Error: ralph workflow actions list requires <exact-run-id>" >&2
    exit 2
  fi
  if [[ "$run_id" == *"/"* || "$run_id" == "." || "$run_id" == ".." || "$run_id" == "latest" ]]; then
    echo "Error: workflow actions list requires an exact common run ID (latest is refused)" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  workflow_cli_source_lifecycle_libs

  local registry_run outer mode namespace="" graph_run_dir="" rows count
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"
  if [[ "$mode" == "dependency" ]]; then
    namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
    if [[ -n "$namespace" ]] && declare -F workflow_dep_engine_state_path >/dev/null 2>&1; then
      graph_run_dir="$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
    fi
  fi

  rows="$(workflow_action_list_public "$registry_run" "$run_id" "$mode" "$graph_run_dir")" || exit 1

  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$rows"
    exit 0
  fi

  printf '# workflow actions  run=%s  mode=%s\n' "$run_id" "$mode"
  count="$(printf '%s' "$rows" | jq 'length')"
  if [[ "$count" -eq 0 ]]; then
    printf 'no action requests\n'
    exit 0
  fi
  printf '%s' "$rows" | jq -r '.[] |
    "\(.requestId)  kind=\(.kind)  stage=\(.stageId)  status=\(.status)  choices=\((.choices // []) | join(","))"'
  exit 0
}

workflow_cli_cmd_actions_respond() {
  local run_id="" request_id="" decision="" message="" yes_flag=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --decision) decision="${2:-}"; shift 2 ;;
      --decision=*) decision="${arg#--decision=}"; shift ;;
      --message) message="${2:-}"; shift 2 ;;
      --message=*) message="${arg#--message=}"; shift ;;
      --yes|-y) yes_flag=1; shift ;;
      --namespace|--node|--namespace=*|--node=*|--run|--run=*|--latest|latest)
        echo "Error: workflow actions respond does not accept namespace/latest selectors; use <exact-run-id> only" >&2
        exit 2
        ;;
      --publish|publish)
        echo "Error: workflow actions has no publish verb; publication is automatic" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_actions_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow actions respond: $arg" >&2
        exit 2
        ;;
      *)
        if [[ -z "$run_id" ]]; then
          run_id="$arg"
        elif [[ -z "$request_id" ]]; then
          request_id="$arg"
        else
          echo "Error: unexpected argument: $arg" >&2
          exit 2
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$run_id" || -z "$request_id" ]]; then
    echo "Error: ralph workflow actions respond requires <exact-run-id> <request-id> --decision <choice>" >&2
    exit 2
  fi
  if [[ "$run_id" == "latest" || "$run_id" == *"/"* ]]; then
    echo "Error: workflow actions respond requires an exact common run ID (latest is refused)" >&2
    exit 2
  fi
  if [[ -z "$decision" ]]; then
    echo "Error: ralph workflow actions respond requires --decision <choice>" >&2
    exit 2
  fi

  workflow_cli_init_roots || exit 1
  local state_root="${_WORKFLOW_RESOURCE_STATE_ROOT}"
  workflow_cli_source_lifecycle_libs
  # shellcheck source=bash-lib/graph/graph-approval-policy.sh
  source "$script_dir/bash-lib/graph/graph-approval-policy.sh"

  local registry_run outer mode namespace="" graph_run_dir="" req kind preview
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || exit 1
  if [[ ! -f "$registry_run/run.json" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    exit 1
  fi
  outer="$(workflow_state_read "$state_root" "$run_id")" || exit 1
  mode="$(printf '%s' "$outer" | jq -r '.mode // empty')"
  if [[ "$mode" == "dependency" ]]; then
    namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
    if [[ -n "$namespace" ]] && declare -F workflow_dep_engine_state_path >/dev/null 2>&1; then
      graph_run_dir="$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
    fi
  fi

  if req="$(workflow_action_request_read "$registry_run" "$request_id" 2>/dev/null)"; then
    kind="$(printf '%s' "$req" | jq -r '.kind // empty')"
  elif [[ -n "$graph_run_dir" ]] && req="$(graph_operator_request_read "$graph_run_dir" "$request_id" 2>/dev/null)"; then
    kind="permission"
  else
    echo "Error: workflow action request not found for common run ID $run_id: $request_id" >&2
    exit 1
  fi

  if ! graph_operator_token_in_list "$decision" "$(workflow_action_choices_for_kind "$kind")"; then
    echo "Error: decision enum for kind ${kind} does not include: $decision" >&2
    exit 1
  fi
  if workflow_action_decision_requires_message "$kind" "$decision"; then
    if [[ -z "$message" ]]; then
      echo "Error: message required for ${kind} decision ${decision}" >&2
      exit 1
    fi
  fi

  printf 'Respond preview:\n' >&2
  printf '  run=%s  request=%s  kind=%s  decision=%s\n' "$run_id" "$request_id" "$kind" "$decision" >&2
  if [[ -n "$message" ]]; then
    printf '  message=%s\n' "$(workflow_action_redact_for_display "$message")" >&2
  fi
  printf '\n' >&2

  workflow_cli_actions_confirm "$yes_flag" "Persist decision ${decision} for ${request_id}" || exit 1

  local outcome
  local -a respond_args=(
    --registry-run "$registry_run"
    --run-id "$run_id"
    --request-id "$request_id"
    --decision "$decision"
    --message "$message"
    --mode "$mode"
    --state-root "$state_root"
  )
  if [[ -n "$graph_run_dir" ]]; then
    respond_args+=(--graph-run-dir "$graph_run_dir")
  fi
  outcome="$(workflow_action_respond_persist "${respond_args[@]}")" || exit 1

  printf '# workflow actions respond  run=%s  request=%s  decision=%s\n' \
    "$run_id" "$request_id" "$decision"
  workflow_action_respond_next_action "$kind" "$decision" "$run_id" \
    "$(printf '%s' "$outcome" | jq -r '.changesTarget // empty')"
  exit 0
}

workflow_cli_cmd_actions_request() {
  local question="" details="" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --question) question="${2:-}"; shift 2 ;;
      --question=*) question="${arg#--question=}"; shift ;;
      --details) details="${2:-}"; shift 2 ;;
      --details=*) details="${arg#--details=}"; shift ;;
      --namespace|--node|--namespace=*|--node=*|--run|--run=*|--latest|latest)
        echo "Error: workflow actions request does not accept namespace/latest selectors" >&2
        exit 2
        ;;
      --publish|publish)
        echo "Error: workflow actions has no publish verb; publication is automatic" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_actions_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow actions request: $arg" >&2
        exit 2
        ;;
      *)
        echo "Error: unexpected argument: $arg" >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$question" ]]; then
    echo "Error: ralph workflow actions request requires --question <text>" >&2
    exit 2
  fi

  local run_id="${RALPH_WORKFLOW_RUN_ID:-}"
  local stage_id="${RALPH_WORKFLOW_STAGE_ID:-}"
  local attempt_id="${RALPH_WORKFLOW_STAGE_ATTEMPT:-}"
  local registry_run="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
  local nonce="${RALPH_WORKFLOW_ACTION_NONCE:-}"
  local capability_path="${RALPH_WORKFLOW_ACTION_CAPABILITY:-}"

  if [[ -z "$run_id" || -z "$stage_id" || -z "$attempt_id" || -z "$registry_run" ]]; then
    echo "Error: workflow actions request refuses standalone or spoofed calls; supervisor-issued run/stage/attempt identity is required" >&2
    exit 1
  fi
  if [[ ! -d "$registry_run" ]]; then
    echo "Error: workflow actions request registry run is missing or invalid" >&2
    exit 1
  fi
  if [[ -z "$nonce" && -n "$capability_path" && -f "$capability_path" && ! -L "$capability_path" ]]; then
    nonce="$(jq -r '.nonce // empty' "$capability_path" 2>/dev/null || true)"
  fi
  if [[ -z "$nonce" ]]; then
    echo "Error: workflow actions request requires an active attempt-bound capability nonce" >&2
    exit 1
  fi

  # Cross-run spoof: capability/env identity must match registry run.json.
  local outer_run
  outer_run="$(jq -r '.runId // empty' "$registry_run/run.json" 2>/dev/null || true)"
  if [[ -z "$outer_run" || "$outer_run" != "$run_id" ]]; then
    echo "Error: workflow actions request refuses cross-run or spoofed identity" >&2
    exit 1
  fi

  workflow_cli_init_roots || exit 1
  # shellcheck source=bash-lib/workflow/workflow-actions.sh
  source "$script_dir/bash-lib/workflow/workflow-actions.sh"

  local request_id
  request_id="$(workflow_action_stage_request_create \
    --registry-run "$registry_run" \
    --run-id "$run_id" \
    --stage-id "$stage_id" \
    --attempt-id "$attempt_id" \
    --nonce "$nonce" \
    --question "$question" \
    --details "$details")" || exit 1

  # Never print the nonce. Confirm it is absent from stdout path.
  printf 'Created input request %s for stage %s attempt %s\n' \
    "$request_id" "$stage_id" "$attempt_id"
  exit 0
}

workflow_cli_cmd_actions_approvals_list() {
  local workspace="" json=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --workspace) workspace="${2:-}"; shift 2 ;;
      --workspace=*) workspace="${arg#--workspace=}"; shift ;;
      --json) json=1; shift ;;
      --namespace|--latest|latest|--publish|publish)
        echo "Error: workflow actions approvals list does not accept namespace/latest/publish selectors" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_actions_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow actions approvals list: $arg" >&2
        exit 2
        ;;
      *)
        echo "Error: unexpected argument: $arg" >&2
        exit 2
        ;;
    esac
  done

  workflow_cli_init_roots || exit 1
  if [[ -z "$workspace" ]]; then
    workspace="${_WORKFLOW_RESOURCE_PROJECT_ROOT}"
  fi
  # Project approvals remain mode-independent and permission-only; reuse the
  # graph approvals CLI without exposing graph namespace/latest selectors.
  if [[ "$json" -eq 1 ]]; then
    bash "$script_dir/graph-run.sh" actions approvals list --workspace "$workspace" --json
  else
    bash "$script_dir/graph-run.sh" actions approvals list --workspace "$workspace"
  fi
  exit $?
}

workflow_cli_cmd_actions_approvals_revoke() {
  local workspace="" runtime="" action="" resource="" effect="" yes_flag=0 json=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --workspace) workspace="${2:-}"; shift 2 ;;
      --workspace=*) workspace="${arg#--workspace=}"; shift ;;
      --runtime) runtime="${2:-}"; shift 2 ;;
      --runtime=*) runtime="${arg#--runtime=}"; shift ;;
      --action) action="${2:-}"; shift 2 ;;
      --action=*) action="${arg#--action=}"; shift ;;
      --resource) resource="${2:-}"; shift 2 ;;
      --resource=*) resource="${arg#--resource=}"; shift ;;
      --effect) effect="${2:-}"; shift 2 ;;
      --effect=*) effect="${arg#--effect=}"; shift ;;
      --yes|-y) yes_flag=1; shift ;;
      --json) json=1; shift ;;
      --namespace|--latest|latest|--publish|publish)
        echo "Error: workflow actions approvals revoke does not accept namespace/latest/publish selectors" >&2
        exit 2
        ;;
      -h|--help)
        workflow_cli_actions_usage
        exit 0
        ;;
      --*)
        echo "Error: unknown option for ralph workflow actions approvals revoke: $arg" >&2
        exit 2
        ;;
      *)
        echo "Error: unexpected argument: $arg" >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$runtime" || -z "$action" || -z "$resource" || -z "$effect" ]]; then
    echo "Error: ralph workflow actions approvals revoke requires --runtime --action --resource --effect" >&2
    exit 2
  fi

  workflow_cli_actions_approvals_confirm "$yes_flag" || exit 1

  workflow_cli_init_roots || exit 1
  if [[ -z "$workspace" ]]; then
    workspace="${_WORKFLOW_RESOURCE_PROJECT_ROOT}"
  fi
  local -a args=(actions approvals revoke --workspace "$workspace" --runtime "$runtime" --action "$action" --resource "$resource" --effect "$effect")
  [[ "$json" -eq 1 ]] && args+=(--json)
  bash "$script_dir/graph-run.sh" "${args[@]}"
  exit $?
}

workflow_cli_cmd_actions_approvals() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list) workflow_cli_cmd_actions_approvals_list "$@" ;;
    revoke) workflow_cli_cmd_actions_approvals_revoke "$@" ;;
    -h|--help|'')
      workflow_cli_actions_usage
      [[ -n "$sub" && "$sub" != "" ]] && exit 0 || exit 2
      ;;
    *)
      echo "Error: unknown workflow actions approvals verb: ${sub}" >&2
      workflow_cli_actions_usage
      exit 2
      ;;
  esac
}

workflow_cli_cmd_actions() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list) workflow_cli_cmd_actions_list "$@" ;;
    respond) workflow_cli_cmd_actions_respond "$@" ;;
    request) workflow_cli_cmd_actions_request "$@" ;;
    approvals) workflow_cli_cmd_actions_approvals "$@" ;;
    -h|--help|'')
      workflow_cli_actions_usage
      [[ -n "$sub" ]] && exit 0 || exit 2
      ;;
    *)
      echo "Error: unknown workflow actions verb: ${sub:-<empty>}" >&2
      workflow_cli_actions_usage
      exit 2
      ;;
  esac
}

case "${1:-}" in
  list) shift; workflow_cli_cmd_list "$@";;
  show) shift; workflow_cli_cmd_show "$@";;
  path) shift; workflow_cli_cmd_path "$@";;
  edit) shift; workflow_cli_cmd_edit "$@";;
  inspect) shift; workflow_cli_cmd_inspect "$@";;
  start) shift; workflow_cli_cmd_start "$@";;
  runs) shift; workflow_cli_cmd_runs "$@";;
  status) shift; workflow_cli_cmd_status "$@";;
  watch) shift; workflow_cli_cmd_watch "$@";;
  logs) shift; workflow_cli_cmd_logs "$@";;
  handoff) shift; workflow_cli_cmd_handoff "$@";;
  resume) shift; workflow_cli_cmd_resume "$@";;
  reset) shift; workflow_cli_cmd_reset "$@";;
  recover) shift; workflow_cli_cmd_recover "$@";;
  cancel) shift; workflow_cli_cmd_cancel "$@";;
  actions) shift; workflow_cli_cmd_actions "$@";;
  list-plans) shift; list_plans "$@";;
  create)
    printf "Error: 'ralph workflow %s' was removed. Use: ralph create workflow\n" "create" >&2
    exit 2
    ;;
  -h|--help) workflow_cli_usage; exit 0;;
  *)
    echo "Error: unknown workflow-cli command: ${1:-<empty>}" >&2
    workflow_cli_usage
    exit 2
    ;;
esac
