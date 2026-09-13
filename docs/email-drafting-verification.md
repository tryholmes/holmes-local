# Email drafting and work visibility

A composer with verified recipients, a literal subject and an empty readable body is observed for 1.5 seconds, then read again before automatic drafting starts. The dedicated writer produces an editable body, and the existing review card offers Insert draft, Copy and Dismiss. A reviewed rewrite offers Replace body. Generation never inserts or sends. The Email Draft automation can be disabled in Settings.

Voice and typed requests such as “Could you draft this email for me?” reach this writer before the guidance/agent routes. Instructional questions still use guidance. The notch tracks reading, queued model work, writing, transcription, approval waits and completion. Stop cancels the owning task; pause, sleep and lock cancel all active work. Local-model failure is reported as failure, rather than a successful text answer.

The browser bridge preserves account/document/tab/composer identity, To/Cc/Bcc, literal subject, body and rich-content revision. It obtains a fresh observation after writing the draft and rechecks the same target immediately before inserting the reviewed body. Changing a header, body, tab or composer invalidates an old draft. A missing editor is not an empty editor; multiple unfocused composers are ambiguous. Chrome and Comet commands are routed to the originating extension instance.

## Repeatable checks

The GitHub build runs the shell suites for compose extraction, the production Swift bridge, intent routing, draft content/session races, the production coordinator, voice/typed entry points, physical Fn ownership, notch/model lifecycle and extension installation. These use synthetic data and injected service/OS boundaries; they do not access mail accounts or microphones.

Additional opt-in checks:

```sh
# Real Chromium DOM with an intercepted, synthetic Gmail document.
# Uses a fresh browser session; no personal Chrome profile or account.
python3 holmes/tests/EmailComposeBrowserTests.py

# Actual installed local model, production prompt/parser/client, synthetic text.
# Volatile settings: qwen3-vl:8b-instruct, num_ctx 32768; no user defaults writes.
holmes/tests/run-email-live-smoke.sh

# Isolated offline UI fixtures; does not start the real agent or microphone.
HOLMES_UI_PREVIEW_WORK_ONLY=1 holmes/tests/render-ui-previews.sh /tmp/holmes-work-previews
```

The browser checks cover subject-focused insertion, multiline readback, unchanged headers, rejection after a user edit, explicit nonempty rewrite, ambiguous composers and an 8,000-character body. Send is a counter in the fixture and remains zero.

The live-model cases cover the reported `boss@gmail.com` / `Im gonna be late` email, a user-specified 15-minute train delay, a self-contained voice request, a professional rewrite and a reply that needs a calendar check. Output is printed for factual review. Validation rejects empty, instructional, refusal and placeholder output, with one bounded repair attempt. These checks verify representative cases, not every possible model response.

## Updating an existing installation

The app refreshes its recognized managed extension folder at `~/Downloads/Holmes Extension` when the bundled version changes. Version 2.2 adds the compose protocol. Chrome still requires Reload on `chrome://extensions`, followed by refreshing Gmail; a persistent Settings notice explains this until the new protocol is observed. Comet must have its own extension installation.

Native Mail uses a bounded Accessibility reader and refuses unsupported or unverifiable controls. Gmail's production scripts were exercised in real Chromium against synthetic fixtures; no personal inbox was opened or message sent during verification.
