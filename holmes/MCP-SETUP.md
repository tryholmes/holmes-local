# Connecting Holmes to MCP servers (Gmail, Google Workspace, …)

Holmes is an **MCP host**: it connects to Model Context Protocol servers and lets the
local model's action loop call their tools. That's how Holmes does *real* things — draft a
Gmail, create a calendar event, edit a Doc — instead of just pasting text.

**MCP is optional.** Holmes Local's five playbooks read the screen and act through native
macOS lanes without any server listed here; MCP adds reach (GitHub data for the repo brief,
Gmail/Calendar for `/run` goals). Two requirements when you do want it:
1. The **local model is ready** — Ollama is running and the chosen model is pulled
   (Holmes ▸ Settings ▸ Local Model shows the status). There is no API key.
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
the local model reads context, drafts via Gmail, and the approval card pops before anything is sent.
(A small local model takes a few seconds per tool call; the glow shows it's working.)

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

Holmes speaks the Streamable-HTTP transport and sends `Authorization: Bearer <token>`.
You can also pass arbitrary `"headers": { … }`. A server may answer each request with a
plain JSON body or an SSE stream; Holmes reads a stream event by event and completes the
call as soon as the matching JSON-RPC response arrives, so a server that keeps the
connection open afterwards does not delay anything. A request that gets no response
within 120 seconds fails with a timeout.

---

---

## 4. Holmes AS an MCP server — let other agents see your screen

Holmes also *exposes* its live context as an MCP server, so **Claude Desktop, Cursor, or a
voice agent can ask Holmes what's on your screen**. While Holmes is running it serves MCP at:

```
http://127.0.0.1:5767/mcp
```

It's bound to **loopback only** (no other machine can reach it) and exposes four read-only tools:
`get_screen_context`, `get_active_app`, `get_upcoming_meetings`, `get_recent_activity`.

**Point an HTTP-capable MCP client at it** (e.g. Claude Desktop's config):
```json
{ "mcpServers": { "holmes": { "url": "http://127.0.0.1:5767/mcp" } } }
```

**For clients that only launch stdio servers**, bridge with `mcp-remote`:
```json
{ "mcpServers": { "holmes": { "command": "npx", "args": ["-y", "mcp-remote", "http://127.0.0.1:5767/mcp"] } } }
```

Then ask that agent things like *"what am I looking at right now?"* — it calls Holmes's
`get_screen_context` and answers from your actual screen.

> Privacy: this serves your screen text on a local port with no auth. It's loopback-only, so
> only apps on this Mac can read it — but be aware any local process can. Quit Holmes to stop it.

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

---

## Composio: one connection, hundreds of actions

[Composio](https://composio.dev) hosts managed MCP servers for 500+ SaaS toolkits — Gmail,
Google Calendar, GitHub, Discord, LinkedIn, Perplexity and more — with all the OAuth handled
for you. One entry in `mcp.json` gives Holmes every one of them, and powers Holmes's
proactive playbooks (see below).

> Heads-up: the old per-app pages at `mcp.composio.dev` now redirect to Composio's toolkit
> catalog. MCP server creation lives in the **Composio dashboard**.

**a. Create the Composio MCP server**

1. Sign up / log in at [dashboard.composio.dev](https://dashboard.composio.dev).
2. Create a new **MCP server** (MCP configs are managed under the dashboard's MCP /
   connect-clients area) and add the toolkits Holmes uses:
   **Gmail, Google Calendar, GitHub, Discord, LinkedIn, Perplexity**.
   Each toolkit is backed by an auth config — Composio's built-in defaults are fine to start.
3. **Connect each account (OAuth).** For every toolkit, click *Connect* and finish that
   provider's consent screen. Composio stores and auto-refreshes the tokens; Holmes never
   sees your passwords.
4. Copy your server's **Streamable-HTTP URL**. It is per-user:
   `https://backend.composio.dev/v3/mcp/<SERVER_ID>?user_id=<USER_ID>`
   You'll also need your Composio **API key** (dashboard → API keys); Composio expects it as
   an `x-api-key` header (required by default for new organizations).

**b. Tell Holmes about it** — `~/.holmes/mcp.json`, same remote-server format as section 3:

```json
{
  "mcpServers": {
    "composio": {
      "url": "https://backend.composio.dev/v3/mcp/YOUR_SERVER_ID?user_id=YOUR_USER_ID",
      "headers": { "x-api-key": "YOUR_COMPOSIO_API_KEY" }
    }
  }
}
```

Name the entry exactly `composio` — Holmes namespaces tools by server name
(`composio__GMAIL_FETCH_EMAILS`, `composio__GITHUB_…`), and the playbooks look for that
prefix. If your endpoint expects `Authorization: Bearer …` instead, use `"bearerToken"`;
arbitrary `"headers"` work too.

**c. Restart Holmes and verify.** On launch the log prints `[MCP] composio: N tools`, and
the status label shows **`Local model (qwen3-vl:4b-instruct) · MCP: N tools`** (with whatever
model you picked). Try: `/run list my 5 most recent emails`.

**Alternative — Rube (one URL, zero dashboard):** Composio's consumer endpoint
`https://rube.app/mcp` puts all 500+ apps behind a single Streamable-HTTP URL with
browser-OAuth on first use. Holmes doesn't drive interactive OAuth itself, so bridge it —
authenticate once in Terminal so the token is cached, then point Holmes at the bridge:

```bash
npx -y mcp-remote https://rube.app/mcp   # complete the browser sign-in, then Ctrl+C
```

```json
{ "mcpServers": { "composio": { "command": "npx", "args": ["-y", "mcp-remote", "https://rube.app/mcp"] } } }
```

### What Holmes does with it automatically

Holmes Local ships five playbooks (see the README). They all run without MCP; connecting
`composio` upgrades the one that benefits from real data. Each one watches your screen and
leaves a **draft** for you to review — the screen edge glows while the model works:

| Playbook | Trigger | Uses Composio? | What you get |
|---|---|---|---|
| **GitHub Brief** | A specific `owner/repo` is open | yes — `GITHUB_*` read-only tools (falls back to the screen text without them) | A 5-line brief: what it is, open PRs, open issues, next actions |
| **Chat Reply** | A Messages / Discord / Slack conversation with a real contact is on screen | no | A suggested reply, staged into the input field, never sent |
| **Terminal Command Help** | A command just failed in your terminal | no | A short spoken explanation and the fix |
| **Meeting Join** | A Zoom / Meet / Teams meeting is starting | no | The join link opened for you |
| **Downloads Sorter** | Finder shows a Downloads folder full of loose files | no | Files sorted into type subfolders, every move undoable |

**Proactive mode is draft-only — guaranteed.** In playbook runs, send/delete/post/update
tools are **filtered out at the code level** before the model ever sees them: only read
tools and explicit draft-creation tools (e.g. `GMAIL_CREATE_EMAIL_DRAFT`) are offered.
Holmes *cannot* send an email, post, or delete anything proactively — **sending always
requires you.** (Your own `/run` commands keep the normal approval-card flow from
"How approval works" above.)

Each playbook can be toggled individually in Holmes's settings.
