#!/usr/bin/env python3
"""Tiny stdio-to-local-HTTP bridge for MCP clients without HTTP transport."""

import json
import sys
import urllib.error
import urllib.request


MCP_URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:7331/mcp"


def main() -> None:
    for line in sys.stdin.buffer:
        if not line.strip():
            continue
        request = urllib.request.Request(
            MCP_URL,
            data=line.strip(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                if body:
                    sys.stdout.buffer.write(body + b"\n")
                    sys.stdout.buffer.flush()
        except urllib.error.HTTPError as error:
            emit_error(line, f"HTTP {error.code}: {error.reason}")
        except Exception as error:  # Local bridge must turn transport failures into MCP errors.
            emit_error(line, str(error))


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
