// Holmes — MV3 background service worker.
//
// Three jobs, nothing else:
//   1. Mint + persist the shared secret that authenticates the extension to the Holmes
//      app (X-Holmes-Token). Generated once on install with crypto.randomUUID().
//   2. Track which tab is actually in front, so every payload can say `isActiveTab`.
//      Holmes must never describe a background tab as "what the user is doing".
//   3. Act as a relay of last resort for the POST, because a content-script fetch is
//      subject to the page's CORS view of 127.0.0.1 while an extension-origin fetch
//      (with host permission) is not.
//
// MV3 workers are killed aggressively, so nothing important lives in a module-level
// variable without a durable backing store. Token -> chrome.storage.local.
// Active tab -> chrome.tabs.query on demand (cheap, always correct, survives eviction).

// Browser-automation executors (navigate/click/fillField/… with the DRAFT-NEVER-SEND
// guard). importScripts is synchronous and legal in a classic MV3 service worker.
importScripts("automation.js");

const ENDPOINT = "http://127.0.0.1:5766/context";
const COMMANDS_ENDPOINT = "http://127.0.0.1:5766/commands";
const RESULT_ENDPOINT = "http://127.0.0.1:5766/command-result";
const HEARTBEAT_ENDPOINT = "http://127.0.0.1:5766/heartbeat";
const TOKEN_KEY = "holmesToken";
const INSTANCE_KEY = "holmesBrowserInstance";
const COMMAND_POLL_MS = 2000;

// Worker-driven heartbeat (see the "Heartbeat" section below). The whole point is
// that this beats from the BACKGROUND service worker, which — unlike a content-script
// timer — is NOT throttled when no browser tab is focused, so connection state stops
// depending on which app/tab is in front.
const HEARTBEAT_ALARM = "holmes-heartbeat";
// chrome.alarms' minimum period is ~0.5 min (30s). An alarm survives worker eviction
// because firing it wakes the worker back up — this is the reliable floor.
const HEARTBEAT_ALARM_MINUTES = 0.5;
// Finer supplemental cadence while the worker happens to be alive. Unreliable across
// evictions (which is exactly why the alarm above exists), but cheap when it works.
const HEARTBEAT_SUPPLEMENT_MS = 15000;

// MARK: - Token

// Returns the persisted token, creating it on first call. Concurrent callers can race
// here (two tabs waking the worker at once); the loser simply re-reads and both end up
// with whichever value landed in storage, so a duplicate mint is harmless.
async function ensureToken() {
  try {
    const stored = await chrome.storage.local.get(TOKEN_KEY);
    if (stored && typeof stored[TOKEN_KEY] === "string" && stored[TOKEN_KEY].length > 0) {
      return stored[TOKEN_KEY];
    }
    const token = crypto.randomUUID();
    await chrome.storage.local.set({ [TOKEN_KEY]: token });
    return token;
  } catch (e) {
    console.warn("[Holmes] token storage unavailable:", e);
    return "";
  }
}

let browserInstancePromise;
function browserInstance() {
  if (!browserInstancePromise) browserInstancePromise = (async () => {
    const stored = await chrome.storage.local.get(INSTANCE_KEY);
    if (stored[INSTANCE_KEY]) return stored[INSTANCE_KEY];
    const id = crypto.randomUUID();
    await chrome.storage.local.set({ [INSTANCE_KEY]: id });
    return id;
  })().catch(error => { browserInstancePromise = null; throw error; });
  return browserInstancePromise;
}

chrome.runtime.onInstalled.addListener(() => {
  ensureToken().then((t) => {
    console.log("[Holmes] extension installed; token " + (t ? "ready" : "UNAVAILABLE"));
  });
  ensureCommandLoop();
  ensureHeartbeatLoop();
});

chrome.runtime.onStartup.addListener(() => {
  ensureToken();
  ensureCommandLoop();
  ensureHeartbeatLoop();
});

// MARK: - Active tab tracking

// Queried rather than cached: after the worker is evicted a cached id would be stale,
// and this call costs microseconds.
async function activeTabId() {
  try {
    const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (tabs && tabs.length > 0 && typeof tabs[0].id === "number") return tabs[0].id;
  } catch (e) { /* no tabs permission yet, or the window is closing */ }
  return -1;
}

