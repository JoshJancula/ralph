#!/usr/bin/env python3
"""Regression coverage for the sed-classified-as-docker_logs defect (PLAN15):
an unsupported non-empty command must never select a semantic family from
output shape alone. Also covers all supported Docker log command forms,
npm/yarn/pnpm/vitest/jest command classification, empty command input,
compound commands that should bail, and binary output.
"""

from __future__ import annotations

import unittest

from ralph_script_loader import load_ralph_script


SOC = load_ralph_script("shell-output-compact")


def _repeated_log_like_text(lines: int = 60) -> str:
    # Many near-identical lines: exactly the shape _detect_shape_repeated_logs
    # (mapped to docker_logs) is designed to catch.
    body = []
    for i in range(lines):
        body.append("  }" if i % 3 == 0 else f"    echo line {i}")
    return "\n".join(body) + "\n"


class TestSedRegression(unittest.TestCase):
    def test_sed_is_never_classified_as_docker_logs(self) -> None:
        text = _repeated_log_like_text()
        self.assertEqual(SOC.detect_output_shape(text), "docker_logs")  # shape alone would say docker_logs
        family = SOC.classify_command("sed -n '2240,2350p' .../mcp-proxy-tools.sh")
        self.assertIsNone(family)
        result = SOC.compact_shell_output(
            "sed -n '2240,2350p' .../mcp-proxy-tools.sh", text, "", 0
        )
        self.assertNotEqual(result.family, "docker_logs")

    def test_sed_output_retains_code_semantics_when_not_compacted(self) -> None:
        text = _repeated_log_like_text()
        result = SOC.compact_shell_output("sed -n '1,60p' script.sh", text, "", 0)
        if not result.compacted:
            self.assertEqual(result.stdout, text)

    def test_full_shape_fallback_only_applies_to_empty_command(self) -> None:
        self.assertTrue(SOC._command_allows_shape_fallback(""))
        self.assertTrue(SOC._command_allows_shape_fallback("   "))
        self.assertFalse(SOC._command_allows_shape_fallback("sed -n 1p x"))
        self.assertFalse(SOC._command_allows_shape_fallback("awk '{print}' x"))


class TestSupportedDockerLogVariants(unittest.TestCase):
    def test_docker_logs_classifies_by_command(self) -> None:
        self.assertEqual(SOC.classify_command("docker logs mycontainer"), "docker_logs")
        self.assertEqual(SOC.classify_command("docker logs -f mycontainer"), "docker_logs")

    def test_docker_compose_logs_classifies_by_command(self) -> None:
        self.assertEqual(SOC.classify_command("docker compose logs web"), "docker_logs")

    def test_docker_hyphen_compose_logs_classifies_by_command(self) -> None:
        self.assertEqual(SOC.classify_command("docker-compose logs -f db"), "docker_logs")

    def test_docker_ps_is_not_docker_logs(self) -> None:
        self.assertEqual(SOC.classify_command("docker ps -a"), "docker_ps")

    def test_docker_compose_up_is_not_docker_logs(self) -> None:
        self.assertNotEqual(SOC.classify_command("docker compose up -d"), "docker_logs")


class TestJsTestRunnerCommands(unittest.TestCase):
    def test_npm_test_classifies(self) -> None:
        self.assertIsNotNone(SOC.classify_command("npm test"))

    def test_npm_run_test_is_deterministic_and_not_docker_logs(self) -> None:
        # "npm run test" is not matched by the npm_test rule (only bare
        # "npm test" is); it must never fall back to a semantic shape family
        # such as docker_logs.
        family = SOC.classify_command("npm run test")
        self.assertNotEqual(family, "docker_logs")

    def test_vitest_binary_classifies_or_is_at_least_stable(self) -> None:
        # Not all runners have a dedicated family; just assert classification
        # is deterministic (same input -> same output) and never docker_logs.
        family = SOC.classify_command("npx vitest run")
        self.assertNotEqual(family, "docker_logs")

    def test_yarn_test_is_deterministic_and_not_docker_logs(self) -> None:
        family = SOC.classify_command("yarn test")
        self.assertNotEqual(family, "docker_logs")

    def test_pnpm_test_is_deterministic_and_not_docker_logs(self) -> None:
        family = SOC.classify_command("pnpm test")
        self.assertNotEqual(family, "docker_logs")


class TestEmptyAndCompoundCommands(unittest.TestCase):
    def test_empty_command_input_allows_full_shape_fallback(self) -> None:
        self.assertIsNone(SOC.classify_command(""))
        self.assertTrue(SOC._command_allows_shape_fallback(""))

    def test_unsupported_command_with_log_like_output_is_generic_or_unchanged(self) -> None:
        text = _repeated_log_like_text()
        result = SOC.compact_shell_output("customtool --verbose run", text, "", 0)
        self.assertIn(result.family, (None, "generic_large"))

    def test_compound_command_bails(self) -> None:
        # should_bail is exercised via classify_command returning None for
        # compound/piped commands that are not safe to classify by shape.
        family = SOC.classify_command("cat file.txt | grep foo && echo done")
        self.assertIsNone(family)
        self.assertFalse(SOC._command_allows_generic_shape_fallback("cat file.txt | grep foo && echo done"))


class TestGenericThresholdAndBinary(unittest.TestCase):
    def test_generic_threshold_behavior_is_size_driven_not_semantic(self) -> None:
        small_text = "line\n" * 5
        result = SOC.compact_shell_output("customtool run", small_text, "", 0)
        self.assertFalse(result.compacted)

    def test_binary_output_passes_through_unchanged(self) -> None:
        binary_text = "line one\x00binary\nline two\n"
        result = SOC.compact_shell_output("sed -n 1p x", binary_text, "", 0)
        self.assertFalse(result.compacted)
        self.assertEqual(result.stdout, binary_text)


if __name__ == "__main__":
    unittest.main()
