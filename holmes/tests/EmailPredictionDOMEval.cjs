// Second half of the live email prediction evaluation: writes every model
// answer into a provider fixture with the production writer, then prints the
// per check and overall success rates. Usage: node EmailPredictionDOMEval.cjs model-results.json scenarios.json [report.json]
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const [resultsPath, scenariosPath, reportPath] = process.argv.slice(2);
const results = JSON.parse(fs.readFileSync(resultsPath, 'utf8'));
const scenarios = JSON.parse(fs.readFileSync(scenariosPath, 'utf8'));
const writer = fs.readFileSync(path.resolve(__dirname, '../holmes-extension/email-compose.js'), 'utf8');
const esc = s => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const PROTECTED = '.gmail_signature, .gmail_quote, #Signature, #divRplyFwdMsg, .protonmail_signature_block, .protonmail_quote';

function fixtureHTML(s) {
  const c = s.compose, to = c.recipients[0], name = (c.recipientNames || {})[to] || '';
  const message = (s.thread || [])[0];
  const notes = c.notes ? c.notes.split('\n').map(line => `<div>${esc(line)}</div>`).join('') : '';
  if (s.provider === 'Outlook') {
    const signature = c.signature ? `<div id="Signature">${c.signature.split('\n').map(l => `<div>${esc(l)}</div>`).join('')}</div>` : '';
    const quote = message ? `<div id="appendonsend"></div><hr><div id="divRplyFwdMsg"><b>From:</b> ${esc(message.from)}</div><div>${esc(message.text)}</div>` : '';
    return { url: 'https://outlook.office.com/mail/', html: `<div class="compose-inline"><div role="textbox" contenteditable="true" aria-label="To"><span title="${esc(name)} &lt;${esc(to)}&gt;">${esc(name || to)}</span></div>
      <input aria-label="Add a subject" value="${esc(c.subject)}"><div role="textbox" contenteditable="true" aria-label="Message body, press Alt+F10 to exit">${notes || '<div><br></div>'}${signature}${quote}</div><button id="send">Send</button></div>` };
  }
  if (s.provider === 'Proton Mail') {
    const signature = c.signature ? `<div class="protonmail_signature_block"><div>${esc(c.signature)}</div></div>` : '';
    return { url: 'https://mail.proton.me/u/0/inbox', html: `<div class="composer"><input data-testid="composer:to" value="${esc(to)}"><input data-testid="composer:subject" value="${esc(c.subject)}">
      <div data-testid="composer:body" contenteditable="true">${notes || '<div><br></div>'}${signature}</div><button id="send">Send</button></div>` };
  }
  const signature = c.signature ? `<div dir="ltr"><br clear="all"><div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">${c.signature.split('\n').map(esc).join('<br>')}</div></div>` : '';
  const quote = message ? `<div class="gmail_quote">On ${esc(message.date)} ${esc(message.from)} &lt;${esc(message.fromEmail)}&gt; wrote:<br><blockquote class="gmail_quote">${esc(message.text).replace(/\n/g, '<br>')}</blockquote></div>` : '';
  const body = (notes || ((signature || quote) ? '<div><br></div>' : '')) + signature + quote;
  if (s.layout === 'inline') {
    return { url: 'https://mail.google.com/mail/u/0/#inbox/thread', html: `<div class="nH"><h2 class="hP">${esc(c.subject.replace(/^re:\s*/i, ''))}</h2>
      <div class="M9"><input type="hidden" name="to" value="${esc(name)} <${esc(to)}>"><input type="hidden" name="subjectbox" value="${esc(c.subject)}">
      <div contenteditable="true" aria-label="Message Body" g_editable="true">${body}</div><button id="send">Send</button></div></div>` };
  }
  return { url: 'https://mail.google.com/mail/u/0/#inbox', html: `<div role="dialog"><table><tr><td>To</td><td><span email="${esc(to)}" name="${esc(name)}">${esc(name || to)}</span><input name="to"></td></tr></table>
    <input name="subjectbox" value="${esc(c.subject)}"><div contenteditable="true" aria-label="Message Body">${body}</div><button id="send">Send</button></div>` };
}

function lines(text) {
  return String(text || '').split('\n').map(l => l.replace(/\s+/g, ' ').trim()).filter(Boolean);
}

