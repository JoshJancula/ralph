from __future__ import annotations

import io
import json
import threading
from functools import partial
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Iterator
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import urlopen

import pytest

from ralph_dashboard import handler, paths


@pytest.fixture
def allowed_root(monkeypatch, tmp_path: Path) -> Path:
    root = tmp_path / "artifacts"
    root.mkdir()
    roots = {"artifacts": root}
    monkeypatch.setattr(paths, "ALLOWED_ROOTS", roots)
    monkeypatch.setattr(handler, "ALLOWED_ROOTS", roots)
    return root


@pytest.fixture
def server_url(allowed_root: Path) -> Iterator[str]:
    handler_class = partial(handler.DashboardHandler, directory=str(paths.STATIC_DIR))
    server = ThreadingHTTPServer(("localhost", 0), handler_class)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    try:
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


def build_url(base: str, path: str, params: dict[str, str]) -> str:
    query = urlencode(params)
    return f"{base}{path}?{query}"


def read_json(url: str) -> dict[str, object]:
    with urlopen(url) as response:
        return json.load(response)


def read_error_payload(exc: HTTPError) -> dict[str, object]:
    body = exc.read().decode("utf-8")
    return json.loads(body)


def test_list_root_success(server_url: str, allowed_root: Path) -> None:
    directory = allowed_root / "folder"
    directory.mkdir()
    (directory / "child.txt").write_text("child")
    (allowed_root / "root.txt").write_text("root")
    nested = directory / "nested"
    nested.mkdir()

    url = build_url(server_url, "/api/list", {"root": "artifacts", "path": ""})
    payload = read_json(url)

    assert payload["root"] == "artifacts"
    assert payload["path"] == "."
    assert payload["parent"] == ""
    entries = payload["entries"]
    names = [entry["name"] for entry in entries]
    assert names == ["folder", "root.txt"]
    assert entries[0]["type"] == "directory"

    nested_url = build_url(
        server_url,
        "/api/list",
        {"root": "artifacts", "path": "folder/nested"},
    )
    nested_payload = read_json(nested_url)
    assert nested_payload["path"] == "folder/nested"
    assert nested_payload["parent"] == "folder"


def test_list_missing_path_returns_error(server_url: str) -> None:
    url = build_url(server_url, "/api/list", {"root": "artifacts", "path": "missing"})
    with pytest.raises(HTTPError) as excinfo:
        urlopen(url)

    assert excinfo.value.code == 400
    payload = read_error_payload(excinfo.value)
    assert "path does not exist" in payload["error"]


def test_list_file_instead_of_directory(server_url: str, allowed_root: Path) -> None:
    file_path = allowed_root / "file.txt"
    file_path.write_text("data")
    url = build_url(server_url, "/api/list", {"root": "artifacts", "path": "file.txt"})
    with pytest.raises(HTTPError) as excinfo:
        urlopen(url)

    payload = read_error_payload(excinfo.value)
    assert "path is not a directory" in payload["error"]


def test_file_api_returns_contents(server_url: str, allowed_root: Path) -> None:
    file_path = allowed_root / "file.txt"
    file_path.write_text("content")

    base_url = build_url(server_url, "/api/file", {"root": "artifacts", "path": "file.txt"})
    payload = read_json(base_url)
    assert payload["content"] == "content"
    assert payload["size"] == 7
    assert payload["offset"] == 0
    assert payload["next_offset"] == 7
    assert payload["path"] == "file.txt"

    partial_url = build_url(
        server_url, "/api/file", {"root": "artifacts", "path": "file.txt", "offset": "2"}
    )
    partial_payload = read_json(partial_url)
    assert partial_payload["content"] == "ntent"

    clamped_url = build_url(
        server_url,
        "/api/file",
        {"root": "artifacts", "path": "file.txt", "offset": "999"},
    )
    clamped_payload = read_json(clamped_url)
    assert clamped_payload["content"] == ""
    assert clamped_payload["offset"] == 7
    assert clamped_payload["next_offset"] == 7


def test_file_api_invalid_offset(server_url: str) -> None:
    url = build_url(
        server_url,
        "/api/file",
        {"root": "artifacts", "path": "file.txt", "offset": "abc"},
    )
    with pytest.raises(HTTPError) as excinfo:
        urlopen(url)

    payload = read_error_payload(excinfo.value)
    assert "offset must be an integer" in payload["error"]


def test_file_api_directory_instead_of_file(server_url: str, allowed_root: Path) -> None:
    directory = allowed_root / "dir"
    directory.mkdir()
    url = build_url(server_url, "/api/file", {"root": "artifacts", "path": "dir"})
    with pytest.raises(HTTPError) as excinfo:
        urlopen(url)

    payload = read_error_payload(excinfo.value)
    assert "path is not a file" in payload["error"]


def test_file_api_unknown_root_returns_error(server_url: str) -> None:
    url = build_url(
        server_url,
        "/api/file",
        {"root": "missing", "path": "file.txt", "offset": "0"},
    )
    with pytest.raises(HTTPError) as excinfo:
        urlopen(url)

    payload = read_error_payload(excinfo.value)
    assert "unknown root" in payload["error"]


def test_static_fallback_serves_dashboard(server_url: str) -> None:
    with urlopen(f"{server_url}/") as response:
        assert response.status == 200
        text = response.read().decode("utf-8")
    assert "<title>Ralph Dashboard</title>" in text


def test_static_file_served_from_stylesheet(server_url: str) -> None:
    with urlopen(f"{server_url}/styles.css") as response:
        assert response.status == 200
        content_type = response.getheader("Content-Type", "")
        assert "text/css" in content_type


def test_write_json_sets_status_and_body() -> None:
    class DummyHandler:
        def __init__(self) -> None:
            self.wfile = io.BytesIO()
            self.headers: list[tuple[str, str]] = []
            self.response_status: HTTPStatus | None = None

        def send_response(self, status: HTTPStatus) -> None:
            self.response_status = status

        def send_header(self, name: str, value: str) -> None:
            self.headers.append((name, value))

        def end_headers(self) -> None:
            self.headers.append(("end", ""))

    dummy = DummyHandler()
    payload = {"state": "ok"}

    handler.DashboardHandler.write_json(dummy, HTTPStatus.ACCEPTED, payload)

    assert dummy.response_status == HTTPStatus.ACCEPTED
    assert ("Content-Type", "application/json; charset=utf-8") in dummy.headers
    assert ("Cache-Control", "no-store") in dummy.headers
    length_header = next(value for name, value in dummy.headers if name == "Content-Length")
    assert int(length_header) == len(dummy.wfile.getvalue())
    body = json.loads(dummy.wfile.getvalue().decode("utf-8"))
    assert body == payload
