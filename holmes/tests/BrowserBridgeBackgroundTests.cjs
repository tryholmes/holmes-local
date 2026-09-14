// Runs the production MV3 worker (background.js + automation.js) against a mock
// chrome.* surface. No browser, no network: fetch is a scripted fake.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const extension = path.resolve(__dirname, '../holmes-extension');
const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'manifest.json'), 'utf8'));
let checks = 0;
function check(condition, description) { checks++; assert.ok(condition, description); console.log('PASS ' + description); }
// The test's own waits keep node alive; only the worker's timers are unref'd.
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(label, condition, timeout = 3000) {
  const start = Date.now();
  while (!condition()) {
    if (Date.now() - start > timeout) throw new Error('Timed out waiting for: ' + label);
    await sleep(5);
  }
}

function event() {
  const listeners = [];
  return { listeners, addListener(fn) { listeners.push(fn); }, removeListener(fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
    emit(...args) { return listeners.map(fn => fn(...args)); } };
}

// Creates one isolated worker. `options.fetch(url, init)` scripts the bridge.
function loadWorker(options = {}) {
  const tabs = new Map((options.tabs || [{ id: 17, windowId: 23, url: 'https://mail.example.test/', status: 'complete', active: true }])
    .map(tab => [tab.id, Object.assign({ status: 'complete', active: false }, tab)]));
  const log = { fetches: [], injections: [], messages: [], updates: [], platformInfo: 0 };
  // Passing options.storage shares chrome.storage between two workers, which is how
  // a test simulates the same browser after its MV3 worker was evicted and restarted.
  const storage = options.storage || { local: new Map([['holmesToken', 'synthetic-token'], ['holmesBrowserInstance', 'test-profile']]), session: new Map() };
  // `quota` mimics chrome.storage.session's byte cap: a set that would exceed it
  // throws and changes nothing, as Chrome does.
  const area = (map, quota) => ({
    async get(keys) {
      const list = keys == null ? [...map.keys()] : Array.isArray(keys) ? keys : typeof keys === 'string' ? [keys] : Object.keys(keys);
      const out = {}; for (const key of list) if (map.has(key)) out[key] = structuredClone(map.get(key)); return out;
    },
    async set(values) {
      if (quota) {
        const next = new Map(map);
        for (const [key, value] of Object.entries(values)) next.set(key, value);
        if (JSON.stringify([...next]).length > quota) {
          log.sessionSetFailures = (log.sessionSetFailures || 0) + 1;
          throw new Error('QUOTA_BYTES quota exceeded');
        }
      }
      for (const [key, value] of Object.entries(values)) map.set(key, structuredClone(value));
    },
    async remove(keys) { for (const key of [].concat(keys)) map.delete(key); }
  });
  const events = {
    installed: event(), startup: event(), message: event(), activated: event(), updated: event(),
    removed: event(), focus: event(), alarm: event(), storageChanged: event()
  };
  const timers = {
    setTimeout: (fn, ms, ...args) => { const t = setTimeout(fn, ms, ...args); if (t.unref) t.unref(); return t; },
    setInterval: (fn, ms, ...args) => { const t = setInterval(fn, ms, ...args); if (t.unref) t.unref(); return t; },
    clearTimeout, clearInterval
  };
  const chrome = {
    runtime: {
      id: 'synthetic-extension', lastError: undefined,
      getManifest: () => manifest,
      getPlatformInfo: async () => { log.platformInfo++; return { os: 'mac' }; },
      onInstalled: events.installed, onStartup: events.startup, onMessage: events.message
    },
    storage: { local: area(storage.local), session: options.noSessionStorage ? undefined : area(storage.session, options.sessionQuotaBytes), onChanged: events.storageChanged },
    alarms: { onAlarm: events.alarm, get: (name, cb) => cb(undefined), create() {} },
    scripting: {
      async executeScript(details) {
        log.injections.push(details);
        if (options.executeScript) return options.executeScript(details, tabs);
        return [{ result: undefined }];
      }
    },
    tabs: {
      onActivated: events.activated, onUpdated: events.updated, onRemoved: events.removed,
      async query(filter = {}) {
        if (options.queryDelayMs) await sleep(options.queryDelayMs);
        let list = [...tabs.values()];
        if (filter.active) list = list.filter(tab => tab.active);
        if (filter.url) {
          const patterns = [].concat(filter.url).map(p => p.split('://')[0]);
          list = list.filter(tab => patterns.some(scheme => tab.url.startsWith(scheme + '://')));
        }
        return list;
      },
      async get(id) { if (!tabs.has(id)) throw new Error('No tab with id: ' + id); return tabs.get(id); },
      async update(id, props) {
        log.updates.push({ id, props });
        const tab = tabs.get(id);
        if (props.active) { for (const other of tabs.values()) if (other.windowId === tab.windowId) other.active = false; tab.active = true; }
        if (props.url) {
          // lazyNavigate mirrors real Chrome: update resolves before the new load
          // starts, so the tab still reports the old page as complete.
          if (!options.lazyNavigate) { tab.url = props.url; tab.status = 'loading'; }
          if (options.onNavigate) options.onNavigate(tab, events, props.url);
        }
        return tab;
      },
      async create(props) { const id = 100 + tabs.size; const tab = { id, windowId: 23, url: props.url, status: 'loading', active: props.active !== false }; tabs.set(id, tab); return tab; },
      async sendMessage(tabId, message) {
        log.messages.push({ tabId, message });
        if (options.sendMessage) return options.sendMessage(tabId, message, tabs);
        if (message.type === 'holmes:ping') return { ok: true, visible: true, isActiveTab: true };
        return { ok: true };
      },
      async captureVisibleTab(windowId, opts) {
        log.captures = log.captures || [];
        log.captures.push(opts);
        return options.capture ? options.capture(opts) : 'data:image/jpeg;base64,AAAA';
      }
    },
    windows: {
      onFocusChanged: events.focus,
      async get(id) { return { id, type: 'normal', focused: true }; },
      async getLastFocused() { return { id: 23, type: 'normal', focused: options.focused !== false }; },
      async update(id, props) { log.updates.push({ window: id, props }); return { id }; }
    }
  };
  const context = vm.createContext(Object.assign({
    console: options.quiet === false ? console : { log() {}, warn() {}, error() {}, info() {} },
    crypto: { randomUUID: () => 'uuid-' + Math.random().toString(16).slice(2) },
    AbortController, URL, TextEncoder, structuredClone, Blob, Response,
    chrome,
    fetch: async (url, init = {}) => {
      const entry = { url, init, aborted: false };
      log.fetches.push(entry);
      if (init.signal) init.signal.addEventListener('abort', () => { entry.aborted = true; });
      const handler = options.fetch || (() => ({ status: 200, body: [] }));
      const reply = await handler(url, init, entry);
      if (reply instanceof Error) throw reply;
      const status = reply.status || 200;
      const headers = new Map(Object.entries(reply.headers || {}).map(([k, v]) => [k.toLowerCase(), v]));
      return { ok: status >= 200 && status < 300, status, headers: { get: key => headers.get(String(key).toLowerCase()) || null },
        json: async () => reply.body, text: async () => JSON.stringify(reply.body) };
    },
    __holmesBridgeConfig: Object.assign({ pollIdleMs: 40, pollErrorBackoffMs: 40, heartbeatProbeMs: 0, visibilityPollMs: 10 }, options.config || {})
  }, timers));
  context.self = context;
  context.importScripts = (...files) => { for (const file of files) vm.runInContext(fs.readFileSync(path.join(extension, file), 'utf8'), context, { filename: file }); };
  vm.runInContext(fs.readFileSync(path.join(extension, 'background.js'), 'utf8'), context, { filename: 'background.js' });
  // Stops a finished test's worker from doing real work: every later fetch fails
  // fast, so its loops fall back to their error backoff.
  const dispose = () => { options.fetch = () => new Error('disposed'); };
  return { context, chrome, tabs, log, events, storage, dispose };
}

// A fetch that never answers on its own and rejects only when aborted.
function hangUntilAborted(init) {
  return new Promise((_, reject) => {
    if (init.signal) init.signal.addEventListener('abort', () => reject(new Error('The operation was aborted.')));
  });
}

async function transportTests() {
  // Heartbeat with a server that accepts the connection and never answers.
  let worker = loadWorker({
    config: { fetchTimeoutMs: { heartbeat: 60, relay: 60, commands: 80, result: 60 }, pollErrorBackoffMs: 30 },
    fetch: (url, init) => hangUntilAborted(init)
  });
  const beat = await Promise.race([worker.context.sendHeartbeat().then(() => 'done'), sleep(600).then(() => 'hung')]);
  check(beat === 'done' && worker.log.fetches.some(f => f.url.endsWith('/heartbeat') && f.aborted),
    'A heartbeat to a stalled bridge is aborted by its timeout instead of hanging');

  const relayed = await Promise.race([
    new Promise(resolve => worker.events.message.emit({ type: 'holmes:post', body: '{}' }, { tab: { id: 17, windowId: 23 } }, resolve)),
    sleep(600).then(() => 'hung')
  ]);
  check(relayed !== 'hung' && relayed.ok === false && worker.log.fetches.some(f => f.url.endsWith('/context') && f.aborted),
    'A relayed page context post times out and reports failure to the page');

  await until('two command polls', () => worker.log.fetches.filter(f => f.url.endsWith('/commands')).length >= 2, 1500);
  const polls = worker.log.fetches.filter(f => f.url.endsWith('/commands'));
  check(polls[0].aborted, 'A stalled command poll is aborted by its timeout');
  check(polls.length >= 2, 'The in flight flag clears after an aborted poll so polling continues');
  check(Number(polls[0].init.headers['X-Holmes-Long-Poll']) > 0, 'Command polls ask the bridge to long poll');
  worker.dispose();

  // A server that supports long polling: the worker re-polls right away.
  worker = loadWorker({
    config: { pollIdleMs: 400, longPollMinMs: 20 },
    fetch: async url => {
      if (!url.endsWith('/commands')) return { status: 200, body: {} };
      await sleep(30);
      return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
    }
  });
  await sleep(300);
  const longPolls = worker.log.fetches.filter(f => f.url.endsWith('/commands')).length;
  check(longPolls >= 4, `With long poll support the worker re-polls immediately (${longPolls} polls in 300ms)`);
  worker.dispose();

  // An older app without long polling: idle interval, not a tight loop.
  worker = loadWorker({
    config: { pollIdleMs: 150 },
    fetch: async url => ({ status: 200, body: [] })
  });
  await sleep(320);
  const idlePolls = worker.log.fetches.filter(f => f.url.endsWith('/commands')).length;
  check(idlePolls >= 2 && idlePolls <= 4, `Without long poll support polls keep an idle interval (${idlePolls} polls in 320ms)`);
  worker.dispose();

  // Holmes not running: failed polls back off instead of spinning.
  worker = loadWorker({ config: { pollErrorBackoffMs: 100 }, fetch: () => new Error('Failed to fetch') });
  await sleep(350);
  const failedPolls = worker.log.fetches.filter(f => f.url.endsWith('/commands')).length;
  check(failedPolls >= 1 && failedPolls <= 6, `Failed polls back off (${failedPolls} attempts in 350ms)`);
  worker.dispose();

  // After a command arrives the worker keeps itself awake for a while, then stops.
  let served = false;
  worker = loadWorker({
    config: { keepaliveMs: 40, keepaliveWindowMs: 400 },
    fetch: async url => {
      if (url.endsWith('/commands')) {
        await sleep(20);
        if (!served) { served = true; return { status: 200, body: [{ id: 1, action: 'listTabs', params: {}, session: 's1' }], headers: { 'X-Holmes-Long-Poll': '1' } }; }
        return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
      }
      return { status: 200, body: {} };
    }
  });
  await until('command result posted', () => worker.log.fetches.some(f => f.url.endsWith('/command-result')), 1500);
  await sleep(200);
  const awake = worker.log.platformInfo;
  check(awake >= 2, `The worker keeps itself awake after receiving a command (${awake} keepalive calls)`);
  await sleep(700);
  const settled = worker.log.platformInfo;
  await sleep(200);
  check(worker.log.platformInfo === settled, 'The self keepalive stops once commands have gone quiet');
  worker.dispose();
}

const receivingEndMissing = () => new Error('Could not establish connection. Receiving end does not exist.');

async function reinjectionTests() {
  const worker = loadWorker({
    fetch: () => ({ status: 503, body: {} }),
    tabs: [
      { id: 1, windowId: 23, url: 'https://open-before-install.test/', active: true },
      { id: 2, windowId: 23, url: 'chrome://settings/' },
      { id: 3, windowId: 23, url: 'http://discarded.test/', discarded: true },
      { id: 4, windowId: 23, url: 'https://second.test/' }
    ],
    executeScript(details) { if (details.target.tabId === 4 && details.world === 'MAIN') throw new Error('Cannot access contents of the page'); return [{}]; }
  });
  worker.events.installed.emit({ reason: 'update', previousVersion: '2.2' });
  await until('reinjection finished', () => worker.log.injections.filter(i => i.target.tabId === 1).length >= 2);
  await sleep(30);
  const tab1 = worker.log.injections.filter(i => i.target.tabId === 1);
  check(tab1[0].files.join() === 'history-hook.js' && tab1[0].world === 'MAIN' && tab1[0].injectImmediately === true,
    'Update reinjects the MAIN world history hook first, as at document_start');
  check(tab1[1].files.join() === 'email-compose.js,content.js' && (tab1[1].world === undefined || tab1[1].world === 'ISOLATED'),
    'Then the isolated world scripts in manifest order');
  check(!worker.log.injections.some(i => i.target.tabId === 2 || i.target.tabId === 3),
    'Restricted and discarded tabs are skipped');
  check(worker.log.injections.filter(i => i.target.tabId === 4).length === 2,
    'A failure injecting one script does not stop the rest for that tab or other tabs');
  const before = worker.log.injections.length;
  worker.events.installed.emit({ reason: 'chrome_update' });
  await sleep(30);
  check(worker.log.injections.length === before, 'A browser update does not reinject (manifest scripts already ran)');
}

async function probeTests() {
  const heartbeats = [];
  let pingMode = 'missing';
  const worker = loadWorker({
    config: { heartbeatProbeMs: 0 },
    fetch(url, init) {
      if (url.endsWith('/heartbeat')) heartbeats.push(JSON.parse(init.body || '{}'));
      return { status: url.endsWith('/commands') ? 503 : 200, body: {} };
    },
    tabs: [{ id: 9, windowId: 23, url: 'https://orphaned.test/', active: true }],
    sendMessage(tabId, message) {
      if (message.type !== 'holmes:ping') return { ok: true };
      if (pingMode === 'missing') throw receivingEndMissing();
      return { ok: true, visible: true, isActiveTab: true };
    }
  });
  await until('first heartbeat', () => heartbeats.some(h => h.activeTab));
  const first = heartbeats.find(h => h.activeTab);
  check(first.instanceId === 'test-profile' && typeof first.focused === 'boolean', 'Heartbeat body names the browser instance and focus');
  check(first.activeTab.script === 'missing' || first.activeTab.script === 'reinjected',
    'An active tab whose content script is gone is reported, not hidden behind worker heartbeats');
  await until('self heal injection', () => worker.log.injections.some(i => i.target.tabId === 9));
  check(worker.log.injections.filter(i => i.target.tabId === 9 && i.world === 'MAIN').length === 1,
    'The worker reinjects a missing active tab once');
  pingMode = 'ok';
  heartbeats.length = 0;
  await worker.context.sendHeartbeat();
  check(heartbeats.at(-1).activeTab.script === 'ok', 'A live content script reports ok');
  worker.tabs.get(9).url = 'chrome://newtab/';
  await worker.context.sendHeartbeat();
  check(heartbeats.at(-1).activeTab.script === 'restricted', 'A browser page is restricted, not missing');
  const beat = worker.log.fetches.findLast(f => f.url.endsWith('/heartbeat'));
  check(beat.init.headers['X-Holmes-Browser-Instance'] === 'test-profile' && beat.init.headers['X-Holmes-Browser-Focused'] === '1',
    'Heartbeat headers carry the instance and focus for routing');
}

// Serves each queued command once through a long polling /commands, then idles.
function commandFeed(commands) {
  const queue = commands.slice();
  return async () => {
    await sleep(15);
    return { status: 200, body: queue.length ? [queue.shift()] : [], headers: { 'X-Holmes-Long-Poll': '1' } };
  };
}

function resultPosts(worker, id) {
  return worker.log.fetches.filter(f => f.url.endsWith('/command-result'))
    .map(f => ({ entry: f, body: JSON.parse(f.init.body) }))
    .filter(p => id === undefined || p.body.id === id);
}

async function resultDeliveryTests() {
  // A result POST that fails is retried with backoff until it lands.
  let attempts = 0;
  let feed = commandFeed([{ id: 7, action: 'listTabs', params: {}, session: 's1' }]);
  let worker = loadWorker({
    config: { resultRetryDelaysMs: [20, 40, 80] },
    fetch: async (url) => {
      if (url.endsWith('/commands')) return feed();
      if (url.endsWith('/command-result')) {
        attempts++;
        if (attempts === 1) return new Error('Failed to fetch');
        if (attempts === 2) return { status: 503, body: {} };
        return { status: 200, body: { ok: true } };
      }
      return { status: 200, body: {} };
    }
  });
  await until('result delivered after retries', () => attempts >= 3, 2000);
  await sleep(150);
  const posts = resultPosts(worker, 7);
  check(posts.length === 3 && posts.every(p => p.body.ok === true && p.body.session === 's1'),
    `A failed result POST is retried with backoff until it lands (${posts.length} attempts)`);
  worker.dispose();

  // A refused token is not retried.
  let unauthorized = 0;
  feed = commandFeed([{ id: 8, action: 'listTabs', params: {} }]);
  worker = loadWorker({
    config: { resultRetryDelaysMs: [20, 40, 80] },
    fetch: async (url) => {
      if (url.endsWith('/commands')) return feed();
      if (url.endsWith('/command-result')) { unauthorized++; return { status: 401, body: {} }; }
      return { status: 200, body: {} };
    }
  });
  await until('401 result attempt', () => unauthorized >= 1, 2000);
  await sleep(250);
  check(unauthorized === 1, 'A 401 result POST is not retried');
  worker.dispose();

  // The bridge answers 413: the worker sends a compact error explaining the size.
  const huge = 'X'.repeat(200000);
  let bigAttempts = 0;
  feed = commandFeed([{ id: 9, action: 'extract', params: { selector: 'p' }, session: 's1' }]);
  worker = loadWorker({
    executeScript: details => details.func ? [{ result: { ok: true, count: 1, elements: [{ text: huge }] } }] : [{}],
    fetch: async (url, init) => {
      if (url.endsWith('/commands')) return feed();
      if (url.endsWith('/command-result')) {
        bigAttempts++;
        return init.body.length > 100000 ? { status: 413, body: { error: 'Body exceeds', limit: 100000 } } : { status: 200, body: { ok: true } };
      }
      return { status: 200, body: {} };
    }
  });
  await until('compact error posted', () => resultPosts(worker, 9).length >= 2, 2000);
  const compact = resultPosts(worker, 9).at(-1);
  check(compact.entry.init.body.length < 4096 && compact.body.ok === false && /too large/i.test(compact.body.error)
    && compact.body.bytes > 200000 && compact.body.session === 's1',
    'After a 413 the worker posts a compact error that names the result size');
  worker.dispose();

  // A result already over the configured cap is never sent in full.
  feed = commandFeed([{ id: 10, action: 'extract', params: { selector: 'p' } }]);
  worker = loadWorker({
    config: { maxResultBytes: 50000 },
    executeScript: details => details.func ? [{ result: { ok: true, count: 1, elements: [{ text: huge }] } }] : [{}],
    fetch: async (url) => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } }
  });
  await until('proactive compact error', () => resultPosts(worker, 10).length >= 1, 2000);
  await sleep(50);
  const proactive = resultPosts(worker, 10);
  check(proactive.length === 1 && proactive[0].body.ok === false && proactive[0].entry.init.body.length < 4096,
    'A result over the size cap is replaced by a compact error before sending');
  worker.dispose();

  // Screenshots are JPEG, stepping quality down until they fit.
  feed = commandFeed([{ id: 11, action: 'screenshotTab', params: {} }]);
  worker = loadWorker({
    config: { maxScreenshotChars: 45000 },
    capture: opts => 'data:image/jpeg;base64,' + 'A'.repeat((opts.quality || 100) * 1000),
    fetch: async (url) => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } }
  });
  await until('screenshot result', () => resultPosts(worker, 11).length >= 1, 2000);
  const shot = resultPosts(worker, 11)[0].body;
  const qualities = worker.log.captures.map(c => c.quality);
  check(worker.log.captures.every(c => c.format === 'jpeg') && shot.format === 'jpeg',
    'screenshot_tab captures JPEG instead of PNG');
  check(shot.ok === true && shot.dataUrl.length <= 45000 && qualities[0] > qualities.at(-1),
    `screenshot_tab compresses until the image fits (qualities ${qualities.join(', ')})`);
  worker.dispose();
}

