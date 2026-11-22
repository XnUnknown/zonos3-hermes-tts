#!/usr/bin/env python3
"""Lazy front end for the Zonos3 server.

Sits on the public port and costs almost nothing while idle. On the first request it
starts zonos3-server on a private port, waits for the model to load, forwards the request,
and returns the response. After `--idle` seconds without requests it stops the backend, so
the 1.65 GB of VRAM and the RAM that goes with it are released.

  python3 zonos3_lazy.py                 # port 1919, backend 1920, idle 120s
  python3 zonos3_lazy.py --idle 300
  python3 zonos3_lazy.py --status        # one line, does not wake the backend

Endpoints that pass through: /v1/audio/speech, /v2/generate, /v2/speakers, /v2/capabilities.
/v2/health answers locally so health checks never wake the model. /lazy/status reports state.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("ZONOS_ROOT", HERE)
GGML = os.path.join(ROOT, "servers", "ggml")
BIN = os.path.join(GGML, "build-cuda", "zonos3-server")
VOICES = os.path.join(ROOT, "voices")
LOG = os.path.join(os.path.expanduser("~"), "zonos3-server.log")

PASSTHROUGH = ("/v1/", "/v2/")

_state = {
    "proc": None,          # subprocess.Popen
    "since": 0.0,          # last request time
    "loads": 0,
    "lock": threading.Lock(),
}


def log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def backend_health(port: int, timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/v2/health", timeout=timeout) as r:
            return json.loads(r.read().decode()).get("status") == "ok"
    except Exception:
        return False


def start_backend(port: int) -> None:
    env = dict(os.environ)
    libs = [
        os.path.join(GGML, "build-cuda", "ggml", "src"),
        os.path.join(GGML, "build-cuda", "ggml", "src", "ggml-cuda"),
        os.path.join(ROOT, "cuda-libs"),
    ]
    env["LD_LIBRARY_PATH"] = ":".join(libs + ([env["LD_LIBRARY_PATH"]] if env.get("LD_LIBRARY_PATH") else []))

    voices = ["--tts-default-voices-dir", VOICES] if os.path.isdir(VOICES) else []
    cmd = [BIN, "gguf/zonos3-ptq.gguf", "--gpu", "--host", "127.0.0.1", "--port", str(port)] + voices

    # earlyoom-friendly: no shell, no console, log to file
    logf = open(LOG, "a", encoding="utf-8")
    proc = subprocess.Popen(
        cmd, cwd=GGML, env=env, stdout=logf, stderr=logf,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    _state["proc"] = proc
    _state["loads"] += 1
    log(f"backend starting (pid {proc.pid}) on port {port}")


def wait_healthy(port: int, proc: subprocess.Popen, timeout: float = 300.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            log("backend exited during load, check the log above")
            return False
        if backend_health(port):
            return True
        time.sleep(0.4)
    return False


def stop_backend() -> None:
    proc = _state["proc"]
    if proc is None:
        return
    log(f"idle, unloading backend (pid {proc.pid}) to free VRAM")
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:
        try:
            proc.terminate()
        except Exception:
            pass
    try:
        proc.wait(timeout=15)
    except Exception:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            pass
    _state["proc"] = None


def ensure_backend(port: int) -> bool:
    with _state["lock"]:
        proc = _state["proc"]
        if proc is not None and proc.poll() is None and backend_health(port):
            return True
        if proc is not None:
            stop_backend()
        start_backend(port)
        ok = wait_healthy(port, _state["proc"])
        if not ok:
            stop_backend()
        return ok


def idle_watchdog(port: int, idle: float) -> None:
    while True:
        time.sleep(5)
        with _state["lock"]:
            proc = _state["proc"]
            if proc is None:
                continue
            if proc.poll() is not None:
                _state["proc"] = None
                continue
            if idle > 0 and (time.time() - _state["since"]) > idle:
                stop_backend()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    backend_port = 1920

    def log_message(self, fmt, *args):
        return

    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload: dict) -> None:
        self._send(code, json.dumps(payload).encode())

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/v2/health":
            loaded = _state["proc"] is not None and _state["proc"].poll() is None
            self._json(200, {"status": "ok", "mode": "lazy", "backend": "loaded" if loaded else "asleep"})
            return
        if path == "/lazy/status":
            loaded = _state["proc"] is not None and _state["proc"].poll() is None
            self._json(200, {
                "backend": "loaded" if loaded else "asleep",
                "loads": _state["loads"],
                "idle_seconds": round(time.time() - _state["since"], 1) if _state["since"] else None,
                "backend_port": self.backend_port,
            })
            return
        self._forward("GET", path, b"")

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self._forward("POST", path, body)

    def _forward(self, method: str, path: str, body: bytes) -> None:
        if not any(path.startswith(p) for p in PASSTHROUGH):
            self._json(404, {"detail": "not found"})
            return

        if not ensure_backend(self.backend_port):
            self._json(503, {"detail": "zonos3 backend failed to load, see ~/zonos3-server.log"})
            return

        _state["since"] = time.time()
        url = f"http://127.0.0.1:{self.backend_port}{path}"
        req = urllib.request.Request(url, data=body or None, method=method)
        for h in ("Content-Type", "X-TTS-Session-ID", "Authorization"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])

        try:
            with urllib.request.urlopen(req, timeout=900) as resp:
                payload = resp.read()
                ctype = resp.headers.get("Content-Type", "application/octet-stream")
                self._send(resp.status, payload, ctype)
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            self._send(exc.code, payload, exc.headers.get("Content-Type", "application/json"))
        except Exception as exc:  # noqa: BLE001
            self._json(502, {"detail": f"backend error: {type(exc).__name__}: {exc}"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("ZONOS_PORT", 1919)))
    ap.add_argument("--backend-port", type=int, default=int(os.environ.get("ZONOS_BACKEND_PORT", 1920)))
    ap.add_argument("--idle", type=float, default=float(os.environ.get("ZONOS_IDLE", 120)))
    ap.add_argument("--status", action="store_true")
    args = ap.parse_args()

    if args.status:
        loaded = _state["proc"] is not None
        print(json.dumps({"backend": "loaded" if loaded else "asleep", "note": "state is per process"}))
        return 0

    if not os.path.exists(BIN):
        print(f"missing binary: {BIN}", file=sys.stderr)
        return 1

    Handler.backend_port = args.backend_port

    threading.Thread(target=idle_watchdog, args=(args.backend_port, args.idle), daemon=True).start()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    log(f"lazy front end listening on http://127.0.0.1:{args.port} "
        f"(backend {args.backend_port}, unload after {args.idle:.0f}s idle)")

    def shutdown(*_):
        with _state["lock"]:
            stop_backend()
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
