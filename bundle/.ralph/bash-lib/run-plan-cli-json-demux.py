#!/usr/bin/env python3
"""Read newline-delimited JSON from stdin; print human-readable text lines; write first session id to file.

Argv: <mode> <session_id_file>
mode: claude | cursor | codex | opencode
"""
import json
import os
import sys
from typing import Any, List, Optional


def session_id_from(obj: Any, mode: str) -> Optional[str]:
    if isinstance(obj, dict):
        if mode == "claude":
            for k, v in obj.items():
                if k == "session_id" and isinstance(v, str) and v.strip():
                    return v.strip()
                n = session_id_from(v, mode)
                if n:
                    return n
        elif mode == "cursor":
            for k, v in obj.items():
                kl = k.lower()
                if kl in {"session_id", "chat_id", "thread_id"} and isinstance(v, str) and v.strip():
                    return v.strip()
                n = session_id_from(v, mode)
                if n:
                    return n
        elif mode == "opencode":
            for k in ("session_id", "sessionId", "chat_id", "id"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("thread_id", "threadId"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("payload", "result", "data"):
                if k in obj:
                    n = session_id_from(obj.get(k), mode)
                    if n:
                        return n
        else:
            for k in ("session_id", "sessionId", "chat_id", "id"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("thread_id", "threadId"):
                v = obj.get(k)
                if isinstance(v, (str, int)) and str(v).strip():
                    return str(v).strip()
            for k in ("payload", "result", "data"):
                if k in obj:
                    n = session_id_from(obj.get(k), mode)
                    if n:
                        return n
    elif isinstance(obj, list):
        for i in obj:
            n = session_id_from(i, mode)
            if n:
                return n
    return None


def extract_text(obj: Any, mode: str) -> List[str]:
    out: List[str] = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower()
            if kl in {"text", "content", "message", "output", "final"} and isinstance(v, str):
                out.append(v)
            out.extend(extract_text(v, mode))
    elif isinstance(obj, list):
        for i in obj:
            out.extend(extract_text(i, mode))
    elif isinstance(obj, str) and mode == "codex":
        out.append(obj)
    return out


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "claude"
    path = sys.argv[2] if len(sys.argv) > 2 else ""
    sid: Optional[str] = None
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            print(line)
            continue
        if sid is None and path:
            sid = session_id_from(o, mode)
        texts = extract_text(o, mode)
        if texts:
            for t in texts:
                t = t.strip()
                if t:
                    print(t)
        else:
            print(line)
    if sid and path:
        try:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(sid + "\n")
        except OSError:
            pass


if __name__ == "__main__":
    main()
