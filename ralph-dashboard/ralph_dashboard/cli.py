from __future__ import annotations

from argparse import ArgumentParser, Namespace
from functools import partial
from http.server import ThreadingHTTPServer

from .handler import DashboardHandler
from .paths import STATIC_DIR


def parse_args() -> Namespace:
    parser = ArgumentParser(description="Local Ralph dashboard server")
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Bind host, defaults to localhost",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8123,
        help="Bind port, defaults to 8123",
    )
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
