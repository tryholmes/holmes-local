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

// Tunables. Tests shorten them through self.__holmesBridgeConfig; the browser never
// sets that global, so production always runs with these defaults.
const CONFIG_OVERRIDES = (typeof self !== "undefined" && self.__holmesBridgeConfig) || {};
const CONFIG = Object.assign({
  // How often a heartbeat re-probes the active tab's content script.
  heartbeatProbeMs: 15000,
  // Seconds the bridge may hold GET /commands open. Chrome kills a worker whose
  // fetch waits 30s for a response, so the hold and its timeout stay below that.
  longPollSeconds: 20,
  // Gap between polls when the app does not support long polling.
  pollIdleMs: COMMAND_POLL_MS,
  // First retry delay after a failed poll; doubles up to 30s.
  pollErrorBackoffMs: 1000,
  // While commands are active, call a cheap extension API this often (resets the
  // MV3 idle timer) for keepaliveWindowMs after the last command activity.
  keepaliveMs: 20000,
  keepaliveWindowMs: 120000,
  // Result POST retry schedule: one attempt plus one per delay.
  resultRetryDelaysMs: [250, 1000, 3000],
  // The bridge accepts 16 MB of result; stay a little under it.
  maxResultBytes: 16 * 1024 * 1024 - 64 * 1024,
  // Commands for different tabs run concurrently, up to this many at once.
  maxConcurrentCommands: 4
}, CONFIG_OVERRIDES);
// Every request to the bridge is bounded. A stalled app must never park a worker.
CONFIG.fetchTimeoutMs = Object.assign({ heartbeat: 5000, relay: 5000, commands: 28000, result: 15000 },
  CONFIG_OVERRIDES.fetchTimeoutMs || {});

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

chrome.runtime.onInstalled.addListener((details) => {
  ensureToken().then((t) => {
    console.log("[Holmes] extension installed; token " + (t ? "ready" : "UNAVAILABLE"));
  });
  // Chrome only runs manifest content scripts on pages loaded AFTER install or
  // update. Tabs that were already open keep no script (fresh install) or an
  // orphaned one (update/reload) that can no longer reach this worker, so inject
  // again. A browser update needs nothing: its tabs reload with the scripts.
  const reason = details && details.reason;
  if (reason === "install" || reason === "update") reinjectContentScripts();
  ensureCommandLoop();
  ensureHeartbeatLoop();
});

chrome.runtime.onStartup.addListener(() => {
  ensureToken();
  ensureCommandLoop();
  ensureHeartbeatLoop();
});

// MARK: - Content script injection and health

function manifestContentScripts() {
  try { return chrome.runtime.getManifest().content_scripts || []; } catch (_) { return []; }
}

function isInjectableTab(tab) {
  return !!tab && typeof tab.id === "number" && !tab.discarded && /^https?:\/\//i.test(tab.url || "");
}

function isMissingReceiver(error) {
  const text = String(error && error.message ? error.message : error);
  return /receiving end does not exist|could not establish connection/i.test(text);
}

// fetch() with a hard deadline. Aborts the request (so the socket is released) and
// rejects even if the underlying fetch ignores the abort.
async function fetchWithTimeout(url, init, ms) {
  const controller = typeof AbortController === "function" ? new AbortController() : null;
  let timer;
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => {
      if (controller) { try { controller.abort(); } catch (_) { /* ignore */ } }
      reject(new Error("request to " + url + " timed out after " + ms + "ms"));
    }, ms);
  });
  try {
    const options = Object.assign({}, init, controller ? { signal: controller.signal } : {});
    return await Promise.race([fetch(url, options), expiry]);
  } finally {
    clearTimeout(timer);
  }
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function withTimeout(promise, ms, label) {
  let timer;
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error((label || "operation") + " timed out after " + ms + "ms")), ms);
  });
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer));
}

