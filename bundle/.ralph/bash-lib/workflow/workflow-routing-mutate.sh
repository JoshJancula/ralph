#!/usr/bin/env bash
# Noninteractive scoped workflow routing mutation: byte-preserving persist, full
# workflow validation, optional sha256 optimistic concurrency, same-directory
# atomic publication.

if [[ -n "${RALPH_WORKFLOW_ROUTING_MUTATE_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_ROUTING_MUTATE_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_workflow_routing_mutate_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workflow_routing_mutate_persist="$_workflow_routing_mutate_lib_dir/../../python/workflow-routing-persist.py"

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_workflow_routing_mutate_lib_dir/../runtime-normalize.sh"
fi

_workflow_routing_mutate_supervisor_types() {
  printf '%s\n' supervisor approval integrate join gate checkpoint router
}

_workflow_routing_mutate_ordinary_stage_types() {
  printf '%s\n' '' agent voter consensus-voter
}

_workflow_routing_mutate_stage_type() {
  local wf_path="$1" scope="$2" stage_id="$3"
  local json
  json="$(workflow_inspect_report "$wf_path" json "$scope" 2>/dev/null)" || return 1
  printf '%s' "$json" | jq -r --arg id "$stage_id" '
    .stages[] | select(.id == $id) | .type // "agent"
  ' 2>/dev/null
}

_workflow_routing_mutate_stage_is_mutable() {
  local wf_path="$1" scope="$2" stage_id="$3"
  local st
  st="$(_workflow_routing_mutate_stage_type "$wf_path" "$scope" "$stage_id")" || return 1
  case "$st" in
    ""|agent|voter|consensus-voter) return 0 ;;
    *)
      echo "Error: stage '$stage_id' (type: $st) does not accept runtime or model routing" >&2
      return 1
      ;;
  esac
}

_workflow_routing_mutate_normalize_runtime() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    echo "Error: runtime value is required" >&2
    return 1
  fi
  local normalized
  normalized="$(ralph_normalize_runtime_name "$raw")"
  if ! ralph_runtime_is_supported "$normalized"; then
    echo "Error: unsupported runtime: $raw" >&2
    return 1
  fi
  printf '%s\n' "$normalized"
}

_workflow_routing_mutate_file_sha256() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
  else
    echo "Error: sha256 tool unavailable" >&2
    return 1
  fi
}

_workflow_routing_mutate_read_default_runtime() {
  local wf_path="$1" scope="$2"
  workflow_inspect_report "$wf_path" json "$scope" 2>/dev/null \
    | jq -r '.routing.workflowRuntime // ""' 2>/dev/null
}

_workflow_routing_mutate_read_stage_runtime() {
  local wf_path="$1" scope="$2" stage_id="$3"
  workflow_inspect_report "$wf_path" json "$scope" 2>/dev/null \
    | jq -r --arg id "$stage_id" '.stages[] | select(.id == $id) | .runtime // ""' 2>/dev/null
}

# Apply one persist mode by chaining through a temp file.
_workflow_routing_mutate_run_persist() {
  local src="$1" dst="$2" mode="$3"
  shift 3
  if ! python3 "$_workflow_routing_mutate_persist" "$src" "$dst" "$mode" "$@" 2>&1; then
    return 1
  fi
  return 0
}

