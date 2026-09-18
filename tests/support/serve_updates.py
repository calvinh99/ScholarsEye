#!/usr/bin/env python3
"""Loopback-only Sparkle fixture server; the signing key is never served.

Start: python3 tests/support/serve_updates.py
Switch: python3 tests/support/serve_updates.py --set-scenario tampered-archive
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
from urllib.parse import unquote, urlsplit


SCENARIOS = ("good", "no-update", "tampered-archive", "bad-feed", "unavailable")
DEFAULT_FIXTURE = Path(__file__).resolve().parents[2] / "runtime" / "update-test"


def set_scenario(fixture, scenario):
    if scenario not in SCENARIOS:
        raise ValueError("Unknown updater fixture scenario")
    if not (fixture / "fixture.json").is_file():
        raise ValueError("Prepare the updater fixtures first")
    temporary = fixture / "scenario.tmp"
    temporary.write_text(scenario + "\n", encoding="utf-8")
    temporary.replace(fixture / "scenario.txt")


def resolve_request(fixture, request_target):
    """Return only one explicitly prepared public fixture file, never a directory."""
    scenario = (fixture / "scenario.txt").read_text(encoding="utf-8").strip()
    if scenario not in SCENARIOS:
        raise ValueError("Unknown updater fixture scenario")
    if scenario == "unavailable":
        return None
    filename = unquote(urlsplit(request_target).path)
    # Flat allowlist also rejects traversal, encoded slashes, and private keys.
    if not filename.startswith("/") or "/" in filename[1:] or "\\" in filename:
        return None
    filename = filename[1:]
    if not filename or filename.startswith("."):
        return None
    public_root = (fixture / "server" / scenario).resolve()
    candidate = public_root / filename
    if candidate.suffix.lower() not in (".xml", ".zip", ".html", ".md", ".txt"):
        return None
    if not candidate.is_file() or candidate.is_symlink() or candidate.resolve().parent != public_root:
        return None
    return candidate


def handler_for(fixture):
    class UpdateHandler(BaseHTTPRequestHandler):
        server_version = "ScholarsEyeUpdaterFixture/1"

        def do_HEAD(self):
            self.respond(send_body=False)

        def do_GET(self):
            self.respond(send_body=True)

        def respond(self, send_body):
            try:
                path = resolve_request(fixture, self.path)
            except (OSError, ValueError):
                self.send_error(503, "Fixture scenario unavailable")
                return
            if path is None:
                self.send_error(404, "Fixture not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
            self.send_header("Content-Length", str(path.stat().st_size))
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.end_headers()
            if send_body:
                try:
                    with path.open("rb") as source:
                        while True:
                            chunk = source.read(128 * 1024)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # A canceled update download is an expected test action.

    return UpdateHandler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--port", type=int)
    parser.add_argument("--set-scenario", choices=SCENARIOS)
    args = parser.parse_args()
    fixture = args.fixture.resolve()
    if args.set_scenario:
        set_scenario(fixture, args.set_scenario)
        print("Updater fixture scenario: " + args.set_scenario)
        return
    settings = json.loads((fixture / "fixture.json").read_text(encoding="utf-8"))
    port = args.port if args.port is not None else settings["port"]
    if port != settings["port"]:
        parser.error("Port must match the URL compiled into the prepared test applications")
    server = ThreadingHTTPServer(("127.0.0.1", port), handler_for(fixture))
    server.daemon_threads = True
    print("Updater test server: http://127.0.0.1:{}/appcast.xml".format(port), flush=True)
    print("Switch scenarios with --set-scenario; no private key is exposed.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
