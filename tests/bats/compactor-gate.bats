#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "shell compactor gate rejects larger candidate output" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  response="$(python3 <<PY
import importlib.util
import json
import pathlib
import sys

script_path = pathlib.Path("$REPO_ROOT/bundle/.ralph/python/shell-output-compact.py")
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("shell_output_compact", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def stub(command, stdout, stderr, exit_status):
    return ("x" * 500, "", True)

entry = module.CompactorFamily(
    family_id=module.FAMILY_BATS,
    classifier=lambda _: True,
    compactor=stub,
    safety_metadata={"safe": True},
)
module._FAMILY_REGISTRY = [entry]
module._FAMILY_MAP = {module.FAMILY_BATS: entry}
orig = "orig-output" + ("x" * 400)
result = module.compact_shell_output("bats", orig, "", 0)
print(json.dumps(result.to_dict()))
PY
)"

  printf '%s\n' "$response" | jq -e '
    .status == "not compacted"
    and (.stdout | length) > 400
    and .compacted == false
  '
}

@test "shell compactor gate rejects empty candidate output" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  response="$(python3 <<PY
import importlib.util
import json
import pathlib
import sys

script_path = pathlib.Path("$REPO_ROOT/bundle/.ralph/python/shell-output-compact.py")
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("shell_output_compact", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def stub(command, stdout, stderr, exit_status):
    return ("", "", True)

entry = module.CompactorFamily(
    family_id=module.FAMILY_BATS,
    classifier=lambda _: True,
    compactor=stub,
    safety_metadata={"safe": True},
)
module._FAMILY_REGISTRY = [entry]
module._FAMILY_MAP = {module.FAMILY_BATS: entry}
result = module.compact_shell_output("bats", "orig-output", "", 0)
print(json.dumps(result.to_dict()))
PY
)"

  printf '%s\n' "$response" | jq -e '
    .status == "not compacted"
    and .stdout == "orig-output"
  '
}

@test "shell compactor gate rejects binary candidate output" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  response="$(python3 <<PY
import importlib.util
import json
import pathlib
import sys

script_path = pathlib.Path("$REPO_ROOT/bundle/.ralph/python/shell-output-compact.py")
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("shell_output_compact", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def stub(command, stdout, stderr, exit_status):
    return ("binary\\x00payload", "", True)

entry = module.CompactorFamily(
    family_id=module.FAMILY_BATS,
    classifier=lambda _: True,
    compactor=stub,
    safety_metadata={"safe": True},
)
module._FAMILY_REGISTRY = [entry]
module._FAMILY_MAP = {module.FAMILY_BATS: entry}
result = module.compact_shell_output("bats", "orig-output", "", 0)
print(json.dumps(result.to_dict()))
PY
)"

  printf '%s\n' "$response" | jq -e '
    .status == "not compacted"
    and .stdout == "orig-output"
  '
}

@test "shell compactor gate leaves raw output when command not registered" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"

  response="$(python3 <<PY
import importlib.util
import json
import pathlib
import sys

script_path = pathlib.Path("$REPO_ROOT/bundle/.ralph/python/shell-output-compact.py")
sys.path.insert(0, str(script_path.parent))
spec = importlib.util.spec_from_file_location("shell_output_compact", script_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

result = module.compact_shell_output("sleep 0", "plain-output", "plain-error", 0)
print(json.dumps(result.to_dict()))
PY
)"

  printf '%s\n' "$response" | jq -e '
    .status == "not compacted"
    and .stdout == "plain-output"
    and .stderr == "plain-error"
  '
}
