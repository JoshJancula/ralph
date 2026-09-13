#!/usr/bin/env python3
"""Exhaustive stdlib tests for killswitch_config validate/normalize.

Case matrix lives here (millisecond). Bats only covers the shell-visible
command exit/stdout/stderr contract.
"""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from ralph_script_loader import load_ralph_script

REPO_ROOT = Path(__file__).resolve().parents[2]
ks = load_ralph_script("killswitch_config")


def _minimal(**overrides: object) -> dict:
    base = {
        "schema_version": 2,
        "enabled": True,
        "dry_run": False,
        "banned_tools": [],
        "tool_denylist": [],
        "allowed_tools": [],
        "banned_paths": [],
        "allowed_paths": [],
        "allowed_commands": [],
        "allowed_patterns": [],
        "denied_argument_patterns": [],
        "custom_rules": [],
    }
    base.update(overrides)
    return base


class NormalizeAcceptTests(unittest.TestCase):
    def test_bundle_default_validates_and_is_idempotent(self) -> None:
        path = REPO_ROOT / "bundle" / ".ralph" / "killswitch.json"
        first = ks.validate_file(str(path))
        second = ks.normalize_config(first, source="<already-normalized>")
        self.assertEqual(first, second)
        self.assertEqual(list(first.keys()), list(ks.CANONICAL_KEYS))
        self.assertEqual(first["schema_version"], 2)

    def test_camelcase_aliases_normalize_to_snake(self) -> None:
        raw = {
            "schema_version": 2,
            "enabled": True,
            "dryRun": True,
            "bannedTools": ["curl"],
            "toolDenylist": ["Bash"],
            "allowedTools": [],
            "bannedPaths": [".env*"],
            "allowedPaths": [],
            "allowedCommands": [],
            "allowedPatterns": [],
            "deniedArgumentPatterns": [
                {"tool": "ralph_proxy_read", "pattern": "/etc/passwd"}
            ],
            "customRules": [
                {"name": "no_sudo", "pattern": "^sudo\\s", "target": "command"}
            ],
        }
        out = ks.normalize_config(raw, source="alias.json")
        self.assertTrue(out["dry_run"])
        self.assertEqual(out["banned_tools"], ["curl"])
        self.assertEqual(out["tool_denylist"], ["Bash"])
        self.assertEqual(out["banned_paths"], [".env*"])
        self.assertEqual(out["denied_argument_patterns"][0]["mode"], "regex")
        self.assertEqual(out["custom_rules"][0]["name"], "no_sudo")
        self.assertNotIn("dryRun", out)
        self.assertNotIn("customRules", out)

    def test_nested_tools_deny_and_arguments_deny_patterns(self) -> None:
        raw = _minimal()
        del raw["tool_denylist"]
        del raw["denied_argument_patterns"]
        raw["tools"] = {"deny": ["ralph_write_file"]}
        raw["arguments"] = {
            "denyPatterns": [
                {
                    "tool": "ralph_run_plan",
                    "argument": "plan_path",
                    "pattern": "^/tmp/",
                    "mode": "regex",
                }
            ]
        }
        out = ks.normalize_config(raw, source="nested.json")
        self.assertEqual(out["tool_denylist"], ["ralph_write_file"])
        self.assertEqual(out["denied_argument_patterns"][0]["argument"], "plan_path")
        self.assertNotIn("tools", out)
        self.assertNotIn("arguments", out)

    def test_tools_denylist_alias(self) -> None:
        raw = _minimal()
        del raw["tool_denylist"]
        raw["tools"] = {"denylist": ["Shell"]}
        out = ks.normalize_config(raw)
        self.assertEqual(out["tool_denylist"], ["Shell"])

    def test_enabled_capital_alias(self) -> None:
        raw = _minimal()
        del raw["enabled"]
        raw["Enabled"] = False
        out = ks.normalize_config(raw)
        self.assertIs(out["enabled"], False)

    def test_custom_rule_match_shape(self) -> None:
        raw = _minimal(
            custom_rules=[{"name": "no_rm", "match": "rm -rf", "target": "command"}]
        )
        out = ks.normalize_config(raw)
        self.assertEqual(out["custom_rules"][0]["match"], "rm -rf")
        self.assertNotIn("pattern", out["custom_rules"][0])

    def test_custom_rule_default_target(self) -> None:
        raw = _minimal(custom_rules=[{"name": "x", "match": "y"}])
        out = ks.normalize_config(raw)
        self.assertEqual(out["custom_rules"][0]["target"], "command")

    def test_denied_argument_literal_mode_skips_regex(self) -> None:
        raw = _minimal(
            denied_argument_patterns=[
                {"pattern": "[unclosed", "mode": "literal"}
            ]
        )
        out = ks.normalize_config(raw)
        self.assertEqual(out["denied_argument_patterns"][0]["mode"], "literal")

    def test_deterministic_dumps_key_order(self) -> None:
        out = ks.normalize_config(_minimal(banned_tools=["b", "a"]))
        text = ks.dumps_normalized(out)
        again = ks.dumps_normalized(json.loads(text))
        self.assertEqual(text, again)
        self.assertTrue(text.endswith("\n"))
        keys = list(json.loads(text).keys())
        self.assertEqual(keys, list(ks.CANONICAL_KEYS))


