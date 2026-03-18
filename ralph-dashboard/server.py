#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from functools import partial
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs, urlparse


REPO_ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = Path(__file__).resolve().parent / "static"
ALLOWED_ROOTS = {
    "plans": REPO_ROOT / ".agents" / "orchestration-plans",
    "artifacts": REPO_ROOT / ".agents" / "artifacts",
    "logs": REPO_ROOT / ".agents" / "logs",
}


def clean_relative_path(raw_path: str) -> Path:
    relative = PurePosixPath(raw_path or ".")
    if relative.is_absolute():
        raise ValueError("absolute paths are not allowed")

    if any(part in {"", ".", ".."} for part in relative.parts if part != "."):
        raise ValueError("path traversal is not allowed")

    normalized = Path(".")
    for part in relative.parts:
        if part != ".":
            normalized /= part
    return normalized


def resolve_allowed_path(root_key: str, raw_path: str) -> Path:
    try:
        base = ALLOWED_ROOTS[root_key].resolve(strict=True)
    except KeyError as exc:
        raise ValueError(f"unknown root: {root_key}") from exc

    target = (base / clean_relative_path(raw_path)).resolve()
    if not target.is_relative_to(base):
        raise ValueError("requested path escapes allowlisted root")
    return target


class DashboardHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/list":
            self.handle_list(parsed.query)
            return
        if parsed.path == "/api/file":
            self.handle_file(parsed.query)
            return
        super().do_GET()

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def handle_list(self, query: str) -> None:
        params = parse_qs(query)
        root_key = params.get("root", [""])[0]
        raw_path = params.get("path", [""])[0]

        try:
            target = resolve_allowed_path(root_key, raw_path)
            if not target.exists():
                raise FileNotFoundError("path does not exist")
            if not target.is_dir():
                raise NotADirectoryError("path is not a directory")
        except (ValueError, FileNotFoundError, NotADirectoryError) as exc:
            self.write_json(
                HTTPStatus.BAD_REQUEST,
                {"error": str(exc)},
            )
            return

        base = ALLOWED_ROOTS[root_key].resolve()
        entries = []
        for child in sorted(
            target.iterdir(),
            key=lambda item: (item.is_file(), item.name.lower()),
        ):
            stat = child.stat()
            entries.append(
                {
                    "name": child.name,
                    "path": child.relative_to(base).as_posix(),
                    "type": "directory" if child.is_dir() else "file",
                    "size": stat.st_size,
                    "mtime": stat.st_mtime,
                }
            )

        relative = "." if target == base else target.relative_to(base).as_posix()
        parent = ""
        if target != base:
            parent_path = target.parent
            parent = "" if parent_path == base else parent_path.relative_to(base).as_posix()

        self.write_json(
            HTTPStatus.OK,
            {
                "root": root_key,
                "path": relative,
                "parent": parent,
                "entries": entries,
            },
        )

    def handle_file(self, query: str) -> None:
        params = parse_qs(query)
        root_key = params.get("root", [""])[0]
        raw_path = params.get("path", [""])[0]
        offset_raw = params.get("offset", ["0"])[0]

        try:
            offset = max(0, int(offset_raw))
        except ValueError:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "offset must be an integer"})
            return

        try:
            target = resolve_allowed_path(root_key, raw_path)
            if not target.exists():
                raise FileNotFoundError("path does not exist")
            if not target.is_file():
                raise IsADirectoryError("path is not a file")
        except (ValueError, FileNotFoundError, IsADirectoryError) as exc:
            self.write_json(
                HTTPStatus.BAD_REQUEST,
                {"error": str(exc)},
            )
            return

        size = target.stat().st_size
        if offset > size:
            offset = size

        with target.open("rb") as handle:
            handle.seek(offset)
            content = handle.read().decode("utf-8", errors="replace")

        self.write_json(
            HTTPStatus.OK,
            {
                "root": root_key,
                "path": target.relative_to(ALLOWED_ROOTS[root_key]).as_posix(),
                "content": content,
                "size": size,
                "offset": offset,
                "next_offset": size,
            },
        )

    def write_json(self, status: HTTPStatus, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local Ralph dashboard server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host, defaults to localhost")
    parser.add_argument("--port", type=int, default=8123, help="Bind port, defaults to 8123")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    handler = partial(DashboardHandler, directory=str(STATIC_DIR))
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"Serving Ralph dashboard on http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
