// Content script lifecycle against jsdom: double injection, orphaning after an
// extension reload, takeover by a fresh injection, ping and worker keepalive.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const extension = path.resolve(__dirname, '../holmes-extension');
const source = fs.readFileSync(path.join(extension, 'content.js'), 'utf8');
let checks = 0;
function check(condition, description) { checks++; assert.ok(condition, description); console.log('PASS ' + description); }
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function runtimeMock(id, log) {
  const listeners = [];
  return {
    listeners,
    runtime: {
      id, lastError: undefined,
      getManifest: () => ({ version: '2.3' }),
      onMessage: { addListener(fn) { listeners.push(fn); } },
      sendMessage(message, callback) {
        if (!this.id) throw new Error('Extension context invalidated.');
        log.push(message);
        if (message.type === 'holmes:hello') callback && callback({ token: 't', tabId: 5, windowId: 6, instanceId: 'inst', isActiveTab: true });
        else if (callback) callback({ ok: true });
      }
    }
  };
}

function page(options = {}) {
  const dom = new JSDOM('<title>Example</title><main><p>Hello world, this is a page.</p></main>',
    { url: 'https://example.test/article', pretendToBeVisual: true, runScripts: 'outside-only' });
  const w = dom.window;
  const live = new Set();
  const originalSet = w.setInterval.bind(w), originalClear = w.clearInterval.bind(w);
  w.setInterval = (fn, ms) => { const id = originalSet(fn, ms); live.add(id); return id; };
  w.clearInterval = id => { live.delete(id); originalClear(id); };
  const log = [];
  const first = runtimeMock('extension-v1', log);
  w.chrome = { runtime: first.runtime, storage: { local: { get(keys, cb) { cb({}); } }, onChanged: { addListener() {} } } };
  w.fetch = async () => ({ ok: true, status: 200 });
  if (options.config) w.__holmesContentConfig = options.config;
  return {
    dom, w, log, live, first,
    load() { w.eval(source); },
    message(listeners, msg) {
      let response;
      for (const listener of listeners) listener(msg, {}, value => { if (response === undefined) response = value; });
      return response;
    },
    close() { dom.window.close(); }
  };
}

(async () => {
  // Double injection is a no-op while the first copy is alive.
  let p = page();
  p.load();
  const listenerCount = p.first.listeners.length;
  const intervalCount = p.live.size;
  p.load();
  check(listenerCount > 0 && p.first.listeners.length === listenerCount && p.live.size === intervalCount,
    'Injecting content.js twice into a live page registers listeners and timers once');
  const ping = p.message(p.first.listeners, { type: 'holmes:ping' });
  check(ping && ping.ok === true && typeof ping.visible === 'boolean' && typeof ping.isActiveTab === 'boolean',
    'The content script answers holmes:ping with its visibility and active state');

  // The extension reloads: the old runtime is invalidated. The next activity must
  // stop the orphan quietly instead of throwing or pretending to send.
  p.first.runtime.id = undefined;
  p.w.document.dispatchEvent(new p.w.Event('focusin'));
  await sleep(450);
  check(p.live.size === 0, 'An orphaned content script clears its intervals');
  const sentBefore = p.log.length;
  p.w.document.dispatchEvent(new p.w.Event('focusin'));
  await sleep(300);
  check(p.log.length === sentBefore, 'An orphaned content script sends nothing further');
  check(p.w.__holmesContentScript && p.w.__holmesContentScript.alive() === false, 'The guard reports the orphan as dead');

  // A reinjected copy from the reloaded extension takes over the same page.
  const second = runtimeMock('extension-v2', p.log);
  p.w.chrome = { runtime: second.runtime, storage: p.w.chrome.storage };
  p.load();
  check(second.listeners.length > 0 && p.live.size > 0, 'A reinjected content script takes over from the orphan');
  check(p.log.some(m => m.type === 'holmes:hello'), 'The new copy says hello to the reloaded worker');
  check(p.w.__holmesContentScript.alive() === true, 'The guard now belongs to the live copy');
  p.close();

  // Keepalive pings keep an MV3 worker awake while this tab is visible and active.
  p = page({ config: { keepaliveMs: 40 } });
  p.load();
  await sleep(220);
  const keepalives = p.log.filter(m => m.type === 'holmes:keepalive').length;
  check(keepalives >= 2, `A visible active tab pings the worker to keep it awake (${keepalives} pings)`);
  Object.defineProperty(p.w.document, 'visibilityState', { value: 'hidden', configurable: true });
  const hiddenStart = p.log.filter(m => m.type === 'holmes:keepalive').length;
  await sleep(200);
  check(p.log.filter(m => m.type === 'holmes:keepalive').length === hiddenStart, 'A hidden tab does not keep the worker awake');
  p.close();

  console.log(`Browser bridge content script: ${checks} checks passed (jsdom, mock runtime).`);
  // jsdom windows keep their own timers; exit explicitly so a pass never hangs.
  process.exit(0);
})().catch(error => { console.error(error); process.exit(1); });
