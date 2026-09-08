# Holmes SDK: playbook manifests

A playbook is "when Holmes sees this, it prepares that". The five built in
playbooks are written in Swift. A manifest lets you add your own without
touching Xcode: one JSON file, dropped in a folder, compiled by Holmes into the
same `Playbook` type the built ins use.

## Where manifests live

```
~/Library/Application Support/Holmes/playbooks/<id>.json
```

Holmes reads the folder at launch and watches both the folder and each file,
so saving takes effect within about a second. There is also a **Reload**
button in Settings ▸ Automations. Files are loaded in filename order. A file
that fails validation is skipped and the reason is shown in Settings under
the list. Loaded manifests appear with a COMMUNITY badge. Their dial offers
only Observe and Draft: a manifest always runs on the draft path, even when
autonomous actions are on for the built ins. Manual only ones get a
**Run now** button.

`windowTitle` is an ICU regular expression, the dialect Apple's frameworks
use. The CLI validates with Python's `re`, which agrees for everyday patterns
but not for exotic syntax such as possessive quantifiers.

`holmes-sdk playbook new <id> --install` writes a starter file into the folder,
and `holmes-sdk playbook validate <file>` checks one without launching Holmes.

## Minimal example

```json
{
  "version": 1,
  "id": "linear-ticket-summary",
  "name": "Linear Ticket Summary",
  "summary": "When you open a Linear ticket, drafts a two line status comment.",
  "match": {
    "apps": ["Safari", "Chrome", "Arc", "Linear"],
    "windowTitle": "\\b[A-Z]{2,6}-\\d{1,5}\\b",
    "windowTitleNot": ["Inbox", "My Issues"]
  },
  "goal": "The user has a Linear ticket open.\n\n{scene}\n\nWrite a status comment of at most two sentences. Return ONLY the comment text."
}
```

See `examples/` for complete files and `playbook.schema.json` for the full
schema. Point your editor at the schema to get completion and validation.

## Fields

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | Always `1` for this build. |
| `id` | yes | `a-z`, `0-9`, `-`, 3 to 48 chars. Must not reuse a built in id. |
| `name`, `summary` | yes | Shown in Settings and on the review card. |
| `icon` | no | SF Symbol name. Default `sparkles`. |
| `kind` | no | Persona that writes the result. One of `aiAnswer` (default), `chatReply`, `repoBrief`, `meetingPrep`, `linkedInPost`, `promptSuggestion`. |
| `autoTriggers` | no | `false` makes it manual only. Default `true`. |
| `cooldownSeconds` | no | Minimum seconds between fires for the same `key`. Minimum 60, default 600. |
| `composioApps` | no | Composio app slugs whose read only tools to offer, for example `["GITHUB"]`. |
| `match` | yes | When to fire. See below. |
| `key` | no | Template for the cooldown key. Default `{windowTitle}`. |
| `goal` | yes | Prompt template. |
| `title` | no | Review card title template. Default `name`. |
| `target` | no | `clipboard` (default) or `typeIntoApp`. |
| `persona` | no | Voice and shape guidance, up to 1500 characters. See below. |
| `mcpServers` | no | Server names from `mcp.json` whose read only tools this playbook may use. See below. |

### `match`

All listed gates must pass. Use the most structural signal you can.

| Field | Meaning |
|---|---|
| `apps` | Required. Case insensitive substrings of the active app name. Any one matches. |
| `contextTypes` | Substrings of the detected context type, for example `github`, `chat`, `terminal`. |
| `windowTitle` | Regular expression the window title must match. |
| `windowTitleNot` | Substrings that veto a match, for use on dashboards and inboxes. |
| `requiredEntities` | Entity keys that must be present: `sender`, `subject`, `recipient`, `contact`, `promptText`, `repoOwner`, `repoName`, `platform`, `eventTitle`, `eventId`. |
| `screenTextAny`, `screenTextAll` | Substrings of the on screen text. The least precise gate. Prefer the others. |

### Templates

`goal`, `title`, and `key` accept these placeholders. Unknown placeholders
render as empty text.

| Placeholder | Value |
|---|---|
| `{app}` | Active app name |
| `{windowTitle}` | Window title |
| `{contextType}` | Detected context type |
| `{scene}` | The same "what Holmes saw" block the built ins use: app, title, entities, and a screen text excerpt |
| `{screenText}` | Raw screen text, first 1500 characters |
| `{contact}`, `{repoOwner}`, any entity key | That extracted entity |

### `persona`

By default the `kind` picks one of the built in personas. `persona` lets you
write your own. Holmes does not use it verbatim. It is placed between a fixed
preamble that states the draft only rule and a fixed epilogue that pins the
output to the deliverable alone. Your text can narrow the voice, the audience,
and the shape. It cannot grant permissions, because the tool list is filtered
by code before the prompt is ever read.

### `mcpServers`

Holmes takes tools from MCP servers listed in `mcp.json`. A manifest names
which servers it may draw on. Each tool from those servers is still held to
the same bar as every built in integration: it must declare `readOnlyHint`
and its name must read as a read (`search_*`, `get_*`, `list_*`). Details and
a linter in [`../mcp/README.md`](../mcp/README.md). Built in playbooks never
see SDK servers, and the Composio server cannot be named here.

## What a manifest cannot do

These are not omissions. They are the reason manifests are safe to share.

- It cannot name a tool, a backend, or a coordinate. It runs on the draft only
  path and the tool list is filtered by the same code as the built ins. Send,
  delete, post, and publish tools are never offered.
- It cannot remove the draft never send rule. Holmes appends it to every goal.
- It cannot press Return. `typeIntoApp` stages text through the same executor
  the built in chat reply uses, which never submits.
- It cannot use the scheduled personas (`briefing`, `triage`, `followUp`,
  `prRadar`, `scheduleAlert`, `wrapup`). Those fire without screen context and
  were removed from the product for that reason. It also cannot use
  `emailReply`, the one kind that lets the built in playbook stage a Gmail
  draft server side.
- It cannot be dialed past Draft. Built ins can be set to Confirm or Auto and
  go through the action planner; a manifest never does.

If you need a new ability rather than a new trigger, add a tool through MCP.
Holmes connects to any MCP server listed in `mcp.json`, and every tool from it
passes through the same filter. See `holmes/MCP-SETUP.md`.

## Contributing a built in

A manifest that proves useful can graduate to a first party playbook. Open an
issue with the manifest attached and the real screens it fired on. Built ins
have a higher bar: a matcher keyed on app identity, window title, or extracted
entities, and near zero false positives over a week of daily use.