// Injects this extension's content scripts into one tab exactly as the manifest
// declares them: same order, same world, and document_start entries immediately.
// Each entry is attempted even if an earlier one failed. Returns how many landed.
async function injectContentScripts(tabId) {
  let injected = 0;
  for (const entry of manifestContentScripts()) {
    const files = (entry.js || []).slice();
    if (!files.length) continue;
    const details = { target: { tabId }, files };
    if (entry.world === "MAIN") details.world = "MAIN";
    if (entry.run_at === "document_start") details.injectImmediately = true;
    try {
      await chrome.scripting.executeScript(details);
      injected++;
    } catch (e) {
      // Restricted page, a tab that closed, or a page blocking one world.
    }
  }
  return injected;
}

async function reinjectContentScripts() {
  let tabs = [];
  try { tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] }); } catch (_) { return; }
  for (const tab of tabs) {
    if (isInjectableTab(tab)) await injectContentScripts(tab.id);
  }
}

// Asks the active tab's content script whether it is alive, so the app can tell a
// healthy page from one whose script went missing while this worker keeps beating.
// A missing script in a normal page is reinjected once per tab per worker lifetime.
const reinjectedTabs = new Set();
let lastProbe = { at: 0, value: null };

async function probeActiveTab() {
  const now = Date.now();
  if (lastProbe.value && now - lastProbe.at < CONFIG.heartbeatProbeMs) return lastProbe.value;
  let value;
  try {
    const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    const tab = tabs && tabs[0];
    if (!tab || typeof tab.id !== "number") {
      value = { script: "none" };
    } else if (!isInjectableTab(tab)) {
      value = { script: "restricted" };
    } else {
      try {
        const reply = await withTimeout(chrome.tabs.sendMessage(tab.id, { type: "holmes:ping" }), 1500, "ping");
        value = { script: reply && reply.ok ? "ok" : "missing" };
      } catch (e) {
        if (isMissingReceiver(e) && !reinjectedTabs.has(tab.id)) {
          reinjectedTabs.add(tab.id);
          value = { script: (await injectContentScripts(tab.id)) > 0 ? "reinjected" : "missing" };
        } else {
          value = { script: "missing" };
        }
      }
    }
  } catch (_) {
    value = { script: "none" };
  }
  lastProbe = { at: now, value };
  return value;
}

async function browserFocused() {
  try {
    const win = await chrome.windows.getLastFocused();
    return !!(win && win.focused);
  } catch (_) {
    return false;
  }
}

function extensionVersion() {
  try { return chrome.runtime.getManifest().version || ""; } catch (_) { return ""; }
}