function domCheck(s, result) {
  const reasons = [];
  if (!result.parsed) return { ok: false, reasons: ['no model answer to insert'] };
  const { url, html } = fixtureHTML(s);
  const dom = new JSDOM(`<style>[contenteditable]{white-space:normal}</style>${html}`, { url, pretendToBeVisual: true, runScripts: 'outside-only' });
  const w = dom.window;
  Object.defineProperties(w.HTMLElement.prototype, {
    offsetWidth: { get() { return 100; } }, offsetHeight: { get() { return 30; } },
    isContentEditable: { get() { return !!this.closest('[contenteditable="true"]'); } }
  });
  let sends = 0;
  w.document.addEventListener('click', () => sends++, true);
  w.eval(writer);
  const api = w.HolmesEmailCompose;
  api.setEnvironment({ tabId: 1, windowId: 1, instanceId: 'eval', app: 'Chrome' });
  const body = [...w.document.querySelectorAll('[contenteditable="true"]')].find(el => !/^to$/i.test(el.getAttribute('aria-label') || ''));
  const snapshot = api.read();
  if (!snapshot) { dom.window.close(); return { ok: false, reasons: ['composer not detected'] }; }
  const protectedBefore = [...body.querySelectorAll(PROTECTED)].map(el => el.outerHTML).join('');
  const htmlBefore = body.innerHTML, subjectBefore = snapshot.subject;
  const mode = s.compose.notes ? 'replace' : 'auto';
  const staged = api.stage(result.body, snapshot, { mode, subject: result.subject || undefined });
  if (!staged.ok) reasons.push('write refused: ' + staged.reason);
  const after = api.read();
  if (staged.ok) {
    if (lines(after.userText).join('\n') !== lines(result.body).join('\n')) reasons.push('written lines differ');
    if (/\n\s*\n/.test(result.body) && !/\n\s*\n/.test(after.userText)) reasons.push('paragraph breaks collapsed');
    if ([...body.querySelectorAll(PROTECTED)].map(el => el.outerHTML).join('') !== protectedBefore) reasons.push('signature or quote changed');
    const editable = s.compose.subjectEditable !== false;
    const expectedSubject = result.subject && editable && !subjectBefore ? result.subject : subjectBefore;
    if (after.subject !== expectedSubject) reasons.push('subject not as expected');
    const undone = api.undo(staged.undoToken);
    if (!undone.ok || body.innerHTML !== htmlBefore || api.read().subject !== subjectBefore) reasons.push('undo did not restore');
  }
  if (sends) reasons.push('a click reached the page');
  dom.window.close();
  return { ok: reasons.length === 0, reasons };
}

const checks = ['parse', 'clean', 'grounded', 'subject', 'actions', 'dom'];
const totals = Object.fromEntries(checks.map(c => [c, 0]));
let overall = 0, firstAttempt = 0, seconds = 0;
const report = [];
for (const result of results) {
  const s = scenarios.find(x => x.id === result.id);
  const dom = domCheck(s, result);
  const row = Object.assign({}, result.checks, { dom: dom.ok });
  checks.forEach(c => { if (row[c]) totals[c]++; });
  const passed = checks.every(c => row[c]);
  if (passed) overall++;
  if (result.firstAttemptValid) firstAttempt++;
  seconds += result.seconds || 0;
  if (!dom.ok) console.log(`DOM FAIL ${result.id}: ${dom.reasons.join('; ')}`);
  report.push({ id: result.id, passed, checks: row, domReasons: dom.reasons, body: result.body, subject: result.subject, actions: result.actions, error: result.error });
}
const n = results.length;
const pct = k => `${k}/${n} (${n ? Math.round((k / n) * 1000) / 10 : 0}%)`;
console.log('\nEmail prediction evaluation');
checks.forEach(c => console.log(`  ${c.padEnd(9)} ${pct(totals[c])}`));
console.log(`  ${'overall'.padEnd(9)} ${pct(overall)}`);
console.log(`  first model answer valid without repair: ${pct(firstAttempt)}; mean ${n ? (seconds / n).toFixed(1) : 0}s per scenario`);
const failing = report.filter(r => !r.passed);
if (failing.length) console.log('  still failing: ' + failing.map(r => `${r.id} [${checks.filter(c => !r.checks[c]).join(', ')}]`).join('; '));
if (reportPath) fs.writeFileSync(reportPath, JSON.stringify({ totals, overall, n, report }, null, 2));
