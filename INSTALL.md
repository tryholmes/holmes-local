# Installing Holmes

Holmes ships as one DMG. The app inside carries everything else: the browser
extension, the SDK, and a first run setup that installs and links them.

## 1. Get the DMG

Download `Holmes-<version>.dmg` from the
[Releases page](../../releases). Open it and drag **Holmes** onto
**Applications**.

If the build is signed and notarized it opens like any other app. If you are
running a community build that is only ad hoc signed, macOS will refuse the
first double click. Right click the app in Applications, choose **Open**, and
confirm once. Or from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Holmes.app
```

## 2. First launch does the setup

Holmes walks you through six short steps. Each one can be skipped and
finished later from Settings.

| Step | What happens | Skip and do later in |
|---|---|---|
| Permissions | Screen Recording and Accessibility, so Holmes can see and act | Settings ▸ Privacy |
| Local model | Finds or installs [Ollama](https://ollama.com), starts it, downloads the default vision model | Settings ▸ Local Model |
| Connect your browser | Copies the bundled extension to disk, opens your browser's Extensions page, opens a two minute pairing window | Settings ▸ Privacy ▸ Install extension in… |
| Connect your tools | Optional. Paste your Composio MCP URL and key. Holmes writes `mcp.json` and shows how many read only tools came back | Settings, or edit `mcp.json` |
| Ready | Hotkeys and a summary | |

### The browser step in detail

Chromium browsers do not allow an app to install an extension for you. Holmes
does everything around that one gesture:

1. Pick your browser (Chrome, Arc, Brave, Edge, Comet, Vivaldi, Opera).
2. Holmes opens the browser's Extensions page and a Finder window at
   `~/Library/Application Support/Holmes/extension`.
3. In the browser: turn on **Developer mode**, press **Load unpacked**, choose
   that folder.
4. Click the Holmes puzzle piece in the toolbar and press **Pair with Holmes**.

The status line in Holmes turns green when the first page arrives. The pairing
window is open for two minutes; the button reopens it.

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
`~/Library/Application Support/Holmes` (extension copy, memory database,
playbooks, `mcp.json`) and the extension from your browser.