function browserName() {
  try {
    const brands = (typeof navigator !== "undefined" && navigator.userAgentData && navigator.userAgentData.brands) || [];
    const named = brands.map(b => b.brand).find(b => !/chromium|not.?a.?brand/i.test(b));
    return named || "";
  } catch (_) {
    return "";
  }
}

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
        const res = await fetchWithTimeout(ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
          body: JSON.stringify(payload)
        }, CONFIG.fetchTimeoutMs.relay);
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

  // A visible, active tab pings periodically. Any message wakes an evicted MV3
  // worker and resets its idle timer, so this keeps command delivery alive while
  // the user is actually looking at a page.
  if (msg.type === "holmes:keepalive") {
    ensureCommandLoop();
    ensureHeartbeatAlarm();
    sendResponse({ ok: true });
    return false;
  }

  // The popup arms adoption by making one authenticated request from the extension
  // origin (a heartbeat), which the Mac app adopts if the user opened the pairing
  // window in Settings. Nothing here can pair on its own — the human still arms it.
  if (msg.type === "holmes:pairPing") {
    (async () => {
      const token = await ensureToken();
      try {
        const res = await fetchWithTimeout(HEARTBEAT_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
          body: "{}"
        }, CONFIG.fetchTimeoutMs.heartbeat);
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
    // The beat says which browser instance this is, whether it has OS focus (the
    // app routes commands that name no browser to the one in front), and whether
    // the active tab's content script is alive.
    const [instanceId, focused, activeTab] = await Promise.all([
      browserInstance().catch(() => ""), browserFocused(), probeActiveTab()
    ]);
    await fetchWithTimeout(HEARTBEAT_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json", "X-Holmes-Token": token,
        "X-Holmes-Browser-Instance": instanceId, "X-Holmes-Browser-Focused": focused ? "1" : "0"
      },
      body: JSON.stringify({ instanceId, focused, activeTab, version: extensionVersion(), browser: browserName() })
    }, CONFIG.fetchTimeoutMs.heartbeat);
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

// Delivery is a long poll: GET /commands asks the bridge to hold the request until a
// command arrives (or ~20s pass), so a command reaches a live worker immediately
// instead of on the next 2s tick. The loop re-polls as soon as each poll returns;
// against an older app without long polling it falls back to the 2s idle gap, and
// when Holmes is not running it backs off. A watchdog interval restarts the loop if
// it ever stops, and every fetch carries a timeout so the in-flight flag always clears.

let commandLoopRunning = false;
let commandWatchdog = null;
let commandPollInFlight = false;
let commandPollStartedAt = 0;
let lastCommandActivityAt = 0;
let runningCommandCount = 0;
let selfKeepaliveTimer = null;

function ensureCommandLoop() {
  if (commandWatchdog === null) {
    commandWatchdog = setInterval(() => { if (!commandLoopRunning) runCommandLoop(); }, COMMAND_POLL_MS);
  }
  if (!commandLoopRunning) runCommandLoop();
}

async function runCommandLoop() {
  if (commandLoopRunning) return;
  commandLoopRunning = true;
  let failures = 0;
  try {
    for (;;) {
      const outcome = await pollCommands();
      if (outcome === "longpoll") { failures = 0; continue; }
      if (outcome === "error") {
        failures++;
        await delay(Math.min(CONFIG.pollErrorBackoffMs * Math.pow(2, Math.min(failures - 1, 5)), 30000));
        continue;
      }
      failures = 0;
      await delay(CONFIG.pollIdleMs);  // "idle" (no long poll support) or "busy"
    }
  } catch (e) {
    // Unexpected failure (timers unavailable, worker shutting down). The watchdog
    // interval restarts the loop; never spin here.
  } finally {
    commandLoopRunning = false;
  }
}

// One poll. Resolves "longpoll" | "idle" | "busy" | "error"; never throws.
async function pollCommands() {
  if (commandPollInFlight && Date.now() - commandPollStartedAt < CONFIG.fetchTimeoutMs.commands + 5000) return "busy";
  commandPollInFlight = true;
  commandPollStartedAt = Date.now();
  try {
    const token = await ensureToken();
    if (!token) return "error";
    const [instanceId, focused] = await Promise.all([browserInstance().catch(() => ""), browserFocused()]);

    let res;
    try {
      res = await fetchWithTimeout(COMMANDS_ENDPOINT, {
        method: "GET",
        headers: {
          "X-Holmes-Token": token, "Accept": "application/json",
          "X-Holmes-Browser-Instance": instanceId, "X-Holmes-Browser-Focused": focused ? "1" : "0",
          "X-Holmes-Long-Poll": String(CONFIG.longPollSeconds)
        }
      }, CONFIG.fetchTimeoutMs.commands);
    } catch (e) {
      return "error"; // Holmes app not running, port closed, or the poll timed out.
    }
    if (!res.ok) return "error"; // 401 (wrong token), 404 (older app without the channel), etc.
    const longPoll = !!(res.headers && typeof res.headers.get === "function" && res.headers.get("X-Holmes-Long-Poll") === "1");

    let data;
    try { data = await res.json(); } catch (e) { return "error"; }

    const commands = Array.isArray(data)
      ? data
      : (data && Array.isArray(data.commands) ? data.commands : []);
    if (commands.length) noteCommandActivity();
    // Dispatch without waiting: each tab has its own serial lane and an overall cap
    // bounds concurrency, so a long waitForSelector never stalls other tabs or the
    // next poll.
    for (const cmd of commands) scheduleCommand(cmd, token);
    return longPoll ? "longpoll" : "idle";
  } catch (e) {
    return "error";
  } finally {
    commandPollInFlight = false;
  }
}

// Commands are "expected" for a while after one arrives: the model usually sends a
// follow up. Calling any extension API resets the MV3 idle timer, so a cheap call on
// an interval keeps the worker (and its long poll) alive until things go quiet.
function noteCommandActivity() {
  lastCommandActivityAt = Date.now();
  if (selfKeepaliveTimer !== null) return;
  selfKeepaliveTimer = setInterval(() => {
    if (runningCommandCount === 0 && Date.now() - lastCommandActivityAt > CONFIG.keepaliveWindowMs) {
      clearInterval(selfKeepaliveTimer);
      selfKeepaliveTimer = null;
      return;
    }
    try { Promise.resolve(chrome.runtime.getPlatformInfo()).catch(() => {}); } catch (_) { /* ignore */ }
  }, CONFIG.keepaliveMs);
}

// MARK: - Per tab scheduling
//
// Commands used to run strictly one after another, so one waitForSelector (up to
// 15s) delayed every other command past the app's result timeout. Now each target
// tab has a serial lane (two commands for the same page still run in order) and
// lanes run in parallel up to maxConcurrentCommands.
const commandLanes = new Map();
let busyCommandSlots = 0;
const commandSlotWaiters = [];

function acquireCommandSlot() {
  if (busyCommandSlots < CONFIG.maxConcurrentCommands) {
    busyCommandSlots++;
    return { immediate: true, ready: Promise.resolve() };
  }
  return { immediate: false, ready: new Promise(resolve => commandSlotWaiters.push(resolve)) };
}

function releaseCommandSlot() {
  const next = commandSlotWaiters.shift();
  if (next) next(); else busyCommandSlots--;
}

function commandLane(cmd) {
  const params = (cmd && cmd.params) || {};
  if (typeof params.tabId === "number") return Promise.resolve("tab:" + params.tabId);
  if (cmd && cmd.action === "fill_email_draft") {
    try {
      const identity = JSON.parse(params.expected && params.expected.identity);
      if (Array.isArray(identity) && Number.isInteger(identity[2])) return Promise.resolve("tab:" + identity[2]);
    } catch (_) { /* fall through to the active tab */ }
  }
  if (cmd && (cmd.action === "openTab" || cmd.action === "listTabs")) return Promise.resolve("browser");
  return activeTabId().then(id => (id >= 0 ? "tab:" + id : "browser"));
}

// Tells the app a delivered command has started running after waiting its turn,
// so time spent queued in the browser does not count against its result timeout.
function postStarted(cmd, token) {
  const body = { id: cmd.id, action: cmd.action, session: cmd.session, _holmesStarted: true, at: Date.now() };
  postResult(body, token);
}

function scheduleCommand(cmd, token) {
  return (async () => {
    const lane = await commandLane(cmd);
    const previous = commandLanes.get(lane);
    let release;
    const turn = new Promise(resolve => { release = resolve; });
    const tail = (previous || Promise.resolve()).then(() => turn);
    commandLanes.set(lane, tail);
    if (previous) await previous;
    const slot = acquireCommandSlot();
    await slot.ready;
    try {
      if ((previous || !slot.immediate) && cmd && cmd.id !== undefined) postStarted(cmd, token);
      await runOneCommand(cmd, token);
    } finally {
      releaseCommandSlot();
      release();
      if (commandLanes.get(lane) === tail) commandLanes.delete(lane);
    }
  })().catch(() => { /* runOneCommand reports its own failures */ });
}

// MARK: - Idempotent execution
//
// A command id can reach this worker more than once: the bridge requeues a command
// whose poll response was lost, and an evicted worker restarts mid-command. Running
// fill_field or click twice is exactly the bug, so every command is recorded in a
// ledger keyed by app launch session plus id, kept in chrome.storage.session (which
// survives worker restarts but not a browser restart) with an in-memory fallback.
//   • done      → the stored result is posted again; nothing re-runs.
//   • running   → in this worker life: the live run will post. From a previous life:
//                 report "interrupted" rather than guess whether it took effect.
const LEDGER_KEY = "holmesCommandLedger";
const LEDGER_LIMIT = 100;
const LEDGER_TTL_MS = 10 * 60 * 1000;
const LEDGER_REPLAY_BYTES = 256 * 1024;
const ledgerMemory = new Map();
const runningCommandKeys = new Set();
let ledgerWrites = Promise.resolve();

function ledgerKey(cmd) {
  return (cmd && typeof cmd.session === "string" ? cmd.session : "nosession") + ":" + cmd.id;
}

function sessionArea() {
  try { return chrome.storage && chrome.storage.session ? chrome.storage.session : null; } catch (_) { return null; }
}

function pruneLedger(ledger) {
  const now = Date.now();
  const keys = Object.keys(ledger).filter(key => ledger[key] && now - (ledger[key].at || 0) < LEDGER_TTL_MS);
  keys.sort((a, b) => (ledger[b].at || 0) - (ledger[a].at || 0));
  const kept = {};
  for (const key of keys.slice(0, LEDGER_LIMIT)) kept[key] = ledger[key];
  return kept;
}

async function ledgerEntry(key) {
  if (ledgerMemory.has(key)) return ledgerMemory.get(key);
  const area = sessionArea();
  if (!area) return null;
  try {
    await ledgerWrites;
    const stored = await area.get(LEDGER_KEY);
    const ledger = (stored && stored[LEDGER_KEY]) || {};
    return ledger[key] || null;
  } catch (_) {
    return null;
  }
}

// Serialized so concurrent commands never overwrite each other's entries.
function recordLedger(key, entry) {
  ledgerMemory.set(key, entry);
  if (ledgerMemory.size > LEDGER_LIMIT) ledgerMemory.delete(ledgerMemory.keys().next().value);
  const area = sessionArea();
  if (!area) return Promise.resolve();
  ledgerWrites = ledgerWrites.then(async () => {
    try {
      const stored = await area.get(LEDGER_KEY);
      const ledger = (stored && stored[LEDGER_KEY]) || {};
      ledger[key] = entry;
      await area.set({ [LEDGER_KEY]: pruneLedger(ledger) });
    } catch (_) { /* storage full or unavailable: the memory ledger still dedupes */ }
  });
  return ledgerWrites;
}

// Keeps a result for replay when it is small enough; a large one (a screenshot)
// is replaced by an honest note rather than replayed as a success without data.
function replayableOutcome(outcome) {
  let size = 0;
  try { size = JSON.stringify(outcome).length; } catch (_) { size = Infinity; }
  if (size <= LEDGER_REPLAY_BYTES) return outcome;
  return { ok: false, replayTruncated: true,
    error: "the earlier result (" + size + " bytes) was too large to keep for replay; request it again if it is still needed" };
}

async function runOneCommand(cmd, token) {
  const id = cmd && cmd.id !== undefined ? cmd.id : null;
  const action = cmd && cmd.action;
  const session = cmd && typeof cmd.session === "string" ? cmd.session : undefined;
  const key = id !== null ? ledgerKey(cmd) : null;

  if (key !== null) {
    if (runningCommandKeys.has(key)) return; // already running here; that run posts the result
    const prior = await ledgerEntry(key);
    if (prior && prior.state === "done") {
      await postResult(Object.assign({ id, action, session, at: Date.now(), replayed: true }, prior.result), token);
      return;
    }
    if (prior && prior.state === "running") {
      const interrupted = { ok: false, interrupted: true,
        error: "interrupted: the browser extension restarted while running this command, so it was not run again. Check the page before retrying." };
      await recordLedger(key, { state: "done", action, at: Date.now(), result: interrupted });
      await postResult(Object.assign({ id, action, session, at: Date.now() }, interrupted), token);
      return;
    }
    runningCommandKeys.add(key);
    // Recorded before anything runs, so a restart mid-command is detectable.
    await recordLedger(key, { state: "running", action, at: Date.now() });
  }

  let outcome;
  runningCommandCount++;
  try {
    outcome = action === "read_email_compose" || action === "fill_email_draft"
      ? await emailComposeCommand(cmd) : await HolmesAutomation.execute(cmd);
  } catch (e) {
    outcome = { ok: false, error: String(e && e.message ? e.message : e) };
  } finally {
    runningCommandCount--;
    noteCommandActivity();
  }

  if (key !== null) {
    await recordLedger(key, { state: "done", action, at: Date.now(), result: replayableOutcome(outcome) });
    runningCommandKeys.delete(key);
  }
  // The session echo lets the app ignore a result meant for a previous launch.
  const body = Object.assign({ id, action, session, at: Date.now() }, outcome);
  await postResult(body, token);
}

function byteLength(text) {
  try { return new TextEncoder().encode(text).length; } catch (_) { return text.length; }
}

// A result the bridge cannot take is replaced by a small, explicit error, so the
// app reports "too large" instead of timing out on a result that never arrived.
function compactSizeError(body, bytes, limit) {
  return JSON.stringify({
    id: body.id, action: body.action, session: body.session, at: Date.now(), ok: false,
    error: "result too large (" + bytes + " bytes; the Holmes bridge accepts " + limit + "). Narrow the selector or request less.",
    bytes, limit
  });
}

// POSTs one command result. Transient failures (network error, timeout, 5xx) are
// retried with backoff; a 413 is answered with a compact size error; an auth or
// protocol refusal is not retried. Never throws. Resolves true once delivered.
async function postResult(body, token) {
  const bytes = byteLength(JSON.stringify(body));
  let text = bytes > CONFIG.maxResultBytes ? compactSizeError(body, bytes, CONFIG.maxResultBytes) : JSON.stringify(body);
  const delays = CONFIG.resultRetryDelaysMs || [];
  for (let attempt = 0; attempt <= delays.length; attempt++) {
    let status = 0;
    let limit = CONFIG.maxResultBytes;
    try {
      const res = await fetchWithTimeout(RESULT_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Holmes-Token": token },
        body: text
      }, CONFIG.fetchTimeoutMs.result);
      status = res.status;
      if (res.ok) return true;
      if (status === 413) {
        try { const info = await res.json(); if (info && Number(info.limit) > 0) limit = Number(info.limit); } catch (_) { /* ignore */ }
      }
    } catch (e) {
      status = 0; // network failure or timeout: retry below
    }
    if (status === 413) {
      if (byteLength(text) < 4096) return false; // even the compact error was refused
      text = compactSizeError(body, bytes, limit);
      continue; // resend the small version right away
    }
    if (status === 400 || status === 401 || status === 403 || status === 404) return false;
    if (attempt < delays.length) await delay(delays[attempt]);
  }
  return false;
}

async function emailComposeCommand(cmd) {
  const params = cmd.params || {};
  const instanceId = await browserInstance();
  let tab;
  if (cmd.action === "fill_email_draft") {
    // Explicit Insert targets the original tab, never the current cursor. A
    // document/composer comparison still occurs inside it before any write.
    let identity;
    try { identity = JSON.parse(params.expected && params.expected.identity); } catch (_) { identity = null; }
    if (!Array.isArray(identity) || identity[0] !== instanceId || !Number.isInteger(identity[2])) {
      return { ok: false, refused: true, reason: "The draft belongs to another browser session." };
    }
    tab = await chrome.tabs.get(identity[2]);
    if (tab.windowId !== identity[1]) return { ok: false, refused: true, reason: "The composer window changed." };
    await chrome.windows.update(tab.windowId, { focused: true });
    await chrome.tabs.update(tab.id, { active: true });
    await notifyActive(tab.id, true);
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
  const result = await chrome.tabs.sendMessage(tab.id, {
    type: cmd.action === "read_email_compose" ? "holmes:readEmailCompose" : "holmes:fillEmailDraft",
    environment, body: params.body, expected: params.expected
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
