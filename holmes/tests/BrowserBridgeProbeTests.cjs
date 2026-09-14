// Active tab probe classification: a page that blocks script injection (Chrome
// Web Store, the PDF viewer, other protected pages) is restricted, not a missing
// content script that the app would tell the user to refresh.
const { loadWorker, check, until, receivingEndMissing } = require('./BrowserBridgeBackgroundTests.cjs');

function probeWorker(tab, executeScript) {
  const heartbeats = [];
  let injections = 0;
  const worker = loadWorker({
    config: { heartbeatProbeMs: 0 },
    tabs: [tab],
    fetch(url, init) {
      if (url.endsWith('/heartbeat')) heartbeats.push(JSON.parse(init.body || '{}'));
      return { status: url.endsWith('/commands') ? 503 : 200, body: {} };
    },
    executeScript(details) { injections++; return executeScript(details); },
    sendMessage(tabId, message) {
      if (message.type === 'holmes:ping') throw receivingEndMissing();
      return { ok: true };
    }
  });
  return { worker, heartbeats, injections: () => injections };
}

(async () => {
  setInterval(() => {}, 1000);
  let passed = 0;

  const store = probeWorker({ id: 5, windowId: 23, url: 'https://chromewebstore.google.com/detail/x', active: true },
    () => { throw new Error('The extensions gallery cannot be scripted.'); });
  await until('first store probe', () => store.heartbeats.some(h => h.activeTab));
  await store.worker.context.sendHeartbeat();
  const storeScripts = store.heartbeats.filter(h => h.activeTab).map(h => h.activeTab.script);
  check(storeScripts.length >= 2 && storeScripts.every(s => s === 'restricted'),
    `A page that blocks injection is reported restricted, not missing (${storeScripts.join(', ')})`);
  passed++;
  store.worker.dispose();

  const normal = probeWorker({ id: 6, windowId: 23, url: 'https://normal.test/', active: true }, () => [{}]);
  await until('first normal probe', () => normal.heartbeats.some(h => h.activeTab));
  await normal.worker.context.sendHeartbeat();
  const normalScripts = normal.heartbeats.filter(h => h.activeTab).map(h => h.activeTab.script);
  check(normal.injections() > 0 && normalScripts.at(-1) === 'missing',
    `A normal page that still does not answer after a successful reinjection is missing (${normalScripts.join(', ')})`);
  passed++;
  normal.worker.dispose();

  console.log(`Browser bridge probe: ${passed} checks passed (mock chrome).`);
  process.exit(0);
})().catch(error => { console.error(error); process.exit(1); });
