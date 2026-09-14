// Runs production isolated-world scripts against synthetic Gmail DOM only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const extension = path.resolve(__dirname, '../holmes-extension');
let assertions = 0;
function check(condition, message) { assertions++; assert.ok(condition, message); }
function compose(id = 'one', body = '', recipient = 'boss@example.test') {
  return `<div role="dialog" id="${id}"><table><tr><td>To:</td><td><span email="${recipient}">Boss</span><input name="to"></td></tr>
    <tr><td>Cc:</td><td><input name="cc"></td></tr><tr><td>Bcc:</td><td><input name="bcc"></td></tr></table>
    <input name="subjectbox" value="I'm gonna be late"><div contenteditable="true" aria-label="Message Body">${body}</div>
    <button type="submit" id="send-${id}">Send</button></div>`;
}
function fixture(html, { tabId = 17, windowId = 23, instanceId = 'test-profile', url = 'https://mail.google.com/mail/u/0/#inbox' } = {}) {
  const dom = new JSDOM(`<title>Inbox — this is not a subject</title>${html}`, { url, pretendToBeVisual: true, runScripts: 'outside-only' });
  const w = dom.window;
  Object.defineProperties(w.HTMLElement.prototype, {
    offsetWidth: { get() { return 100; } }, offsetHeight: { get() { return 30; } },
    isContentEditable: { get() { return !!this.closest('[contenteditable="true"]'); } }
  });
  const listeners = [], messages = [];
  w.chrome = {
    runtime: {
      id: 'synthetic-extension', lastError: null,
      getManifest() { return { version: '2.2' }; },
      onMessage: { addListener(listener) { listeners.push(listener); } },
      sendMessage(message, callback) {
        messages.push(message);
        if (message.type === 'holmes:hello') callback({ token: 'synthetic-token', tabId, windowId, instanceId, isActiveTab: true });
        else if (callback) callback({ ok: true });
      }
    },
    storage: { local: { get(keys, callback) { callback({}); } }, onChanged: { addListener() {} } }
  };
  // No network, including accidental transport calls while testing content.js.
  w.fetch = async () => ({ ok: true, status: 200 });
  w.eval(fs.readFileSync(path.join(extension, 'email-compose.js'), 'utf8'));
  w.HolmesEmailCompose.setEnvironment({ tabId, windowId, instanceId, app: 'Google Chrome' });
  return { dom, w, read: () => w.HolmesEmailCompose.read(),
    body: () => w.document.querySelector('[aria-label="Message Body"]'),
    close: () => dom.window.close(),
    loadContent() { w.eval(fs.readFileSync(path.join(extension, 'content.js'), 'utf8')); },
    message(message) {
      let response;
      listeners.forEach(listener => listener(message, {}, value => { response = value; }));
      return response;
    }
  };
}

let f = fixture(compose());
let snapshot = f.read();
check(snapshot.recipients[0] === 'boss@example.test', 'To comes from its own labeled row');
check(snapshot.subject === "I'm gonna be late" && snapshot.bodyIsEmpty && snapshot.bodyReadable, 'Empty body with real headers is recognized');
check(f.read().identity === snapshot.identity, 'Composer identity survives repeated observations');
f.w.document.querySelector('[name="subjectbox"]').focus();
check(f.read().body === '', 'Typing/focus in Subject is not body content');
f.w.document.querySelector('[name="subjectbox"]').value = '';
check(f.read().subject === '', 'Blank subject is literal, never page title');
f.loadContent();
const payload = f.message({ type: 'holmes:readEmailCompose' }).payload;
check(payload.subject === '' && payload.emailCompose.subject === '', 'Production payload preserves explicit empty subject');
check(payload.capturedAt === payload.emailCompose.capturedAt, 'Payload and composer share one capture timestamp');
check(payload.extensionVersion === '2.2' && payload.emailComposeProtocolVersion === 1, 'Reloaded extension publishes version and structured composer capability');
f.w.document.querySelector('[name="subjectbox"]').value = snapshot.subject;
let sends = 0, keys = 0, inputs = 0;
f.w.document.addEventListener('click', () => sends++);
f.w.document.addEventListener('submit', () => sends++);
f.w.document.addEventListener('keydown', () => keys++);
f.body().addEventListener('input', () => inputs++);
snapshot = f.read();
let result = f.message({ type: 'holmes:fillEmailDraft', body: "I'll be a little late today.", expected: snapshot });
check(result.ok && f.body().textContent === "I'll be a little late today.", 'Production message handler writes only expected body');
check(inputs === 1 && sends === 0 && keys === 0, 'Insertion emits input only; no click, submit or keys');
result = f.w.HolmesEmailCompose.stage('Duplicate', snapshot);
check(!result.ok && f.body().textContent !== 'Duplicate', 'Old empty snapshot cannot overwrite inserted text');
snapshot = f.read();
result = f.w.HolmesEmailCompose.stage('Reviewed rewrite', snapshot);
check(result.ok && f.body().textContent === 'Reviewed rewrite', 'Explicit reviewed rewrite accepts an exactly unchanged nonempty body');
snapshot = f.read();
const longDraft = 'A'.repeat(8000);
result = f.w.HolmesEmailCompose.stage(longDraft, snapshot);
check(result.ok && f.body().textContent === longDraft, 'A long approved draft is verified against complete DOM text, not the clipped observation');
check(!f.read().bodyReadable, 'Long body is conservatively unavailable for another automatic rewrite');
f.body().textContent = 'Reviewed rewrite';
snapshot = f.read();
f.body().appendChild(f.w.document.createTextNode(' user edit'));
check(!f.w.HolmesEmailCompose.stage('Do not overwrite', snapshot).ok, 'User typing after review is preserved');
snapshot = f.read();
f.w.document.querySelector('[name="subjectbox"]').value = 'Different intent';
check(!f.w.HolmesEmailCompose.stage('Wrong subject', snapshot).ok, 'Changed subject invalidates insertion');
snapshot = f.read();
f.w.document.querySelector('[email]').setAttribute('email', 'other@example.test');
check(!f.w.HolmesEmailCompose.stage('Wrong person', snapshot).ok, 'Changed recipient invalidates insertion');
f.close();

