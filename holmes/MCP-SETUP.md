# Connecting Holmes to MCP servers (Gmail, Google Workspace, …)

Holmes is an **MCP host**: it connects to Model Context Protocol servers and lets the
Claude action loop call their tools. That's how Holmes does *real* things — send a Gmail,
create a calendar event, edit a Doc — instead of just pasting text.

Two requirements:
1. An **Anthropic API key** (the action loop runs on Claude). Put it in `~/.holmes/anthropic_key`.
2. One or more **MCP servers** listed in `~/.holmes/mcp.json`.

Holmes reads config from (first found wins):
- `~/Library/Application Support/Holmes/mcp.json`
- `~/.holmes/mcp.json`

The format is identical to Claude Desktop's `mcpServers` block, so you can paste an existing one.

---

## 0. Quick test (no Google account needed)

Confirm the whole pipeline works before dealing with OAuth. Put this in `~/.holmes/mcp.json`:

```json
{ "mcpServers": { "test": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-everything"] } } }
```

Launch Holmes, then `Ctrl+Space` → `/run use the echo tool to say hello`. Holmes will spin up the
server and call `everything__echo`. *(This exact server is verified working with Holmes.)*

Requirements: Node.js (`npx`) on your PATH. For the Google servers you also need `uvx` (from
[uv](https://github.com/astral-sh/uv)) **or** Node, depending on which server you pick.

---

## 1. Gmail only — `@gongrzhe/server-gmail-autoauth-mcp`

Simplest path to Gmail (send, search, read, labels, drafts).

**a. Create a Google OAuth client**
- Google Cloud Console → create/select a project → enable the **Gmail API**.
- APIs & Services → Credentials → **Create OAuth client ID → Desktop app** → download the JSON.

**b. Authenticate once (in Terminal):**
```bash
mkdir -p ~/.gmail-mcp
mv ~/Downloads/client_secret_*.json ~/.gmail-mcp/gcp-oauth.keys.json
npx @gongrzhe/server-gmail-autoauth-mcp auth      # opens a browser, caches the token
```

**c. Tell Holmes about it** — `~/.holmes/mcp.json`:
```json
{ "mcpServers": { "gmail": { "command": "npx", "args": ["-y", "@gongrzhe/server-gmail-autoauth-mcp"] } } }
```

Because you authenticated in step (b), the server Holmes launches reads the cached token and
does **not** block — important, since Holmes spawns it in the background.

Try: `/run reply to the latest email from <name> saying I'll send the deck tomorrow` →
Claude reads context, drafts via Gmail, and the approval card pops before anything is sent.

---

## 2. Full Google Workspace — `workspace-mcp` (Gmail + Calendar + Drive + Docs + Sheets + Slides …)

One server for all Google services. Runs via `uvx` (no install). Pick the tools you want.

**a. OAuth client** (as above) — enable the APIs you'll use (Gmail, Calendar, Drive, Docs…).
Grab the **client ID** and **client secret**.

**b. Authenticate once (in Terminal):**
```bash
export GOOGLE_OAUTH_CLIENT_ID="…apps.googleusercontent.com"
export GOOGLE_OAUTH_CLIENT_SECRET="…"
uvx workspace-mcp --single-user --tools gmail calendar   # complete the browser sign-in, then Ctrl+C
```
This caches your credentials so later runs don't block on a browser.

**c. Holmes config** — `~/.holmes/mcp.json`:
```json
{
  "mcpServers": {
    "google": {
      "command": "uvx",
      "args": ["workspace-mcp", "--single-user", "--tools", "gmail", "calendar", "drive", "docs"],
      "env": {
        "GOOGLE_OAUTH_CLIENT_ID": "…apps.googleusercontent.com",
        "GOOGLE_OAUTH_CLIENT_SECRET": "…"
      }
    }
  }
}
```

Useful flags: `--read-only` (read scopes only), `--permissions gmail:send drive:readonly`
(granular — Gmail levels: `readonly`, `organize`, `drafts`, `send`, `full`).

---

## 3. Remote / hosted MCP servers (HTTP)

If you use a hosted Google MCP endpoint (Zapier, Composio, Pipedream, or your own), give Holmes
the URL and a token instead of a command:

```json
{ "mcpServers": { "google": { "url": "https://your-endpoint/mcp", "bearerToken": "YOUR_TOKEN" } } }
```

Holmes speaks the Streamable-HTTP transport (handles both JSON and SSE replies) and sends
`Authorization: Bearer <token>`. You can also pass arbitrary `"headers": { … }`.

---

## How approval works

- **Read-only tools** (the server marks them with `readOnlyHint`) run automatically.
- **Anything that changes state** (send email, create event, delete file) pops the Holmes
  approval card first — with an editable preview — exactly like its other actions. Nothing is
  sent without your click.

## Troubleshooting

- Holmes logs each server on launch: `[MCP] gmail: 12 tools` or `[MCP] gmail failed: …`.
  Server diagnostics are surfaced as `[MCP:gmail] …` (run Holmes from Console/Xcode to see them).
- "command not found" → the server's runner (`npx`/`uvx`) isn't on the PATH Holmes augments
  (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`). Install it there, or
  use an absolute `command` path in `mcp.json`.
- First `npx`/`uvx` run downloads the package — Holmes allows up to 120s for the handshake.
- Auth hangs → you skipped the one-time Terminal `auth` step; do it so the cached token exists.
