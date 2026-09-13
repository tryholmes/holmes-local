# Third-Party Notices

Holmes bundles and derives from third-party software. This file reproduces the
required copyright and permission notices.

Holmes's computer-control layer — `InputController.swift`, `WindowCapture.swift`,
and `ComputerUseEngine.swift` (all under `holmes/holmes/Core/`) — is derived from
OpenClicky's native computer-use runtime, which itself embeds a narrow, modified
subset of trycua/cua-driver. Holmes's on-screen teaching overlay —
`Views/Glow/VisualGuidanceOverlay.swift` and `Core/VisualGuidance.swift` — adapts
OpenClicky's visual-guidance approach (the transparent click-through overlay,
POINT/RECT/SCRIBBLE annotation shapes, and screenshot-pixel→screen-point mapping).
Holmes's voice layer and companion loop — `Core/VoiceInputController.swift`
(push-to-talk on-device dictation), `Core/SpeechSynthesizer.swift` (two-backend
ElevenLabs/Apple text-to-speech), and `Core/ClickyController.swift` (the
hotkey → ask-and-point / do-the-task orchestration) — adapt OpenClicky's
dictation, TTS, and companion-manager approaches. Holmes's notch HUD —
everything under `Views/NotchAnimation/` — is ported from boring.notch, which is
distributed under the GNU General Public License v3.0; see its section below for
what was copied and the license terms that apply to it. OpenClicky and
trycua/cua-driver are distributed under the MIT License; all notices are
reproduced in full below.

---

## 1. OpenClicky

Holmes's computer-control layer (`InputController.swift`, `WindowCapture.swift`,
`ComputerUseEngine.swift`) is derived from OpenClicky's native computer-use
runtime: the CGEvent keyboard and mouse delivery primitives, the AppKit→Quartz
per-display coordinate conversion, the retina-safe screenshot resize and
model-pixel→screen-point coordinate mapping, and the master-enable gating
pattern. Holmes's visual teaching overlay (`VisualGuidanceOverlay.swift`,
`VisualGuidance.swift`) additionally adapts OpenClicky's visual-guidance overlay:
the borderless transparent click-through overlay window, the POINT/RECT/SCRIBBLE
annotation model, the model→annotations tag/JSON bridge, and the "draw right on the
screen to point the way" rendering approach. Holmes's voice layer and companion
loop additionally adapt OpenClicky: `VoiceInputController.swift` from the
push-to-talk dictation manager (live `SFSpeechAudioBufferRecognition` streaming,
the on-device recognition flag, and the final-transcript fallback timer);
`SpeechSynthesizer.swift` from the ElevenLabs/Apple two-backend TTS client (the
ElevenLabs request shape and the sentence-chunk-for-prompt-start playback
strategy); and `ClickyController.swift` from the companion manager (hotkey →
dictate → answer-and-point vs. do-the-task routing).

MIT License

Copyright (c) 2025 Jason Kneen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## 2. boring.notch

Holmes's notch HUD (`Views/NotchAnimation/NotchDetector.swift`,
`NotchViewModel.swift`, `NotchView.swift`, `NotchWindow.swift`) is a direct port
of boring.notch's notch UI with Holmes content in place of music/battery/shelf:
the `NotchShape` path (originally from MrKai77/DynamicNotchKit), the sizing
model (`openNotchSize`/`windowSize`/`cornerRadiusInsets` and the real-notch
measurement from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), the
`ContentView` layout structure (padding/background/clip/1px seam overlay/shadow,
open/close/hover springs and delays, closed-state live-activity wings and
sneak-peek rows), the `BoringHeader` open-state header with its black
`NotchShape` mask over the physical notch, the `BoringViewModel` open/close
state machine, and the `BoringNotchWindow` panel configuration and top-center
positioning.

Source reference: https://github.com/TheBoredTeam/boring.notch

boring.notch is Copyright (c) TheBoredTeam and contributors, and is licensed
under the GNU General Public License, version 3.0 (GPL-3.0). The full license
text is available at https://www.gnu.org/licenses/gpl-3.0.txt and in the
boring.notch repository's LICENSE file.

NOTE (GPL-3.0 obligations): because this directory ports GPL-3.0-licensed code,
distributing Holmes binaries that include it triggers GPL-3.0's terms for the
combined work (source availability under GPL-compatible terms). If Holmes is
ever distributed under a non-GPL license, this port must first be removed or
replaced with independently developed code.

---

## 3. trycua/cua-driver

By way of OpenClicky, Holmes's computer-control layer embeds a narrow, modified
Swift subset inspired by trycua/cua-driver for native in-app computer use:
app/window discovery, ScreenCaptureKit target-window capture, and pid-directed
keyboard delivery fallback logic.

Source reference: https://github.com/trycua/cua

MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Bundled typography

Holmes uses the typography from https://www.try-holmes.com/ locally, without
loading fonts over the network:

- **LT Remark Regular**, by Daniel Lyons / LyonsType: SIL Open Font License 1.0.
- **Geist and Geist Mono**, by Vercel and Basement Studio, v1.7.2: SIL Open Font License 1.1.

Original font files, complete license notices, upstream download references,
and SHA-256 checksums are included in `holmes/holmes/Resources/Fonts/` and copied
into the app bundle. See `LT-Remark-OFL.txt`, `Geist-OFL.txt`, and the accompanying
`README.md` in that directory. The fonts are registered only within the Holmes
process, not installed system-wide.
