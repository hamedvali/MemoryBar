#!/usr/bin/env python3
"""OAuth-aware stdio bridge for MCP clients without Streamable HTTP support."""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser


MCP_URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:7331/mcp"
SERVER_BASE = MCP_URL.rsplit("/mcp", 1)[0]
SCOPES = " ".join(
    [
        "memory:search",
        "memory:recent",
        "memory:episodes",
        "memory:summary",
        "memory:actions",
        "memory:people",
        "memory:projects",
    ]
)
CACHE_DIRECTORY = Path.home() / "Library" / "Application Support" / "MemoryBar" / "oauth-clients"
CACHE_KEY = hashlib.sha256(MCP_URL.encode()).hexdigest()[:16]
CACHE_PATH = CACHE_DIRECTORY / f"stdio-{CACHE_KEY}.json"


class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
    result: dict[str, str] = {}
    expected_state = ""

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        state = query.get("state", [""])[0]
        if state != self.expected_state:
            self.send_error(400, "Invalid OAuth state")
            return
        type(self).result = {key: values[0] for key, values in query.items() if values}
        body = b"MemoryBar is connected. You can close this window."
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    for line in sys.stdin.buffer:
        if not line.strip():
            continue
        try:
            body = post_mcp(line.strip(), ensure_access_token())
        except urllib.error.HTTPError as error:
            if error.code == 401:
                cache = load_cache()
                cache.pop("access_token", None)
                cache.pop("expires_at", None)
                save_cache(cache)
                try:
                    body = post_mcp(line.strip(), ensure_access_token())
                except Exception as retry_error:
                    emit_error(line, str(retry_error))
                    continue
            else:
                emit_error(line, f"HTTP {error.code}: {read_http_error(error)}")
                continue
        except Exception as error:  # Transport failures must become MCP errors.
            emit_error(line, str(error))
            continue

        if body:
            sys.stdout.buffer.write(body + b"\n")
            sys.stdout.buffer.flush()


def post_mcp(payload: bytes, token: str) -> bytes:
    request = urllib.request.Request(
        MCP_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def ensure_access_token() -> str:
    cache = load_cache()
    if cache.get("access_token") and float(cache.get("expires_at", 0)) > time.time() + 30:
        return str(cache["access_token"])

    if cache.get("refresh_token") and cache.get("client_id"):
        try:
            token = token_request(
                {
                    "grant_type": "refresh_token",
                    "refresh_token": str(cache["refresh_token"]),
                    "client_id": str(cache["client_id"]),
                    "resource": MCP_URL,
                }
            )
            return update_token_cache(cache, token)
        except urllib.error.HTTPError as error:
            if error.code not in (400, 401):
                raise

    return authorize_interactively()


def authorize_interactively() -> str:
    metadata = get_json(f"{SERVER_BASE}/.well-known/oauth-authorization-server")
    callback_server = http.server.HTTPServer(("127.0.0.1", 0), OAuthCallbackHandler)
    callback_server.timeout = 180
    callback_uri = f"http://127.0.0.1:{callback_server.server_port}/callback"

    registration = post_json(
        str(metadata["registration_endpoint"]),
        {
            "client_name": "MemoryBar stdio bridge",
            "redirect_uris": [callback_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        },
    )
    client_id = str(registration["client_id"])
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    OAuthCallbackHandler.expected_state = state
    OAuthCallbackHandler.result = {}
    authorization_url = str(metadata["authorization_endpoint"]) + "?" + urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": client_id,
            "redirect_uri": callback_uri,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "scope": SCOPES,
            "resource": MCP_URL,
            "state": state,
        }
    )
    print("MemoryBar needs one-time approval in your browser.", file=sys.stderr)
    if not webbrowser.open(authorization_url):
        print(f"Open this URL to authorize MemoryBar:\n{authorization_url}", file=sys.stderr)
    callback_server.handle_request()
    callback_server.server_close()
    result = OAuthCallbackHandler.result
    if result.get("error"):
        raise RuntimeError(f"MemoryBar authorization was denied: {result['error']}")
    code = result.get("code")
    if not code:
        raise RuntimeError("MemoryBar authorization timed out or returned no code")

    token = token_request(
        {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client_id,
            "redirect_uri": callback_uri,
            "code_verifier": verifier,
            "resource": MCP_URL,
        },
        endpoint=str(metadata["token_endpoint"]),
    )
    return update_token_cache({"client_id": client_id}, token)


def token_request(values: dict[str, str], endpoint: str | None = None) -> dict[str, object]:
    request = urllib.request.Request(
        endpoint or f"{SERVER_BASE}/token",
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def get_json(url: str) -> dict[str, object]:
    with urllib.request.urlopen(url, timeout=10) as response:
        return json.load(response)


def post_json(url: str, value: dict[str, object]) -> dict[str, object]:
    request = urllib.request.Request(
        url,
        data=json.dumps(value).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def update_token_cache(cache: dict[str, object], token: dict[str, object]) -> str:
    access_token = str(token["access_token"])
    cache["access_token"] = access_token
    cache["refresh_token"] = token.get("refresh_token", cache.get("refresh_token"))
    cache["expires_at"] = time.time() + int(token.get("expires_in", 600))
    save_cache(cache)
    return access_token


def load_cache() -> dict[str, object]:
    try:
        return json.loads(CACHE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_cache(cache: dict[str, object]) -> None:
    CACHE_DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(CACHE_DIRECTORY, 0o700)
    temporary = CACHE_PATH.with_suffix(".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as file:
        json.dump(cache, file, separators=(",", ":"))
    os.replace(temporary, CACHE_PATH)
    os.chmod(CACHE_PATH, 0o600)


def read_http_error(error: urllib.error.HTTPError) -> str:
    try:
        payload = json.loads(error.read())
        return str(payload.get("error_description") or payload.get("error") or error.reason)
    except Exception:
        return str(error.reason)


def emit_error(request_line: bytes, message: str) -> None:
    try:
        request_id = json.loads(request_line).get("id")
    except Exception:
        request_id = None
    if request_id is None:
        return
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32000, "message": f"MemoryBar is unavailable: {message}"},
    }
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