async function idempotencyTests() {
  const fill = (id, session = 's1') => ({ id, action: 'fillField', params: { selector: '#to', value: 'boss@example.test' }, session });
  let executions = 0;
  const executeScript = details => {
    if (!details.func) return [{}];
    executions++;
    return [{ result: { ok: true, filled: { tag: 'input', id: 'to' }, length: 17 } }];
  };
  const okResults = async () => ({ status: 200, body: { ok: true } });

  // The same command id delivered twice (a requeue after a lost poll response)
  // runs once; the second delivery gets the stored result again.
  let feed = commandFeed([fill(21), fill(21)]);
  let worker = loadWorker({ executeScript, fetch: async url => url.endsWith('/commands') ? feed() : okResults() });
  await until('two results for id 21', () => resultPosts(worker, 21).length >= 2, 2000);
  let posts = resultPosts(worker, 21);
  check(executions === 1, `A redelivered command id executes once (${executions} executions)`);
  check(posts[1].body.ok === true && posts[1].body.filled.id === 'to' && posts[1].body.session === 's1',
    'The redelivery re-posts the stored result instead of re-running fill_field');
  worker.dispose();

  // Across a worker restart (same chrome.storage.session) the result is replayed.
  const shared = { local: new Map([['holmesToken', 'synthetic-token'], ['holmesBrowserInstance', 'test-profile']]), session: new Map() };
  executions = 0;
  feed = commandFeed([fill(22)]);
  worker = loadWorker({ storage: shared, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : okResults() });
  await until('first life result', () => resultPosts(worker, 22).length >= 1, 2000);
  await sleep(50);
  worker.dispose();
  feed = commandFeed([fill(22), fill(22, 's2')]);
  worker = loadWorker({ storage: shared, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : okResults() });
  await until('second life results', () => resultPosts(worker, 22).length >= 2, 2000);
  posts = resultPosts(worker, 22);
  check(executions === 2 && posts[0].body.ok === true,
    'After a worker restart the same id and session is replayed from session storage, not re-run');
  check(posts[1].body.session === 's2', 'The same numeric id from a new app launch is a different command and runs');
  worker.dispose();

  // A command the previous worker started but never finished is not re-run blindly.
  executions = 0;
  const interrupted = { local: new Map(shared.local), session: new Map() };
  interrupted.session.set('holmesCommandLedger', { 's1:23': { state: 'running', action: 'fillField', at: Date.now() } });
  feed = commandFeed([fill(23)]);
  worker = loadWorker({ storage: interrupted, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : okResults() });
  await until('interrupted result', () => resultPosts(worker, 23).length >= 1, 2000);
  posts = resultPosts(worker, 23);
  check(executions === 0 && posts[0].body.ok === false && /interrupted/i.test(posts[0].body.error),
    'A command interrupted by a worker restart reports that instead of running twice');
  worker.dispose();

  // Without chrome.storage.session (older Chrome) the in-memory ledger still dedupes.
  executions = 0;
  feed = commandFeed([fill(24), fill(24)]);
  worker = loadWorker({ noSessionStorage: true, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : okResults() });
  await until('memory ledger results', () => resultPosts(worker, 24).length >= 2, 2000);
  check(executions === 1, 'Without session storage a redelivered id still executes once');
  worker.dispose();
}

