# Holmes — Zero Prompt AI for macOS

Holmes is a local-first AI desktop agent that watches your screen and suggests actions before you ask. No prompts. No cloud. Everything runs on your machine.

---

## What It Does

- **Reads your screen** — understands what app you're in and what you're working on
- **Suggests actions** — auto-drafts replies, fills forms, breaks tasks into steps
- **Joins your meetings** — detects calendar events and auto-joins 2 minutes before they start
- **Responds to commands** — type `/run`, `/ask`, `/plan`, `/watch` from the command bar
- **Works offline** — powered by a local LLM via Ollama, nothing leaves your device

---

## UI

Three surfaces, all floating and transparent (Apple-glass style):

| Surface | Hotkey | What it does |
|---|---|---|
| **Command Bar** | `Ctrl + Space` | Type commands or questions about your screen |
| **Main Panel** | `Option + Space` | See context, suggested actions, meetings, and activity |
| **Side Icon** | Always on | Floating icon on the screen edge — tap to open the panel |

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+
- [Ollama](https://ollama.com) — for AI features (optional, app works without it)

---

## Setup

### 1. Install Ollama

```bash
brew install ollama
```

Or download from [ollama.com](https://ollama.com).

### 2. Pull a model

```bash
ollama pull llama3.2:3b
```

Holmes auto-selects the best available model. Also works with `llama3.2`, `llama3`, `phi3`, and `mistral`.

### 3. Start Ollama

```bash
ollama serve
```

> Keep this running in the background while using Holmes. Without it, Holmes still works — context detection falls back to heuristics but AI suggestions won't be generated.

### 4. Clone and open

```bash
git clone https://github.com/tryholmes/Frontend-UI.git
cd Frontend-UI/holmes
open holmes.xcodeproj
```

### 5. Build and run

Select the `holmes` scheme in Xcode and press **⌘R**.

On first launch, Holmes will ask for three permissions:

| Permission | Why it's needed |
|---|---|
| **Screen Recording** | To read your screen and understand context |
| **Accessibility** | To take actions in apps on your behalf |
| **Calendar** | To detect upcoming meetings and auto-join |

Grant all three — you can also do this manually in **System Settings → Privacy & Security**.

---

## Gmail Extension (Optional)

For richer Gmail context (compose fields, sender info) without OCR:

1. Open Chrome or Arc → `chrome://extensions`
2. Enable **Developer mode**
3. Click **Load unpacked** → select the `holmes-extension/` folder

The extension runs silently and only communicates with Holmes locally.

---

## Hotkeys

| Shortcut | Action |
|---|---|
| `Ctrl + Space` | Open / close command bar |
| `Option + Space` | Toggle main panel |
| `Cmd + \` | Toggle side icon |

---

## Commands

Type any of these in the command bar (`Ctrl + Space`):

| Command | What it does |
|---|---|
| `/run` | Execute a task autonomously on screen |
| `/ask` | Ask a question about what's on your screen |
| `/plan` | Break a goal into actionable steps |
| `/watch` | Monitor the screen for a specific change |
| `/done` | Mark the current task complete |

---

## Calendar & Meeting Auto-Join

Holmes monitors **Apple Calendar** in the background. Any calendar synced to Apple Calendar works — iCloud, Google Calendar, Exchange, Outlook.

Two minutes before a meeting, Holmes will:
- Send a macOS notification
- Show a meeting card in the main panel
- Offer a **Join Now** button that opens the call directly

Supported: Zoom, Google Meet, Microsoft Teams, Webex.

**To sync Google Calendar:** System Settings → Internet Accounts → Google → enable Calendars

---

## Privacy

- Screen captures and OCR run entirely on your device
- Ollama is fully offline — no data is sent to any server
- Calendar access is read-only
- No analytics, no telemetry, no account required