// Tell a tab whether it is the one the user is looking at. The content script uses this
// to stamp the payload and to push a fresh read the moment it comes to the foreground.
async function notifyActive(tabId, isActive) {
  if (typeof tabId !== "number" || tabId < 0) return;
  try {
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.sendMessage(tabId, { type: "holmes:active", isActiveTab: isActive, tabId,
      windowId: tab.windowId, instanceId: await browserInstance() });
  } catch (e) {
    // Expected whenever the tab has no content script (chrome:// pages, the web store,
    // a tab still loading). Not an error worth surfacing.
  }
}

let lastActiveTabId = -1;

async function refreshActive() {
  const current = await activeTabId();
  if (current === lastActiveTabId) return;
  const previous = lastActiveTabId;
  lastActiveTabId = current;
  if (previous >= 0) notifyActive(previous, false);
  if (current >= 0) notifyActive(current, true);
}

chrome.tabs.onActivated.addListener(() => {
  refreshActive();
  // A tab switch is a natural reconnect point: beat immediately so the app's badge
  // flips back to "connected" the instant the user returns to the browser, instead
  // of waiting out the next alarm/interval tick.
  sendHeartbeat();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  // A committed URL change in the front tab means the content script is brand new and
  // has not been told it is active yet.
  if (changeInfo.status === "complete" && tabId === lastActiveTabId) {
    notifyActive(tabId, true);
    sendHeartbeat();
  }
});

chrome.windows.onFocusChanged.addListener(() => {
  refreshActive();
  // Fires when browser focus changes — including leaving for a native app. Beating
  // here proves the extension is alive across that transition; once fully inside the
  // native app it's the alarm/interval below that keeps the connection warm.
  sendHeartbeat();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === lastActiveTabId) lastActiveTabId = -1;
});

// MARK: - Messages from content scripts

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || typeof msg.type !== "string") return false;

  // Handshake: content script asks who it is and for the token.
  if (msg.type === "holmes:hello") {
    (async () => {
      const token = await ensureToken();
      const active = await activeTabId();
      if (active >= 0) lastActiveTabId = active;
      const tabId = sender && sender.tab && typeof sender.tab.id === "number" ? sender.tab.id : -1;
      sendResponse({ token, tabId, windowId: sender.tab ? sender.tab.windowId : -1,
        instanceId: await browserInstance(), isActiveTab: tabId >= 0 && tabId === active });
    })();
    return true; // keep the message channel open for the async reply
  }

  // Relay of last resort. The content script only falls back to this after both a direct
  // fetch and a direct XHR have failed, which in practice means the page origin refused
  // the cross-origin POST. Extension-origin fetch with host_permissions bypasses CORS.
  if (msg.type === "holmes:post") {
    (async () => {
      const token = await ensureToken();
      try {
        // Tab-activation notifications reach content scripts asynchronously.
        // Recheck the actual sender at relay time so a previously active window
        // cannot publish one last stale composer after the user switches tabs.
        const active = await activeTabId();
        if (!sender.tab || sender.tab.id !== active) {
          sendResponse({ ok: true, dropped: "inactive tab" });
          return;
        }
        const payload = typeof msg.body === "string" ? JSON.parse(msg.body) : Object.assign({}, msg.body || {});
        payload.tabId = sender.tab.id;
        payload.windowId = sender.tab.windowId;
        payload.isActiveTab = true;
        const res = await fetch(ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
          body: JSON.stringify(payload)
        });
        sendResponse({ ok: res.ok, status: res.status });
      } catch (e) {
        sendResponse({ ok: false, error: String(e && e.message ? e.message : e) });
      }
    })();
    // A page just posted, so the worker is awake — a good moment to make sure the
    // command poll loop and heartbeat are running (they may have been torn down by
    // an eviction).
    ensureCommandLoop();
    ensureHeartbeatLoop();
    return true;
  }

  // The popup arms adoption by making one authenticated request from the extension
  // origin (a heartbeat), which the Mac app adopts if the user opened the pairing
  // window in Settings. Nothing here can pair on its own — the human still arms it.
  if (msg.type === "holmes:pairPing") {
    (async () => {
      const token = await ensureToken();
      try {
        const res = await fetch("http://127.0.0.1:5766/heartbeat", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
          body: "{}"
        });
        sendResponse({ ok: res.ok, status: res.status });
      } catch (e) {
        sendResponse({ ok: false, error: String(e && e.message ? e.message : e) });
      }
    })();
    return true;
  }

  return false;
});

