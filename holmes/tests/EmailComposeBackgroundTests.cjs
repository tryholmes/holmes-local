const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
let checks = 0;
function check(condition, description) { checks++; assert.ok(condition, description); }
const event = { addListener() {} };
const messageListeners = [];
let active = 17, changeDuringRead = false, genericExecutions = 0;
const tabs = new Map([[17, { id: 17, windowId: 23 }], [28, { id: 28, windowId: 29 }]]);
const messages = [], requests = [], activations = [];
const context = vm.createContext({
  console, crypto: { randomUUID: () => 'test-profile' }, setInterval: () => 1,
  setTimeout: (fn, ms) => { const timer = setTimeout(fn, ms); timer.unref(); return timer; }, clearTimeout, AbortController,
  importScripts() {},
  HolmesAutomation: { async execute() { genericExecutions++; return { ok: true }; } },
  fetch: async (url, options) => { requests.push({ url, options }); return { ok: true, json: async () => [] }; },
  chrome: {
    runtime: { onInstalled: event, onStartup: event, onMessage: { addListener(listener) { messageListeners.push(listener); } } },
    storage: { local: { async get() { return { holmesToken: 'synthetic-token', holmesBrowserInstance: 'test-profile' }; }, async set() {} } },
    tabs: {
      onActivated: event, onUpdated: event, onRemoved: event,
      async query() { return tabs.has(active) ? [tabs.get(active)] : []; },
      async get(id) { if (!tabs.has(id)) throw new Error('tab closed'); return tabs.get(id); },
      async update(id, updates) { activations.push({ tab: id, updates }); active = id; return tabs.get(id); },
      async sendMessage(tabId, message) {
        messages.push({ tabId, message });
        if (message.type === 'holmes:active') return {};
        if (message.type === 'holmes:ping') return { ok: true, visible: true, isActiveTab: true };
        if (changeDuringRead && message.type === 'holmes:readEmailCompose') active = 28;
        return message.type === 'holmes:readEmailCompose' ? { ok: true, payload: { capturedAt: Date.now() } }
          : { ok: true, inserted: true, identity: message.expected.identity };
      }
    },
    windows: { onFocusChanged: event, async get() { return { type: 'normal' }; }, async update(id, updates) { activations.push({ window: id, updates }); } }
  }
});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../holmes-extension/background.js'), 'utf8'), context);

(async () => {
  await new Promise(resolve => setImmediate(resolve));
  check(requests.some(r => r.url.endsWith('/commands') && r.options.headers['X-Holmes-Browser-Instance'] === 'test-profile'), 'Command poll declares browser instance for queue isolation');
  let result = await context.emailComposeCommand({ action: 'read_email_compose' });
  check(result.ok && activations.length === 0, 'Refresh reads the active tab without navigation or activation');
  check(messages.at(-1).message.environment.windowId === 23 && messages.at(-1).message.environment.tabId === 17, 'Fresh read carries exact tab/window identity');
  changeDuringRead = true;
  result = await context.emailComposeCommand({ action: 'read_email_compose' });
  check(!result.ok, 'Tab switch during refresh invalidates its response');
  changeDuringRead = false;
  const expected = { identity: JSON.stringify(['test-profile', 23, 17, 'document', 'account', 1]), recipients: ['boss@example.test'], cc: [], bcc: [], subject: 'Running late', body: '', bodyReadable: true, bodyIsEmpty: true };
  result = await context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'Reviewed draft', expected } });
  check(result.ok && active === 17, 'Explicit Insert returns to original known tab');
  check(messages.at(-1).tabId === 17 && messages.at(-1).message.expected === expected && messages.at(-1).message.body === 'Reviewed draft', 'Exact expected fields reach original content script');
  check(activations.length === 2 && genericExecutions === 0, 'Draft insertion uses only targeted tab/window activation, never generic computer automation');
  const previous = messages.length;
  result = await context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'Wrong browser', expected: { ...expected, identity: JSON.stringify(['other-profile', 23, 17]) } } });
  check(!result.ok && messages.length === previous, 'Another browser profile cannot execute the draft');
  tabs.set(17, { id: 17, windowId: 99 });
  result = await context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'Moved tab', expected } });
  check(!result.ok && messages.length === previous, 'Moving composer to another window invalidates saved destination');
  result = await context.emailComposeCommand({ action: 'fill_email_draft', params: { body: 'No target' } });
  check(!result.ok && messages.length === previous, 'Missing composer identity never falls back to active field');
  active = 28;
  const beforePosts = requests.filter(r => r.url.endsWith('/context')).length;
  function relay(tab) {
    return new Promise(resolve => messageListeners[0]({ type: 'holmes:post', body: JSON.stringify({ isActiveTab: true, tabId: 17 }) }, { tab }, resolve));
  }
  const inactive = await relay({ id: 17, windowId: 99 });
  check(inactive.dropped === 'inactive tab' && requests.filter(r => r.url.endsWith('/context')).length === beforePosts,
    'Relay independently rejects stale active-tab flags from a previous window');
  const activeReply = await relay({ id: 28, windowId: 29 });
  const posted = JSON.parse(requests.findLast(r => r.url.endsWith('/context')).options.body);
  check(activeReply.ok && posted.tabId === 28 && posted.windowId === 29,
    'Active relay uses authoritative sender tab/window instead of content-script metadata');
  console.log(`Email compose command protocol: ${checks} checks passed (mock browser only).`);
})().catch(error => { console.error(error); process.exitCode = 1; });
