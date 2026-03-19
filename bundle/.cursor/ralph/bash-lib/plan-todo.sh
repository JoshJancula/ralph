#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

plan_normalize_path() {
  local path="$1"
  local workspace="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return
  fi

  if [[ "$path" == ~* ]]; then
    printf '%s\n' "${path/#\~/$HOME}"
    return
  fi

  if [[ -n "$workspace" ]]; then
    printf '%s\n' "$workspace/$path"
  else
    printf '%s\n' "$path"
  fi
}

plan_config_plan_path() {
  local config_file="$1"
  local workspace="$2"
  local default_plan="$3"
  local plan=""

  if [[ -f "$config_file" ]]; then
    plan="$(grep -o '"plan"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$plan" ]]; then
      plan_normalize_path "$plan" "$workspace"
      return
    fi
  fi

  plan_normalize_path "$default_plan" "$workspace"
}

get_plan_path() {
  plan_config_plan_path "$CONFIG_FILE" "$WORKSPACE" "$DEFAULT_PLAN"
}

plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  printf '%s\n' "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

get_next_todo() {
  local plan_path="$1"
  local line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*) ]]; then
      printf '%s|%s\n' "$line_num" "$line"
      return 0
    fi
  done < "$plan_path"
  return 1
}

count_todos() {
  local plan_path="$1"
  local total=0
  local done=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]] ]]; then
      total=$((total + 1))
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]] ]]; then
      total=$((total + 1))
      done=$((done + 1))
    fi
  done < "$plan_path"
  printf '%s %s\n' "$done" "$total"
}
#!/usr/bin/env bash

if [[ -n "${RALPH_PLAN_TODO_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_PLAN_TODO_LIB_LOADED=1

plan_normalize_path() {
  local path="$1"
  local workspace="$2"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return
  fi

  if [[ "$path" == ~* ]]; then
    printf '%s\n' "${path/#\~/$HOME}"
    return
  fi

  if [[ -n "$workspace" ]]; then
    printf '%s\n' "$workspace/$path"
  else
    printf '%s\n' "$path"
  fi
}

plan_config_plan_path() {
  local config_file="$1"
  local workspace="$2"
  local default_plan="$3"
  local plan=""

  if [[ -f "$config_file" ]]; then
    plan="$(grep -o '"plan"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$plan" ]]; then
      plan_normalize_path "$plan" "$workspace"
      return
    fi
  fi

  plan_normalize_path "$default_plan" "$workspace"
}

get_plan_path() {
  plan_config_plan_path "$CONFIG_FILE" "$WORKSPACE" "$DEFAULT_PLAN"
}

plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  printf '%s\n' "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

get_next_todo() {
  local plan_path="$1"
  local line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*) ]]; then
      printf '%s|%s\n' "$line_num" "$line"
      return 0
    fi
  done < "$plan_path"
  return 1
}

count_todos() {
  local plan_path="$1"
  local total=0
  local done=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]] ]]; then
      total=$((total + 1))
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]] ]]; then
      total=$((total + 1))
      done=$((done + 1))
    fi
  done < "$plan_path"
  printf '%s %s\n' "$done" "$total"
}