// Regression: Gmail's editor uses normal white space, so one text node with
// "\n" collapsed into a single line and the readback then failed after writing.
f = fixture('<style>[contenteditable]{white-space:normal}</style>' + compose());
const raw = f.w.document.createElement('div');
raw.textContent = 'Hi,\n\nSecond paragraph';
f.w.document.body.appendChild(raw);
check(f.w.HolmesEmailCompose.renderedText(raw) === 'Hi, Second paragraph', 'Normal white space renders a raw newline as a space, like Gmail');
raw.remove();
const multiline = "Hi Dana,\n\nThanks for the update.\nI'll review it today.";
snapshot = f.read();
result = f.w.HolmesEmailCompose.stage(multiline, snapshot);
check(result.ok, 'Multiline draft verifies in a normal white space editor');
check(f.body().children.length === 4 && f.body().children[1].innerHTML === '<br>', 'Each line is its own block and the blank line keeps a <br>');
check(f.w.HolmesEmailCompose.renderedText(f.body()) === multiline, 'Rendered body keeps every line break and the blank line');
f.body().innerHTML = '';
snapshot = f.read();
const rejectOnce = () => { f.body().removeEventListener('input', rejectOnce); f.body().replaceChildren(f.w.document.createTextNode('collapsed')); };
f.body().addEventListener('input', rejectOnce);
result = f.w.HolmesEmailCompose.stage(multiline, snapshot);
check(!result.ok && /restored/.test(result.reason) && f.body().innerHTML === '', 'Unconfirmed write is rolled back to the saved body');
f.close();

f = fixture(compose('one', '<div><br></div>'));
check(f.read().bodyIsEmpty, 'Structural blank line is empty');
f.body().innerHTML = '&nbsp;\u200b';
check(f.read().bodyIsEmpty, 'Whitespace-only placeholder text is empty');
f.body().innerHTML = '<img src="cid:synthetic-image">';
snapshot = f.read();
check(!snapshot.bodyIsEmpty, 'Inline image is not an empty body');
f.body().querySelector('img').setAttribute('src', 'cid:changed-image');
check(!f.w.HolmesEmailCompose.stage('Changed rich content', snapshot).ok, 'Rich content changes invalidate same-text snapshot');
f.body().innerHTML = '<table><tr><td></td></tr></table>';
check(!f.read().bodyIsEmpty, 'Empty-looking table is user content');
f.body().remove();
check(!f.read().bodyReadable && !f.read().bodyIsEmpty, 'Missing body control is not empty');
f.close();

f = fixture(compose('first') + compose('second', '', 'other@example.test'));
check(f.read() === null, 'Two unfocused composers are ambiguous');
f.w.document.querySelector('#first [name="subjectbox"]').focus();
snapshot = f.read();
check(snapshot.recipients[0] === 'boss@example.test', 'Focused composer outranks last DOM composer');
f.w.document.querySelector('#second [name="subjectbox"]').focus();
check(f.read().identity !== snapshot.identity, 'Switching composer changes identity');
check(!f.w.HolmesEmailCompose.stage('Wrong compose box', snapshot).ok, 'Original draft cannot fill another composer');
f.w.document.querySelector('#first').remove();
check(!f.w.HolmesEmailCompose.stage('Closed composer', snapshot).ok, 'Closed composer is invalid');
f.close();

f = fixture(compose()); snapshot = f.read();
const otherWindow = fixture(compose(), { windowId: 99 });
check(otherWindow.read().identity !== snapshot.identity, 'Same recipient/subject in another window has a different identity');
check(!otherWindow.w.HolmesEmailCompose.stage('Other window', snapshot).ok, 'Cross-window insertion is refused');
otherWindow.close();
const reloaded = fixture(compose());
check(reloaded.read().identity !== snapshot.identity, 'Document reload invalidates old composer identity');
check(!reloaded.w.HolmesEmailCompose.stage('Reloaded document', snapshot).ok, 'Reloaded document cannot receive stale draft');
reloaded.close();
f.w.HolmesEmailCompose.setEnvironment({ windowId: 999 });
check(!f.w.HolmesEmailCompose.stage('Moved tab', snapshot).ok, 'Moving a tab between windows invalidates expected identity');
f.close();

