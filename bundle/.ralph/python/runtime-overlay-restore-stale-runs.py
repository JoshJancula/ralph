#!/usr/bin/env python3
"""Restore stale runtime overlay files from journal."""
import json, os, shutil, sys, time

workspace_root = sys.argv[1]
plan_filter_arg = sys.argv[2]
threshold_seconds = int(sys.argv[3]) if sys.argv[3].isdigit() else 3600
plan_filter = None if not plan_filter_arg else plan_filter_arg
runtime_config_root = os.path.join(workspace_root, ".ralph-workspace", "runtime-config")
if not os.path.isdir(runtime_config_root):
    sys.exit(0)
now = int(time.time())
messages = []
had_errors = False
for plan_dir in sorted(os.listdir(runtime_config_root)):
    plan_path = os.path.join(runtime_config_root, plan_dir)
    if not os.path.isdir(plan_path):
        continue
    journal_dir = os.path.join(plan_path, "journals")
    if not os.path.isdir(journal_dir):
        continue
    for journal_file in sorted(os.listdir(journal_dir)):
        journal_path = os.path.join(journal_dir, journal_file)
        if not os.path.isfile(journal_path):
            continue
        if not journal_file.endswith(".json"):
            continue
        try:
            with open(journal_path) as fh:
                data = json.load(fh)
        except (json.JSONDecodeError, FileNotFoundError):
            messages.append(f"Skipping invalid overlay journal: {journal_path}")
            continue
        journal_plan = data.get("plan_key") or plan_dir
        if plan_filter and journal_plan != plan_filter:
            continue
        if data.get("cleanup_status") == "cleaned":
            continue
        pid = data.get("pid", 0)
        start_time = data.get("start_time", 0)
        pid_alive = True
        if isinstance(pid, int) and pid > 0:
            if pid == os.getpid():
                pid_alive = False
            else:
                try:
                    os.kill(pid, 0)
                except PermissionError:
                    pid_alive = True
                except ProcessLookupError:
                    pid_alive = False
        need_restore = (not pid_alive) or (threshold_seconds >= 0 and start_time and (start_time + threshold_seconds) < now)
        if not need_restore:
            continue
        success = True
        for entry in data.get("mutated_files", []):
            target = entry.get("path")
            backup = entry.get("backup")
            if not target:
                continue
            try:
                if backup and os.path.isfile(backup):
                    dirpath = os.path.dirname(target)
                    if dirpath:
                        os.makedirs(dirpath, exist_ok=True)
                    shutil.copy2(backup, target)
                    os.remove(backup)
                else:
                    if os.path.exists(target):
                        os.remove(target)
                entry["restored"] = True
            except Exception as exc:
                success = False
                messages.append(f"Error restoring {target} from {backup}: {exc}")
                had_errors = True
        for entry in data.get("generated_files", []):
            path = entry.get("path")
            if not path:
                continue
            try:
                if os.path.exists(path):
                    os.remove(path)
                entry["cleaned"] = True
            except Exception as exc:
                success = False
                messages.append(f"Error removing generated overlay file {path}: {exc}")
                had_errors = True
        if success:
            data["cleanup_status"] = "cleaned"
            data["cleanup_time"] = now
            messages.append(f"Restored stale runtime overlay for plan {journal_plan} (journal {journal_file})")
        else:
            had_errors = True
            messages.append(f"Runtime overlay restore incomplete for {journal_path}")
        with open(journal_path, "w") as fh:
            json.dump(data, fh, indent=2)
print("\n".join(messages))
if had_errors:
    sys.exit(1)
