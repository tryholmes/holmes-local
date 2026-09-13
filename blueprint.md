<h1>
  <img src="holmes/assets/readmeicon.png" alt="Holmes" width="376">
</h1>

the autonomous desktop agent that runs entirely on your Mac

> **Beta.** Holmes Local is the open-source, fully local build of Holmes. The model that drives it is an open-weights vision model served by [Ollama](https://ollama.com) on your own machine. No API key, no account, no cloud. The hosted (commercial) build of Holmes lives in a different repository and is not part of this one.

Holmes is a **local-first, autonomous AI agent for macOS**. It watches your screen, understands what you're doing, and quietly prepares the next thing for you — a drafted chat reply, a project brief for the repo you just opened, the fix for the command that just failed, a tidy Downloads folder — **before you ask, and without you typing a command.**

You never open a chat box. You just work. When Holmes spots something it can help with, the screen edges glow, your trackpad buzzes, and a ready-to-review draft appears. You approve it (or don't). **Holmes can only ever draft — it never sends, posts, or deletes anything. That line is enforced in code, not by prompt.**

> **Install:** [download the latest Holmes installer](https://github.com/tryholmes/holmes-local/releases/latest/download/Holmes.dmg) and follow [INSTALL.md](INSTALL.md). First launch prepares the browser extension and helps connect your tools.

---

## The one-paragraph mental model

> **Structured reads are the eyes. The local model is the hands. Composio (optional) is the reach. You are the send button.**

Holmes reads your screen every few seconds from *structured* sources — the browser extension's view of the DOM, or the macOS Accessibility tree — and turns that into one deterministic sentence about what you're doing (`LiveContext`). No model writes that sentence, which is exactly why it is never a confident guess. A deterministic matcher then decides *"is there something actionable here?"* When there is, the local model wakes up, gathers what it needs (the screen, and your connected tools if you have wired up Composio MCP), and prepares a deliverable. Everything it prepares is a **draft you review**. The only outbound action Holmes can perform on its own is creating a draft inside *your own* Gmail Drafts folder — and even that is exact-match allow-listed and recipient-grounded so it can never be turned into a send.

---

## How it works, step by step

Take the chat-reply example (every playbook follows the same shape):

1. **You have a conversation open** in Messages, Discord, Slack, WhatsApp, Telegram, or Signal. That's the only thing you do.
2. **Holmes reads the screen.** Every ~3 seconds it reads the page through the browser extension (exact DOM values) or the macOS Accessibility tree, falling back to on-device Apple Vision OCR only when neither is available — and when it's down to OCR it *says so* instead of describing what it can't actually read.
3. **A deterministic matcher classifies the opportunity.** *"This is a chat with a real contact that may need a reply."* App identity + extracted entities → playbook, computed on-device from that structured read. If nothing's actionable, nothing happens — Holmes stays silent.
4. **The screen glows + your trackpad buzzes.** A rotating sweep appears around the screen edges the instant an action starts, with a haptic tap so you feel it caught something.
5. **The local model acts.** It builds a goal from the on-screen context and, where a playbook allows it, calls tools — always through the deterministic tool loop in `OllamaClient`, one request at a time on your GPU.
6. **The model drafts** a reply in the conversation's tone.
7. **You get told.** The glow pulses, the trackpad double-buzzes, a macOS notification fires, and an editable review card slides in. The draft is staged into the input field, never submitted.
8. **You press send.** In the app, on your terms. **Holmes physically cannot** — send/post/delete tools are filtered out of its reach at the code level.

---

## What Holmes does — the five golden playbooks

Holmes used to ship 154 heuristic playbooks. They fired randomly, burned a full matcher sweep every tick, and eroded trust. This build ships **five** deliberately engineered automations, each chosen for deterministic, works-every-time execution, a high-precision trigger with near-zero false positives, and real daily value.

| Playbook | Fires when… | Lane | What you get |
|---|---|---|---|
| **Meeting Join** | a Zoom / Meet / Teams meeting is *starting* (an imminence phrase is on screen, not just a link) | app (`open_url`) | the meeting link is opened for you — reversible, you can leave |
| **Terminal Command Help** | a command in your terminal just failed (`command not found`, `permission denied`, `exited with code`, …) | teach (zero mutation) | a one- or two-sentence spoken explanation of why it failed and the fix |
| **GitHub Brief** | a specific `owner/repo` is open (the slug is in the window title, never the feed or notifications) | read-only draft | a 5-line brief: what it is, open PRs, open issues, next actions |
| **Chat Reply** | a chat app is frontmost and a real contact was extracted from the AX tree / DOM | draft, confirm | a tone-matched reply staged into the input field, never sent |
| **Downloads Sorter** | Finder is showing *exactly* your Downloads folder with 10+ loose files | file lane, undoable | files sorted into Images / Documents / Archives / Installers / Media, every move individually undoable |

New automations must clear the same bar: a deterministic backend, and a matcher that keys off **structural** signals (app identity, window title, extracted entities) — never loose words in OCR.

### Beyond the playbooks
- **Ask and point** (hold Fn / globe): dictate a question on-device and Holmes answers out loud, drawing on the screen to point the way.
- **Command bar** (`Ctrl + Space`): `/run …` a one-off goal through the same planner and confirmation gates.
- **Your own playbooks** (the Holmes SDK): drop a JSON manifest in `~/Library/Application Support/Holmes/playbooks/` and it loads as a draft-only playbook next to the built-ins. Add tools with any MCP server, and use the `holmes-sdk` CLI to scaffold and lint both. Start at [`holmes/sdk/`](holmes/sdk/README.md).
- **Local MCP server** (opt-in, off by default): expose your live screen context to other agents (Claude Desktop, Cursor, a voice agent) over a loopback-only MCP endpoint.

---

## The action doctrine — the "school of agentic actions"

Every step Holmes takes runs on the **most deterministic backend that can do the job**:

1. **Structured verbs first** — `nsworkspace` (open app / URL / reveal file / join meeting), `file` (move / trash / create folder, with a real undo), `eventkit` (calendar), `composio` (a hosted action by exact slug).
2. **Accessibility element actions second** — `ax_press` a named button, `ax_type` into a named field.
3. **Pixels last** — screenshot → click / type / scroll, only for genuinely visual work no structured verb covers.

The planner **never emits coordinates**. It cannot see the screen, so any coordinate it wrote would be fiction; a visual step's input is always empty and the screen-driven executor places the click itself from the live frame. A preflight pass refuses plans that violate this before anything runs, and any step that is not reversible pauses for your confirmation.

---

## The safety model — draft-never-send

This is the load-bearing guarantee, and it survived multiple rounds of adversarial review (~57 attack payloads across builds, all blocked):

- **Autonomous mode runs a default-deny tool filter.** Before any tool reaches the model in a proactive run, its name is checked with whole-token matching: anything containing `SEND`, `DELETE`, `POST`, `PUBLISH`, `CREATE` (except the one exact allow-listed draft slug), `MODIFY`, `ARCHIVE`, `MOVE`, and dozens more mutation verbs is **structurally unavailable**. Read/list/fetch/search tools are allowed.
- **The one sanctioned write is `GMAIL_CREATE_EMAIL_DRAFT`** — exact-string allow-listed. A draft cannot send itself; you review it in Gmail.
- **Recipient grounding.** A draft-create call is rejected unless every `to`/`cc`/`bcc` address already appeared in data fetched earlier in the same run — so a prompt-injected email ("forward this to attacker@evil.com") cannot make Holmes draft to a stranger.
- **Meta-tool guard.** Composio routes real actions through a single `COMPOSIO_MULTI_EXECUTE_TOOL`; Holmes inspects the *inner* tool slugs of every such call and applies the same default-deny policy, so a send can't be smuggled inside a batch.
- **The prompt is never the only defense.** The filter is code, not instructions — even if a small local model is talked into trying to send, the tool simply isn't there.

---

## Requirements

- **An Apple Silicon Mac** (M1 or later). Intel Macs are not supported: the model runs on the GPU through Metal.
- **macOS 14 (Sonoma) or later.**
- **Unified memory: 16 GB recommended, 8 GB minimum.** The default model is picked by memory (see the table below); on 8 GB Holmes uses the smallest one and you should expect more misclicks.
- **[Ollama](https://ollama.com)** — the local model server. **0.33 or newer recommended** (`brew upgrade ollama`): it runs Hugging Face model imports on the native engine and honors "no thinking" for Qwen3-VL. The hard minimum is 0.12.10 (tool-call ids); newer models need newer servers (see the table below).
- **Disk:** about 3.3 GB for the default model.
- **Xcode 15 or later** if you build from source.

There is no API key. Readiness means *"is the Ollama server reachable, and is the chosen model pulled?"* Without both, Holmes still computes the deterministic `LiveContext` headline from DOM / Accessibility data, but nothing else runs — no drafting, no enrichment, no tool use — and it tells you what is missing rather than degrading into something that looks like an answer.

---

## Install

### 1. Install Ollama

Either the desktop app from [ollama.com/download](https://ollama.com/download), or:

```bash
brew install ollama
```

That is the only thing you have to install yourself. **Holmes starts the server for you** (`ollama serve`, detached, so it outlives Holmes) whenever it finds the server down, and if the Ollama desktop app is installed it launches that instead. You can turn auto-start off in **Holmes ▸ Settings ▸ Local Model**.

### 2. Get the model

On first launch Holmes probes the server, sees that no suitable model is pulled, and offers to download the recommended one for your machine — **`qwen3-vl:4b-instruct`, about 3.3 GB** on a 16 GB Mac. Download progress shows in the settings pane; everything stays on this Mac. If you prefer the terminal:

```bash
ollama pull qwen3-vl:4b-instruct
```

### 3. Install and run Holmes

[Download Holmes.dmg](https://github.com/tryholmes/holmes-local/releases/latest/download/Holmes.dmg), open it, and drag **Holmes** into **Applications**. Follow [INSTALL.md](INSTALL.md) for first-launch instructions. You can also [build from source](#build-from-source).

### 4. Permissions

On first launch, grant:

| Permission | Why |
|---|---|
| **Screen Recording** | to see and OCR your screen |
| **Accessibility** | to read native-app text and stage drafts into fields |
| **Calendar** | to detect meetings and prep for them |
| **Notifications** | to tell you when it's prepared something |
| **Microphone / Speech Recognition** | only if you use hold-Fn-to-talk (on-device dictation) |

**After granting Screen Recording, fully quit and relaunch once** — macOS only applies that grant on restart.

### 5. Browser extension (exact page context) — recommended

Whenever the **Connect Your Browser** onboarding step opens, Holmes automatically prepares or refreshes its bundled extension in **`~/Downloads/Holmes Extension`**. No button click is needed to create the folder; opening that step again also recreates it if it was removed.

Click **Open extension folder** in onboarding or **Holmes ▸ Settings ▸ Privacy** to open it in Finder. **Copy folder path** copies its full path if you prefer to paste it into Chrome's file picker. Both controls also prepare or refresh the folder.

In Chrome, open **Extensions → Developer mode → Load unpacked**, then choose **Downloads → Holmes Extension**. Keep that folder in place after loading it: Chrome reads the extension from there. Comet, Brave, Edge and other Chromium browsers use the same unpacked-extension flow. The extension posts the structured contents of the page you're actually looking at to Holmes on `127.0.0.1:5766`, which is the only source Holmes trusts enough to quote.

The extension mints its own secret, so you have to authorize it once: **Holmes ▸ Settings ▸ Privacy ▸ Pair browser extension**. That opens a 2-minute window during which the next extension that posts is adopted and remembered; outside that window an unrecognized token is rejected. Nothing pairs itself silently — a loopback port is reachable by every process on your Mac, so first-contact trust is not something Holmes hands out on its own.

### 6. Composio MCP (the reach) — optional

Holmes works without any connected tools: the five playbooks read the screen and act locally. If you want GitHub Brief to fetch real PRs and issues, or `/run` goals that touch Gmail, Calendar, GitHub, and web search, connect a [Composio](https://composio.dev) MCP server and drop it into `~/.holmes/mcp.json`:

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

(The `x-api-key` there is Composio's own header; it is the only key anywhere in this setup, and it is optional.) The full walkthrough — per-toolkit OAuth, remote / HTTP servers, stdio servers, and the local Holmes MCP server — is in [`holmes/MCP-SETUP.md`](holmes/MCP-SETUP.md). On launch you'll see `[MCP] composio: N tools` in the console and `Local model (qwen3-vl:4b-instruct) · MCP: N tools` in the panel.

---

## Models

Holmes uses **one** model for everything: it must support both `tools` and `vision`, because Holmes drives the screen from screenshots and acts through tool calls in the same loop (Ollama can't split those across two models without a 20 s+ reload on every alternation). Non-thinking `instruct` variants are preferred — on a laptop a thinking model spends minutes per step deliberating, which is unusable for a screenshot → act loop.

The curated list in **Settings ▸ Local Model** (`OllamaConfig.recommendedModels`):

| Model | Download | Min. memory | Min. Ollama | Notes |
|---|---|---|---|---|
| `qwen3-vl:2b-instruct` | 1.9 GB | 8 GB | 0.12.7 | Smallest. For 8 GB Macs. Sees the screen and calls tools; expect misclicks on dense UIs. |
| `qwen3-vl:4b-instruct` | 3.3 GB | 16 GB | 0.12.7 | **Default for 16 GB Macs.** Trained for GUI agents; good balance of speed and accuracy. |
| `qwen3-vl:8b-instruct` | 6.1 GB | 16 GB | 0.12.7 | More accurate; tight on 16 GB alongside a browser, comfortable on 24 GB+. |
| `qwen3.5:9b` | 6.6 GB | 24 GB | 0.17.3 | Newer unified vision model. Thinks by default; Holmes turns thinking off per request. |
| `qwen3-vl:30b-a3b-instruct` | 20 GB | 32 GB | 0.12.7 | Mixture-of-experts: fast per step for its size. Needs 32 GB+. |
| `gemma4:12b` | 7.6 GB | 16 GB | 0.20.0 | Google's current family. Requires Ollama 0.20 or newer. |

The default is picked by unified memory so it never swaps the machine to death: under 12 GB → `2b`, under 32 GB → `4b`, under 64 GB → `8b`, otherwise `30b-a3b`. Any other tag that advertises `tools` and `vision` in `ollama show` can be typed in; Holmes checks the capabilities and refuses a model that lacks either ("*model* can't drive Holmes") instead of silently dropping your screenshots.

### Local model settings

All of these live in **Holmes ▸ Settings ▸ Local Model** (stored in `UserDefaults`, nothing secret):

| Setting | Default | Why it exists |
|---|---|---|
| **Server** | `http://127.0.0.1:11434` | Where Ollama answers. You can point it at another machine, but then your screenshots go there. |
| **Model** | by memory (see above) | The one tag every request uses. |
| **Context window** (`num_ctx`) | 8192 (<12 GB) / 16384 (<32 GB) / 32768 | Ollama's default on a small GPU is 4096, which the first turn of a computer session already overflows. Changing it reloads the model, so it is one value for the whole app. |
| **Keep model loaded** (`keep_alive`) | 30 minutes | Holmes fires every few seconds; a short keep-alive would pay a 20–40 s cold load constantly. Shorten it if RAM is tight; "Forever" is sent as `-1m`. |
| **Let the model think before acting** | off | Lets a thinking-capable model deliberate. Multiplies per-step latency 5–10×. |
| **Click coordinates** | Auto (model-aware) | How the model reports screen positions. Holmes asks for pixels of the screenshot frame; some vision models are trained to answer in a normalized 0–1000 grid. Flip this if clicks land in the wrong place in a consistent, scaled way. The engine converts in one place (`WindowCapture.modelPointToGlobalAppKit`), so switching is safe at runtime. Default is model-aware: Qwen3-VL models answer on a 0–1000 grid no matter what the prompt says (measured on qwen3-vl:4b, Ollama 0.17.4), so they default to *normalized*; other families default to *pixels*. If clicks land in the wrong place, flip this setting. |
| **Start Ollama automatically** | on | Spawn `ollama serve` when the server is down (local host only), restart it if it dies, and start it from the pane's refresh arrow. |

Under the hood, `OllamaClient` serializes every request through a single gate (there is one GPU), gives agent turns priority over background enrichment, keeps only the three newest image-bearing messages (older screenshots are replaced with a placeholder), caps tool results so the transcript fits the context window, never sends `format` together with `tools`, restates JSON schema descriptions in the prompt (Ollama's grammar drops them), and coerces the common small-model slips in tool arguments (`{x, y}` → `coordinate`, JSON-as-string → JSON). Streaming keeps the connection alive through cold loads.

---

## What runs where

| | Where |
|---|---|
| Screen capture, Accessibility reads, Apple Vision OCR, the deterministic `LiveContext` headline | on-device, always |
| The model — drafting, enrichment, planning, the screenshot → act loop | **Ollama on this Mac** (or the host you configure) |
| Dictation (hold Fn) | on-device Apple speech recognition |
| Spoken answers | Apple's on-device voices by default; **ElevenLabs** if you add a key — the one optional cloud service, see below |
| Composio / MCP tool calls | your connected services, only if you configure them |
| Memory | a local SQLite file |

**The one optional cloud voice.** Holmes speaks its "teach" answers and status lines. Out of the box that is Apple's built-in text-to-speech, entirely local. If you want a more natural voice you can add an ElevenLabs key (a one-line file at `~/.holmes/elevenlabs_key`, migrated into the Keychain on first read); then the *text Holmes speaks* — and only that — is sent to ElevenLabs. Delete the key and it is back to on-device.

---

## Known beta limitations

Be honest with yourself about what a 4-billion-parameter model on a laptop can do:

- **Local models misclick more than hosted ones.** On dense UIs the model may pick the wrong element or a neighbouring pixel. The action doctrine limits the blast radius — structured verbs and Accessibility actions do most of the work, pixel clicks are last resort, and anything irreversible waits for your confirmation — but the visual route is noticeably less reliable than the hosted build.
- **Each step takes seconds.** A screenshot → decide → act turn is a full prompt evaluation of a few thousand tokens plus an image on your GPU. Expect 3–15 s per step on an M-series laptop, longer with a browser eating memory. Playbooks are capped at a small number of iterations for that reason.
- **The first run downloads a model** (3.3 GB by default) and the first request after launch pays a 20–40 s cold load. Holmes warms the model up after the server is ready and keeps it resident (`keep_alive`), so this is a once-per-launch cost.
- **Thinking models are slow.** `qwen3.5:9b` and `gemma4:12b` think by default; Holmes sends `think: false`, and the **Let the model think before acting** toggle exists for experiments, not for daily use.
- **Memory pressure is real.** A 4b model plus a 16k context fits comfortably in 16 GB; the 8b model next to Chrome does not always. If the machine starts swapping, drop a size or shorten the context.
- **Background enrichment is dropped, not queued, while an agent session owns the GPU** (`AgentError.busy`). The context card may say less while Holmes is in the middle of a task.
- **Ollama version skew.** Newer models need newer servers; the settings pane warns when yours is older than a model needs. `brew upgrade ollama` or update the desktop app.

---

## Build from source

```bash
git clone <this repository>
cd holmes-local/holmes          # the repo folder, then the Xcode project folder
xcodebuild -project holmes.xcodeproj -scheme holmes -configuration Debug build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

That produces an ad-hoc-signed `holmes.app` under Xcode's DerivedData (`xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR` prints the folder). Or open `holmes.xcodeproj` in Xcode, select the `holmes` scheme, and press **⌘R**.

**Signing and macOS permissions.** macOS ties the Screen Recording / Accessibility grants to the app's code signature. Ad-hoc signing changes the signature on every build, which invalidates those grants; for day-to-day development set your own **Development Team** under Signing & Capabilities so the signature is stable across rebuilds. If a grant ever goes stale, toggle holmes.app off/on in System Settings → Privacy and relaunch.

CI builds exactly this command on `macos-14` — see [`.github/workflows/build.yml`](.github/workflows/build.yml).

---

## Usage and hotkeys

Holmes is mostly hands-off: it runs in the menu bar and acts on its own. But you can reach in:

| Shortcut | Action |
|---|---|
| `Option + Space` | Toggle the main panel (context, drafts, meetings, activity) |
| `Ctrl + Space` | Open the command bar (`/run …`) |
| `Cmd + \` | Toggle the floating side icon |
| **Hold Fn (globe)** | Push-to-talk: ask a question, Holmes answers out loud and points on screen |
| `Cmd + Option + Esc` | Emergency stop for a computer-control run |

Say **“open Spotify”** while holding Fn, or type it into the command bar. Explicit
app-opening requests use the native macOS launcher immediately, including polite
forms such as “can you open Spotify?”. They work without Ollama or the Computer
control toggle; clicking and typing inside apps still require that toggle.
Holmes reports the actual launch result, including when an app is not installed.

- **Settings → Automations**: per-playbook on/off toggles.
- **Settings → Local Model**: server status, model picker and download, and under Advanced the Context window, Keep model loaded, Let the model think before acting, Click coordinates and Start Ollama automatically controls.
- **Main panel → Drafts**: everything Holmes has prepared; tap to re-open the review card.
- **Glow language**: rotating sweep = *thinking*; vibrating zoom-in pulse + double-buzz = *done, something's ready*.

**Fastest way to see it work:** open a terminal and run a command that fails (`git pusj`). Holmes should explain the typo out loud within a few seconds.

---

## Troubleshooting

- **"Couldn't reach ollama.com" when downloading the model** — `registry.ollama.ai` is a separate host from `ollama.com` and is occasionally unreachable on some networks. On Ollama 0.33+ Holmes falls back automatically to the same weights from Hugging Face and registers them under the expected tag. To do it by hand:
  ```
  ollama pull hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M
  printf 'FROM hf.co/unsloth/Qwen3-VL-4B-Instruct-GGUF:Q4_K_M\nRENDERER qwen3-vl-instruct\nPARSER qwen3-vl-instruct\nPARAMETER temperature 0.7\nPARAMETER top_k 20\nPARAMETER top_p 0.8\n' > Modelfile
  ollama create qwen3-vl:4b-instruct -f Modelfile
  ```
  (`RENDERER qwen3-vl-instruct` is what makes Ollama advertise tool calling for the import; without it the model shows only `vision`.)
- **Every step takes minutes** — you are on a *thinking* tag (`qwen3-vl:4b` rather than `qwen3-vl:4b-instruct`). Older Ollama versions cannot switch its thinking off. Install the instruct tag (Settings ▸ Local Model ▸ Download); Holmes switches to it automatically.

- **"Ollama is not installed"** — Holmes looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/Applications/Ollama.app`, `~/Applications/Ollama.app`, `/opt/local/bin`, then `PATH`. Install from ollama.com or `brew install ollama`.
- **"Ollama isn't running" / "Ollama didn't start"** — Holmes spawns `ollama serve` and logs its output to **`~/Library/Logs/Holmes/ollama-serve.log`**. Look there first. A common cause is the desktop Ollama app already owning port 11434 (then Holmes should have launched the app instead; quit stray `ollama serve` processes).
- **"Model … isn't downloaded"** — pull it from the settings pane or `ollama pull <tag>`.
- **"… can't drive Holmes"** — the chosen tag lacks `tools` or `vision` (`ollama show <tag>` lists capabilities). Pick one from the table.
- **Clicks land off-target in a consistent, scaled way** — try the **Click coordinates** setting under Advanced (Screen pixels ↔ 0–1000 grid).
- **Everything is slow** — check `ollama ps`: if the model shows partly on CPU, drop a model size or shorten the context window. Make sure **Let the model think before acting** is off.
- **Holmes acts on the focused window** — click into the app you want it to help with; a background tab won't trigger while a terminal is frontmost.
- MCP problems: see the Troubleshooting section of [`holmes/MCP-SETUP.md`](holmes/MCP-SETUP.md).

---

## Architecture

Everything lives under `holmes/holmes/`. The `Core/` layer is the engine; `Views/` is the UI; `Core/Playbooks/` and `Core/Autonomy/` are the autonomous brain.

```
Core/
  LiveContext         the anti-hallucination core — deterministic headline formatter + validator
  BrowserBridge       loopback receiver for the extension's exact DOM reads (token-gated)
  ScreenEngine        SCK + Accessibility screen capture (3s loop), blank-frame + permission handling
  OCREngine           Apple Vision text recognition (last resort; never quoted)
  ContextEngine       heuristic screen understanding, entity extraction, app/site detection
  HolmesAgent         orchestrator — wires capture -> LiveContext -> playbooks -> UI
  MemoryStore/Feed    SQLite memory of past contexts + the dashboard mirror
  ReplyComposer       grounded reply drafting from a real thread + memory
  OllamaConfig        the one model: host, tag, context, keep-alive, thinking, coordinate space, readiness
  OllamaClient        /api/chat client + agentic tool loop (serialized gate, image pruning, arg coercion)
  OllamaServer        server lifecycle: probe, auto-start, pull with progress, warm-up
  Playbooks/
    PlaybookModels    Playbook/Draft types + ComposioCatalog (the draft-never-send tool policy)
    DefaultPlaybooks  the five golden playbooks (structural matchers, goals, cooldowns)
    PlaybookEngine    evaluate -> debounce -> cooldown -> fire; quiet-when-empty; notifications
    TriggerBrain      deterministic opportunity classifier over LiveContext (surface + entities)
    Autopilot         scheduler for time-based work
  Autonomy/
    ActionPlanner     the doctrine prompt: structured verbs > AX > pixels; never coordinates
    AutonomousActionRunner  preflight + confirmation gates + execution
    BackendRouter     nsworkspace / file / eventkit / app / composio / computer lanes
  HolmesBrain         the model action loop (runPlaybook), guarded Composio meta-execute
  ComputerUseEngine   the screenshot -> act loop (WindowCapture + InputController)
  MCPClient/MCPModels MCP host (stdio + Streamable-HTTP), tool namespacing
  MCPServer           Holmes-as-MCP-server (opt-in, loopback-only)
  CalendarEngine      EventKit meeting detection
  MeetingJoinEngine   deep-link join (Zoom/Meet/Teams/Webex) + notifications
  ActionExecutor      AX/CGEvent staging into fields (stages text, never presses Send)
  SpeechSynthesizer   priority speech queue; Apple voices, ElevenLabs optional
  VoiceInputController on-device push-to-talk dictation

Views/
  MainPanel/          context card, drafts, meetings, activity (glass UI)
  Confirmation/       the draft review card (glass, editable, Copy/Insert/Dismiss)
  Glow/               ScreenGlow — the edge glow + trackpad haptics; VisualGuidanceOverlay
  NotchAnimation/     the notch HUD (ported from boring.notch, GPL-3.0 — see THIRD_PARTY_NOTICES.md)
  Settings/           SettingsWindow incl. LocalModelSettingsView (Ollama status, model picker, pull)
  Onboarding/, SideIcon/
```

**Two firing paths converge on cooldown-safe `fire()`:** the heuristic `PlaybookEngine.evaluate()` (matches -> dwell-debounce -> cooldown) and `TriggerBrain`, which maps the structured `LiveContext` (surface + entities) onto a playbook for opportunities the heuristics miss. Both are single-flight and share per-context cooldowns so nothing double-drafts. TriggerBrain consults the model for exactly one thing — an ambiguous screen — and even then the model can only choose among the fireable opportunities or answer "none"; it never invents entities and never sees an OCR-only screen.

---

## Privacy

**Everything stays on your Mac by default.** There is no account, no API key, no telemetry, and no analytics. Concretely:

- **On-device, always:** screen capture (ScreenCaptureKit), Accessibility reads, Apple Vision OCR, dictation, and the deterministic `LiveContext` headline — the sentence on the context card is computed from structured fields on your machine and never leaves it to be written.
- **Sent to the local model (Ollama on `127.0.0.1` by default):** the on-screen context a playbook acts on, the screenshots of a computer-control run, and the ambiguous-screen check `TriggerBrain` occasionally asks. Ollama does not phone home with your prompts. If you point the Server setting at another machine, that machine sees this data instead.
- **Sent to ElevenLabs, only if you add a key:** the text Holmes speaks. Nothing else.
- **Sent to your connected services, only if you configure Composio / MCP:** tool calls, under the draft-never-send filter.
- Calendar access is read-only.
- The browser bridge is **loopback-only and token-gated**, and pairs only inside a window you open in Settings. The local MCP server is **off by default** — while it's on, any process on this Mac can read your screen context through it.
- Memory lives in a local SQLite file. Settings live in `UserDefaults`; the only credential Holmes ever stores is the optional ElevenLabs key, in the Keychain.

---

## Contributing

Issue first, one focused branch per change, PRs into `main` that say what changed, why, and how it was tested — and keep the action doctrine. Details in [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## License

Holmes Local is released under the **GNU General Public License, version 3.0** — see [`LICENSE`](LICENSE). Copyright © 2026 Holmes Local contributors.

Why GPL: the notch HUD under `holmes/holmes/Views/NotchAnimation/` is a direct port of [boring.notch](https://github.com/TheBoredTeam/boring.notch), which is GPL-3.0. Distributing a binary that includes that port makes the combined work subject to GPL-3.0, so the open-source build is licensed as a whole under the same terms rather than pretending otherwise. The computer-control, visual-guidance, and voice layers derive from OpenClicky and [trycua/cua-driver](https://github.com/trycua/cua) (both MIT) — their notices are reproduced in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). MIT code can be combined into a GPL work; the reverse is not true.

The license choice can be revisited if the notch port is ever replaced with independently developed code: at that point nothing in this repository would require GPL, and a more permissive license would be on the table. Until then, GPL-3.0 it is.

---

*Holmes — it watches, it understands, it prepares. You decide.*