f = fixture(compose());
f.w.document.querySelector('[name="to"]').value = 'unfinished';
check(f.read().recipients.some(x => !x.includes('@')), 'Uncommitted recipient is retained as invalid readiness');
f.w.document.querySelector('[name="to"]').value = 'valid@example.test, unfinished';
check(f.read().recipients.some(x => !x.includes('@')), 'Partially entered second recipient blocks readiness');
f.w.document.querySelector('[name="to"]').value = '';
f.w.document.querySelector('[name="cc"]').value = 'cc@example.test';
check(f.read().cc[0] === 'cc@example.test' && f.read().recipients.length === 1, 'Cc is not folded into To');
Object.defineProperty(f.w.document, 'visibilityState', { value: 'hidden', configurable: true });
check(f.read() === null, 'Hidden page is not a composer observation');
f.close();
f = fixture('<div role="dialog"><input aria-label="To" value="boss@example.test"><input aria-label="Add a subject" value="Running late"><div aria-label="Message body" contenteditable="true"></div></div>', { url: 'https://outlook.live.com/mail/0/' });
check(f.read().provider === 'Outlook' && f.read().bodyIsEmpty && f.read().subject === 'Running late', 'Outlook explicit empty composer is recognized');
f.close();
f = fixture('<div class="composer"><input data-testid="composer:to" value="boss@example.test"><input data-testid="composer:subject" value="Running late"><div data-testid="composer:body" contenteditable="true"></div></div>', { url: 'https://mail.proton.me/u/0/inbox' });
check(f.read().provider === 'Proton Mail' && f.read().bodyIsEmpty && f.read().subject === 'Running late', 'Proton explicit empty composer is recognized');
f.close();

// Regression: Gmail inline replies have no dialog, div.nH.Hd or div.AD wrapper.
const gmailInline = `<div class="nH"><h2 class="hP">Budget review</h2>
  <div class="adn ads"><span class="gD" email="dana@example.test" name="Dana Lee">Dana Lee</span><div class="a3s aiL">Can you send the Q3 numbers?</div></div>
  <div class="M9"><div class="aoD hl"><span email="dana@example.test" name="Dana Lee">Dana Lee</span></div>
    <input type="hidden" name="to" value="Dana Lee <dana@example.test>"><input type="hidden" name="subjectbox" value="Re: Budget review">
    <div contenteditable="true" aria-label="Message Body" g_editable="true"></div></div></div>`;
f = fixture(gmailInline);
snapshot = f.read();
check(snapshot && snapshot.recipients.length === 1 && snapshot.recipients[0] === 'dana@example.test', 'Gmail inline reply reads its hidden committed recipient');
check(snapshot.subject === 'Re: Budget review' && snapshot.subjectEditable === false && snapshot.bodyIsEmpty, 'Inline reply subject is literal but not editable');
result = f.w.HolmesEmailCompose.stage('Hi Dana,\n\nI will send them today.', snapshot);
check(result.ok && f.w.document.querySelector('.a3s').textContent === 'Can you send the Q3 numbers?', 'Inline reply insertion changes only the reply body, never the thread');
f.close();

// Regression: Outlook labels vary and inline replies live in the reading pane.
f = fixture(`<div data-app-section="ConversationContainer"><div role="document" aria-label="Message body">Are we still on for Friday?</div>
  <div class="compose-inline"><div role="textbox" contenteditable="true" aria-label="To"><span title="Dana Lee &lt;dana@contoso.com&gt;">Dana Lee</span></div>
  <input aria-label="Add a subject" value="RE: Friday">
  <div role="textbox" contenteditable="true" aria-label="Message body, press Alt+F10 to exit"><div><br></div></div></div></div>`, { url: 'https://outlook.office.com/mail/' });
snapshot = f.read();
check(snapshot && snapshot.provider === 'Outlook' && snapshot.recipients[0] === 'dana@contoso.com' && snapshot.bodyIsEmpty, 'Outlook body label with extra words and an inline reply are recognized');
result = f.w.HolmesEmailCompose.stage('Hi Dana,\n\nYes, Friday still works.', snapshot);
check(result.ok && f.w.document.querySelector('[aria-label="To"]').textContent === 'Dana Lee'
  && f.w.document.querySelector('[role="document"]').textContent === 'Are we still on for Friday?', 'Outlook write leaves the To textbox and the read message untouched');
f.close();
f = fixture(`<div data-testid="compose-form"><input aria-label="To" value="sam@contoso.com"><input aria-label="Subject" value="Plans">
  <div role="textbox" contenteditable="true"></div></div>`, { url: 'https://outlook.live.com/mail/0/' });
check(f.read() && f.read().bodyIsEmpty && f.read().subject === 'Plans', 'Outlook body exposed only as a textbox in the compose pane is recognized');
f.close();
console.log(`Email compose DOM: ${assertions} checks passed (synthetic fixtures; no network or mail account).`);
