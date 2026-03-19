# Holmes — Zero Prompt AI for macOS

Holmes is a local-first AI desktop agent that lives on the edge of your screen. It watches your screen, understands what you're doing, and proactively surfaces actions — before you ever need to type a prompt.

Everything runs on your machine. No cloud. No API keys. No data leaves your device.

---

## What It Looks Like

Holmes has three UI surfaces, all built in SwiftUI with a transparent Apple-glass aesthetic (frosted `NSVisualEffectView` blur + white layering — like macOS Spotlight or Control Center):

| Surface | Hotkey | Description |
|---|---|---|
| **Command Bar** | `Ctrl + Space` | Spotlight-style input strip — type commands or slash-commands |
| **Main Panel** | `Option + Space` | Floating sidebar — context card, suggested actions, meetings, activity log |
| **Side Icon** | Always visible | Floating character icon on the screen edge — tap to toggle the panel |

---

## Features

- **Apple Glass UI** — transparent frosted-glass windows that float over any app, matching macOS system aesthetics
- **Context-aware** — reads your screen via ScreenCaptureKit + Apple Vision OCR to understand what app you're in and what you're working on
- **Proactive suggestions** — auto-drafts email replies, message replies, form completions, and task plans based on current screen context
- **Slash commands** — `/run`, `/ask`, `/plan`, `/watch`, `/done` from the command bar
- **Calendar integration** — monitors Apple Calendar and auto-joins Zoom / Google Meet / Teams meetings 2 minutes before they start
- **Gmail browser extension** — reads compose/inbox context directly from Chrome/Arc without needing OCR
- **Local LLM** — powered by Ollama (llama3.2:3b by default), fully offline
- **Zero prompt** — Holmes acts without you typing anything; just approve or dismiss suggested actions
- **Activity log** — every action Holmes takes or suggests is logged with timestamps

---

## How It Works

```
Screen → ScreenEngine (ScreenCaptureKit)
       → OCREngine (Apple Vision)
       → ContextEngine (heuristics + LLM)
       → HolmesAgent (orchestrator)
       → ActionSuggestions (approve / dismiss)
       → ActionExecutor (Accessibility API)
```

1. **ScreenEngine** captures a screenshot every few seconds using ScreenCaptureKit
2. **OCREngine** runs Apple Vision text recognition on the capture
3. **ContextEngine** combines OCR text + active app name to infer what the user is doing (writing an email, filling a form, in a meeting, etc.)
4. **HolmesAgent** sends the context to the local LLM (Ollama) and receives suggested actions
5. The **Main Panel** displays the context + suggestions — user can approve individually or "Approve All"
6. **ActionExecutor** carries out approved actions via macOS Accessibility API (typing, clicking, form-filling)

If Ollama is not running, Holmes falls back to heuristic context detection — the UI and calendar features still work fully.

---

## Architecture