// MARK: - Heartbeat (worker-driven, focus-independent)
//
// The bug this fixes: the content script's 5s heartbeat only fires while a browser
// tab is FOCUSED, because Chromium throttles a background page's timers. The moment
// the user is in a native app (Messages, WhatsApp, Xcode) that heartbeat stalls, and
// after the Mac app's connectionTimeout the badge flaps to "disconnected" — then back
// to "connected" when the user returns to the browser. That flap is the whole bug.
//
// The MV3 service worker is NOT subject to tab-focus throttling, and it holds the
// token, so it can authenticate a /heartbeat entirely on its own. Two mechanisms keep
// it beating, independent of which app/tab is in front:
//   • chrome.alarms — survives worker eviction (firing the alarm wakes the worker).
//     Its minimum period is ~30s; this is the reliable floor.
//   • a supplemental setInterval — finer cadence while the worker is alive; unreliable
//     across MV3 evictions, which is exactly why the alarm exists as the backstop.
// Plus an immediate beat on every tab/focus change (wired above) so returning to the
// browser reconnects instantly rather than waiting for the next alarm tick.
//
// The content-script heartbeat is kept as an additional supplement — it's harmless
// and covers the case where the worker is momentarily down but a tab is focused.

let heartbeatTimer = null;

async function sendHeartbeat() {
  const token = await ensureToken();
  if (!token) return;
  try {
    await fetch(HEARTBEAT_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
      body: "{}"
    });
  } catch (e) {
    // Holmes app not running / port closed — expected, stay quiet.
  }
}

function ensureHeartbeatAlarm() {
  try {
    // Defensive: if the "alarms" permission is absent, chrome.alarms is undefined.
    // The setInterval supplement still runs, so an alive worker keeps beating.
    if (!chrome.alarms) return;
    // Create only if it doesn't already exist. ensureHeartbeatLoop() runs on EVERY
    // worker wake — and while the user is browsing the worker wakes constantly (each
    // relayed post, each tab event). Calling create() every time would reset the
    // alarm's schedule on each wake, so the 30s countdown would restart over and over
    // and the beat that actually matters — the first one AFTER the user leaves the
    // browser and the wakes stop — could be pushed out. Registering it once keeps a
    // steady, un-resettable cadence.
    chrome.alarms.get(HEARTBEAT_ALARM, (existing) => {
      void chrome.runtime.lastError;
      if (!existing) {
        chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: HEARTBEAT_ALARM_MINUTES });
      }
    });
  } catch (e) { /* alarms unavailable — supplement covers the alive worker */ }
}

// Re-invoked from every worker wake point (install, startup, relayed post, module
// load) so a revived worker always restarts the loop and re-registers the alarm.
function ensureHeartbeatLoop() {
  ensureHeartbeatAlarm();
  if (heartbeatTimer === null) {
    heartbeatTimer = setInterval(sendHeartbeat, HEARTBEAT_SUPPLEMENT_MS);
  }
  sendHeartbeat(); // beat immediately on every wake so reconnect isn't delayed
}

if (chrome.alarms && chrome.alarms.onAlarm) {
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (!alarm || alarm.name !== HEARTBEAT_ALARM) return;
    // The alarm is the ONLY thing that wakes an evicted worker while the user is
    // outside the browser, so treat every firing as a full revival, not just a beat:
    //   • re-arm both loops (their setIntervals died with the evicted worker),
    //   • beat immediately (ensureHeartbeatLoop does this) so the app's badge stays
    //     "connected",
    //   • drain any queued browser commands NOW. Without this a command the app
    //     enqueued while the worker was down would sit unpolled until the *next*
    //     alarm (up to a clamped 60s away) and time out at the app's 20s deadline —
    //     the automation equivalent of the connection flap.
    ensureHeartbeatLoop();
    ensureCommandLoop();
    pollCommands();
  });
}

// MARK: - Command channel (browser automation)
//
// The Holmes Mac app drives the browser by leaving commands at GET /commands; the
// worker polls every 2s, executes each through HolmesAutomation (which enforces the
// DRAFT-NEVER-SEND guard), and POSTs the structured outcome to /command-result.
//
// Eviction caveat: MV3 kills idle workers, so this setInterval doesn't live forever.
// ensureCommandLoop() is therefore re-invoked from every worker wake point (install,
// startup, each relayed post, tab events) and at module load below — so a revived
// worker always restarts the loop. When the Holmes app isn't listening the GET simply
// fails and is swallowed, costing nothing.

let commandTimer = null;
let commandPollInFlight = false;

function ensureCommandLoop() {
  if (commandTimer !== null) return;
  commandTimer = setInterval(pollCommands, COMMAND_POLL_MS);
  pollCommands();
}

