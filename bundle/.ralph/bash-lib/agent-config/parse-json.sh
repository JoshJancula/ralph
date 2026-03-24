#!/usr/bin/env bash
#
# Low-level JSON field extraction for agent config.json (sourced by agent-config-tool.sh modules).
#
# Public interface:
#   load_cfg_path -- path to an agent's config.json.
#   json_string_value -- crude quoted-string reader for a top-level key.
#   array_block -- raw lines for a top-level JSON array by key.
#   list_agent_ids -- sorted agent directory names under agents_root.

load_cfg_path() {
  local agents_root="$1" agent_id="$2"
  echo "$agents_root/$agent_id/config.json"
}

json_string_value() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" "$file" | head -1
}

array_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN{in_arr=0; depth=0}
    {
      if (!in_arr && $0 ~ "\""key"\"[[:space:]]*:[[:space:]]*\\[") {
        in_arr=1
      }
      if (in_arr) {
        print $0
        opens=gsub(/\[/,"[")
        closes=gsub(/\]/,"]")
        depth += opens - closes
        if (depth<=0 && $0 ~ /\]/) exit
      }
    }' "$file"
}

list_agent_ids() {
  local agents_root="$1"
  [[ -d "$agents_root" ]] || return 0
  local d
  for d in "$agents_root"/*; do
    [[ -d "$d" && -f "$d/config.json" ]] || continue
    basename "$d"
  done | sort
}
