from __future__ import annotations

import sys
from types import SimpleNamespace

from ralph_dashboard import cli


def test_parse_args_defaults(monkeypatch) -> None:
    monkeypatch.setattr(sys, "argv", ["ralph-dashboard"])
    args = cli.parse_args()
    assert args.host == "127.0.0.1"
    assert args.port == 8123


def test_parse_args_with_overrides(monkeypatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        ["ralph-dashboard", "--host", "0.0.0.0", "--port", "9000"],
    )
    args = cli.parse_args()
    assert args.host == "0.0.0.0"
    assert args.port == 9000


def test_main_keyboard_interrupt_closes_server(monkeypatch) -> None:
    args = SimpleNamespace(host="0.0.0.0", port=9000)
    monkeypatch.setattr(cli, "parse_args", lambda: args)
    servers: list["DummyServer"] = []

    class DummyServer:
        def __init__(self, server_address, handler_class) -> None:
            servers.append(self)
            self.server_address = server_address
            self.handler_class = handler_class
            self.closed = False

        def serve_forever(self) -> None:
            raise KeyboardInterrupt

        def server_close(self) -> None:
            self.closed = True

    monkeypatch.setattr(cli, "ThreadingHTTPServer", DummyServer)

    printed: list[str] = []

    def fake_print(*values: object, sep: str = " ", end: str = "\n") -> None:
        printed.append(sep.join(str(value) for value in values))

    monkeypatch.setattr("builtins.print", fake_print)

    cli.main()

    assert servers, "server was not instantiated"
    server = servers[0]
    assert server.server_address == ("0.0.0.0", 9000)
    assert server.closed
    assert any("Stopping server." in line for line in printed)