async function concurrencyTests() {
  const spans = [];
  const delays = { '#slow': 300, '#first': 200, '#second': 10, '#fast': 10, '.capped': 100 };
  const executeScript = async details => {
    if (!details.func) return [{}];
    const params = details.args[1] || {};
    const span = { tab: details.target.tabId, selector: params.selector, start: Date.now() };
    spans.push(span);
    await sleep(delays[params.selector] || 10);
    span.end = Date.now();
    return [{ result: { ok: true, count: 0, elements: [], selector: params.selector } }];
  };
  const tabs = [1, 2, 3, 4, 5, 6].map(id => ({ id, windowId: 23, url: 'https://tab' + id + '.test/', active: id === 1 }));
  function batchFeed(batch) {
    let served = false;
    return async () => {
      await sleep(15);
      if (served) return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
      served = true;
      return { status: 200, body: batch, headers: { 'X-Holmes-Long-Poll': '1' } };
    };
  }
  const extract = (id, tabId, selector) => ({ id, action: 'extract', params: { tabId, selector }, session: 's1' });

  // A long command on one tab does not stall a command for another tab.
  let feed = batchFeed([extract(31, 1, '#slow'), extract(32, 2, '#fast')]);
  let worker = loadWorker({ tabs, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } } });
  await until('both results', () => resultPosts(worker, 31).some(p => !p.body._holmesStarted) && resultPosts(worker, 32).length >= 1, 3000);
  const slowDone = worker.log.fetches.findIndex(f => f.url.endsWith('/command-result') && JSON.parse(f.init.body).id === 31 && !JSON.parse(f.init.body)._holmesStarted);
  const fastDone = worker.log.fetches.findIndex(f => f.url.endsWith('/command-result') && JSON.parse(f.init.body).id === 32);
  check(fastDone < slowDone, 'A fast command on another tab finishes while a slow one is still running');
  worker.dispose();

  // Commands for the same tab still run strictly in order.
  spans.length = 0;
  feed = batchFeed([extract(33, 3, '#first'), extract(34, 3, '#second')]);
  worker = loadWorker({ tabs, executeScript, fetch: async url => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } } });
  await until('same tab results', () => resultPosts(worker, 34).some(p => !p.body._holmesStarted), 3000);
  const first = spans.find(s => s.selector === '#first'), second = spans.find(s => s.selector === '#second');
  check(second.start >= first.end, 'Commands for the same tab run one at a time, in order');
  check(resultPosts(worker, 34).some(p => p.body._holmesStarted === true),
    'A command that waited behind another tells the app when it actually starts');
  worker.dispose();

  // An overall cap bounds how many run at once.
  spans.length = 0;
  feed = batchFeed([1, 2, 3, 4, 5, 6].map(tab => extract(40 + tab, tab, '.capped')));
  worker = loadWorker({ tabs, config: { maxConcurrentCommands: 2 }, executeScript,
    fetch: async url => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } } });
  await until('capped results', () => [41, 42, 43, 44, 45, 46].every(id => resultPosts(worker, id).some(p => !p.body._holmesStarted)), 4000);
  // True peak concurrency: sweep start and end instants (ends first on ties).
  // Counting every span that overlaps a given span overcounts staggered runs.
  const instants = spans.flatMap(span => [{ t: span.start, d: 1 }, { t: span.end, d: -1 }])
    .sort((a, b) => a.t - b.t || a.d - b.d);
  let running = 0, peak = 0;
  for (const instant of instants) { running += instant.d; peak = Math.max(peak, running); }
  check(peak === 2, `No more than the configured number of commands run at once (peak ${peak})`);
  worker.dispose();
}

