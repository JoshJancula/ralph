#!/usr/bin/env python3
"""Shared shell command registry: safety gates, predicates, rule ids, and rewrites.

SHELL_COMMAND_RULES holds two kinds of rules. Match-only rules (the
majority) exist solely to classify a command into a family for the
compaction layer; they never alter the command text. Rewrite rules
(carrying a non-None `rewrite=` callable) alter the command text before it
runs. Exactly two rewrite rules exist, and both only fire when the user
passed no conflicting flags of their own: `pytest` becomes
`pytest -q --tb=line`, and `tsc` becomes `tsc --pretty false`. The whole
rewrite path is gated behind RALPH_BASH_REWRITE (bundle/.claude/hooks/
rewrite-bash-command.sh and its per-runtime equivalents), which is unset by
default, so no rewriting happens unless it is explicitly enabled.
tests/python/test_shell_command_registry.py asserts this rewrite-rule set
stays at exactly two rules, so adding or removing one must also update this
docstring and the table in docs/HOOKS.md.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass, field
from typing import Callable

# Family ids (single source for rewrite telemetry and compaction classification).
FAMILY_BATS = "bats"
FAMILY_GIT_STATUS = "git_status"
FAMILY_GIT_DIFF = "git_diff"
FAMILY_GIT_SHOW = "git_show"
FAMILY_GIT_LOG = "git_log"
FAMILY_GREP = "grep"
FAMILY_FIND = "find"
FAMILY_LS = "ls"
FAMILY_TREE = "tree"
FAMILY_NPM_TEST = "npm_test"
FAMILY_VITEST = "vitest"
FAMILY_TSC = "tsc"
FAMILY_ESLINT = "eslint"
FAMILY_PYTEST = "pytest"
FAMILY_SHELLCHECK = "shellcheck"
FAMILY_DOCKER_PS = "docker_ps"
FAMILY_DOCKER_LOGS = "docker_logs"
FAMILY_KUBECTL = "kubectl"
FAMILY_GH_PR_VIEW = "gh_pr_view"
FAMILY_GH_PR_LIST = "gh_pr_list"

RULE_GIT_STATUS = FAMILY_GIT_STATUS
RULE_PYTEST = FAMILY_PYTEST
RULE_TSC = FAMILY_TSC

_COMPOUND_RE = re.compile(
    r"(?:&&|\|\||;|\||\$\(|\$\{|<\(|>\(|`|\n|<<-?|<<<|\|\s*tee\b)"
)
_REDIRECT_RE = re.compile(
    r"(?:^|[\s])(?:\d{1,2})?(?:&>>?|>>?|<<|<>|[<>])(?!\(|=)"
)
_TRAILING_SAFE_REDIRECT_RE = re.compile(
    r"(?:"
    r"\s(?:\d{1,2})?>\s*/dev/null"
    r"|\s(?:\d{1,2})?>>\s*/dev/null"
    r"|\s&>\s*/dev/null"
    r"|\s2>&1"
    r"|\s>\s*&\s*2"
    r"|\s\d?>&\s*\d?"
    r")+\s*$"
)
_BACKGROUND_RE = re.compile(r"(?<![&])&(?!&|[>])")
_ENV_ASSIGN_RE = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*=")
_TOKEN_ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_FUNCTION_DEF_RE = re.compile(
    r"(?:^\s*function\s+\w+|^\s*\w+\s*\(\s*\)\s*\{)"
)
_RESERVED_FIRST = frozenset({
    "alias",
    "builtin",
    "case",
    "coproc",
    "eval",
    "exec",
    "for",
    "function",
    "if",
    "select",
    "source",
    "time",
    "until",
    "while",
})

_PYTEST_QUIET_FLAG = frozenset({"-q", "--quiet"})
_PYTEST_TB_PREFIX = "--tb="
_GIT_GLOBAL_OPTION_WITH_VALUE = frozenset({"-C", "-c", "--git-dir", "--work-tree"})
_GIT_GLOBAL_OPTION_INLINE = frozenset({"--git-dir", "--work-tree"})
_GREP_BINARIES = frozenset({"grep", "rg", "egrep", "fgrep"})
_NPM_BINARIES = frozenset({"npm", "pnpm", "yarn"})

CommandMatcher = Callable[[str, list[str]], bool]
RewriteFn = Callable[[str, list[str], list[str]], str | None]


@dataclass(frozen=True)
class RewriteResult:
    command: str
    rewritten_command: str
    rewritten: bool
    rule_id: str | None
    status: str

    def to_dict(self) -> dict[str, object]:
        return {
            "command": self.command,
            "rewritten_command": self.rewritten_command,
            "rewritten": self.rewritten,
            "rule_id": self.rule_id,
            "status": self.status,
        }


@dataclass(frozen=True)
class ShellCommandRule:
    rule_id: str
    family_id: str
    match: CommandMatcher
    rewrite: RewriteFn | None = None
    safety_metadata: dict[str, object] = field(default_factory=dict)


def should_bail(command: str) -> bool:
    """Return True when the command must not be rewritten or registry-classified."""
    if _is_compound(command):
        return True
    if _has_background(command):
        return True
    if _FUNCTION_DEF_RE.search(command):
        return True
    return False


def should_bail_after_parse(_command: str, tokens: list[str]) -> bool:
    first = tokens[0]
    if _basename(first) in _RESERVED_FIRST:
        return True
    if "(" in first or ")" in first:
        return True
    return False


def _join_line_continuations(command: str) -> str:
    return re.sub(r"\\\s*\n\s*", " ", command)


def _strip_trailing_safe_redirects(command: str) -> str:
    previous = None
    current = command.rstrip()
    while previous != current:
        previous = current
        current = _TRAILING_SAFE_REDIRECT_RE.sub("", current).rstrip()
    return current


def _has_unsafe_redirect(command: str) -> bool:
    return bool(_REDIRECT_RE.search(command))


def _strip_leading_env_assignments(tokens: list[str]) -> tuple[list[str], list[str]]:
    prefix: list[str] = []
    index = 0
    while index < len(tokens) and _TOKEN_ENV_ASSIGN_RE.match(tokens[index]):
        prefix.append(tokens[index])
        index += 1
    return prefix, tokens[index:]


def _strip_wrapper_prefixes(tokens: list[str]) -> tuple[list[str], list[str]]:
    prefix: list[str] = []
    index = 0
    while index < len(tokens):
        base = _basename(tokens[index])
        if base in ("command", "noglob"):
            prefix.append(tokens[index])
            index += 1
            continue
        if base == "env":
            prefix.append(tokens[index])
            index += 1
            while index < len(tokens) and _TOKEN_ENV_ASSIGN_RE.match(tokens[index]):
                prefix.append(tokens[index])
                index += 1
            continue
        if base == "poetry" and index + 1 < len(tokens) and tokens[index + 1] == "run":
            prefix.extend(tokens[index : index + 2])
            index += 2
            continue
        if base == "bundle" and index + 1 < len(tokens) and tokens[index + 1] == "exec":
            prefix.extend(tokens[index : index + 2])
            index += 2
            continue
        break
    return prefix, tokens[index:]


def _strip_git_global_options(tokens: list[str]) -> tuple[list[str], list[str]]:
    if not tokens or _basename(tokens[0]) != "git":
        return [], tokens
    prefix = [tokens[0]]
    index = 1
    while index < len(tokens):
        arg = tokens[index]
        option = arg.split("=", 1)[0]
        if option in _GIT_GLOBAL_OPTION_WITH_VALUE:
            if "=" in arg or option in _GIT_GLOBAL_OPTION_INLINE:
                prefix.append(tokens[index])
                index += 1
                continue
            if index + 1 >= len(tokens):
                break
            prefix.extend(tokens[index : index + 2])
            index += 2
            continue
        break
    return prefix, tokens[:1] + tokens[index:]


def _normalize_tokens(tokens: list[str]) -> tuple[list[str], list[str]]:
    rewrite_prefix: list[str] = []
    env_prefix, tokens = _strip_leading_env_assignments(tokens)
    rewrite_prefix.extend(env_prefix)
    wrapper_prefix, tokens = _strip_wrapper_prefixes(tokens)
    rewrite_prefix.extend(wrapper_prefix)
    git_prefix, tokens = _strip_git_global_options(tokens)
    rewrite_prefix.extend(git_prefix)
    return tokens, rewrite_prefix


def try_parse_tokens(command: str) -> tuple[str, list[str], list[str]] | None:
    """Parse a command into (stripped command, match tokens, rewrite prefix tokens)."""
    original = command if command is not None else ""
    cmd = _join_line_continuations(original.strip())
    if not cmd or should_bail(cmd):
        return None
    cmd = _strip_trailing_safe_redirects(cmd)
    if not cmd or _has_unsafe_redirect(cmd):
        return None
    try:
        tokens = shlex.split(cmd, posix=True)
    except ValueError:
        return None
    if not tokens:
        return None
    tokens, rewrite_prefix = _normalize_tokens(tokens)
    if not tokens or should_bail_after_parse(cmd, tokens):
        return None
    return cmd, tokens, rewrite_prefix


def classify_registry_family(command: str) -> str | None:
    """Return a compactor family id for registry rules, or None."""
    parsed = try_parse_tokens(command)
    if parsed is None:
        return None
    cmd, tokens, _rewrite_prefix = parsed
    for rule in SHELL_COMMAND_RULES:
        if rule.match(cmd, tokens):
            return rule.family_id
    return None


def rewrite_command(command: str) -> RewriteResult:
    """Rewrite a registry allowlisted command, or return it unchanged."""
    original = command if command is not None else ""
    parsed = try_parse_tokens(original)
    if parsed is None:
        return _unchanged(original)

    cmd, tokens, rewrite_prefix = parsed
    for rule in SHELL_COMMAND_RULES:
        if rule.rewrite is None or not rule.match(cmd, tokens):
            continue
        rewritten = rule.rewrite(cmd, tokens, rewrite_prefix)
        if rewritten is None or rewritten == cmd:
            continue
        return RewriteResult(
            command=original,
            rewritten_command=rewritten,
            rewritten=True,
            rule_id=rule.rule_id,
            status="rewritten",
        )
    return _unchanged(original)


def classifier_for_rule(rule: ShellCommandRule) -> Callable[[str], bool]:
    """Thin adapter: compactor entrypoints use command-string classifiers."""

    def classify(command: str) -> bool:
        parsed = try_parse_tokens(command)
        if parsed is None:
            return False
        cmd, tokens, _rewrite_prefix = parsed
        return rule.match(cmd, tokens)

    return classify


def classifier_for_family(family_id: str) -> Callable[[str], bool]:
    """Return a classifier that matches any registry rule in the family."""

    rules = [rule for rule in SHELL_COMMAND_RULES if rule.family_id == family_id]
    if not rules:
        return lambda _command: False

    def classify(command: str) -> bool:
        parsed = try_parse_tokens(command)
        if parsed is None:
            return False
        cmd, tokens, _rewrite_prefix = parsed
        return any(rule.match(cmd, tokens) for rule in rules)

    return classify


def _unchanged(command: str) -> RewriteResult:
    return RewriteResult(
        command=command,
        rewritten_command=command,
        rewritten=False,
        rule_id=None,
        status="unchanged",
    )


def _is_compound(command: str) -> bool:
    return bool(_COMPOUND_RE.search(command))


def _has_background(command: str) -> bool:
    return bool(_BACKGROUND_RE.search(command))


def _basename(token: str) -> str:
    if "/" in token:
        return token.rsplit("/", 1)[-1]
    return token


def _join_command(head: str, rest: list[str]) -> str:
    if not rest:
        return head
    return head + " " + " ".join(shlex.quote(arg) for arg in rest)


def _apply_rewrite_prefix(prefix: list[str], rewritten: str) -> str:
    if not prefix:
        return rewritten
    if _basename(prefix[0]) == "git" and rewritten.startswith("git "):
        rewritten = rewritten[4:]
    prefix_cmd = " ".join(shlex.quote(arg) for arg in prefix)
    return f"{prefix_cmd} {rewritten}"


def _match_binary(tokens: list[str], name: str) -> bool:
    return bool(tokens) and _basename(tokens[0]) == name


def _match_git_subcommand(_cmd: str, tokens: list[str], subcommand: str) -> bool:
    return len(tokens) >= 2 and _basename(tokens[0]) == "git" and tokens[1] == subcommand


def _match_git_status(_cmd: str, tokens: list[str]) -> bool:
    return _match_git_subcommand(_cmd, tokens, "status")


def _match_git_diff(_cmd: str, tokens: list[str]) -> bool:
    return _match_git_subcommand(_cmd, tokens, "diff")


def _match_git_show(_cmd: str, tokens: list[str]) -> bool:
    return _match_git_subcommand(_cmd, tokens, "show")


def _match_git_log(_cmd: str, tokens: list[str]) -> bool:
    return _match_git_subcommand(_cmd, tokens, "log")


def _match_grep(_cmd: str, tokens: list[str]) -> bool:
    return bool(tokens) and _basename(tokens[0]) in _GREP_BINARIES


def _match_find(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "find")


def _match_ls(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "ls")


def _match_tree(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "tree")


def _match_bats(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "bats")


def _match_pytest(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "pytest")


def _match_npm_test(_cmd: str, tokens: list[str]) -> bool:
    return (
        len(tokens) >= 2
        and _basename(tokens[0]) in _NPM_BINARIES
        and tokens[1] == "test"
    )


def _match_vitest(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "vitest")


def _match_eslint(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "eslint")


def _match_tsc(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "tsc")


def _match_shellcheck(_cmd: str, tokens: list[str]) -> bool:
    return _match_binary(tokens, "shellcheck")


def _match_docker_ps(_cmd: str, tokens: list[str]) -> bool:
    return len(tokens) >= 2 and _basename(tokens[0]) == "docker" and tokens[1] == "ps"


def _match_docker_logs(_cmd: str, tokens: list[str]) -> bool:
    """Match supported Docker log command forms by command text, never by
    output shape: `docker logs`, `docker compose logs`, `docker-compose logs`.
    """
    if len(tokens) < 2:
        return False
    base = _basename(tokens[0])
    if base == "docker":
        if tokens[1] == "logs":
            return True
        if len(tokens) >= 3 and tokens[1] == "compose" and tokens[2] == "logs":
            return True
        return False
    if base == "docker-compose":
        return tokens[1] == "logs"
    return False


def _match_kubectl_get(_cmd: str, tokens: list[str]) -> bool:
    return len(tokens) >= 2 and _basename(tokens[0]) == "kubectl" and tokens[1] == "get"


def _match_kubectl_logs(_cmd: str, tokens: list[str]) -> bool:
    return len(tokens) >= 2 and _basename(tokens[0]) == "kubectl" and tokens[1] == "logs"


def _match_gh_pr_view(_cmd: str, tokens: list[str]) -> bool:
    return (
        len(tokens) >= 3
        and _basename(tokens[0]) == "gh"
        and tokens[1] == "pr"
        and tokens[2] == "view"
    )


def _match_gh_pr_list(_cmd: str, tokens: list[str]) -> bool:
    return (
        len(tokens) >= 3
        and _basename(tokens[0]) == "gh"
        and tokens[1] == "pr"
        and tokens[2] == "list"
    )


def _rewrite_pytest(_cmd: str, tokens: list[str], rewrite_prefix: list[str]) -> str | None:
    if not _match_pytest(_cmd, tokens):
        return None
    rest = tokens[1:]
    for arg in rest:
        if arg in _PYTEST_QUIET_FLAG:
            return None
        if arg == "--tb" or arg.startswith(_PYTEST_TB_PREFIX):
            return None
        if arg.startswith("-"):
            return None
    return _apply_rewrite_prefix(
        rewrite_prefix,
        _join_command("pytest -q --tb=line", rest),
    )


def _rewrite_tsc(_cmd: str, tokens: list[str], rewrite_prefix: list[str]) -> str | None:
    if not _match_tsc(_cmd, tokens):
        return None
    rest = tokens[1:]
    for arg in rest:
        if arg == "--pretty" or arg.startswith("--pretty="):
            return None
        if arg.startswith("-"):
            return None
    return _apply_rewrite_prefix(
        rewrite_prefix,
        _join_command("tsc --pretty false", rest),
    )


def _rule(
    rule_id: str,
    family_id: str,
    match: CommandMatcher,
    *,
    rewrite: RewriteFn | None = None,
    phase: str,
) -> ShellCommandRule:
    return ShellCommandRule(
        rule_id=rule_id,
        family_id=family_id,
        match=match,
        rewrite=rewrite,
        safety_metadata={"safe": True, "phase": phase, "rewrite": rewrite is not None},
    )


SHELL_COMMAND_RULES: tuple[ShellCommandRule, ...] = (
    # git_status is match-only: the compactor still trims noisy output, but the
    # command itself is never rewritten. Rewriting `git status` to
    # `--porcelain=v2 --branch` changes the output form the agent explicitly
    # requested, which is a different and less defensible trade than dropping
    # progress noise from output the agent did not ask to reshape.
    _rule(RULE_GIT_STATUS, FAMILY_GIT_STATUS, _match_git_status, phase="phase2"),
    _rule(FAMILY_GIT_DIFF, FAMILY_GIT_DIFF, _match_git_diff, phase="phase2"),
    _rule(FAMILY_GIT_SHOW, FAMILY_GIT_SHOW, _match_git_show, phase="phase2"),
    _rule(FAMILY_GIT_LOG, FAMILY_GIT_LOG, _match_git_log, phase="phase2"),
    _rule(FAMILY_GREP, FAMILY_GREP, _match_grep, phase="phase2"),
    _rule(FAMILY_FIND, FAMILY_FIND, _match_find, phase="phase2"),
    _rule(FAMILY_BATS, FAMILY_BATS, _match_bats, phase="phase2"),
    _rule(FAMILY_NPM_TEST, FAMILY_NPM_TEST, _match_npm_test, phase="phase3"),
    _rule(FAMILY_VITEST, FAMILY_VITEST, _match_vitest, phase="phase3"),
    _rule(RULE_TSC, FAMILY_TSC, _match_tsc, rewrite=_rewrite_tsc, phase="phase3"),
    _rule(FAMILY_ESLINT, FAMILY_ESLINT, _match_eslint, phase="phase3"),
    _rule(RULE_PYTEST, FAMILY_PYTEST, _match_pytest, rewrite=_rewrite_pytest, phase="phase3"),
    _rule(FAMILY_SHELLCHECK, FAMILY_SHELLCHECK, _match_shellcheck, phase="phase3"),
    _rule(FAMILY_LS, FAMILY_LS, _match_ls, phase="phase4"),
    _rule(FAMILY_TREE, FAMILY_TREE, _match_tree, phase="phase4"),
    _rule(FAMILY_DOCKER_PS, FAMILY_DOCKER_PS, _match_docker_ps, phase="phase4"),
    _rule(FAMILY_DOCKER_LOGS, FAMILY_DOCKER_LOGS, _match_docker_logs, phase="phase4"),
    _rule("kubectl_get", FAMILY_KUBECTL, _match_kubectl_get, phase="phase4"),
    _rule("kubectl_logs", FAMILY_KUBECTL, _match_kubectl_logs, phase="phase4"),
    _rule(FAMILY_GH_PR_VIEW, FAMILY_GH_PR_VIEW, _match_gh_pr_view, phase="phase4"),
    _rule(FAMILY_GH_PR_LIST, FAMILY_GH_PR_LIST, _match_gh_pr_list, phase="phase4"),
)

CLASSIFIER_GIT_STATUS = classifier_for_family(FAMILY_GIT_STATUS)
CLASSIFIER_PYTEST = classifier_for_family(FAMILY_PYTEST)
CLASSIFIER_TSC = classifier_for_family(FAMILY_TSC)
