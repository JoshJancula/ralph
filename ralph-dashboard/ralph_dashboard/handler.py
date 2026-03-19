from __future__ import annotations

import json
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .paths import ALLOWED_ROOTS, REPO_ROOT, resolve_allowed_path

EMPTY_ALLOWLIST_ROOTS = {
    "docs",
    "cursor_skills",
    "claude_skills",
    "codex_skills",
}

WRITEABLE_ROOTS: set[str] = {
    "plans",
    "cursor_agents",
    "claude_agents",
    "codex_agents",
    "cursor_skills",
    "claude_skills",
    "codex_skills",
}
WRITEABLE_EXTENSIONS = (
    ".json",
    ".md",
    ".mdc",
    ".toml",
)


class DashboardHandler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/list":
            self.handle_list(parsed.query)
            return
        if parsed.path == "/api/file":
            self.handle_file(parsed.query)
            return
        if parsed.path == "/api/template":
            self.handle_template(parsed.query)
            return
        super().do_GET()

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def handle_list(self, query: str) -> None:
        params = parse_qs(query)
        root_key = params.get("root", [""])[0]
        raw_path = params.get("path", [""])[0]

        allowed_base = ALLOWED_ROOTS.get(root_key)
        if (
            root_key in EMPTY_ALLOWLIST_ROOTS
            and allowed_base is not None
            and not allowed_base.exists()
        ):
            if raw_path not in ("", "."):
                self.write_json(
                    HTTPStatus.BAD_REQUEST,
                    {"error": "path does not exist"},
                )
                return
            self.write_json(
                HTTPStatus.OK,
                {
                    "root": root_key,
                    "path": ".",
                    "parent": "",
                    "entries": [],
                },
            )
            return

        if root_key == "docs":
            docs_root = ALLOWED_ROOTS["docs"]
            if not docs_root.exists() and raw_path in ("", "."):
                self.write_json(
                    HTTPStatus.OK,
                    {
                        "root": "docs",
                        "path": ".",
                        "parent": "",
                        "entries": [],
                    },
                )
                return

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

        base = ALLOWED_ROOTS[root_key].resolve()

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
                "path": target.relative_to(base).as_posix(),
                "content": content,
                "size": size,
                "offset": offset,
                "next_offset": size,
            },
        )

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/file":
            self.handle_file_write()
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def handle_file_write(self) -> None:
        length_raw = self.headers.get("Content-Length", "0")
        try:
            length = max(0, int(length_raw))
        except ValueError:
            length = 0
        body = self.rfile.read(length).decode("utf-8")
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON body"})
            return

        root_key = payload.get("root", "")
        raw_path = payload.get("path", "")
        content = payload.get("content", "")
        if root_key not in WRITEABLE_ROOTS:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "root is not writable"})
            return
        if not raw_path:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "path is required"})
            return
        if not self._is_allowed_extension(raw_path):
            self.write_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "file extension is not allowed for writing"},
            )
            return

        try:
            target = resolve_allowed_path(root_key, raw_path)
        except ValueError as exc:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        if target.exists() and target.is_dir():
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "path is a directory"})
            return

        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(str(content), encoding="utf-8")
        except OSError as exc:
            self.write_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})
            return

        size = target.stat().st_size
        base = ALLOWED_ROOTS[root_key].resolve()
        self.write_json(
            HTTPStatus.OK,
            {
                "root": root_key,
                "path": target.relative_to(base).as_posix(),
                "content": str(content),
                "size": size,
                "offset": 0,
                "next_offset": size,
            },
        )

    def _is_allowed_extension(self, raw_path: str) -> bool:
        lowered = raw_path.lower()
        return any(lowered.endswith(ext) for ext in WRITEABLE_EXTENSIONS)

    def handle_template(self, query: str) -> None:
        params = parse_qs(query)
        name = (params.get("name", [""])[0] or "orchestration").lower()
        if name not in {"orchestration", "plan"}:
            self.write_json(
                HTTPStatus.BAD_REQUEST,
                {"error": f"unknown template {name}"},
            )
            return
        template_map = {
            "orchestration": REPO_ROOT / ".ralph" / "orchestration.template.json",
            "plan": REPO_ROOT / ".ralph" / "plan.template",
        }
        template_path = template_map[name]
        if not template_path.exists():
            self.write_json(
                HTTPStatus.NOT_FOUND,
                {"error": "template not found"},
            )
            return
        try:
            content = template_path.read_text(encoding="utf-8")
        except OSError as exc:
            self.write_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": str(exc)},
            )
            return
        self.write_json(
            HTTPStatus.OK,
            {
                "name": name,
                "content": content,
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