class NormalizeRejectTests(unittest.TestCase):
    def test_duplicate_dry_run_alias(self) -> None:
        raw = _minimal(dry_run=False)
        raw["dryRun"] = True
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="dup.json")
        msg = ctx.exception.format()
        self.assertIn("dup.json", msg)
        self.assertIn("$.dry_run", msg)
        self.assertIn("$.dryRun", msg)
        self.assertIn("duplicate alias", msg)

    def test_duplicate_tool_denylist_and_tools_deny(self) -> None:
        raw = _minimal(tool_denylist=["Bash"])
        raw["tools"] = {"deny": ["Shell"]}
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="dup-tools.json")
        msg = ctx.exception.format()
        self.assertIn("duplicate alias for tool_denylist", msg)
        self.assertIn("$.tool_denylist", msg)
        self.assertIn("$.tools.deny", msg)

    def test_duplicate_tools_deny_and_denylist(self) -> None:
        raw = _minimal()
        del raw["tool_denylist"]
        raw["tools"] = {"deny": ["A"], "denylist": ["B"]}
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="both.json")
        self.assertIn("duplicate alias", ctx.exception.format())

    def test_duplicate_denied_argument_aliases(self) -> None:
        raw = _minimal(denied_argument_patterns=[])
        raw["deniedArgumentPatterns"] = []
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="dup-args.json")
        self.assertIn("duplicate alias for denied_argument_patterns", ctx.exception.format())

    def test_unknown_top_level_key(self) -> None:
        raw = _minimal()
        raw["unexpected"] = 1
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="unk.json")
        msg = ctx.exception.format()
        self.assertIn("$.unexpected", msg)
        self.assertIn("unknown key", msg)

    def test_unknown_tools_nested_key(self) -> None:
        raw = _minimal()
        del raw["tool_denylist"]
        raw["tools"] = {"deny": [], "allow": []}
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="tools.json")
        self.assertIn("$.tools.allow", ctx.exception.format())

    def test_wrong_type_enabled(self) -> None:
        raw = _minimal(enabled="yes")  # type: ignore[arg-type]
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="type.json")
        msg = ctx.exception.format()
        self.assertIn("$.enabled", msg)
        self.assertIn("boolean", msg)

    def test_wrong_type_banned_tools_item(self) -> None:
        raw = _minimal(banned_tools=[1])  # type: ignore[list-item]
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="list.json")
        self.assertIn("$.banned_tools[0]", ctx.exception.format())

    def test_schema_version_must_be_two(self) -> None:
        raw = _minimal(schema_version=1)
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="ver.json")
        self.assertIn("must be 2", ctx.exception.format())

    def test_invalid_custom_rule_regex(self) -> None:
        raw = _minimal(custom_rules=[{"name": "bad", "pattern": "("}])
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="re.json")
        msg = ctx.exception.format()
        self.assertIn("$.custom_rules[0].pattern", msg)
        self.assertIn("invalid regex", msg)

    def test_invalid_denied_argument_regex(self) -> None:
        raw = _minimal(
            denied_argument_patterns=[{"pattern": "(", "mode": "regex"}]
        )
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="re2.json")
        self.assertIn("$.denied_argument_patterns[0].pattern", ctx.exception.format())

    def test_custom_rule_both_match_and_pattern(self) -> None:
        raw = _minimal(
            custom_rules=[
                {"name": "x", "match": "a", "pattern": "b"}
            ]
        )
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="shape.json")
        self.assertIn("exactly one of match or pattern", ctx.exception.format())

    def test_custom_rule_missing_match_and_pattern(self) -> None:
        raw = _minimal(custom_rules=[{"name": "x"}])
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="shape2.json")
        self.assertIn("exactly one of match or pattern", ctx.exception.format())

    def test_custom_rule_invalid_target(self) -> None:
        raw = _minimal(
            custom_rules=[{"name": "x", "match": "a", "target": "path"}]
        )
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="tgt.json")
        self.assertIn("$.custom_rules[0].target", ctx.exception.format())

    def test_missing_required_key(self) -> None:
        raw = _minimal()
        del raw["banned_paths"]
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config(raw, source="miss.json")
        self.assertIn("$.banned_paths", ctx.exception.format())
        self.assertIn("missing required key", ctx.exception.format())

    def test_non_object_root(self) -> None:
        with self.assertRaises(ks.KillswitchConfigError) as ctx:
            ks.normalize_config([], source="arr.json")
        self.assertIn("must be a JSON object", ctx.exception.format())