```
holmes/
├── App/
│   ├── holmesApp.swift              — app entry + Settings scene
│   ├── AppDelegate.swift            — lifecycle, onboarding, hotkeys
│   └── Permissions.swift            — permission helpers
│
├── Core/
│   ├── HolmesAgent.swift            — main orchestrator (screen → context → suggestions)
│   ├── ScreenEngine.swift           — ScreenCaptureKit screenshot loop
│   ├── OCREngine.swift              — Apple Vision text recognition
│   ├── ContextEngine.swift          — heuristic + LLM context detection
│   ├── LocalModelEngine.swift       — Ollama HTTP client (llama3.2:3b)
│   ├── CalendarEngine.swift         — EventKit calendar monitor + meeting detection
│   ├── MeetingJoinEngine.swift      — meeting auto-join, notifications, deep-links
│   ├── BrowserBridge.swift          — localhost socket server for browser extension
│   ├── ActionExecutor.swift         — Accessibility API app control (type, click)
│   ├── CommandBus.swift             — command routing between views
│   ├── HotkeyManager.swift          — global hotkey registration
│   ├── MenuBarManager.swift         — menu bar status item
│   ├── KeychainManager.swift        — secure token storage
│   └── ClerkAuthManager.swift       — auth state management
│
├── Views/
│   ├── SearchBar/                   — command bar (Ctrl+Space)
│   │   ├── SearchBarView.swift      — glass input strip with slash-command autocomplete
│   │   ├── SearchBarWindow.swift    — floating NSPanel controller
│   │   ├── CommandViewModel.swift   — command parsing + execution state
│   │   └── SearchViewModel.swift    — search/filter logic
│   │
│   ├── MainPanel/                   — floating sidebar panel (Option+Space)
│   │   ├── MainPanelView.swift      — root layout + staggered card entrance animations
│   │   ├── MainPanelWindow.swift    — floating NSPanel controller
│   │   ├── ContextCard.swift        — detected context display with live dot
│   │   ├── ActionSuggestions.swift  — suggested actions list + Approve All CTA
│   │   └── ActivityLog.swift        — collapsible recent activity with staggered rows
│   │
│   ├── Confirmation/                — action approval overlay
│   │   ├── ConfirmationView.swift
│   │   └── ConfirmationWindowController.swift
│   │
│   ├── SideIcon/                    — floating edge icon
│   │   ├── SideIconView.swift       — animated character + badge dot
│   │   └── SideIconWindow.swift     — draggable edge-pinned NSPanel
│   │
│   ├── Onboarding/                  — first-run setup flow (glass window)
│   │   ├── OnboardingFlow.swift     — step router with slide transitions
│   │   ├── WelcomeScreen.swift
│   │   ├── HowItWorksScreen.swift
│   │   ├── PermissionsScreen.swift
│   │   └── ReadyScreen.swift
│   │
│   ├── Login/                       — auth screen (glass window)
│   │   ├── LoginView.swift
│   │   └── LoginWindow.swift
│   │
│   └── NotchAnimation/              — notch-aware status animation (MacBooks)
│
├── Components/                      — reusable SwiftUI components
│   ├── GlassCard.swift              — AppleGlassBackground, VisualEffectBlur, GlassBorderModifier
│   ├── NoirButton.swift             — primary (black CTA) / secondary / ghost button styles
│   ├── NoirTextField.swift          — glass-styled input fields
│   ├── NoirCharacterView.swift      — Holmes character image view
│   └── GrainOverlay.swift           — optional film grain texture overlay
│
├── Design/
│   ├── NoirColors.swift             — full Apple-glass color palette + legacy aliases
│   ├── NoirFonts.swift              — typography scale (SF Mono + SF Pro)
│   └── AnimationCurves.swift        — shared spring + easing presets
│
└── Resources/
    └── NoirCharacter (asset)        — Holmes detective character image

holmes-extension/                    — Chrome / Arc browser extension
├── manifest.json
└── content.js                       — reads Gmail compose/inbox, posts to BrowserBridge
```

---

## UI Design System

Holmes uses a custom **Apple Glass** design system — all windows are transparent `NSPanel`s with `NSVisualEffectView` blur underneath SwiftUI layers.

### Color Tokens (`NoirColors`)

| Token | Value | Usage |
|---|---|---|
| `glassSurface` | white 8% | Card and panel fill |
| `glassElevated` | white 13% | Hovered rows, raised surfaces |
| `glassChrome` | white 5% | Header / footer chrome |
| `glassBorder` | white 18% | Card borders |
| `glassDivider` | white 10% | Dividers and separators |
| `textPrimary` | white 92% | Headings, active labels |
| `textSecondary` | white 60% | Body text, descriptions |
| `textTertiary` | white 38% | Timestamps, metadata |
| `ctaBackground` | `#0E0E0E` | Primary button (black pill) |
| `ctaForeground` | white | Label on black button |
| `success` | `#4CD97A` | Completed actions, live dot |
| `error` | `#FF5E5E` | Errors, urgent meeting alerts |
| `calendarBlue` | `#5EB5FF` | Calendar / meeting accent |

### Glass Window Pattern

Every floating window follows this pattern:

```swift
// Window setup
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false

// SwiftUI root view
ZStack {
    AppleGlassBackground(cornerRadius: 18, material: .hudWindow)
    // content...
}
.clipShape(RoundedRectangle(cornerRadius: 18))
.overlay(RoundedRectangle(cornerRadius: 18).stroke(glassStroke, lineWidth: 0.75))
.shadow(color: .black.opacity(0.42), radius: 32, x: 0, y: 10)
```

### Animation System

| Animation | Spec | Used For |
|---|---|---|
| Card entrance | spring(0.44, 0.82) + staggered delay | Panel cards sliding in on show |
| Row entrance | spring(0.40, 0.78) + 60ms per-index delay | Action rows, activity rows |
| Checkbox bounce | spring(0.25, 0.60) | Checkbox select/deselect |
| Collapse toggle | spring(0.36, 0.72) | ActivityLog expand/collapse |
| Hover scale | easeInOut(0.14) | All interactive elements |
| Window fade | easeOut(0.22) | Panel appear/disappear |

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+
- [Ollama](https://ollama.com) installed and running (optional — app degrades gracefully without it)

---

## Setup

### 1. Install Ollama (optional but recommended)

```bash
brew install ollama
ollama pull llama3.2:3b
ollama serve &
```

Holmes will auto-detect and use the best available local model. Supported: `llama3.2:3b`, `llama3.2`, `llama3`, `phi3`, `mistral`. If none are found, context detection runs on heuristics only.

### 2. Clone and open

```bash
git clone https://github.com/tryholmes/Frontend-UI.git
cd Frontend-UI/holmes
open holmes.xcodeproj
```

### 3. Build & Run

Select the `holmes` scheme → **Run** (⌘R).

On first launch Holmes requests three permissions:

| Permission | Why |
|---|---|
| **Screen Recording** | Capture screen for OCR and context detection |
| **Accessibility** | Control apps — type messages, click buttons, fill forms |
| **Calendar** | Monitor events and auto-join meetings |

Grant all three when prompted, or open **System Settings → Privacy & Security** manually.

---

## Hotkeys

| Shortcut | Action |
|---|---|
| `Ctrl + Space` | Open / close command bar |
| `Option + Space` | Toggle main panel |
| `Cmd + \` | Toggle side icon visibility |

---

## Slash Commands (Command Bar)

| Command | Description |
|---|---|
| `/run` | Execute an autonomous task on screen |
| `/ask` | Ask a free-form question about what's on screen |
| `/plan` | Break a goal into actionable steps |
| `/watch` | Monitor screen continuously for a specific change |
| `/done` | Mark current task complete |

---

## Calendar & Meeting Auto-Join

Holmes monitors **Apple Calendar** every 60 seconds via EventKit. Any calendar synced to Apple Calendar works — iCloud, Google Calendar (via system sync), Exchange, Outlook.

**2 minutes before a meeting starts**, Holmes:
1. Fires a macOS system notification
2. Shows a "MEETING STARTING SOON" confirmation card in the main panel
3. Pre-warms the Zoom app if applicable
4. Provides a **Join Now** button that deep-links directly into the call

Meeting links are auto-detected from the event's URL field, Notes, and Location — supporting Zoom, Google Meet, Microsoft Teams, and Webex.

**To sync Google Calendar:** System Settings → Internet Accounts → Google → enable Calendars

---

## Gmail Browser Extension

The `holmes-extension/` folder contains a Chrome/Arc extension that gives Holmes richer Gmail context (compose fields, sender info, thread subject) without relying on OCR.

**To install:**
1. Chrome/Arc → `chrome://extensions`
2. Enable **Developer mode**
3. **Load unpacked** → select the `holmes-extension/` folder

The extension runs silently in the background and posts context to Holmes via a localhost socket.

---

## Privacy

- All processing is local — screen captures, OCR, and LLM inference never leave your machine
- Ollama runs fully offline
- Calendar data is read-only, never stored or transmitted
- Browser extension communicates only with localhost
- No analytics, no telemetry, no accounts required to use core features
