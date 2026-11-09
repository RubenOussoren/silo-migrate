#!/usr/bin/env -S python3 -I
"""Project page: one project at a glance, and the only place new files are labelled.

Reached only through term-llm's signed-in proxy, by the engineer. It shows file names, so it never
serves an agent. It reuses the Runs widget's plumbing and never touches a project's data itself:
everything goes through `silo-migrate-control data WS`, in bin/data_tools.py.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import socketserver
import stat
import sys
import time
from urllib.parse import parse_qs, urlsplit
from http.server import BaseHTTPRequestHandler

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("silo_runs_widget", HERE.parent / "runs" / "server.py")
runs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runs)

Refused = runs.Refused
WORKSPACE = runs.WORKSPACE
DATASET = re.compile(r"dataset-[0-9a-f]{32}\Z")
MAX_BODY = 128 * 1024  # a label lists the files it covers
MAX_FILES = 400
STATIC = {"/": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8"), "/tokens.css": ("tokens.css", "text/css; charset=utf-8")}
# Varnish's own font files, so that the page matches without a second copy of them.
FONTS = {"/fonts/Geist-Variable.woff2": "Geist-Variable.woff2", "/fonts/GeistMono-Variable.woff2": "GeistMono-Variable.woff2"}
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
           "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"}


def data(control, workspace, request, timeout=90):
    if not isinstance(workspace, str) or not WORKSPACE.fullmatch(workspace):
        raise Refused("STANDARD_ARGUMENTS_INVALID")
    return runs.control_call(control, ["data", workspace], timeout=timeout, send=json.dumps(request).encode("utf-8"))


def intake_folder(control, base):
    """Where `silo intake` puts drop folders: beside the installed control shim, as data_tools works it out."""
    shim = Path(control)
    if shim.name == "silo-migrate-control" and shim.parent.name == "bin" and (shim.parent.parent / "intake").is_dir():
        return shim.parent.parent / "intake"
    return base.parent / "intake"


def project_names(base, intake):
    """Every project with a workspace or a drop folder (a new project has only the drop folder)."""
    names = set()
    for folder in (base, intake):
        try:
            with os.scandir(folder) as entries:
                names |= {entry.name for entry in entries if WORKSPACE.fullmatch(entry.name) and entry.is_dir(follow_symlinks=False)}
        except OSError:
            continue
    return sorted(names)


SUMMARY_SECONDS = 20
_summary = {"at": 0.0, "value": None}


def summary(base, control):
    """For the edge tab: projects with files or data waiting for a label. Cached briefly: every open
    chat page asks for it."""
    if _summary["value"] is not None and time.monotonic() - _summary["at"] < SUMMARY_SECONDS:
        return _summary["value"]
    waiting = []
    for name in project_names(base, intake_folder(control, base)):
        try:
            view = data(control, name, {"op": "deliveries"}, timeout=20)
            count = len(view["unlabelled_files"]) + len(view["unlabelled_data"]) + len(view.get("not_ready_files") or [])
        except Exception:  # noqa: BLE001 - one project's trouble mustn't hide the others
            continue
        if count:
            waiting.append({"workspace": name, "files": count})
    _summary.update(at=time.monotonic(), value={"waiting": len(waiting), "latest": waiting[:8]})
    return _summary["value"]


def label(control, body):
    request = {"op": "delivery_label", "kind": body.get("kind"), "by": runs.reviewer_name()}
    if "dataset_id" in body:
        if not isinstance(body["dataset_id"], str) or not DATASET.fullmatch(body["dataset_id"]):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        request["dataset_id"] = body["dataset_id"]
    else:
        files = body.get("files")
        if not isinstance(files, list) or not 0 < len(files) <= MAX_FILES or not all(isinstance(item, dict) for item in files):
            raise Refused("STANDARD_ARGUMENTS_INVALID")
        # What identifies each file, as the page was shown it: data_tools checks it's still the same.
        request["files"] = [{key: item.get(key) for key in ("path", "bytes", "mtime_ns", "ctime_ns", "ino")} for item in files]
    if body.get("confirm") == "LAUNCH":
        request["confirm"] = "LAUNCH"
    if body.get("replaces_launch") is True:
        request["replaces_launch"] = True
    return data(control, body.get("workspace"), request)


class Handler(BaseHTTPRequestHandler):
    server_version = "silo-project"
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="application/json"):
        payload = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for key, value in HEADERS.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        url = urlsplit(self.path)
        query = {key: value[0] for key, value in parse_qs(url.query).items()}
        control, base = self.server.control, self.server.base
        try:
            if url.path in STATIC:
                name, content_type = STATIC[url.path]
                return self.send(200, (HERE / name).read_bytes(), content_type)
            if url.path in FONTS:
                return self.send(200, (HERE.parent.parent / "extensions/varnish/fonts" / FONTS[url.path]).read_bytes(), "font/woff2")
            if url.path == "/api/projects":
                return self.send(200, {"projects": project_names(base, intake_folder(control, base))})
            if url.path == "/api/summary":
                return self.send(200, summary(base, control))
            if url.path == "/api/files":  # quick: reads only files
                return self.send(200, data(control, query.get("workspace"), {"op": "deliveries"}, timeout=30))
            if url.path == "/api/guide":
                return self.send(200, data(control, query.get("workspace"), {"op": "guide"}))
            return self.send(404, {"error": "STANDARD_NOT_FOUND"})
        except Refused as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001 - never a traceback in term-llm's log
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})

    def do_POST(self):
        # term-llm only forwards same-origin, signed-in POSTs; the custom header and JSON body
        # are a second check that the request came from this page's script.
        try:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if not 0 < length <= MAX_BODY:
                self.close_connection = True
                raise Refused("STANDARD_ARGUMENTS_INVALID", 413 if length > 0 else 400)
            raw = self.rfile.read(length)
            if self.headers.get("X-Silo-Project") != "1" or not (self.headers.get("Content-Type") or "").startswith("application/json"):
                raise Refused("STANDARD_REQUEST_REFUSED", 403)
            body = json.loads(raw)
            if urlsplit(self.path).path != "/api/label" or not isinstance(body, dict):
                raise Refused("STANDARD_ARGUMENTS_INVALID")
            result = label(self.server.control, body)
            _summary["value"] = None  # the tab's count changed
            return self.send(200, result)
        except (ValueError, UnicodeDecodeError):
            return self.send(400, {"error": "STANDARD_ARGUMENTS_INVALID"})
        except Refused as refused:
            return self.send(refused.status, {"error": refused.code})
        except Exception:  # noqa: BLE001
            return self.send(500, {"error": "STANDARD_OPERATION_FAILED"})


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        request, _address = super().get_request()
        return request, ("local", 0)  # http.server expects a (host, port) pair


def main(argv):
    if len(argv) != 2 or not argv[1].startswith("/"):
        raise SystemExit("usage: server.py SOCKET")
    control, base = runs.locate()
    # As in the Runs widget: the socket folder must be ours and private.
    folder = os.lstat(os.path.dirname(argv[1]))
    if not stat.S_ISDIR(folder.st_mode) or folder.st_uid != os.geteuid() or folder.st_mode & 0o077:
        raise SystemExit("project widget: " + os.path.dirname(argv[1]) + " must be a folder owned by this account, mode 0700")
    os.umask(0o077)
    try:
        os.unlink(argv[1])
    except FileNotFoundError:
        pass
    server = Server(argv[1], Handler)
    server.control, server.base = control, base
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv)