class CliContractTests(unittest.TestCase):
    def test_validate_success_silent(self) -> None:
        path = REPO_ROOT / "bundle" / ".ralph" / "killswitch.json"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = ks.main(["validate", str(path)])
        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")

    def test_normalize_prints_json(self) -> None:
        path = REPO_ROOT / "bundle" / ".ralph" / "killswitch.json"
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = ks.main(["normalize", str(path)])
        self.assertEqual(code, 0)
        parsed = json.loads(stdout.getvalue())
        self.assertEqual(parsed["schema_version"], 2)

    def test_validate_unreadable_names_source(self) -> None:
        missing = REPO_ROOT / "bundle" / ".ralph" / "does-not-exist-killswitch.json"
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            code = ks.main(["validate", str(missing)])
        self.assertEqual(code, 1)
        err = stderr.getvalue()
        self.assertIn(str(missing), err)
        self.assertIn("unreadable", err)

    def test_validate_invalid_json_names_source(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text("{not-json", encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                code = ks.main(["validate", str(path)])
            self.assertEqual(code, 1)
            err = stderr.getvalue()
            self.assertIn(str(path), err)
            self.assertIn("invalid JSON", err)

    def test_validate_duplicate_alias_stderr_contract(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ks.json"
            payload = _minimal(dry_run=False)
            payload["dryRun"] = True
            path.write_text(json.dumps(payload), encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                code = ks.main(["validate", str(path)])
            self.assertEqual(code, 1)
            err = stderr.getvalue()
            self.assertIn(str(path), err)
            self.assertIn("$.dry_run", err)
            self.assertIn("$.dryRun", err)


class SchemaPathTests(unittest.TestCase):
    def test_schema_lives_under_schemas_not_root(self) -> None:
        schema = REPO_ROOT / "bundle" / ".ralph" / "schemas" / "killswitch.schema.json"
        legacy = REPO_ROOT / "bundle" / ".ralph" / "killswitch.schema.json"
        self.assertTrue(schema.is_file())
        self.assertGreater(schema.stat().st_size, 0)
        self.assertFalse(legacy.exists())
        doc = json.loads(schema.read_text(encoding="utf-8"))
        self.assertEqual(doc["properties"]["schema_version"]["enum"], [2])


if __name__ == "__main__":
    unittest.main()