async function visibilityTests() {
  const expected = { identity: JSON.stringify(['test-profile', 23, 17, 'document', 'account', 1]), recipients: [], cc: [], bcc: [], subject: 's', body: '', bodyReadable: true, bodyIsEmpty: true };
  const tabs = [{ id: 17, windowId: 23, url: 'https://mail.example.test/', active: false }, { id: 28, windowId: 23, url: 'https://other.test/', active: true }];

  // The tab becomes visible a little after activation; insertion waits for it.
  let pings = 0, pingsBeforeFill = -1;
  let worker = loadWorker({
    tabs, config: { visibilityPollMs: 10, visibilityTimeoutMs: 1000 },
    fetch: async () => ({ status: 503, body: {} }),
    sendMessage(tabId, message) {
      if (message.type === 'holmes:ping') { pings++; return { ok: true, visible: pings > 3, isActiveTab: pings > 3 }; }
      if (message.type === 'holmes:fillEmailDraft') { pingsBeforeFill = pings; return { ok: true, inserted: true, identity: message.expected.identity }; }
      return {};
    }
  });
  let result = await worker.context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'Reviewed', expected } });
  check(result.ok === true && pingsBeforeFill >= 4, `Insert into a background tab waits until the tab reports visible (${pingsBeforeFill} pings first)`);
  worker.dispose();

  // A tab that never becomes visible is refused within a bounded time, never written.
  let fills = 0;
  worker = loadWorker({
    tabs: tabs.map(t => Object.assign({}, t)), config: { visibilityPollMs: 10, visibilityTimeoutMs: 150 },
    fetch: async () => ({ status: 503, body: {} }),
    sendMessage(tabId, message) {
      if (message.type === 'holmes:ping') return { ok: true, visible: false, isActiveTab: true };
      if (message.type === 'holmes:fillEmailDraft') { fills++; return { ok: true, inserted: true, identity: message.expected.identity }; }
      return {};
    }
  });
  const started = Date.now();
  result = await worker.context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'Reviewed', expected } });
  check(result.ok === false && /did not become visible/i.test(result.reason) && fills === 0 && Date.now() - started < 1000,
    'A tab that never becomes visible is refused within the bound and nothing is inserted');
  worker.dispose();
}

