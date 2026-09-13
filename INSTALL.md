# Installing Holmes

Holmes ships as one DMG. The app includes the browser extension and first-run
setup for permissions, the local model, and connected tools.

## 1. Get the DMG

Download `Holmes-<version>.dmg` from the
[Releases page](https://github.com/tryholmes/holmes-local/releases/latest). Open it and drag **Holmes** onto
**Applications**.

If the build is signed and notarized it opens like any other app. If you are
running a community build that is only ad hoc signed, macOS will refuse the
first double click. Right click the app in Applications, choose **Open**, and
confirm once. Or from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Holmes.app
```

## 2. First launch does the setup

Holmes walks you through setup. Optional connections and model setup can be
finished later from Settings.

| Step | What happens | Skip and do later in |
|---|---|---|
| Permissions | Screen Recording and Accessibility, so Holmes can see and act | Settings ▸ Privacy |
| Local model | Finds or installs [Ollama](https://ollama.com), starts it, downloads the default vision model | Settings ▸ Local Model |
| Connect your browser | Automatically prepares or refreshes `~/Downloads/Holmes Extension` each time the step opens; choosing a browser opens its Extensions page and a two minute pairing window | Settings ▸ Privacy ▸ Install extension in… |
| Connect your tools | Optional. Paste your Composio MCP URL and key. Holmes writes `mcp.json` and shows how many read only tools came back | Settings, or edit `mcp.json` |
| Ready | Hotkeys and a guided demo | Holmes menu ▸ Try Holmes… |

### Try Holmes after setup

Choose **Try Holmes** on the Ready screen to open three interactive examples:

- **Open Calculator:** runs a native app launch, even before the model is ready.
- **Summarize notes:** turns supplied sample meeting notes into action items.
- **Draft a reply:** writes an editable reply to a supplied sample message.

Each example runs when you press its button and shows the actual result. The
text examples use your configured Ollama model and sample data; they do not read
your conversations or send a message. If the model needs setup, the demo links
to Settings. Closing the window cancels the active example, and successful
examples stay marked as tried across launches.

The demo appears once after completed setup, including the first launch after
updating from a version without it. You can skip it and reopen it at any time
from **Holmes menu ▸ Try Holmes…** or the play button in the assistant panel.

### The browser step in detail

Chromium browsers do not allow an app to install an extension for you. Holmes
does everything around that one gesture:

1. Opening **Connect Your Browser** automatically prepares or refreshes the
   bundled extension at **`~/Downloads/Holmes Extension`**. No button click is
   needed. This happens every time the step opens, including recreating the
   folder if it was removed.
2. Pick your browser (Chrome, Arc, Brave, Edge, Comet, Vivaldi, Opera). Holmes
   opens both the extension folder in Finder and the browser's Extensions page.
3. In Chrome: turn on **Developer mode**, press **Load unpacked**, then choose
   **Downloads → Holmes Extension**. Other Chromium browsers use the same flow.
4. Click the Holmes puzzle piece in the toolbar and press **Pair with Holmes**.

The status line in Holmes turns green when the first page arrives. The pairing
window is open for two minutes; the button reopens it.

You can always find the folder again with **Open extension folder** in onboarding
or **Holmes ▸ Settings ▸ Privacy**. **Copy folder path** copies the full path for
the browser's file picker. Both buttons also prepare or refresh the folder.
Keep **Holmes Extension** in Downloads after loading it: Chrome reads the extension
from that folder.

### The tools step in detail

1. In the [Composio dashboard](https://dashboard.composio.dev) create an MCP
   server with the toolkits you want (Gmail, Google Calendar, GitHub are what
   the built in playbooks use) and connect each account.
2. Copy the server's Streamable HTTP URL and your API key into Holmes.
3. Press **Connect**. Holmes writes the entry to
   `~/Library/Application Support/Holmes/mcp.json`, restarts its MCP host, and
   reports the tool count.

Holmes only ever offers read tools from that connection. Send, delete, and
post tools are filtered out in code. See `holmes/MCP-SETUP.md` for other MCP
servers and the manual format.

## 3. Optional: the SDK CLI

The `holmes-sdk` command lives in the repository at `holmes/sdk/bin/holmes-sdk`.
Symlink it onto your PATH to scaffold playbooks and tool servers:

```sh
ln -s /path/to/holmes-ollama/holmes/sdk/bin/holmes-sdk /usr/local/bin/holmes-sdk
```

## Building the DMG yourself

```sh
holmes/scripts/release/build-dmg.sh
```

Produces `dist/Holmes-<version>.dmg`, ad hoc signed. To sign and notarize:

```sh
xcrun notarytool store-credentials holmes-notary --apple-id you@example.com --team-id TEAMID
HOLMES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
HOLMES_TEAM_ID=TEAMID HOLMES_NOTARY_PROFILE=holmes-notary \
holmes/scripts/release/build-dmg.sh
```

Pushing a tag `vX.Y.Z` runs the same script in GitHub Actions and attaches the
DMG to a draft release. Add the secrets named in
`.github/workflows/release.yml` to get signed, notarized builds from CI.

## Uninstall

Quit Holmes, delete `/Applications/Holmes.app`, and optionally remove
`~/Library/Application Support/Holmes` (memory database, playbooks, `mcp.json`).
Remove the extension from your browser before deleting `~/Downloads/Holmes Extension`.
