#!/usr/bin/env python3
"""Holmes MCP server template (Python, FastMCP).

Two things matter for Holmes specifically:
  1. Every tool Holmes may use must set readOnlyHint=True and have a name
     that reads as a read (search_*, get_*, list_*, find_*). Anything else
     is filtered out before the model sees it. See ../README.md.
  2. A playbook manifest opts into this server by listing its mcp.json name
     in "mcpServers". Built in playbooks never see it.

Run:  uv run server.py        (or: pip install "mcp<2" && python server.py)
Wire: holmes-sdk mcp add __NAME__ -- python3 /abs/path/to/server.py
Lint: holmes-sdk mcp lint __NAME__
"""

import json
import urllib.request

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

mcp = FastMCP("holmes-mcp-__NAME__")

READ_ONLY = ToolAnnotations(readOnlyHint=True, openWorldHint=False)


def holmes_screen_context() -> dict | None:
    """What the user is looking at, from Holmes's loopback MCP endpoint.

    Returns None when the user has not turned on "Share screen context with
    local MCP clients" in Settings, so tools keep working without it.
    """
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": "get_screen_context", "arguments": {}},
    }
    req = urllib.request.Request(
        "http://127.0.0.1:5767/mcp",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            body = json.load(resp)
        text = body.get("result", {}).get("content", [{}])[0].get("text")
        return json.loads(text) if text else None
    except Exception:
        return None


@mcp.tool(annotations=READ_ONLY)
def search_items(query: str, limit: int = 5) -> str:
    """Search __NAME__ for items matching a query. Returns up to `limit` results with id, title, and url."""
    ctx = holmes_screen_context()
    hint = f" (user is viewing: {ctx['windowTitle']})" if ctx and ctx.get("windowTitle") else ""
    # TODO: replace with a real call.
    results = [
        {"id": f"item-{i}", "title": f'Example result {i} for "{query}"{hint}', "url": f"https://example.com/items/{i}"}
        for i in range(1, min(limit, 3) + 1)
    ]
    return json.dumps(results, indent=2)


@mcp.tool(annotations=READ_ONLY)
def get_item(id: str) -> str:
    """Fetch one __NAME__ item by id, with its full body."""
    # TODO: replace with a real call.
    return json.dumps({"id": id, "title": f"Example item {id}", "body": "Replace me with real content."}, indent=2)


if __name__ == "__main__":
    mcp.run()