async function navigateTests() {
  // navigate resolves once the tab finishes loading.
  let worker = loadWorker({
    fetch: async () => ({ status: 503, body: {} }),
    onNavigate(tab, events) {
      setTimeout(() => { tab.status = 'complete'; events.updated.emit(tab.id, { status: 'complete' }, tab); }, 150);
    }
  });
  let started = Date.now();
  let result = await worker.context.HolmesAutomation.execute({ action: 'navigate', params: { url: 'https://example.test/next', tabId: 17 } });
  let elapsed = Date.now() - started;
  check(result.ok === true && result.loaded === true && elapsed >= 140, `navigate waits for the page to finish loading (${elapsed}ms)`);
  worker.dispose();

  // A page that never finishes loading still resolves, bounded, and says so.
  worker = loadWorker({ config: { navigateTimeoutMs: 120 }, fetch: async () => ({ status: 503, body: {} }), onNavigate() {} });
  started = Date.now();
  result = await worker.context.HolmesAutomation.execute({ action: 'navigate', params: { url: 'https://slow.test/', tabId: 17 } });
  elapsed = Date.now() - started;
  check(result.ok === true && result.loaded === false && elapsed < 1000, `navigate gives up waiting after its bound (${elapsed}ms)`);
  worker.dispose();

  // Closing the tab mid navigation ends the wait with an error.
  worker = loadWorker({
    fetch: async () => ({ status: 503, body: {} }),
    onNavigate(tab, events) { setTimeout(() => events.removed.emit(tab.id, {}), 40); }
  });
  result = await worker.context.HolmesAutomation.execute({ action: 'navigate', params: { url: 'https://gone.test/', tabId: 17 } });
  check(result.ok === false && /closed/i.test(result.error), 'A tab closed during navigation reports an error instead of waiting');
  worker.dispose();
}

