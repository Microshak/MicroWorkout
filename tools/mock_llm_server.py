#!/usr/bin/env python3
"""Mock LLM server for MicroWorkout (PRD-07 R8).

Speaks all three wire shapes the app supports (OpenAI-compatible, Anthropic, Gemini) and can
be told to misbehave in every way the resilience ladder must survive, so the entire LLM path —
including failure and fallback — is testable with **no real API key and no outbound calls**.

    python3 tools/mock_llm_server.py --host 0.0.0.0 --port 8765 --mode valid --verbose

From the Android emulator the host is reachable at http://10.0.2.2:8765/v1.

Endpoints
    POST /v1/chat/completions                     OpenAI-compatible
    POST /v1/messages                             Anthropic
    POST /v1beta/models/<model>:generateContent   Gemini
    GET  /v1/models                               model list (used for provider hints)
    GET  /__health                                {"ok":true,"mode":...,"requests":N}
    GET|POST /__control?mode=<m>&reset=1          set global mode / reset counters
    any inference path + ?__mode=<m>              one-off override, global mode untouched

Stdlib only. Never makes outbound requests. Redacts anything key-like from its own output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE_DIR = os.path.join(ROOT, "tools", "fixtures")
LIBRARY_PATH = os.path.join(ROOT, "data", "exercise_library.json")

TEST_KEY = "sk-test-0000000000"
DEFAULT_MODEL = "mock-model-1"

MODES = [
    "valid", "malformed", "schema_invalid", "repair_schema", "repair_malformed",
    "http400_json", "http401", "http429", "http500", "empty", "truncated",
    "hang", "slow_ok",
]

KEY_RE = re.compile(r"sk-[A-Za-z0-9_\-]{6,}")


def redact(text: str) -> str:
    """Anything that looks like a credential becomes [REDACTED] in our own logs."""
    return KEY_RE.sub("[REDACTED]", text or "")


class State:
    def __init__(self, mode: str) -> None:
        self.lock = threading.Lock()
        self.mode = mode
        self.requests = 0
        self.calls_by_session: dict[str, int] = {}

    def next_call_index(self, session_key: str) -> int:
        with self.lock:
            self.requests += 1
            index = self.calls_by_session.get(session_key, 0)
            self.calls_by_session[session_key] = index + 1
            return index

    def reset(self) -> None:
        with self.lock:
            self.requests = 0
            self.calls_by_session.clear()


def load_fixtures() -> tuple[dict, dict]:
    valid_path = os.path.join(FIXTURE_DIR, "mock_plan_valid.json")
    invalid_path = os.path.join(FIXTURE_DIR, "mock_plan_invalid.json")
    try:
        with open(valid_path, encoding="utf-8") as fh:
            valid = json.load(fh)
        with open(invalid_path, encoding="utf-8") as fh:
            invalid = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FATAL: cannot load fixtures from {FIXTURE_DIR}: {exc}", file=sys.stderr)
        sys.exit(2)
    return valid, invalid


def referenced_ids(plan: dict) -> set[str]:
    ids: set[str] = set()
    for session in plan.get("sessions", []):
        for key in ("warmup", "blocks", "cooldown"):
            for item in session.get(key, []):
                if isinstance(item, dict) and item.get("exercise_id"):
                    ids.add(item["exercise_id"])
    return ids


def verify_fixture_ids(valid: dict) -> None:
    """A library rename must never silently make the mock test vacuous."""
    ids = referenced_ids(valid)
    if not os.path.exists(LIBRARY_PATH):
        print(f"WARNING: {os.path.relpath(LIBRARY_PATH, ROOT)} not built yet — "
              f"skipping fixture id check ({len(ids)} ids unchecked)", file=sys.stderr)
        return
    try:
        with open(LIBRARY_PATH, encoding="utf-8") as fh:
            library = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FATAL: cannot read the exercise library: {exc}", file=sys.stderr)
        sys.exit(2)
    known = {e.get("id") for e in library.get("exercises", [])}
    missing = sorted(ids - known)
    if missing:
        print("FATAL: the valid fixture references exercise ids that do not exist in "
              f"data/exercise_library.json: {missing}", file=sys.stderr)
        sys.exit(2)
    print(f"[mock] fixture ids verified against the library ({len(ids)} ids)")


def envelope(path: str, text: str, model: str, finish: str | None = None) -> dict:
    """Wrap plan text in whichever provider envelope the request path implies."""
    if path.startswith("/v1/messages"):
        body: dict = {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                      "model": model, "role": "assistant"}
        if finish == "truncated":
            body["stop_reason"] = "max_tokens"
        if finish == "blocked":
            body["stop_reason"] = "refusal"
        return body

    if ":generateContent" in path:
        body = {"candidates": [{"content": {"parts": [{"text": text}]}, "finishReason": "STOP"}]}
        if finish == "truncated":
            body["candidates"][0]["finishReason"] = "MAX_TOKENS"
        if finish == "blocked":
            body = {"promptFeedback": {"blockReason": "SAFETY"}}
        return body

    body = {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                     "finish_reason": "stop"}],
    }
    if finish == "truncated":
        body["choices"][0]["finish_reason"] = "length"
    if finish == "blocked":
        body["choices"][0]["finish_reason"] = "content_filter"
    return body


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MicroWorkoutMockLLM/1.0"

    # ------------------------------------------------------------------ plumbing
    def log_message(self, fmt: str, *args) -> None:  # silence the default stderr spam
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("[mock] " + redact(fmt % args) + "\n")

    def _send(self, status: int, payload: dict | str, content_type: str = "application/json") -> None:
        body = payload.encode("utf-8") if isinstance(payload, str) else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> tuple[int, str]:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.server.verbose:  # type: ignore[attr-defined]
            print(f"[mock] {self.command} {redact(self.path)} body_len={len(raw)}")
        return length, raw.decode("utf-8", "replace")

    # ------------------------------------------------------------------ routing
    def do_GET(self) -> None:  # noqa: N802
        path, _, query = self.path.partition("?")
        params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)

        if path == "/__health":
            self._send(200, {"ok": True, "mode": self.server.state.mode,  # type: ignore[attr-defined]
                             "requests": self.server.state.requests})  # type: ignore[attr-defined]
            return
        if path == "/__control":
            self._control(params)
            return
        if path == "/v1/models":
            self._send(200, {"object": "list", "data": [{"id": DEFAULT_MODEL, "object": "model"}]})
            return
        self._send(404, {"error": {"message": f"no such path: {path}"}})

    def do_POST(self) -> None:  # noqa: N802
        path, _, query = self.path.partition("?")
        params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
        _, body = self._read_body()

        if path == "/__control":
            self._control(params)
            return
        if path not in ("/v1/chat/completions", "/v1/messages") and ":generateContent" not in path:
            self._send(404, {"error": {"message": f"no such path: {path}"}})
            return

        mode = params.get("__mode") or self.server.state.mode  # type: ignore[attr-defined]
        self._infer(path, mode, body, params)

    def _control(self, params: dict) -> None:
        state = self.server.state  # type: ignore[attr-defined]
        if "mode" in params:
            if params["mode"] not in MODES:
                self._send(400, {"error": {"message": f"unknown mode '{params['mode']}'",
                                           "modes": MODES}})
                return
            state.mode = params["mode"]
        if params.get("reset") in ("1", "true"):
            state.reset()
        self._send(200, {"mode": state.mode, "requests": state.requests})

    # ------------------------------------------------------------------ inference
    def _infer(self, path: str, mode: str, body: str, params: dict) -> None:
        state = self.server.state  # type: ignore[attr-defined]
        model = params.get("model") or DEFAULT_MODEL
        if ":generateContent" in path:
            model = path.split("/models/")[-1].split(":")[0] if "/models/" in path else model

        session_key = redact(self.headers.get("X-Session") or "default")
        call_index = state.next_call_index(session_key)

        def plan_text() -> str:
            return json.dumps(self.server.valid_plan, separators=(",", ":"))  # type: ignore[attr-defined]

        if mode == "hang":
            hang = int(self.server.hang_seconds)  # type: ignore[attr-defined]
            if self.server.verbose:  # type: ignore[attr-defined]
                print(f"[mock] mode=hang sleeping {hang}s (headers already sent=false)")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            time.sleep(hang)
            return

        if mode == "slow_ok":
            time.sleep(3)
            self._send(200, envelope(path, plan_text(), model))
            return

        if mode == "http400_json":
            self._send(400, {"error": {"message": "Unsupported parameter: 'response_format'",
                                       "type": "invalid_request_error"}})
            return
        if mode == "http401":
            self._send(401, {"error": {"message": "Invalid API key provided", "type": "auth_error"}})
            return
        if mode == "http429":
            self._send(429, {"error": {"message": "Rate limit reached", "type": "rate_limit"}})
            return
        if mode == "http500":
            self._send(500, {"error": {"message": "Internal server error"}})
            return

        if mode == "malformed":
            self._send(200, envelope(path, '{"name": "X", "sessions": [{"id": "s1",', model))
            return
        if mode == "empty":
            self._send(200, envelope(path, "", model))
            return
        if mode == "truncated":
            self._send(200, envelope(path, plan_text(), model, finish="truncated"))
            return
        if mode == "schema_invalid":
            self._send(200, envelope(path, json.dumps(self.server.invalid_plan,  # type: ignore[attr-defined]
                                                      separators=(",", ":")), model))
            return
        if mode == "repair_schema":
            # First call in this session is invalid, the retry is valid.
            if call_index == 0:
                self._send(200, envelope(path, json.dumps(self.server.invalid_plan,  # type: ignore[attr-defined]
                                                          separators=(",", ":")), model))
            else:
                self._send(200, envelope(path, plan_text(), model))
            return
        if mode == "repair_malformed":
            if call_index == 0:
                self._send(200, envelope(path, '{"name": "X", "sessions": [{"id": "s1",', model))
            else:
                self._send(200, envelope(path, plan_text(), model))
            return

        # "valid" and anything unrecognised
        self._send(200, envelope(path, plan_text(), model))


def main() -> int:
    ap = argparse.ArgumentParser(description="MicroWorkout mock LLM server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--mode", default="valid", choices=MODES)
    ap.add_argument("--hang-seconds", type=int, default=120)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    valid, invalid = load_fixtures()
    verify_fixture_ids(valid)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = State(args.mode)          # type: ignore[attr-defined]
    server.valid_plan = valid                # type: ignore[attr-defined]
    server.invalid_plan = invalid            # type: ignore[attr-defined]
    server.verbose = args.verbose            # type: ignore[attr-defined]
    server.hang_seconds = args.hang_seconds  # type: ignore[attr-defined]

    print(f"[mock] listening on http://{args.host}:{args.port}  mode={args.mode}  "
          f"model={DEFAULT_MODEL}  key={TEST_KEY[:7]}…(placeholder)")
    print(f"[mock] from the Android emulator use http://10.0.2.2:{args.port}/v1")
    print(f"[mock] modes: {', '.join(MODES)}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock] stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
