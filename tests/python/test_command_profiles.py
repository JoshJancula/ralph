#!/usr/bin/env python3
"""Unit tests for command_profiles.py."""

from __future__ import annotations

import json
import multiprocessing
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ralph_script_loader import load_ralph_script

cp = load_ralph_script("command_profiles")


def _worker_record(args: tuple[str, str, str, int]) -> bool:
    """Record one observation in a child process (module reloaded by path)."""
    state_root_s, fingerprint, command, duration_ms = args
    # Re-load in the child so sys.path and module state are self-contained.
    child_sys_path = str(Path(__file__).parent)
    if child_sys_path not in sys.path:
        sys.path.insert(0, child_sys_path)
    from ralph_script_loader import load_ralph_script as load

    mod = load("command_profiles")
    entry = mod.record_observation(
        Path(state_root_s),
        fingerprint,
        command,
        duration_ms,
    )
    return entry is not None


class CommandProfilesTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.state_root = Path(self.tmp.name) / ".ralph-workspace"
        self.state_root.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()


class TestFirstWriteAndMedian(CommandProfilesTestCase):
    def test_first_write_creates_file(self) -> None:
        path = cp.profiles_path(self.state_root)
        self.assertFalse(path.exists())
        entry = cp.record_observation(
            self.state_root,
            "fp-aaa",
            "bash scripts/run-bats.sh",
            1500,
        )
        self.assertIsNotNone(entry)
        self.assertTrue(path.is_file())
        store = json.loads(path.read_text(encoding="utf-8"))
        self.assertIn("fp-aaa", store["entries"])
        saved = store["entries"]["fp-aaa"]
        self.assertEqual(saved["fingerprint"], "fp-aaa")
        self.assertEqual(saved["observation_count"], 1)
        self.assertEqual(saved["durations_ms"], [1500])
        self.assertEqual(saved["median_ms"], 1500)
        self.assertFalse(saved["long_running"])
        self.assertTrue(saved["last_seen"].endswith("Z"))
        self.assertIn("run-bats", saved["command"])
        self.assertFalse(cp.is_long_running(self.state_root, "fp-aaa"))

    def test_second_observation_appends_and_recomputes_median(self) -> None:
        cp.record_observation(self.state_root, "fp-bbb", "pytest tests", 1000)
        entry = cp.record_observation(self.state_root, "fp-bbb", "pytest tests", 3000)
        self.assertIsNotNone(entry)
        self.assertEqual(entry["observation_count"], 2)
        self.assertEqual(entry["durations_ms"], [1000, 3000])
        self.assertEqual(entry["median_ms"], 2000)

        # Odd count median is the middle element.
        entry = cp.record_observation(self.state_root, "fp-bbb", "pytest tests", 9000)
        self.assertEqual(entry["durations_ms"], [1000, 3000, 9000])
        self.assertEqual(entry["median_ms"], 3000)


class TestDurationCap(CommandProfilesTestCase):
    def test_duration_list_capped_at_10(self) -> None:
        for i in range(12):
            cp.record_observation(
                self.state_root,
                "fp-cap",
                "npm test",
                (i + 1) * 100,
            )
        entry = cp.get_entry(self.state_root, "fp-cap")
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertEqual(len(entry["durations_ms"]), 10)
        self.assertEqual(entry["durations_ms"], [300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200])
        self.assertEqual(entry["observation_count"], 12)
        # Median of the retained window (even): mean of 700 and 800.
        self.assertEqual(entry["median_ms"], 750)