async function longPollSpinTests() {
  // Five paired browsers against a bridge that holds only three long polls. The
  // other two get an immediate empty answer; they must wait instead of spinning.
  let held = 0;
  const polls = [0, 0, 0, 0, 0];
  const workers = polls.map((_, index) => loadWorker({
    config: { pollIdleMs: 200, longPollMinMs: 150 },
    fetch: async url => {
      if (!url.endsWith('/commands')) return { status: 200, body: {} };
      polls[index]++;
      if (held < 3) {
        held++;
        await sleep(300);
        held--;
      } else {
        await sleep(1);
      }
      return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
    }
  }));
  await sleep(1000);
  workers.forEach(worker => worker.dispose());
  const total = polls.reduce((a, b) => a + b, 0);
  check(total < 60, `Empty long polls that return immediately back off instead of spinning (${total} polls from 5 workers in 1s)`);
}

async function ledgerRaceTests() {
  // Two copies of one command id land in different tab lanes at the same moment.
  // Only one may run; the check and the running marker must not race.
  let executions = 0;
  const executeScript = async details => {
    if (!details.func) return [{}];
    executions++;
    await sleep(50);
    return [{ result: { ok: true, filled: { tag: 'input' }, length: 1 } }];
  };
  const tabs = [{ id: 1, windowId: 23, url: 'https://a.test/', active: true }, { id: 2, windowId: 23, url: 'https://b.test/' }];
  let served = false;
  const worker = loadWorker({ tabs, executeScript, fetch: async url => {
    if (!url.endsWith('/commands')) return { status: 200, body: { ok: true } };
    await sleep(15);
    if (served) return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
    served = true;
    const copy = tabId => ({ id: 51, action: 'fillField', params: { tabId, selector: '#a', value: 'x' }, session: 's1' });
    return { status: 200, body: [copy(1), copy(2)], headers: { 'X-Holmes-Long-Poll': '1' } };
  } });
  await until('result for 51', () => resultPosts(worker, 51).some(p => !p.body._holmesStarted), 2000);
  await sleep(200);
  check(executions === 1, `Two copies of one id in different lanes execute once (${executions} executions)`);
  worker.dispose();
}

