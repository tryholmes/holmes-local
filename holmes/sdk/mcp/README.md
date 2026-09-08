# Holmes SDK: adding tools with MCP

A playbook decides *when* Holmes acts and *what* it prepares. A tool is
something Holmes can call while preparing it: search your issue tracker, fetch
a wiki page, look up a customer. Holmes gets tools from
[MCP](https://modelcontextprotocol.io) servers, which are separate programs
in any language. You never touch the app.

## How Holmes finds your server

Holmes reads one config file, the first that exists:

1. `~/Library/Application Support/Holmes/mcp.json`
2. `~/.holmes/mcp.json`

```json
{
  "mcpServers": {
    "mytracker": { "command": "node", "args": ["/abs/path/dist/index.js"] },
    "remote":    { "url": "https://mcp.example.com/mcp", "bearerToken": "..." }
  }
}
```

`command` servers speak MCP over stdio. `url` servers speak Streamable HTTP
and accept `headers` or `bearerToken`. The key, here `mytracker`, is the
server name. It becomes the prefix of every tool the model sees
(`mytracker__search_issues`) and it is what a playbook manifest names in
`mcpServers`.

`holmes-sdk mcp add <name> -- <command> [args]` writes the entry for you.

## Which tools Holmes will offer

This is the part that surprises people, so read it before you name anything.
Holmes runs playbooks unattended, so it filters your tool list with a default
deny policy that is code, not prompt. A tool reaches the model only if all of
these hold:

1. **It declares `annotations.readOnlyHint: true`.** No hint, no offer. A name
   is not a contract.
2. **Its name reads as a read.** The name is uppercased and split into whole
   tokens on anything that is not a letter or digit. camelCase is **not**
   split, so `getIssue` is one token and is denied. Use snake_case. Then:
   - any token in the block list denies it: `SEND DELETE REMOVE DESTROY UPDATE
     PATCH PUBLISH UPLOAD EXECUTE CREATE POST WRITE ARCHIVE TRASH MOVE MARK
     REPLY FORWARD ADD INSERT APPEND MERGE SAVE SHARE SUBMIT ACCEPT STAR UNSTAR
     PIN UNPIN ENABLE DISABLE SET MODIFY ASSIGN CLOSE LOCK UNLOCK CANCEL
     TRIGGER RUN` and a few more (the CLI linter has the full list),
   - `AND` or `OR` anywhere denies it (compound actions),
   - otherwise it needs at least one allow token: `GET LIST FETCH SEARCH FIND
     READ RETRIEVE LOOKUP QUERY HISTORY PROFILE`,
   - anything else is denied.
3. **A playbook asked for your server.** A manifest lists your server name in
   `mcpServers`. Built in playbooks never see SDK servers.

So `search_issues`, `get_page`, `list_recent_docs` are offered.
`create_issue`, `update_page`, `sync_and_fetch`, `issues` are not, and that is
the intended behavior. Put writes in a different server that you use from
other MCP clients, not from Holmes.

Run `holmes-sdk mcp lint <name>` to see the verdict for every tool your server
exposes, with the reason.

Two more naming rules. Holmes shows the model `<server>__<tool>` truncated to
64 characters, so keep names short enough that two tools cannot collide after
truncation. And the linter tokenizes ASCII only, while Holmes tokenizes
Unicode letters, so stick to ASCII names.

## Reading the screen back from Holmes

Your server can ask Holmes what the user is looking at. Holmes serves its own
MCP endpoint on loopback when the user turns on **Settings ▸ Share screen
context with local MCP clients**:

```
POST http://127.0.0.1:5767/mcp
{"jsonrpc":"2.0","id":1,"method":"tools/call",
 "params":{"name":"get_screen_context","arguments":{}}}
```

Tools: `get_screen_context`, `get_active_app`, `get_upcoming_meetings`,
`get_recent_activity`. All read only. Both templates include a helper that
calls this and returns `null` when the endpoint is off, so your tool still
works without it.

## Templates

- [`template-ts/`](template-ts/): TypeScript, `@modelcontextprotocol/sdk`,
  one read tool, the Holmes context helper. `npm install && npm run build`.
- [`template-py/`](template-py/): Python, the official `mcp` package 1.x with
  FastMCP, same shape. `uv run server.py` or `pip install "mcp<2" && python
  server.py`. (`mcp` 2.x renamed the server class; the template pins 1.x.)

`holmes-sdk mcp new <name> --lang ts|py` copies one and renames it.

## Testing without the model

You do not need Ollama to test a server. `holmes-sdk mcp lint` speaks enough
MCP to list your tools. For calls, use the MCP Inspector:
`npx @modelcontextprotocol/inspector node dist/index.js`.