class TestCorruptStore(CommandProfilesTestCase):
    def test_corrupt_json_treated_as_empty(self) -> None:
        path = cp.profiles_path(self.state_root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{not-valid-json", encoding="utf-8")
        store = cp.read_store(self.state_root)
        self.assertEqual(store["entries"], {})

        entry = cp.record_observation(
            self.state_root,
            "fp-recover",
            "echo hi",
            50,
        )
        self.assertIsNotNone(entry)
        self.assertEqual(entry["observation_count"], 1)
        reloaded = json.loads(path.read_text(encoding="utf-8"))
        self.assertIn("fp-recover", reloaded["entries"])

    def test_truncated_json_treated_as_empty(self) -> None:
        path = cp.profiles_path(self.state_root)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"schema_version": 1, "entries": {"fp":', encoding="utf-8")
        self.assertEqual(cp.read_store(self.state_root)["entries"], {})
        self.assertIsNone(cp.get_entry(self.state_root, "fp"))
        self.assertFalse(cp.is_long_running(self.state_root, "fp"))


class TestSilentLockDrop(CommandProfilesTestCase):
    def test_contested_nonblocking_lock_drops(self) -> None:
        lock_path = cp.profiles_lock_path(self.state_root)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with open(lock_path, "a+", encoding="utf-8") as held:
            import fcntl

            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            dropped = cp.try_locked_run(self.state_root, lambda: "should-not-run")
            self.assertIsNone(dropped)
            fcntl.flock(held.fileno(), fcntl.LOCK_UN)


class TestConcurrentWriters(CommandProfilesTestCase):
    def test_concurrent_writers_preserve_every_fingerprint(self) -> None:
        worker_count = 8
        jobs = [
            (
                str(self.state_root),
                f"fp-concurrent-{i:02d}",
                f"bash scripts/run-bats.sh --filter worker-{i}",
                1000 + i * 10,
            )
            for i in range(worker_count)
        ]
        # fork is unreliable with some macOS+Python combos; spawn is safer.
        ctx = multiprocessing.get_context("spawn")
        with ctx.Pool(processes=worker_count) as pool:
            results = pool.map(_worker_record, jobs)
        self.assertTrue(all(results), f"some writers failed: {results}")

        path = cp.profiles_path(self.state_root)
        self.assertTrue(path.is_file())
        raw = path.read_text(encoding="utf-8")
        store = json.loads(raw)  # must be valid JSON
        entries = store["entries"]
        for i in range(worker_count):
            fp = f"fp-concurrent-{i:02d}"
            self.assertIn(fp, entries)
            self.assertEqual(entries[fp]["fingerprint"], fp)
            self.assertEqual(entries[fp]["observation_count"], 1)
            self.assertEqual(entries[fp]["durations_ms"], [1000 + i * 10])


class TestRedaction(CommandProfilesTestCase):
    def test_sensitive_assignment_redacted_in_display(self) -> None:
        entry = cp.record_observation(
            self.state_root,
            "fp-secret",
            "TOKEN=super-secret-value bash scripts/run-bats.sh",
            10,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertIn("TOKEN=[REDACTED]", entry["command"])
        self.assertNotIn("super-secret-value", entry["command"])


class TestPromoteDemote(CommandProfilesTestCase):
    def test_single_90s_observation_promotes(self) -> None:
        self.assertEqual(cp.LONG_RUNNING_THRESHOLD_MS, 60000)
        entry = cp.record_observation(
            self.state_root,
            "fp-promote",
            "bash scripts/run-bats.sh",
            90000,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertTrue(entry["long_running"])
        self.assertTrue(cp.is_long_running(self.state_root, "fp-promote"))
        self.assertIn("promoted_at", entry)
        self.assertTrue(str(entry["promoted_at"]).endswith("Z"))

    def test_single_5s_observation_does_not_promote(self) -> None:
        entry = cp.record_observation(
            self.state_root,
            "fp-fast",
            "echo hi",
            5000,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertFalse(entry["long_running"])
        self.assertNotIn("promoted_at", entry)
        self.assertFalse(cp.is_long_running(self.state_root, "fp-fast"))

    def test_90s_then_5s_then_5s_demotes(self) -> None:
        self.assertEqual(cp.MIN_OBSERVATIONS_FOR_DEMOTION, 2)
        cp.record_observation(self.state_root, "fp-demote", "npm test", 90000)
        self.assertTrue(cp.is_long_running(self.state_root, "fp-demote"))

        cp.record_observation(self.state_root, "fp-demote", "npm test", 5000)
        cp.record_observation(self.state_root, "fp-demote", "npm test", 5000)
        entry = cp.get_entry(self.state_root, "fp-demote")
        self.assertIsNotNone(entry)
        assert entry is not None
        # Median of [90000, 5000, 5000] is 5000, below the threshold.
        self.assertEqual(entry["median_ms"], 5000)
        self.assertFalse(entry["long_running"])
        self.assertIn("promoted_at", entry)
        self.assertIn("demoted_at", entry)
        self.assertTrue(str(entry["demoted_at"]).endswith("Z"))

    def test_stays_promoted_while_median_above_threshold(self) -> None:
        cp.record_observation(self.state_root, "fp-stay", "pytest tests", 90000)
        cp.record_observation(self.state_root, "fp-stay", "pytest tests", 70000)
        entry = cp.record_observation(
            self.state_root,
            "fp-stay",
            "pytest tests",
            80000,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        # Median of [90000, 70000, 80000] is 80000, still above threshold.
        self.assertEqual(entry["median_ms"], 80000)
        self.assertTrue(entry["long_running"])
        self.assertIn("promoted_at", entry)
        self.assertNotIn("demoted_at", entry)
        self.assertTrue(cp.is_long_running(self.state_root, "fp-stay"))


class TestNeverBackgroundDenylist(CommandProfilesTestCase):
    """Denylisted shapes are recorded but never injection-eligible."""

    def _record_slow(self, fingerprint: str, command: str) -> dict:
        entry = cp.record_observation(
            self.state_root,
            fingerprint,
            command,
            90000,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertTrue(entry["long_running"])
        return entry

    def test_denylist_dependency_installs_recorded_not_eligible(self) -> None:
        cases = [
            ("fp-npm-i", "npm install"),
            ("fp-npm-ci", "npm ci"),
            ("fp-pnpm-i", "pnpm install"),
            ("fp-yarn-i", "yarn install"),
            ("fp-pip-i", "pip install requests"),
            ("fp-cargo-f", "cargo fetch"),
            ("fp-bundle-i", "bundle install"),
            ("fp-gomod", "go mod download"),
        ]
        for fingerprint, command in cases:
            with self.subTest(command=command):
                self._record_slow(fingerprint, command)
                self.assertTrue(cp.is_never_background(command, self.state_root))
                self.assertFalse(
                    cp.is_injection_eligible(self.state_root, fingerprint, command)
                )
                # Recording still landed in the store.
                self.assertIsNotNone(cp.get_entry(self.state_root, fingerprint))

    def test_denylist_git_mutating_recorded_not_eligible(self) -> None:
        for sub in ("clone", "pull", "fetch", "push", "merge", "rebase", "checkout"):
            command = f"git {sub}"
            fingerprint = f"fp-git-{sub}"
            with self.subTest(command=command):
                self._record_slow(fingerprint, command)
                self.assertTrue(cp.is_never_background(command, self.state_root))
                self.assertFalse(
                    cp.is_injection_eligible(self.state_root, fingerprint, command)
                )

    def test_denylist_migrate_seed_deploy_publish_release(self) -> None:
        cases = [
            ("fp-migrate", "python manage.py migrate"),
            ("fp-seed", "rails db:seed"),
            ("fp-deploy", "./scripts/deploy.sh staging"),
            ("fp-publish", "npm publish"),
            ("fp-release", "gh release create v1.0.0"),
        ]
        for fingerprint, command in cases:
            with self.subTest(command=command):
                self._record_slow(fingerprint, command)
                self.assertTrue(cp.is_never_background(command, self.state_root))
                self.assertFalse(
                    cp.is_injection_eligible(self.state_root, fingerprint, command)
                )

    def test_denylist_background_operator_and_run_in_background_flag(self) -> None:
        bg_cmd = "sleep 90 &"
        self.assertTrue(cp.is_never_background(bg_cmd, self.state_root))
        # Already-backgrounded tool input is denylisted even for a normal command.
        normal = "bash scripts/run-bats.sh"
        self._record_slow("fp-bg-flag", normal)
        self.assertTrue(
            cp.is_never_background(normal, self.state_root, run_in_background=True)
        )
        self.assertFalse(
            cp.is_injection_eligible(
                self.state_root,
                "fp-bg-flag",
                normal,
                run_in_background=True,
            )
        )

    def test_never_background_file_custom_regex_honored(self) -> None:
        denylist = cp.never_background_path(self.state_root)
        denylist.parent.mkdir(parents=True, exist_ok=True)
        denylist.write_text(
            "# project-specific\nmy-slow-suite\\b\n",
            encoding="utf-8",
        )
        command = "bash scripts/my-slow-suite.sh --full"
        self._record_slow("fp-custom", command)
        self.assertTrue(cp.is_never_background(command, self.state_root))
        self.assertFalse(
            cp.is_injection_eligible(self.state_root, "fp-custom", command)
        )

    def test_non_denylist_long_running_is_injection_eligible(self) -> None:
        command = "bash scripts/run-bats.sh"
        self._record_slow("fp-ok", command)
        self.assertFalse(cp.is_never_background(command, self.state_root))
        self.assertTrue(cp.is_injection_eligible(self.state_root, "fp-ok", command))


class TestInflightPairing(CommandProfilesTestCase):
    """Pre/post duration pairing for runtimes without a payload duration field."""

    def test_mark_and_complete_records_duration(self) -> None:
        command = "bash scripts/run-bats.sh"
        started = cp._utc_now_ms()
        self.assertTrue(
            cp.mark_inflight_start(
                self.state_root,
                command,
                "inv-1",
                started_at_ms=started,
            )
        )
        marker_path = cp.inflight_dir(self.state_root) / "id.inv-1.json"
        self.assertTrue(marker_path.is_file())
        entry = cp.complete_inflight(
            self.state_root,
            invocation_id="inv-1",
            ended_at_ms=started + 2500,
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertEqual(entry["durations_ms"], [2500])
        self.assertFalse(marker_path.exists())

    def test_concurrent_identical_commands_key_on_invocation_id(self) -> None:
        command = "bash scripts/run-bats.sh"
        t0 = cp._utc_now_ms()
        self.assertTrue(
            cp.mark_inflight_start(
                self.state_root, command, "inv-a", started_at_ms=t0
            )
        )
        self.assertTrue(
            cp.mark_inflight_start(
                self.state_root, command, "inv-b", started_at_ms=t0 + 100
            )
        )
        entry_b = cp.complete_inflight(
            self.state_root,
            invocation_id="inv-b",
            ended_at_ms=t0 + 4100,
        )
        entry_a = cp.complete_inflight(
            self.state_root,
            invocation_id="inv-a",
            ended_at_ms=t0 + 1100,
        )
        self.assertIsNotNone(entry_b)
        self.assertIsNotNone(entry_a)
        assert entry_a is not None
        # Both observations retained; order depends on completion order.
        self.assertEqual(sorted(entry_a["durations_ms"]), [1100, 4000])

    def test_expire_stale_inflight_older_than_one_hour(self) -> None:
        command = "bash scripts/run-bats.sh"
        now = cp._utc_now_ms()
        old = now - (cp.INFLIGHT_MAX_AGE_SECONDS * 1000) - 1
        directory = cp.inflight_dir(self.state_root)
        directory.mkdir(parents=True, exist_ok=True)
        stale_path = directory / "id.stale.json"
        fresh_path = directory / "id.fresh.json"
        # Write markers directly so expire is tested in isolation (mark_inflight_start
        # also expires, which would reclaim a synthetic-old marker mid-setup).
        stale_path.write_text(
            json.dumps(
                {
                    "fingerprint": "fp-stale",
                    "command": command,
                    "invocation_id": "stale",
                    "started_at_ms": old,
                    "started_at": "2020-01-01T00:00:00Z",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        fresh_path.write_text(
            json.dumps(
                {
                    "fingerprint": "fp-fresh",
                    "command": command,
                    "invocation_id": "fresh",
                    "started_at_ms": now - 1000,
                    "started_at": "2020-01-01T00:00:00Z",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        removed = cp.expire_stale_inflight(self.state_root, now_ms=now)
        self.assertGreaterEqual(removed, 1)
        self.assertFalse(stale_path.exists())
        self.assertTrue(fresh_path.exists())
        self.assertIsNone(
            cp.complete_inflight(
                self.state_root,
                invocation_id="stale",
                ended_at_ms=now,
            )
        )


if __name__ == "__main__":
    unittest.main()