async function ledgerQuotaTests() {
  // 60 large extract results (200 KB each) must not grow the replay ledger past
  // chrome.storage.session's 10 MB quota, where writes fail silently.
  const text = 'L'.repeat(200 * 1024);
  const commands = Array.from({ length: 60 }, (_, i) => ({ id: 300 + i, action: 'extract', params: { selector: 'p' }, session: 's1' }));
  const feed = commandFeed(commands);
  const worker = loadWorker({
    sessionQuotaBytes: 10 * 1024 * 1024,
    executeScript: details => details.func ? [{ result: { ok: true, count: 1, elements: [{ text }] } }] : [{}],
    fetch: async url => url.endsWith('/commands') ? feed() : { status: 200, body: { ok: true } }
  });
  await until('all quota results', () => worker.log.fetches.filter(f => f.url.endsWith('/command-result')).length >= 60, 30000);
  await sleep(200);
  const stored = worker.storage.session.get('holmesCommandLedger') || {};
  const bytes = JSON.stringify(stored).length;
  const failures = worker.log.sessionSetFailures || 0;
  check(failures === 0 && bytes < 1024 * 1024,
    `Large results keep the ledger small and every session write succeeds (${bytes} bytes, ${failures} failed writes)`);
  const newest = stored['s1:359'];
  check(newest && newest.state === 'done' && newest.result && newest.result.ok === true && JSON.stringify(newest.result).length < 8192,
    'The newest command stays in the ledger with a compact outcome');
  worker.dispose();
}

