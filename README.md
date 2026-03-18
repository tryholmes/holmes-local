# Holmes — Zero Prompt AI for macOS

Holmes is a local-first AI desktop agent that lives in your menubar. It watches your screen, understands what you're doing, and proactively suggests actions — without you ever needing to type a prompt.

Everything runs on your machine. No cloud. No API keys. No data leaves your device.

---

## Features

- **Context-aware** — reads your screen via OCR + Accessibility APIs to understand what app you're in and what you're doing
- **Proactive suggestions** — auto-drafts email replies, message replies, meeting prep notes
- **Calendar integration** — monitors Apple Calendar and auto-joins Zoom / Google Meet / Teams meetings 2 minutes before they start
- **Gmail browser extension** — reads compose/inbox context directly from the browser
- **Local LLM** — powered by Ollama (llama3.2:3b by default), fully offline
- **Zero prompt** — Holmes acts without you typing anything; just approve or dismiss

---

## Requirements

- macOS 14 (Sonoma) or later
- [Ollama](https://ollama.com) installed and running
- Xcode 15+

---

## Setup

### 1. Install Ollama

```bash
brew install ollama
```

Or download from [ollama.com](https://ollama.com).

### 2. Pull the model

```bash
ollama pull llama3.2:3b
```

Holmes will auto-select the best available model. Supported: `llama3.2:3b`, `llama3.2`, `llama3`, `phi3`, `mistral`.

### 3. Start Ollama

```bash
ollama serve &
```

> The `&` runs it in the background. Ollama must be running before you launch Holmes, otherwise the LLM features will be unavailable (context detection still works via heuristics).

### 4. Clone the repo

```bash
git clone https://github.com/tryholmes/Frontend-UI.git
cd Frontend-UI/holmes
```

### 5. Open in Xcode

```bash
open holmes.xcodeproj
```

### 6. Build & Run

Select the `holmes` scheme and hit **Run** (⌘R).

On first launch Holmes will ask for:
- **Accessibility** — required to control apps (type messages, click buttons)
- **Screen Recording** — required to capture and analyse your screen
- **Calendar** — required for meeting detection and auto-join

Grant all three when prompted, or open **System Settings → Privacy & Security** manually.

---

## Gmail Browser Extension

The `holmes-extension/` folder contains a Chrome/Arc extension that gives Holmes richer Gmail context (compose fields, sender info) without OCR.

To install:
1. Open Chrome/Arc → `chrome://extensions`
2. Enable **Developer mode**
3. Click **Load unpacked** → select the `holmes-extension/` folder
4. The extension runs silently and sends context to Holmes over localhost

---

## Calendar & Meeting Auto-Join

Holmes monitors **Apple Calendar** every 60 seconds. Any calendar synced to Apple Calendar works — iCloud, Google Calendar (via system sync), Exchange, Outlook.

**2 minutes before a meeting starts**, Holmes:
1. Fires a system notification
2. Shows a "MEETING STARTING SOON" confirmation card
3. Pre-warms the Zoom app (if applicable)
4. Lets you click **Join Now** to deep-link directly into the call

Meeting links are detected from the event's URL field, Notes, and Location — supporting Zoom, Google Meet, Microsoft Teams, and Webex.

**To sync Google Calendar with Apple Calendar:**
System Settings → Internet Accounts → Google → enable Calendars

---

## Hotkeys

| Shortcut | Action |
|---|---|
| `Ctrl + Space` | Open command bar |
| `Option + Space` | Toggle main panel |
| `Cmd + \` | Toggle side icon |

---

## Commands

| Command | Description |
|---|---|
| `/run` | Execute an autonomous task |
| `/ask` | Ask a free-form question about what's on screen |
| `/plan` | Break a goal into steps |
| `/watch` | Monitor screen continuously for changes |
| `/done` | Mark a task complete |

---

## Architecture

```
Holmes
├── Core/
│   ├── HolmesAgent.swift        — orchestrator: screen → context → suggestions
│   ├── ScreenEngine.swift       — ScreenCaptureKit screenshot loop
│   ├── OCREngine.swift          — Apple Vision framework text recognition
│   ├── ContextEngine.swift      — heuristic + LLM context detection
│   ├── LocalModelEngine.swift   — Ollama HTTP client (llama3.2:3b)
│   ├── CalendarEngine.swift     — EventKit calendar monitor
│   ├── MeetingJoinEngine.swift  — meeting auto-join + notifications
│   ├── BrowserBridge.swift      — localhost socket server for browser ext
│   ├── ActionExecutor.swift     — Accessibility API app control
│   └── CommandBus.swift         — command routing between views
├── Views/
│   ├── MainPanel/               — context card, suggestions, activity log, meetings
│   ├── SearchBar/               — command input bar
│   ├── Confirmation/            — action approval overlay
│   ├── SideIcon/                — floating sidebar icon
│   └── Onboarding/              — first-run setup flow
└── holmes-extension/            — Chrome/Arc Gmail extension
```

---

## Privacy

- All processing is local — screen captures, OCR, and LLM inference never leave your machine
- Ollama runs entirely offline
- Calendar data is read-only and never stored or transmitted
- No analytics, no telemetry
