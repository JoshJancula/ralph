#!/usr/bin/env python3
"""Unit tests for shell_command_registry.py.

Tests covering safe rewrite rules for git status, pytest, and tsc;
bail-out behavior for compound commands, redirects, heredocs, functions,
reserved words, and background commands; and wrapper/env-prefix handling.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Add the tests/python directory to the path for importing ralph_script_loader
sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

# Load the shell_command_registry module
scr = load_ralph_script("shell_command_registry")


class TestShouldBail(unittest.TestCase):
    """Tests for should_bail function."""

    def test_simple_command_no_bail(self) -> None:
        """Simple commands should not bail."""
        self.assertFalse(scr.should_bail("git status"))
        self.assertFalse(scr.should_bail("pytest"))
        self.assertFalse(scr.should_bail("ls -la"))

    def test_compound_and_bails(self) -> None:
        """Commands with && should bail."""
        self.assertTrue(scr.should_bail("git status && git log"))
        self.assertTrue(scr.should_bail("echo a && echo b"))

    def test_compound_or_bails(self) -> None:
        """Commands with || should bail."""
        self.assertTrue(scr.should_bail("git status || echo failed"))

    def test_semicolon_bails(self) -> None:
        """Commands with ; should bail."""
        self.assertTrue(scr.should_bail("git status; git log"))

    def test_pipe_bails(self) -> None:
        """Commands with | should bail."""
        self.assertTrue(scr.should_bail("git status | cat"))

    def test_subshell_bails(self) -> None:
        """Commands with $() should bail."""
        self.assertTrue(scr.should_bail("echo $(git status)"))

    def test_command_substitution_brace_bails(self) -> None:
        """Commands with ${} should bail."""
        self.assertTrue(scr.should_bail("echo ${var}"))

    def test_process_substitution_bails(self) -> None:
        """Commands with <() or >() should bail."""
        self.assertTrue(scr.should_bail("cat <(echo test)"))
        self.assertTrue(scr.should_bail("echo test > >(cat)"))

    def test_backtick_bails(self) -> None:
        """Commands with backticks should bail."""
        self.assertTrue(scr.should_bail("echo `git status`"))

    def test_newline_bails(self) -> None:
        """Commands with newlines should bail."""
        self.assertTrue(scr.should_bail("git status\ngit log"))

    def test_heredoc_bails(self) -> None:
        """Commands with heredocs (<<) should bail."""
        self.assertTrue(scr.should_bail("cat <<EOF\ncontent\nEOF"))
        self.assertTrue(scr.should_bail("cat <<-EOF\ncontent\nEOF"))
        self.assertTrue(scr.should_bail("cat <<<string"))

    def test_tee_pipe_bails(self) -> None:
        """Commands with | tee should bail."""
        self.assertTrue(scr.should_bail("git status | tee log.txt"))

    def test_background_bails(self) -> None:
        """Commands with & background operator should bail."""
        self.assertTrue(scr.should_bail("git status &"))
        self.assertTrue(scr.should_bail("sleep 10 &"))

    def test_function_definition_bails(self) -> None:
        """Function definitions should bail."""
        self.assertTrue(scr.should_bail("function test() { echo hi; }"))
        self.assertTrue(scr.should_bail("test() { echo hi; }"))


class TestRedirectHandling(unittest.TestCase):
    """Tests for redirect detection and handling."""

    def test_trailing_redirect_devnull_stripped(self) -> None:
        """Trailing redirects to /dev/null should be stripped."""
        result = scr.try_parse_tokens("git status >/dev/null")
        self.assertIsNotNone(result)

    def test_trailing_redirect_devnull_append_stripped(self) -> None:
        """Trailing append redirects to /dev/null should be stripped."""
        result = scr.try_parse_tokens("git status >>/dev/null")
        self.assertIsNotNone(result)

    def test_trailing_redirect_both_devnull_stripped(self) -> None:
        """Trailing &> redirects to /dev/null should be stripped."""
        result = scr.try_parse_tokens("git status &>/dev/null")
        self.assertIsNotNone(result)

    def test_trailing_stderr_redirect_not_stripped(self) -> None:
        """Trailing 2>&1 is not considered a safe redirect to strip (bails)."""
        result = scr.try_parse_tokens("git status 2>&1")
        self.assertIsNone(result)

    def test_redirect_to_file_bails(self) -> None:
        """Redirects to files should cause bail via try_parse_tokens."""
        result = scr.try_parse_tokens("git status >output.txt")
        self.assertIsNone(result)

    def test_redirect_from_file_bails(self) -> None:
        """Input redirects should cause bail."""
        result = scr.try_parse_tokens("cat <input.txt")
        self.assertIsNone(result)

    def test_mid_command_redirect_bails(self) -> None:
        """Mid-command redirects should cause bail."""
        result = scr.try_parse_tokens("echo hello > output.txt && cat output.txt")
        self.assertIsNone(result)


class TestReservedWords(unittest.TestCase):
    """Tests for reserved word detection."""

    def test_alias_bails(self) -> None:
        """Commands starting with alias should bail."""
        result = scr.try_parse_tokens("alias ls='ls --color'")
        self.assertIsNone(result)

    def test_builtin_bails(self) -> None:
        """Commands starting with builtin should bail."""
        result = scr.try_parse_tokens("builtin echo hello")
        self.assertIsNone(result)

    def test_case_bails(self) -> None:
        """Commands starting with case should bail."""
        result = scr.try_parse_tokens("case $var in a) echo A;; esac")
        self.assertIsNone(result)

    def test_eval_bails(self) -> None:
        """Commands starting with eval should bail."""
        result = scr.try_parse_tokens("eval 'echo hello'")
        self.assertIsNone(result)

    def test_exec_bails(self) -> None:
        """Commands starting with exec should bail."""
        result = scr.try_parse_tokens("exec ls")
        self.assertIsNone(result)

    def test_for_bails(self) -> None:
        """Commands starting with for should bail."""
        result = scr.try_parse_tokens("for i in 1 2 3; do echo $i; done")
        self.assertIsNone(result)

    def test_if_bails(self) -> None:
        """Commands starting with if should bail."""
        result = scr.try_parse_tokens("if true; then echo hi; fi")
        self.assertIsNone(result)

    def test_source_bails(self) -> None:
        """Commands starting with source should bail."""
        result = scr.try_parse_tokens("source ~/.bashrc")
        self.assertIsNone(result)

    def test_while_bails(self) -> None:
        """Commands starting with while should bail."""
        result = scr.try_parse_tokens("while true; do sleep 1; done")
        self.assertIsNone(result)

    def test_until_bails(self) -> None:
        """Commands starting with until should bail."""
        result = scr.try_parse_tokens("until false; do sleep 1; done")
        self.assertIsNone(result)

    def test_time_bails(self) -> None:
        """Commands starting with time should bail."""
        result = scr.try_parse_tokens("time sleep 1")
        self.assertIsNone(result)

    def test_coproc_bails(self) -> None:
        """Commands starting with coproc should bail."""
        result = scr.try_parse_tokens("coproc test { sleep 1; }")
        self.assertIsNone(result)

    def test_select_bails(self) -> None:
        """Commands starting with select should bail."""
        result = scr.try_parse_tokens("select i in a b c; do echo $i; done")
        self.assertIsNone(result)


class TestWrapperPrefixes(unittest.TestCase):
    """Tests for wrapper prefix stripping."""

    def test_command_wrapper_preserved(self) -> None:
        """Command wrapper should be preserved in rewrite prefix."""
        parsed = scr.try_parse_tokens("command git status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        # Git global options extraction includes git in the prefix
        self.assertIn("command", prefix)
        self.assertIn("git", prefix)

    def test_noglob_wrapper_preserved(self) -> None:
        """Noglob wrapper should be preserved in rewrite prefix."""
        parsed = scr.try_parse_tokens("noglob ls *.txt")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["ls", "*.txt"])
        self.assertEqual(prefix, ["noglob"])

    def test_env_wrapper_preserved(self) -> None:
        """Env wrapper should be preserved in rewrite prefix."""
        parsed = scr.try_parse_tokens("env VAR=value git status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        self.assertIn("env", prefix)
        self.assertIn("VAR=value", prefix)

    def test_env_with_multiple_assignments(self) -> None:
        """Env wrapper with multiple assignments should be preserved."""
        parsed = scr.try_parse_tokens("env VAR1=value1 VAR2=value2 pytest")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["pytest"])
        self.assertEqual(prefix, ["env", "VAR1=value1", "VAR2=value2"])

    def test_poetry_run_wrapper_preserved(self) -> None:
        """Poetry run wrapper should be preserved."""
        parsed = scr.try_parse_tokens("poetry run pytest")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["pytest"])
        self.assertEqual(prefix, ["poetry", "run"])

    def test_bundle_exec_wrapper_preserved(self) -> None:
        """Bundle exec wrapper should be preserved."""
        parsed = scr.try_parse_tokens("bundle exec rake test")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["rake", "test"])
        self.assertEqual(prefix, ["bundle", "exec"])

    def test_leading_env_assignment_preserved(self) -> None:
        """Leading environment variable assignments should be preserved."""
        parsed = scr.try_parse_tokens("VAR=value pytest")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["pytest"])
        self.assertEqual(prefix, ["VAR=value"])

    def test_multiple_leading_assignments_preserved(self) -> None:
        """Multiple leading environment assignments should be preserved."""
        parsed = scr.try_parse_tokens("A=1 B=2 C=3 pytest")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["pytest"])
        self.assertEqual(prefix, ["A=1", "B=2", "C=3"])

    def test_git_global_options_preserved(self) -> None:
        """Git global options should be preserved in prefix."""
        parsed = scr.try_parse_tokens("git -C /path status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        self.assertEqual(prefix, ["git", "-C", "/path"])

    def test_git_global_option_with_value_equals(self) -> None:
        """Git global options with =value should be preserved."""
        parsed = scr.try_parse_tokens("git --git-dir=/path/.git status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        self.assertEqual(prefix, ["git", "--git-dir=/path/.git"])

    def test_git_config_option(self) -> None:
        """Git -c option should be preserved."""
        parsed = scr.try_parse_tokens("git -c color.status=false status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        self.assertIn("-c", prefix)

    def test_combined_wrappers(self) -> None:
        """Multiple wrapper types should be preserved together."""
        parsed = scr.try_parse_tokens("env DEBUG=1 command git status")
        self.assertIsNotNone(parsed)
        cmd, tokens, prefix = parsed
        self.assertEqual(tokens, ["git", "status"])
        self.assertIn("env", prefix)
        self.assertIn("command", prefix)


class TestGitStatusRewrite(unittest.TestCase):
    """git status is match-only: it is classified but never rewritten.

    Rewriting `git status` to `--porcelain=v2 --branch` changes the output
    form the agent explicitly requested, which is a different and less
    defensible trade than dropping progress noise. Only the git_status
    compactor trims output; the command text passed through untouched.
    """

    def test_git_status_basic_unchanged(self) -> None:
        """Basic git status should be unchanged, not rewritten."""
        result = scr.rewrite_command("git status")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.status, "unchanged")
        self.assertEqual(result.rewritten_command, "git status")

    def test_git_status_with_path_unchanged(self) -> None:
        """Git status with path should be unchanged, not rewritten."""
        result = scr.rewrite_command("git status src/")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.rewritten_command, "git status src/")

    def test_git_status_with_short_flag_no_rewrite(self) -> None:
        """Git status with -s flag should not be rewritten."""
        result = scr.rewrite_command("git status -s")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.rewritten_command, "git status -s")

    def test_git_status_with_porcelain_flag_no_rewrite(self) -> None:
        """Git status with --porcelain flag should not be rewritten."""
        result = scr.rewrite_command("git status --porcelain")
        self.assertFalse(result.rewritten)

    def test_git_status_with_branch_flag_no_rewrite(self) -> None:
        """Git status with -b flag should not be rewritten."""
        result = scr.rewrite_command("git status -b")
        self.assertFalse(result.rewritten)

    def test_git_status_with_other_flags_no_rewrite(self) -> None:
        """Git status with other flags should not be rewritten."""
        result = scr.rewrite_command("git status --short")
        self.assertFalse(result.rewritten)

    def test_git_status_with_unknown_flag_no_rewrite(self) -> None:
        """Git status with unknown flag should not be rewritten."""
        result = scr.rewrite_command("git status --untracked-files=all")
        self.assertFalse(result.rewritten)

    def test_git_status_preserves_wrapper_prefix_unchanged(self) -> None:
        """Git status with a wrapper prefix should still be unchanged."""
        result = scr.rewrite_command("env GIT_PAGER=cat git status")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.rewritten_command, "env GIT_PAGER=cat git status")

    def test_git_status_preserves_global_options_unchanged(self) -> None:
        """Git status with global options should still be unchanged."""
        result = scr.rewrite_command("git -C /path status")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.rewritten_command, "git -C /path status")


class TestPytestRewrite(unittest.TestCase):
    """Tests for pytest rewrite rule."""

    def test_pytest_basic_rewrite(self) -> None:
        """Basic pytest should be rewritten with quiet and tb=line."""
        result = scr.rewrite_command("pytest")
        self.assertTrue(result.rewritten)
        self.assertEqual(result.rule_id, scr.RULE_PYTEST)
        self.assertIn("-q", result.rewritten_command)
        self.assertIn("--tb=line", result.rewritten_command)

    def test_pytest_with_path_rewrite(self) -> None:
        """Pytest with path should be rewritten preserving path."""
        result = scr.rewrite_command("pytest tests/unit")
        self.assertTrue(result.rewritten)
        self.assertIn("-q", result.rewritten_command)
        self.assertIn("tests/unit", result.rewritten_command)

    def test_pytest_with_quiet_flag_no_rewrite(self) -> None:
        """Pytest with -q flag should not be rewritten."""
        result = scr.rewrite_command("pytest -q")
        self.assertFalse(result.rewritten)

    def test_pytest_with_tb_flag_no_rewrite(self) -> None:
        """Pytest with --tb flag should not be rewritten."""
        result = scr.rewrite_command("pytest --tb=short")
        self.assertFalse(result.rewritten)

    def test_pytest_with_tb_equals_no_rewrite(self) -> None:
        """Pytest with --tb= value should not be rewritten."""
        result = scr.rewrite_command("pytest --tb=long")
        self.assertFalse(result.rewritten)

    def test_pytest_with_other_flags_no_rewrite(self) -> None:
        """Pytest with other flags should not be rewritten."""
        result = scr.rewrite_command("pytest -v")
        self.assertFalse(result.rewritten)

    def test_pytest_preserves_wrapper_prefix(self) -> None:
        """Pytest rewrite should preserve wrapper prefixes."""
        result = scr.rewrite_command("poetry run pytest")
        self.assertTrue(result.rewritten)
        self.assertIn("poetry", result.rewritten_command)
        self.assertIn("run", result.rewritten_command)

    def test_pytest_preserves_env_prefix(self) -> None:
        """Pytest rewrite should preserve environment variable assignments."""
        result = scr.rewrite_command("PYTHONPATH=src pytest")
        self.assertTrue(result.rewritten)
        self.assertIn("PYTHONPATH=src", result.rewritten_command)


class TestTscRewrite(unittest.TestCase):
    """Tests for tsc rewrite rule."""

    def test_tsc_basic_rewrite(self) -> None:
        """Basic tsc should be rewritten with --pretty false."""
        result = scr.rewrite_command("tsc")
        self.assertTrue(result.rewritten)
        self.assertEqual(result.rule_id, scr.RULE_TSC)
        self.assertIn("--pretty", result.rewritten_command)
        self.assertIn("false", result.rewritten_command)

    def test_tsc_with_files_rewrite(self) -> None:
        """Tsc with file paths should be rewritten preserving paths."""
        result = scr.rewrite_command("tsc src/index.ts")
        self.assertTrue(result.rewritten)
        self.assertIn("--pretty", result.rewritten_command)
        self.assertIn("src/index.ts", result.rewritten_command)

    def test_tsc_with_pretty_false_no_rewrite(self) -> None:
        """Tsc with --pretty false should not be rewritten."""
        result = scr.rewrite_command("tsc --pretty false")
        self.assertFalse(result.rewritten)

    def test_tsc_with_pretty_equals_no_rewrite(self) -> None:
        """Tsc with --pretty= value should not be rewritten."""
        result = scr.rewrite_command("tsc --pretty=false")
        self.assertFalse(result.rewritten)

    def test_tsc_with_other_flags_no_rewrite(self) -> None:
        """Tsc with other flags should not be rewritten."""
        result = scr.rewrite_command("tsc --noEmit")
        self.assertFalse(result.rewritten)

    def test_tsc_preserves_wrapper_prefix(self) -> None:
        """Tsc rewrite should preserve env prefix."""
        result = scr.rewrite_command("env NODE_OPTIONS='--max-old-space-size=4096' tsc")
        self.assertTrue(result.rewritten)
        self.assertIn("env", result.rewritten_command)
        self.assertIn("--pretty", result.rewritten_command)


class TestRewriteResult(unittest.TestCase):
    """Tests for RewriteResult dataclass."""

    def test_to_dict(self) -> None:
        """RewriteResult should convert to dict correctly."""
        result = scr.RewriteResult(
            command="git status",
            rewritten_command="git status --porcelain=v2",
            rewritten=True,
            rule_id="git_status",
            status="rewritten"
        )
        d = result.to_dict()
        self.assertEqual(d["command"], "git status")
        self.assertEqual(d["rewritten_command"], "git status --porcelain=v2")
        self.assertTrue(d["rewritten"])
        self.assertEqual(d["rule_id"], "git_status")
        self.assertEqual(d["status"], "rewritten")

    def test_unchanged_result(self) -> None:
        """Unchanged result should have rewritten=False."""
        result = scr.rewrite_command("git status -s")
        self.assertFalse(result.rewritten)
        self.assertEqual(result.status, "unchanged")
        self.assertIsNone(result.rule_id)


class TestClassifyRegistryFamily(unittest.TestCase):
    """Tests for classify_registry_family function."""

    def test_git_status_classified(self) -> None:
        """Git status should be classified correctly."""
        family = scr.classify_registry_family("git status")
        self.assertEqual(family, scr.FAMILY_GIT_STATUS)

    def test_pytest_classified(self) -> None:
        """Pytest should be classified correctly."""
        family = scr.classify_registry_family("pytest")
        self.assertEqual(family, scr.FAMILY_PYTEST)

    def test_tsc_classified(self) -> None:
        """Tsc should be classified correctly."""
        family = scr.classify_registry_family("tsc")
        self.assertEqual(family, scr.FAMILY_TSC)

    def test_compound_not_classified(self) -> None:
        """Compound commands should not be classified."""
        family = scr.classify_registry_family("git status && git log")
        self.assertIsNone(family)

    def test_redirect_not_classified(self) -> None:
        """Commands with redirects should not be classified."""
        family = scr.classify_registry_family("git status >out.txt")
        self.assertIsNone(family)

    def test_unknown_not_classified(self) -> None:
        """Unknown commands should not be classified."""
        family = scr.classify_registry_family("unknown-command")
        self.assertIsNone(family)


class TestClassifierForFamily(unittest.TestCase):
    """Tests for classifier_for_family function."""

    def test_git_status_classifier(self) -> None:
        """Git status classifier should match git status commands."""
        classifier = scr.classifier_for_family(scr.FAMILY_GIT_STATUS)
        self.assertTrue(classifier("git status"))
        self.assertFalse(classifier("git log"))
        self.assertFalse(classifier("ls"))

    def test_pytest_classifier(self) -> None:
        """Pytest classifier should match pytest commands."""
        classifier = scr.classifier_for_family(scr.FAMILY_PYTEST)
        self.assertTrue(classifier("pytest"))
        self.assertTrue(classifier("pytest tests/"))
        self.assertFalse(classifier("python -m pytest"))

    def test_tsc_classifier(self) -> None:
        """Tsc classifier should match tsc commands."""
        classifier = scr.classifier_for_family(scr.FAMILY_TSC)
        self.assertTrue(classifier("tsc"))
        self.assertTrue(classifier("tsc --noEmit"))
        self.assertFalse(classifier("npx tsc"))

    def test_nonexistent_family(self) -> None:
        """Nonexistent family should return always-false classifier."""
        classifier = scr.classifier_for_family("nonexistent")
        self.assertFalse(classifier("anything"))
        self.assertFalse(classifier(""))


class TestClassifierForRule(unittest.TestCase):
    """Tests for classifier_for_rule function."""

    def test_git_status_rule_classifier(self) -> None:
        """Git status rule classifier should work correctly."""
        for rule in scr.SHELL_COMMAND_RULES:
            if rule.rule_id == scr.RULE_GIT_STATUS:
                classifier = scr.classifier_for_rule(rule)
                self.assertTrue(classifier("git status"))
                self.assertFalse(classifier("git log"))
                break


class TestLineContinuations(unittest.TestCase):
    """Tests for line continuation handling."""

    def test_backslash_continuation_joined(self) -> None:
        """Backslash line continuations should be joined."""
        result = scr.try_parse_tokens("git \\\nstatus")
        self.assertIsNotNone(result)
        cmd, tokens, _prefix = result
        self.assertEqual(tokens[0], "git")
        self.assertEqual(tokens[1], "status")

    def test_multiple_continuations_joined(self) -> None:
        """Multiple continuations should be joined."""
        result = scr.try_parse_tokens("git \\\n  status \\\n    --short")
        self.assertIsNotNone(result)
        cmd, tokens, _prefix = result
        self.assertIn("git", tokens)
        self.assertIn("status", tokens)


class TestEdgeCases(unittest.TestCase):
    """Tests for edge cases."""

    def test_empty_string(self) -> None:
        """Empty string should be handled."""
        result = scr.try_parse_tokens("")
        self.assertIsNone(result)

    def test_none_string(self) -> None:
        """None should be handled as empty."""
        result = scr.try_parse_tokens(None)  # type: ignore
        self.assertIsNone(result)

    def test_whitespace_only(self) -> None:
        """Whitespace-only string should be handled."""
        result = scr.try_parse_tokens("   ")
        self.assertIsNone(result)

    def test_unbalanced_quotes(self) -> None:
        """Unbalanced quotes should cause graceful failure."""
        result = scr.try_parse_tokens('echo "unbalanced')
        self.assertIsNone(result)

    def test_shlex_error_handling(self) -> None:
        """Shlex errors should be handled gracefully."""
        result = scr.try_parse_tokens("echo 'test")
        self.assertIsNone(result)

    def test_double_ampersand_not_background(self) -> None:
        """&& should not be treated as background."""
        self.assertTrue(scr.should_bail("cmd1 && cmd2"))

    def test_path_in_binary(self) -> None:
        """Full path to binary should match basename."""
        result = scr.rewrite_command("/usr/bin/pytest")
        self.assertTrue(result.rewritten)

    def test_relative_path_in_binary(self) -> None:
        """Relative path to binary should match basename."""
        result = scr.rewrite_command("./bin/pytest")
        self.assertTrue(result.rewritten)


class TestShellCommandRule(unittest.TestCase):
    """Tests for ShellCommandRule dataclass."""

    def test_rule_creation(self) -> None:
        """ShellCommandRule should be created with proper attributes."""
        def match_fn(cmd: str, tokens: list[str]) -> bool:
            return len(tokens) > 0 and tokens[0] == "test"

        def rewrite_fn(cmd: str, tokens: list[str], prefix: list[str]) -> str | None:
            return "rewritten"

        rule = scr.ShellCommandRule(
            rule_id="test_rule",
            family_id="test_family",
            match=match_fn,
            rewrite=rewrite_fn,
            safety_metadata={"safe": True}
        )
        self.assertEqual(rule.rule_id, "test_rule")
        self.assertEqual(rule.family_id, "test_family")
        self.assertTrue(rule.match("test", ["test"]))
        self.assertEqual(rule.rewrite("", [""], []), "rewritten")


class TestRewriteRuleCount(unittest.TestCase):
    """Guard the documented rewrite-rule table in docs/HOOKS.md.

    Exactly two SHELL_COMMAND_RULES entries may carry a rewrite= callable:
    pytest and tsc. Any change to that set must also update the rewrite
    table in docs/HOOKS.md and the header comments in
    bundle/.claude/hooks/rewrite-bash-command.sh and
    bundle/.ralph/python/shell_command_registry.py; this test fails first
    to force that update.
    """

    def test_exactly_two_rewrite_rules(self) -> None:
        rewrite_rule_ids = sorted(
            rule.rule_id for rule in scr.SHELL_COMMAND_RULES if rule.rewrite is not None
        )
        self.assertEqual(
            rewrite_rule_ids,
            ["pytest", "tsc"],
            "SHELL_COMMAND_RULES rewrite-rule set changed; update docs/HOOKS.md "
            "and the header comments in rewrite-bash-command.sh and "
            "shell_command_registry.py before changing this test.",
        )


if __name__ == "__main__":
    unittest.main()