# workflow_routing_mutate_apply <target-path> <scope> [expected-sha256] <seed-path> <op> ...
#
# Each op:
#   defaults:<runtime>[:<model>]
#   clear-defaults | clear-default-model | clear-default-runtime
#   stage:<id>=<runtime>[,<model>]
#   clear-stage:<id> | clear-stage-model:<id>
#
# Prints new sha256 on success. Exit 0 ok, 1 validation/refusal, 2 usage.
workflow_routing_mutate_apply() {
  local target_path="${1:-}"
  local scope="${2:-}"
  local expected_sha="${3:-}"
  local seed_path="${4:-}"
  shift 4 2>/dev/null || shift $#

  if [[ -z "$target_path" || -z "$scope" || -z "$seed_path" ]]; then
    echo "Error: workflow_routing_mutate_apply requires target path, scope, sha256 (or -), and seed path" >&2
    return 2
  fi
  if [[ "$expected_sha" == "-" ]]; then
    expected_sha=""
  fi

  case "$scope" in
    project|global) ;;
    bundled)
      echo "Error: bundled workflow sources are immutable" >&2
      return 1
      ;;
    *)
      echo "Error: invalid workflow scope for routing mutation: $scope" >&2
      return 2
      ;;
  esac

  if [[ ! -f "$seed_path" ]]; then
    echo "Error: workflow seed not found: $seed_path" >&2
    return 1
  fi

  local seed_scope="$scope"
  if declare -F workflow_resource_source_kind >/dev/null 2>&1; then
    seed_scope="$(workflow_resource_source_kind "$seed_path" 2>/dev/null || printf '%s' "$scope")"
  fi

  local target_dir pre_sha=""
  target_dir="$(dirname -- "$target_path")"
  mkdir -p -- "$target_dir" || {
    echo "Error: cannot create workflow directory: $target_dir" >&2
    return 1
  }

  if [[ -f "$target_path" ]]; then
    pre_sha="$(_workflow_routing_mutate_file_sha256 "$target_path")" || return 1
    if [[ -n "$expected_sha" && "$pre_sha" != "$expected_sha" ]]; then
      echo "Error: workflow content changed since load (sha256 conflict)" >&2
      return 1
    fi
  elif [[ -n "$expected_sha" ]]; then
    echo "Error: workflow content changed since load (target missing)" >&2
    return 1
  fi

  if [[ ${#@} -eq 0 ]]; then
    echo "Error: at least one routing mutation operation is required" >&2
    return 2
  fi

  local -a persist_queue=()
  local op spec stage_id runtime model rt
  local pending_default_runtime="" pending_default_model=""
  local set_default_runtime=0 set_default_model=0 clear_default_block=0
  local clear_default_model=0 clear_default_runtime=0

  for op in "$@"; do
    case "$op" in
      clear-defaults)
        clear_default_block=1
        ;;
      clear-default-model)
        clear_default_model=1
        ;;
      clear-default-runtime)
        clear_default_runtime=1
        ;;
      defaults:*)
        spec="${op#defaults:}"
        runtime="${spec%%:*}"
        model=""
        if [[ "$spec" == *:* ]]; then
          model="${spec#*:}"
        fi
        runtime="$(_workflow_routing_mutate_normalize_runtime "$runtime")" || return 1
        pending_default_runtime="$runtime"
        pending_default_model="$model"
        set_default_runtime=1
        if [[ -n "$model" ]]; then
          set_default_model=1
        fi
        persist_queue+=("defaults:$runtime:${model}")
        ;;
      stage:*)
        spec="${op#stage:}"
        if [[ "$spec" != *"="* ]]; then
          echo "Error: invalid stage op (expected stage:id=runtime[,model]): $op" >&2
          return 2
        fi
        stage_id="${spec%%=*}"
        runtime="${spec#*=}"
        model=""
        if [[ "$runtime" == *","* ]]; then
          model="${runtime#*,}"
          runtime="${runtime%%,*}"
        fi
        if ! _workflow_routing_mutate_stage_is_mutable "$seed_path" "$seed_scope" "$stage_id"; then
          return 1
        fi
        runtime="$(_workflow_routing_mutate_normalize_runtime "$runtime")" || return 1
        persist_queue+=("stages:$stage_id=$runtime${model:+,}$model")
        ;;
      stage-model:*)
        spec="${op#stage-model:}"
        if [[ "$spec" != *"="* ]]; then
          echo "Error: invalid stage-model op (expected stage-model:id=model): $op" >&2
          return 2
        fi
        stage_id="${spec%%=*}"
        model="${spec#*=}"
        if ! _workflow_routing_mutate_stage_is_mutable "$seed_path" "$seed_scope" "$stage_id"; then
          return 1
        fi
        runtime="$(_workflow_routing_mutate_read_stage_runtime "$seed_path" "$seed_scope" "$stage_id")"
        if [[ -z "$runtime" ]]; then
          echo "Error: stage '$stage_id' has no runtime to pair with model" >&2
          return 1
        fi
        persist_queue+=("stages:$stage_id=$runtime,$model")
        ;;
      clear-stage:*)
        stage_id="${op#clear-stage:}"
        if ! _workflow_routing_mutate_stage_is_mutable "$seed_path" "$seed_scope" "$stage_id"; then
          return 1
        fi
        persist_queue+=("clear-stages:$stage_id")
        ;;
      clear-stage-model:*)
        stage_id="${op#clear-stage-model:}"
        if ! _workflow_routing_mutate_stage_is_mutable "$seed_path" "$seed_scope" "$stage_id"; then
          return 1
        fi
        persist_queue+=("clear-stage-model:$stage_id")
        ;;
      *)
        echo "Error: unknown routing mutation op: $op" >&2
        return 2
        ;;
    esac
  done

  # Pairing: defaults model requires a runtime in the resulting block.
  if [[ "$set_default_model" == "1" && -n "$pending_default_model" ]]; then
    rt="$pending_default_runtime"
    if [[ -z "$rt" ]]; then
      rt="$(_workflow_routing_mutate_read_default_runtime "$seed_path" "$seed_scope")"
    fi
    if [[ -z "$rt" && "$clear_default_runtime" == "1" ]]; then
      rt=""
    fi
    if [[ -z "$rt" ]]; then
      echo "Error: defaults.model requires defaults.runtime" >&2
      return 1
    fi
  fi

  local work_src="$seed_path" work_dst="" next_dst="" item mode args_line

  if [[ "$clear_default_block" == "1" ]]; then
    work_dst="$(mktemp "$target_dir/.workflow-routing-mutate-XXXXXX")" || return 1
    if ! _workflow_routing_mutate_run_persist "$work_src" "$work_dst" clear-defaults; then
      rm -f "$work_dst"
      return 1
    fi
    work_src="$work_dst"
  fi
  if [[ "$clear_default_runtime" == "1" ]]; then
    next_dst="$(mktemp "$target_dir/.workflow-routing-mutate-XXXXXX")" || { rm -f "$work_dst"; return 1; }
    if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" clear-default-runtime; then
      rm -f "$work_dst" "$next_dst"
      return 1
    fi
    [[ "$work_dst" != "$seed_path" ]] && rm -f "$work_dst"
    work_src="$next_dst"
    work_dst="$next_dst"
  fi
  if [[ "$clear_default_model" == "1" ]]; then
    next_dst="$(mktemp "$target_dir/.workflow-routing-mutate-XXXXXX")" || { rm -f "$work_dst"; return 1; }
    if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" clear-default-model; then
      rm -f "$work_dst" "$next_dst"
      return 1
    fi
    [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
    work_src="$next_dst"
    work_dst="$next_dst"
  fi

  for item in "${persist_queue[@]}"; do
    mode="${item%%:*}"
    args_line="${item#*:}"
    next_dst="$(mktemp "$target_dir/.workflow-routing-mutate-XXXXXX")" || {
      [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
      return 1
    }
    case "$mode" in
      defaults)
        runtime="${args_line%%:*}"
        model="${args_line#*:}"
        if [[ "$model" == "$runtime" ]]; then
          model=""
        fi
        if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" defaults "$runtime" "$model"; then
          rm -f "$next_dst"
          [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
          return 1
        fi
        ;;
      stages)
        if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" stages "$args_line"; then
          rm -f "$next_dst"
          [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
          return 1
        fi
        ;;
      clear-stages)
        if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" clear-stages "$args_line"; then
          rm -f "$next_dst"
          [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
          return 1
        fi
        ;;
      clear-stage-model)
        if ! _workflow_routing_mutate_run_persist "$work_src" "$next_dst" clear-stage-model "$args_line"; then
          rm -f "$next_dst"
          [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
          return 1
        fi
        ;;
      *)
        rm -f "$next_dst"
        echo "Error: internal persist queue corruption" >&2
        return 1
        ;;
    esac
    [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
    work_src="$next_dst"
    work_dst="$next_dst"
  done

  if ! declare -F plan_workflow_validate >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_workflow_routing_mutate_lib_dir/../plan-todo.sh"
  fi
  if ! plan_workflow_validate "$work_src" >/dev/null 2>&1; then
    [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
    echo "Error: updated workflow failed validation" >&2
    return 1
  fi

  if [[ -f "$target_path" && -n "$pre_sha" ]]; then
    local now_sha=""
    now_sha="$(_workflow_routing_mutate_file_sha256 "$target_path")" || {
      [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
      return 1
    }
    if [[ "$now_sha" != "$pre_sha" ]]; then
      [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
      echo "Error: workflow content changed during mutation (sha256 conflict)" >&2
      return 1
    fi
  fi

  local publish_tmp=""
  publish_tmp="$(mktemp "$target_dir/.${target_path##*/}.tmp-XXXXXX")" || {
    [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"
    return 1
  }
  if ! cp -f -- "$work_src" "$publish_tmp"; then
    rm -f "$publish_tmp" "$work_dst"
    echo "Error: failed to stage routing mutation" >&2
    return 1
  fi
  [[ "$work_dst" != "$seed_path" && -f "$work_dst" ]] && rm -f "$work_dst"

  if ! plan_workflow_validate "$publish_tmp" >/dev/null 2>&1; then
    rm -f "$publish_tmp"
    echo "Error: staged workflow failed validation" >&2
    return 1
  fi

  if ! mv -f -- "$publish_tmp" "$target_path"; then
    rm -f "$publish_tmp"
    echo "Error: failed to publish routing mutation" >&2
    return 1
  fi

  _workflow_routing_mutate_file_sha256 "$target_path"
  return 0
}
