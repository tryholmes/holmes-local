# Contributing to Holmes Local

Thanks for helping. Holmes Local is a beta, and the bar for what gets merged is deliberately high, because every automation has to work every time on a small local model.

## Workflow

1. **Issue first.** Every contribution starts with an issue before a PR opens: a bug report for reproducible bugs, a feature request for features, a maintenance or chore issue for exploration and cleanup. One issue may back several small PRs.
2. **One focused branch per change.** Branch from `main`, keep the diff about one thing.
3. **PRs go into `main`.** The PR body explains **what** changed, **why** it changed, and **how it was tested** (which playbook you ran, which model, which Ollama version, what you saw). Link the backing issue.
4. **Review.** A maintainer who did not author the change approves before merge. Don't merge your own PRs.
5. **Build before you push.** From the repo root:

   ```bash
   cd holmes && xcodebuild -project holmes.xcodeproj -scheme holmes -configuration Debug build \
     CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
   ```

   CI runs exactly that on `macos-14`, plus SwiftLint as an advisory pass.

## The rules that don't bend

- **Draft-never-send.** Nothing in an autonomous run may send, post, publish, delete, or move the user's data without a confirmation gate. The tool filter in `ComposioCatalog` is the enforcement, not the prompt. Don't loosen it.
- **The action doctrine.** Every step runs on the **most deterministic backend that can do the job**: structured verbs (`nsworkspace`, `file`, `eventkit`, `composio`) first, Accessibility element actions (`ax_press`, `ax_type`) second, pixels last. New action verbs land on the deterministic lanes.
- **The planner never emits coordinates.** It can't see the screen; a visual step's input is `{}` and the screen-driven executor places the click from the live frame. Preflight refuses plans that break this. Keep it that way.
- **No new playbooks without a deterministic matcher.** A playbook earns `autoTriggers` only when its matcher keys off **structural** signals — app identity, window title, extracted entities from the AX tree or DOM — never loose words in OCR text. If you can't state the trigger as "fires when exactly X, never when Y", it isn't ready. We went from 154 playbooks to 5 on purpose.
- **Provider-neutral behaviour stays as is.** Confirmation gates, draft-only rules, the deterministic `LiveContext` headline, the priority speech queue, and the cooldowns are load-bearing. Change them in a dedicated PR with the reasoning spelled out.
- **One model, one context size.** `OllamaClient` serializes every request and sends one `num_ctx`; don't add a second model or a per-call context size (each reloads the model).

## Style

- Swift 5 language mode, macOS 14 target, no strict concurrency. Keep the existing actor / `@MainActor` shapes.
- User-visible strings talk about "the local model", "Ollama", or "Holmes Local".
- No secrets in the repo. There is no API key for the model; the only optional credential (ElevenLabs) lives in `~/.holmes/` or the Keychain, both ignored by git.

## License

By contributing you agree that your contribution is licensed under the GNU General Public License v3.0, the same license as the project (see `LICENSE`). See `THIRD_PARTY_NOTICES.md` for the code Holmes derives from and why the project is GPL.
