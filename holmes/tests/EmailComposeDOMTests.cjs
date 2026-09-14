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
function fixture(html, { tabId = 17, windowId = 23, instanceId = 'test-profile', url = 'https://mail.google.com/mail/u/0/#inbox', helloFailures = 0 } = {}) {
  let hellos = 0;
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
        if (message.type === 'holmes:hello') {
          hellos++;
          // A worker that is still starting answers nothing.
          if (hellos <= helloFailures) callback(undefined);
          else callback({ token: 'synthetic-token', tabId, windowId, instanceId, isActiveTab: true });
        }
        else if (callback) callback({ ok: true });
      }
    },
    storage: { local: { get(keys, callback) { callback({}); } }, onChanged: { addListener() {} } }
  };
  // No network, including accidental transport calls while testing content.js.
  w.fetch = async () => ({ ok: true, status: 200 });
  w.eval(fs.readFileSync(path.join(extension, 'email-compose.js'), 'utf8'));
  if (!helloFailures) w.HolmesEmailCompose.setEnvironment({ tabId, windowId, instanceId, app: 'Google Chrome' });
  return { dom, w, read: () => w.HolmesEmailCompose.read(), hellos: () => hellos,
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

// Signature and quoted thread are never edited; automatic writes go above them.
const gmailSignature = '<div dir="ltr"><br clear="all"><div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">Alex Rivera<br>Acme Corp</div></div>';
f = fixture('<style>[contenteditable]{white-space:normal}</style>' + compose('one', gmailSignature));
snapshot = f.read();
check(!snapshot.bodyIsEmpty && snapshot.autoWritable && snapshot.hasSignature && snapshot.userText === '', 'A body holding only a signature is writable automatically');
const signatureHTML = f.w.document.querySelector('.gmail_signature').outerHTML;
result = f.w.HolmesEmailCompose.stage('Hi,\n\nI am running late.', snapshot, { mode: 'auto' });
check(result.ok && typeof result.undoToken === 'string', 'Automatic write succeeds above the signature and returns an undo token');
check(f.w.document.querySelector('.gmail_signature').outerHTML === signatureHTML && f.read().userText.trim() === 'Hi,\n\nI am running late.', 'Signature is byte for byte intact and the new text sits above it');
check(/I am running late\.\n+--\nAlex Rivera\nAcme Corp$/.test(f.w.HolmesEmailCompose.renderedText(f.body())), 'Signature still renders after the written email');
const signedToken = result.undoToken;
result = f.w.HolmesEmailCompose.undo(signedToken);
check(result.ok && result.undone && f.body().innerHTML === gmailSignature, 'Undo restores exactly what was there');
check(!f.w.HolmesEmailCompose.undo(signedToken).ok, 'Undo is single use');
snapshot = f.read();
f.w.HolmesEmailCompose.noteUserInput();
result = f.w.HolmesEmailCompose.stage('Hi,\n\nText.', snapshot, { mode: 'auto' });
check(!result.ok && result.typing && f.body().innerHTML === gmailSignature, 'No automatic write while the person is typing');
f.w.HolmesEmailCompose.noteUserInput(0);
f.w.document.querySelector('[name="subjectbox"]').dispatchEvent(new f.w.KeyboardEvent('keydown', { key: 'a', bubbles: true }));
check(f.w.HolmesEmailCompose.check(snapshot, { mode: 'auto' }).typing === true, 'A keydown anywhere in the page counts as typing');
f.w.HolmesEmailCompose.noteUserInput(0);
check(f.w.HolmesEmailCompose.check(snapshot, { mode: 'auto' }).ok && f.body().innerHTML === gmailSignature, 'Check validates without writing');
f.body().innerHTML = '<div>Running late, sorry</div>' + gmailSignature;
snapshot = f.read();
check(!snapshot.autoWritable && snapshot.userText.trim() === 'Running late, sorry', 'Typed text is the person\'s own, not a signature');
check(f.w.HolmesEmailCompose.stage('Hi,\n\nSomething else.', snapshot, { mode: 'auto' }).hasOwnText && f.read().userText.trim() === 'Running late, sorry', 'Automatic mode never overwrites typed text');
// Regression: Replace body used to erase the signature along with the notes.
result = f.w.HolmesEmailCompose.stage('Hi,\n\nI am running late, sorry.', f.read(), { mode: 'replace' });
check(result.ok && f.w.document.querySelector('.gmail_signature').outerHTML === signatureHTML && f.read().userText.trim() === 'Hi,\n\nI am running late, sorry.', 'Replace body replaces only the person\'s text and keeps the signature');
result = f.w.HolmesEmailCompose.stage('Back by noon.', f.read(), { mode: 'insert' });
check(result.ok && /I am running late, sorry\.\n+Back by noon\.$/.test(f.read().userText.trim()) && f.w.document.querySelector('.gmail_signature').outerHTML === signatureHTML, 'Insert adds below the person\'s text and above the signature');
f.close();

f = fixture(compose('one', '', 'dana@example.test'));
f.w.document.querySelector('[name="subjectbox"]').value = '';
snapshot = f.read();
result = f.w.HolmesEmailCompose.stage('Hi,\n\nAre we still on for Friday?', snapshot, { mode: 'auto', subject: 'Friday plans' });
check(result.ok && result.subjectFilled && f.read().subject === 'Friday plans', 'An empty subject is filled with the predicted subject');
check(f.w.HolmesEmailCompose.undo(result.undoToken).ok && f.read().subject === '' && f.read().bodyIsEmpty, 'Undo also clears the subject Holmes filled');
f.w.document.querySelector('[name="subjectbox"]').value = 'My subject';
snapshot = f.read();
result = f.w.HolmesEmailCompose.stage('Hi,\n\nText here.', snapshot, { mode: 'auto', subject: 'Other' });
check(result.ok && !result.subjectFilled && f.read().subject === 'My subject', 'A subject the person wrote is never changed');
f.body().appendChild(f.w.document.createTextNode(' edited'));
result = f.w.HolmesEmailCompose.undo(result.undoToken);
check(!result.ok && result.edited && f.w.HolmesEmailCompose.renderedText(f.body()).includes('edited'), 'Undo refuses once the person edited what Holmes wrote');
f.close();

// Thread context: newest message first, nested quotes removed, names kept.
f = fixture(`<div class="nH"><h2 class="hP">Budget review</h2>
  <div class="adn ads"><span class="gD" email="sam@example.test" name="Sam Ortiz">Sam Ortiz</span><span class="g3" title="Sep 10, 2026, 9:00 AM">Sep 10</span><div class="a3s aiL">Kicking off the budget review.</div></div>
  <div class="adn ads"><span class="gD" email="dana@example.test" name="Dana Lee">Dana Lee</span><span class="g3" title="Sep 12, 2026, 4:12 PM">Sep 12</span><div class="a3s aiL">Can you send the Q3 numbers by Friday?<div class="gmail_quote">On Sep 10 Sam wrote: Kicking off</div></div></div>
  <div class="M9"><input type="hidden" name="to" value="Dana Lee <dana@example.test>"><input type="hidden" name="subjectbox" value="Re: Budget review">
    <div contenteditable="true" aria-label="Message Body" g_editable="true"><div><br></div><div class="gmail_quote">On Sat, Sep 12, 2026 at 4:12 PM Dana Lee &lt;dana@example.test&gt; wrote:<blockquote class="gmail_quote">Can you send the Q3 numbers by Friday?</blockquote></div></div></div></div>`);
snapshot = f.read();
check(snapshot.isReply && snapshot.hasQuote && snapshot.autoWritable && snapshot.threadSubject === 'Budget review', 'Inline reply holding only quoted text is a writable reply');
check(snapshot.thread.length === 2 && snapshot.thread[0].fromEmail === 'dana@example.test' && snapshot.thread[0].text === 'Can you send the Q3 numbers by Friday?'
  && snapshot.thread[0].date === 'Sep 12, 2026, 4:12 PM' && snapshot.thread[1].from === 'Sam Ortiz', 'Conversation is read newest first without nested quotes');
check(snapshot.recipientNames['dana@example.test'] === 'Dana Lee', 'Recipient display names come from the header');
const quoteHTML = f.body().querySelector('.gmail_quote').outerHTML;
result = f.w.HolmesEmailCompose.stage('Hi Dana,\n\nI will send them Friday.', snapshot, { mode: 'auto' });
check(result.ok && f.body().querySelector('.gmail_quote').outerHTML === quoteHTML && f.body().firstElementChild.textContent === 'Hi Dana,', 'Reply text goes above the untouched quote');
f.close();

f = fixture(compose('one', '<div><br></div><div class="gmail_quote">On Fri, Sep 11, 2026 at 9:00 AM Dana Lee &lt;dana@example.test&gt; wrote:<br><blockquote class="gmail_quote">Lunch next week?</blockquote></div>'));
f.w.document.querySelector('[name="subjectbox"]').value = 'Re: Lunch';
snapshot = f.read();
check(snapshot.isReply && snapshot.thread.length === 1 && snapshot.thread[0].from === 'Dana Lee' && snapshot.thread[0].fromEmail === 'dana@example.test'
  && snapshot.thread[0].text === 'Lunch next week?', 'A popped out reply without a visible conversation still yields the message it answers');
f.close();

f = fixture(`<div data-app-section="ConversationContainer"><div role="listitem"><span title="Dana Lee &lt;dana@contoso.com&gt;">Dana Lee</span><time datetime="2026-09-12T16:12">Sat 4:12 PM</time><div id="UniqueMessageBody_1">Are we still on for Friday at 3pm?</div></div>
  <div class="compose-inline"><div role="textbox" contenteditable="true" aria-label="To"><span title="Dana Lee &lt;dana@contoso.com&gt;">Dana Lee</span></div><input aria-label="Add a subject" value="RE: Friday">
  <div role="textbox" contenteditable="true" aria-label="Message body"><div><br></div><div id="Signature"><div>Alex Rivera</div></div><div id="appendonsend"></div><hr><div id="divRplyFwdMsg"><b>From:</b> Dana Lee</div><div>Are we still on for Friday at 3pm?</div></div></div></div>`, { url: 'https://outlook.office.com/mail/' });
snapshot = f.read();
check(snapshot.isReply && snapshot.hasSignature && snapshot.hasQuote && snapshot.autoWritable && snapshot.thread.length === 1
  && snapshot.thread[0].fromEmail === 'dana@contoso.com' && snapshot.thread[0].text === 'Are we still on for Friday at 3pm?', 'Outlook reply reads the conversation and treats signature and quote as protected');
const outlookTail = f.w.document.querySelector('#Signature').outerHTML + f.w.document.querySelector('#divRplyFwdMsg').outerHTML;
result = f.w.HolmesEmailCompose.stage('Hi Dana,\n\nYes, Friday at 3pm works.', snapshot, { mode: 'auto' });
check(result.ok && f.w.document.querySelector('#Signature').outerHTML + f.w.document.querySelector('#divRplyFwdMsg').outerHTML === outlookTail
  && f.read().userText.trim() === 'Hi Dana,\n\nYes, Friday at 3pm works.', 'Outlook write lands above its signature and reply header');
f.close();

f = fixture(`<div class="composer"><input data-testid="composer:to" value="sam@proton.me"><input data-testid="composer:subject" value="">
  <div data-testid="composer:body" contenteditable="true"><div><br></div><div class="protonmail_signature_block"><div>Sent with Proton Mail secure email.</div></div></div></div>`, { url: 'https://mail.proton.me/u/0/inbox' });
snapshot = f.read();
check(snapshot.autoWritable && snapshot.hasSignature && snapshot.subjectEditable && snapshot.subject === '', 'Proton composer holding only its signature is writable');
result = f.w.HolmesEmailCompose.stage('Hi Sam,\n\nThanks for the files.', snapshot, { mode: 'auto', subject: 'Thanks for the files' });
check(result.ok && f.w.document.querySelector('.protonmail_signature_block').textContent === 'Sent with Proton Mail secure email.'
  && f.read().subject === 'Thanks for the files', 'Proton write keeps its signature and fills the empty subject');
f.close();

// Production handlers: precheck, write mode, undo.
f = fixture(compose());
f.loadContent();
snapshot = f.read();
let response = f.message({ type: 'holmes:checkEmailDraft', expected: snapshot, body: 'Hi', options: { mode: 'auto' } });
check(response.ok && f.body().textContent === '', 'Production precheck validates without writing');
response = f.message({ type: 'holmes:fillEmailDraft', body: 'Hi,\n\nOn my way.', expected: snapshot, options: { mode: 'auto' } });
check(response.ok && typeof response.undoToken === 'string', 'Production fill passes the write mode and returns an undo token');
response = f.message({ type: 'holmes:undoEmailDraft', token: response.undoToken });
check(response.ok && response.undone && f.body().textContent === '', 'Production undo restores the body');
f.close();

// Regression: a hello that raced the starting worker left an empty identity forever.
f = fixture(compose(), { helloFailures: 1 });
f.loadContent();
check(f.read().identity === '' && f.hellos() === 1, 'A failed hello leaves the composer without identity');
f.message({ type: 'holmes:active', isActiveTab: true });
const realNow = f.w.Date.now;
f.w.Date.now = () => realNow() + 5000;
f.message({ type: 'holmes:readEmailCompose' });
f.w.Date.now = realNow;
check(f.hellos() === 2 && f.read().identity !== '', 'Reading a composer without identity retries the handshake');
f.close();

// Regression: a worker that never answers was asked every 1.5 seconds forever.
f = fixture(compose(), { helloFailures: 1000 });
f.loadContent();
f.message({ type: 'holmes:active', isActiveTab: true });
const systemNow = f.w.Date.now;
let clock = systemNow();
f.w.Date.now = () => clock;
clock += 5000; f.message({ type: 'holmes:readEmailCompose' });
clock += 2000; f.message({ type: 'holmes:readEmailCompose' });
check(f.hellos() === 2, 'Handshake retries back off instead of repeating every 1.5 seconds');
for (let i = 0; i < 30; i++) { clock += 120000; f.message({ type: 'holmes:readEmailCompose' }); }
check(f.hellos() <= 9, 'Handshake retries stop after a bounded number of attempts');
f.w.Date.now = systemNow;
f.close();
console.log(`Email compose DOM: ${assertions} checks passed (synthetic fixtures; no network or mail account).`);
