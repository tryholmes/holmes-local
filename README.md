<!-- ⚠️ This README has been generated from the file(s) "blueprint.md" ⚠️-->
[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#holmes)

# ➤ Holmes

Autonomous desktop agent for macOS. Runs entirely on your Mac, no cloud, no account.

> **Beta.** This is Holmes Local, the open source build. It uses an open weights vision model served by [Ollama](https://ollama.com). The hosted version lives in a separate, private repo.

Holmes watches your screen, understands what you're doing, and prepares things before you ask: a drafted reply, a repo summary, a fix for a failed command, a sorted Downloads folder. You never open a chat box. When it has something ready, the screen glows, your trackpad buzzes, and a draft appears for you to approve. It never sends, posts, or deletes on its own, that's enforced in code.

**[Download Holmes.dmg](https://github.com/tryholmes/holmes-local/releases/latest/download/Holmes.dmg)** · [Install guide](INSTALL.md)

---


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#quick-start)

## ➤ Quick start

```bash
brew install ollama
ollama pull qwen3-vl:4b-instruct
```

Then open Holmes.dmg, drag it to Applications, and launch it. Grant the permissions it asks for (Screen Recording, Accessibility, Calendar, Notifications), then quit and relaunch once.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#how-it-works)

## ➤ How it works

Holmes reads your screen every few seconds through a browser extension or macOS Accessibility, and turns that into one plain, factual sentence describing what's happening. No model writes that sentence, so it never guesses. A rules based check decides if anything's worth acting on. If so, the local model builds a draft using that context and, optionally, your connected tools.

You always approve before anything goes out. The only unsupervised write Holmes can make is creating a Gmail draft, and only to people already in the conversation.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#what-it-does)

## ➤ What it does

| Automation | Trigger | Result |
|---|---|---|
| Meeting Join | A meeting is about to start | Opens the link for you |
| Terminal Help | A command just failed | Explains the fix out loud |
| GitHub Brief | You open a repo | Summary of PRs, issues, next steps |
| Chat Reply | A real contact is on screen | Drafted reply, staged, never sent |
| Downloads Sorter | 10+ loose files in Downloads | Sorted into folders, fully undoable |

Plus: push to talk (hold Fn), a command bar (`Ctrl+Space`), custom playbooks via the Holmes SDK, and an optional local MCP server for other agents to read your screen context.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#safety-drafts-never-sends)

## ➤ Safety: drafts, never sends

- Every mutating tool (send, delete, post, publish, move, etc.) is filtered out of the model's reach before it ever sees the tool list.
- The one exception is Gmail drafts, allow listed by exact name.
- A draft can only go to recipients already present in that conversation's context.
- Batched tool calls are inspected individually, so a send can't hide inside one.
- This is enforced in code, not by prompting the model to behave.

Tested against ~57 adversarial prompts designed to bypass this. All blocked.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#requirements)

## ➤ Requirements

- Apple Silicon Mac, macOS 14+
- 16 GB RAM recommended (8 GB minimum, smaller model auto selected)
- [Ollama](https://ollama.com) 0.33+
- ~3.3 GB disk for the default model

No API key. Without Ollama running, Holmes still shows what's on screen but won't draft anything.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#models)

## ➤ Models

One model handles everything: it needs both vision and tool calling.

| Model | Size | Min RAM |
|---|---|---|
| `qwen3-vl:2b-instruct` | 1.9 GB | 8 GB |
| `qwen3-vl:4b-instruct` (default) | 3.3 GB | 16 GB |
| `qwen3-vl:8b-instruct` | 6.1 GB | 16 GB |
| `qwen3.5:9b` | 6.6 GB | 24 GB |
| `qwen3-vl:30b-a3b-instruct` | 20 GB | 32 GB |
| `gemma4:12b` | 7.6 GB | 16 GB |

Holmes picks one automatically based on your Mac's memory. Change it anytime in Settings → Local Model.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#privacy)

## ➤ Privacy

Everything stays on your Mac by default. No telemetry, no analytics, no account.

- Screen capture, Accessibility reads, OCR, dictation: on device, always
- Screen context during a task: sent to the local model on your Mac (or wherever you point Ollama)
- Spoken text: sent to ElevenLabs only if you add a key
- Tool calls: sent to connected services only if you set up Composio/MCP
- History: local SQLite file. Only stored credential is an optional ElevenLabs key, in Keychain.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#connecting-tools-optional)

## ➤ Connecting tools (optional)

For GitHub Brief to pull real data, or for Gmail/Calendar/GitHub actions via `/run`, connect [Composio](https://composio.dev) in `~/.holmes/mcp.json`:

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

Full walkthrough: [`holmes/MCP-SETUP.md`](holmes/MCP-SETUP.md).


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#known-limitations)

## ➤ Known limitations

- Local models misclick more than hosted ones on busy screens
- Each action takes 3 to 15 seconds
- First launch pays a 20 to 40 second model load
- Older Ollama versions may not support newer models, run `brew upgrade ollama`


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#build-from-source)

## ➤ Build from source

```bash
git clone <this repository>
cd holmes-local/holmes
xcodebuild -project holmes.xcodeproj -scheme holmes -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Set your own Development Team in Xcode if building repeatedly, ad hoc signing resets macOS permissions on every rebuild.


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#contributing)

## ➤ Contributing

Issue first, one change per branch, explain what changed and how you tested it. See [`CONTRIBUTING.md`](CONTRIBUTING.md).


[![-----------------------------------------------------](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/colored.png)](#license)

## ➤ License

GPL-3.0. See [`LICENSE`](LICENSE). Required because the notch UI ports [boring.notch](https://github.com/TheBoredTeam/boring.notch) (GPL-3.0); other MIT licensed components are noted in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