async function laneOrderTests() {
  // A command without tabId (needs an active tab lookup) arrives before one with
  // tabId for the same tab. Lanes must be assigned in arrival order.
  const spans = [];
  const executeScript = async details => {
    if (!details.func) return [{}];
    const params = details.args[1] || {};
    const span = { selector: params.selector, start: Date.now() };
    spans.push(span);
    await sleep(params.selector === '#first' ? 120 : 10);
    span.end = Date.now();
    return [{ result: { ok: true, count: 0, elements: [] } }];
  };
  let served = false;
  const worker = loadWorker({ queryDelayMs: 40, executeScript, fetch: async url => {
    if (!url.endsWith('/commands')) return { status: 200, body: { ok: true } };
    await sleep(15);
    if (served) return { status: 200, body: [], headers: { 'X-Holmes-Long-Poll': '1' } };
    served = true;
    return { status: 200, headers: { 'X-Holmes-Long-Poll': '1' }, body: [
      { id: 61, action: 'extract', params: { selector: '#first' }, session: 's1' },
      { id: 62, action: 'extract', params: { tabId: 17, selector: '#second' }, session: 's1' }
    ] };
  } });
  await until('lane order results', () => spans.length === 2 && spans.every(s => s.end), 3000);
  const first = spans.find(s => s.selector === '#first'), second = spans.find(s => s.selector === '#second');
  check(second.start >= first.end, 'A command with an explicit tabId waits behind an earlier command for the same active tab');
  worker.dispose();
}

async function composeTimeoutTests() {
  // A content script that never answers must not pin a command slot, block its
  // lane and keep the worker awake forever.
  const worker = loadWorker({
    config: { composeMessageTimeoutMs: 100 },
    fetch: async () => ({ status: 503, body: {} }),
    sendMessage(tabId, message) {
      if (message.type === 'holmes:readEmailCompose') return new Promise(() => {});
      return { ok: true, visible: true, isActiveTab: true };
    }
  });
  const started = Date.now();
  const outcome = await Promise.race([
    worker.context.emailComposeCommand({ action: 'read_email_compose' }).then(result => ({ result }), error => ({ error })),
    sleep(1500).then(() => 'hung')
  ]);
  const text = outcome === 'hung' ? 'hung'
    : String((outcome.error && outcome.error.message) || (outcome.result && (outcome.result.error || outcome.result.reason)));
  check(outcome !== 'hung' && Date.now() - started < 1000 && /timed out/i.test(text),
    `A silent content script cannot hold a compose command open (${text})`);
  worker.dispose();
}

async function navigateEarlyTests() {
  const quiet = async () => ({ status: 503, body: {} });
  // The old page still reports complete right after tabs.update; the new load
  // starts 50ms later and finishes at 200ms.
  let worker = loadWorker({
    lazyNavigate: true, fetch: quiet,
    onNavigate(tab, events, url) {
      setTimeout(() => { tab.pendingUrl = url; tab.status = 'loading'; events.updated.emit(tab.id, { status: 'loading' }, tab); }, 50);
      setTimeout(() => { tab.url = url; delete tab.pendingUrl; tab.status = 'complete'; events.updated.emit(tab.id, { status: 'complete' }, tab); }, 200);
    }
  });
  let started = Date.now();
  let result = await worker.context.HolmesAutomation.execute({ action: 'navigate', params: { url: 'https://example.test/next', tabId: 17 } });
  let elapsed = Date.now() - started;
  check(result.ok === true && result.loaded === true && elapsed >= 190 && result.url === 'https://example.test/next',
    `navigate ignores the previous page's complete status and waits for the new load (${elapsed}ms)`);
  worker.dispose();

  // Same document navigation: no loading phase, the URL simply changes.
  worker = loadWorker({
    lazyNavigate: true, config: { navigateTimeoutMs: 2000 }, fetch: quiet,
    onNavigate(tab, events, url) { tab.url = url; events.updated.emit(tab.id, { url }, tab); }
  });
  started = Date.now();
  result = await worker.context.HolmesAutomation.execute({ action: 'navigate', params: { url: 'https://mail.example.test/#inbox', tabId: 17 } });
  elapsed = Date.now() - started;
  check(result.ok === true && result.loaded === true && elapsed < 500, `A same document navigation still resolves promptly (${elapsed}ms)`);
  worker.dispose();
}

module.exports = { loadWorker, check, sleep, until, receivingEndMissing };

if (require.main === module) {
  (async () => {
    // Worker timers are unref'd; keep node alive until every suite has finished so
    // a test awaiting only those timers can never exit early and look like a pass.
    setInterval(() => {}, 1000);
    const only = process.argv[2];
    const suites = { reinjectionTests, probeTests, transportTests, resultDeliveryTests, idempotencyTests,
      concurrencyTests, visibilityTests, navigateTests, longPollSpinTests, ledgerRaceTests, ledgerQuotaTests, laneOrderTests, composeTimeoutTests, navigateEarlyTests };
    for (const [name, suite] of Object.entries(suites)) {
      if (only && name !== only) continue;
      await suite();
    }
    console.log(`Browser bridge worker: ${checks} checks passed (mock chrome, scripted bridge).`);
    // Simulated workers keep polling forever; exit explicitly on pass and on failure.
    process.exit(0);
  })().catch(error => { console.error(error); process.exit(1); });
}
