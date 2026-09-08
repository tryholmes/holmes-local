# holmes-mcp-__NAME__

A read only MCP server for Holmes, in Python.

```sh
pip install "mcp<2"        # or: uv sync   (2.x renamed FastMCP; template targets 1.x)
holmes-sdk mcp add __NAME__ -- python3 "$PWD/server.py"
holmes-sdk mcp lint __NAME__
```

Then reference it from a playbook manifest:

```json
"mcpServers": ["__NAME__"]
```

Edit `server.py`. Keep tool names as reads (`search_*`, `get_*`, `list_*`)
and keep `readOnlyHint=True`, or Holmes will not offer them. Details in
`../README.md`.
