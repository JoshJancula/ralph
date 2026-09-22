#!/usr/bin/env python3
"""Split a Bats file into a library-level half and an end-to-end half.

Tests that drive a real per-node dispatch (they boot the orchestrator and
run-plan once per node) are end-to-end tests. Keeping them in the same file as
library-level tests forces both onto the pull-request path and, because Bats
runs tests within a file serially, makes that one file the wall-clock floor for
its whole tier.

This moves the non-@test body of the file into a shared helper sourced by both
halves, preserving its original order: several helpers are emitted inside
heredocs and depend on that ordering.

Usage:
  python3 scripts/split-bats-e2e.py tests/bats/graph/<name>.bats

Writes <name>.bats (library-level), <name>-e2e.bats, and
test_helper/<name>-shared.bash. Refuses to run if the parse is not a
byte-identical round trip of the input.
"""

import os
import re
import sys

# A test is end-to-end if it reaches the real dispatch stack.
E2E = re.compile(
    r"graph_schedule_run|graph_schedule_resume|setup_dispatch_workspace"
    r"|install_\w*run_plan|graph_dispatch_|install_behavior_orchestrator"
    r"|start_ledgered_run"
)
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z_0-9]*)\1")
TEST_OPEN = re.compile(r'^@test "(.*)" \{$')


def parse(lines):
    """Split into ordered ('shared', lines) / ('test', name, lines) segments.

    Heredoc bodies are skipped so that a `}` at column 0 inside a generated
    stub script does not look like the end of a test block.
    """
    segments = []
    buffer = []
    i = 0
    while i < len(lines):
        match = TEST_OPEN.match(lines[i])
        if not match:
            buffer.append(lines[i])
            i += 1
            continue
        if buffer:
            segments.append(("shared", buffer))
            buffer = []
        j = i + 1
        terminator = None
        while j < len(lines):
            line = lines[j]
            if terminator is not None:
                if line.strip() == terminator:
                    terminator = None
                j += 1
                continue
            heredoc = HEREDOC.search(line)
            if heredoc:
                terminator = heredoc.group(2)
                j += 1
                continue
            if line == "}":
                break
            j += 1
        segments.append(("test", match.group(1), lines[i : j + 1]))
        i = j + 1
    if buffer:
        segments.append(("shared", buffer))
    return segments


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    src = sys.argv[1]
    raw = open(src).read()
    lines = raw.split("\n")

    segments = parse(lines)

    rebuilt = []
    for segment in segments:
        rebuilt += segment[-1]
    if "\n".join(rebuilt) != raw:
        print(f"split-bats-e2e: parse is not a round trip for {src}; refusing", file=sys.stderr)
        return 1

    shared = []
    unit = []
    e2e = []
    for segment in segments:
        if segment[0] == "shared":
            shared += segment[1]
            continue
        body = segment[2]
        (e2e if E2E.search("\n".join(body)) else unit).append(body)

    if not e2e or not unit:
        print(
            f"split-bats-e2e: {src} is not mixed "
            f"(unit={len(unit)} e2e={len(e2e)}); nothing to split",
            file=sys.stderr,
        )
        return 1

    directory = os.path.dirname(src)
    stem = os.path.basename(src)[: -len(".bats")]
    helper_dir = os.path.join(directory, "test_helper")
    os.makedirs(helper_dir, exist_ok=True)
    helper = os.path.join(helper_dir, f"{stem}-shared.bash")

    body = shared[:]
    body[0] = "#!/usr/bin/env bash"
    body[1:1] = [
        f"# Shared fixtures and helpers for the {stem} suites.",
        "#",
        f"# {stem}.bats keeps the library-level tests. {stem}-e2e.bats keeps the",
        "# tests that drive a real dispatch: each boots the orchestrator and",
        "# run-plan once per node, so they run in the acceptance tier rather than",
        "# on the pull-request path.",
        "#",
        f"# This is the non-@test body of the original {stem}.bats in its original",
        "# order. Several helpers are emitted inside heredocs and depend on that",
        "# ordering, so do not reorder.",
    ]
    open(helper, "w").write("\n".join(body).rstrip("\n") + "\n")

    def write(path, title, blocks):
        out = [
            "#!/usr/bin/env bats",
            f"# {title}",
            "",
            f'source "$BATS_TEST_DIRNAME/test_helper/{stem}-shared.bash"',
            "",
        ]
        for block in blocks:
            out += block + [""]
        open(path, "w").write("\n".join(out).rstrip("\n") + "\n")

    write(src, f"{stem}: library-level tests. No real dispatch.", unit)
    write(
        os.path.join(directory, f"{stem}-e2e.bats"),
        f"{stem}: end-to-end tests driving a real per-node dispatch.",
        e2e,
    )
    print(f"{src}: unit={len(unit)} e2e={len(e2e)} helper={helper}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
