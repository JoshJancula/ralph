#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "root contains no untracked ad hoc test_*.py debug scripts" {
  cd "$REPO_ROOT"

  # Find any test_*.py files in root
  files=$(find . -maxdepth 1 -name 'test_*.py' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected test_*.py files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc test_*.sh debug scripts" {
  cd "$REPO_ROOT"

  files=$(find . -maxdepth 1 -name 'test_*.sh' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected test_*.sh files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc debug_*.py scripts" {
  cd "$REPO_ROOT"

  files=$(find . -maxdepth 1 -name 'debug_*.py' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected debug_*.py files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc debug_*.sh scripts" {
  cd "$REPO_ROOT"

  files=$(find . -maxdepth 1 -name 'debug_*.sh' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected debug_*.sh files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc simple_*.py scripts" {
  cd "$REPO_ROOT"

  files=$(find . -maxdepth 1 -name 'simple_*.py' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected simple_*.py files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc simple_*.sh scripts" {
  cd "$REPO_ROOT"

  files=$(find . -maxdepth 1 -name 'simple_*.sh' -type f 2>/dev/null || true)

  if [ -n "$files" ]; then
    echo "Found unexpected simple_*.sh files in root:"
    echo "$files"
    false
  fi
}

@test "root contains no untracked ad hoc comprehensive_test.sh script" {
  cd "$REPO_ROOT"

  if [ -f "comprehensive_test.sh" ]; then
    echo "Found unexpected comprehensive_test.sh in root"
    false
  fi
}