async function pollCommands() {
  if (commandPollInFlight) return;
  commandPollInFlight = true;
  try {
    const token = await ensureToken();
    if (!token) return;

    let res;
    try {
      res = await fetch(COMMANDS_ENDPOINT, {
        method: "GET",
        headers: { "X-Holmes-Token": token, "Accept": "application/json", "X-Holmes-Browser-Instance": await browserInstance() }
      });
    } catch (e) {
      return; // Holmes app not running / port closed — expected, stay quiet.
    }
    if (!res.ok) return; // 401 (wrong token), 404 (older app without the channel), etc.

    let data;
    try { data = await res.json(); } catch (e) { return; }

    const commands = Array.isArray(data)
      ? data
      : (data && Array.isArray(data.commands) ? data.commands : []);
    for (const cmd of commands) {
      await runOneCommand(cmd, token);
    }
  } finally {
    commandPollInFlight = false;
  }
}

async function runOneCommand(cmd, token) {
  const id = cmd && cmd.id !== undefined ? cmd.id : null;
  const action = cmd && cmd.action;

  let outcome;
  try {
    outcome = action === "read_email_compose" || action === "fill_email_draft" || action === "undo_email_draft"
      ? await emailComposeCommand(cmd) : await HolmesAutomation.execute(cmd);
  } catch (e) {
    outcome = { ok: false, error: String(e && e.message ? e.message : e) };
  }

  const body = Object.assign({ id, action, at: Date.now() }, outcome);
  try {
    await fetch(RESULT_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
      body: JSON.stringify(body)
    });
  } catch (e) {
    // The app went away between GET and POST — drop the result rather than retry-storm.
  }
}

async function emailComposeCommand(cmd) {
  const params = cmd.params || {};
  const instanceId = await browserInstance();
  let tab;
  if (cmd.action === "fill_email_draft" || cmd.action === "undo_email_draft") {
    // Writes and undo target the original tab, never the current cursor. A
    // document/composer comparison still occurs inside it before any change.
    let identity;
    try { identity = JSON.parse(params.expected && params.expected.identity); } catch (_) { identity = null; }
    if (!Array.isArray(identity) || identity[0] !== instanceId || !Number.isInteger(identity[2])) {
      return { ok: false, refused: true, reason: "The draft belongs to another browser session." };
    }
    tab = await chrome.tabs.get(identity[2]);
    if (tab.windowId !== identity[1]) return { ok: false, refused: true, reason: "The composer window changed." };
    if (cmd.action === "fill_email_draft") {
      // Validate in the page first: a refused insert leaves windows and tabs
      // exactly where the person had them.
      const precheck = await chrome.tabs.sendMessage(tab.id, { type: "holmes:checkEmailDraft",
        environment: { tabId: tab.id, windowId: tab.windowId, instanceId },
        body: params.body, expected: params.expected, options: params.options });
      if (!precheck || precheck.ok !== true) {
        return precheck || { ok: false, refused: true, reason: "The composer did not answer." };
      }
      // Automatic writes happen only in the composer the person is looking at.
      if (!(params.options && params.options.mode === "auto")) {
        await chrome.windows.update(tab.windowId, { focused: true });
        await chrome.tabs.update(tab.id, { active: true });
        await notifyActive(tab.id, true);
      }
    }
  } else {
    const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    tab = tabs && tabs[0];
  }
  if (!tab || typeof tab.id !== "number") return { ok: false, refused: true, reason: "No active browser tab." };
  const activeWindow = await chrome.windows.get(tab.windowId);
  if (activeWindow.type !== "normal" && activeWindow.type !== "popup") {
    return { ok: false, refused: true, reason: "No active compose window." };
  }
  const environment = { tabId: tab.id, windowId: tab.windowId, instanceId };
  if (await activeTabId() !== tab.id) return { ok: false, refused: true, reason: "The active tab changed." };
  const messageTypes = { read_email_compose: "holmes:readEmailCompose", fill_email_draft: "holmes:fillEmailDraft", undo_email_draft: "holmes:undoEmailDraft" };
  const result = await chrome.tabs.sendMessage(tab.id, {
    type: messageTypes[cmd.action],
    environment, body: params.body, expected: params.expected, options: params.options, token: params.token
  });
  // A tab switch while the response was in flight invalidates a refresh. The
  // page writer separately validates the exact identity before any mutation.
  if (cmd.action === "read_email_compose" && await activeTabId() !== tab.id) {
    return { ok: false, refused: true, reason: "The active tab changed." };
  }
  return result || { ok: false, error: "The compose reader did not respond." };
}

// Restart the poll loop and heartbeat whenever this script (re)loads — i.e. on every
// worker wake.
ensureCommandLoop();
ensureHeartbeatLoop();
