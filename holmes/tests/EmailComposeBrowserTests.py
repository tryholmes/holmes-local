#!/usr/bin/env python3
"""Production composer reader/writer in a fresh Chromium session, with a mocked
Gmail document. No account/profile is reused and all Gmail responses are local.
Requires `npx agent-browser` and Chrome. Run from any directory.
"""
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SESSION = 'holmes-compose-browser-test'
OUTPUT = Path(tempfile.mkdtemp(prefix='holmes-compose-browser-'))
BASE = ['npx', '--yes', 'agent-browser', '--session', SESSION]
checks = 0


def browser(*args, source=None):
    result = subprocess.run(BASE + list(args), input=source, text=True, capture_output=True, timeout=75)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


def evaluate(source):
    return json.loads(browser('eval', '--stdin', source=source))


def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print('PASS ' + label, flush=True)


HTML = '''<html><head><title>Holmes synthetic Gmail test</title><style>
body{font:16px system-ui;background:#eef1f7;padding:36px;color:#172033} section{background:white;padding:24px;border-radius:12px;max-width:600px;box-shadow:0 5px 30px #0002}
label{display:block;margin-bottom:14px}input{padding:8px;font:inherit;width:85%}[contenteditable]{white-space:normal;word-wrap:break-word;border:1px solid #bbb;min-height:140px;padding:12px}button{margin-top:16px;padding:8px 24px}
</style></head><body><h1>Synthetic Gmail compose</h1><p>Local test fixture · no email account connected</p>
<section role="dialog"><label>To<input name="to" aria-label="To" value="boss@gmail.com"></label><label>Subject<input name="subjectbox" aria-label="Subject" value="Im gonna be late"></label>
<div contenteditable="true" aria-label="Message Body" role="textbox"><br></div><button id="send">Send (test counter only)</button></section></body></html>'''

def serve_fixture():
    """Serves HTML for every path over local HTTPS. The browser maps mail.google.com
    here, so the page has Gmail's origin without any network or Google page."""
    key, cert = OUTPUT / 'fixture.key', OUTPUT / 'fixture.crt'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=mail.google.com', '-keyout', str(key), '-out', str(cert)],
                   check=True, capture_output=True)
    page = HTML.encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(page)))
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


try:
    try:
        browser('close')  # a previous session would keep its old launch arguments
    except RuntimeError:
        pass
    server = serve_fixture()
    chrome = os.environ.get('HOLMES_TEST_CHROME', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    launch = ['--executable-path', chrome] if Path(chrome).exists() else []
    rules = f'--host-resolver-rules=MAP mail.google.com 127.0.0.1:{server.server_address[1]},--disable-quic'
    browser(*launch, '--ignore-https-errors', '--args', rules, 'open', 'https://mail.google.com/mail/u/0/#inbox?holmes-synthetic-test=1')
    check(evaluate('location.hostname') == 'mail.google.com' and evaluate('!!document.querySelector("[role=dialog]")'),
          'synthetic page is served at the Gmail origin without network access')
    # HOLMES_COMPOSE_SCRIPT runs this same test against another writer build,
    # e.g. an older revision, to confirm the fixture still catches a regression.
    production = Path(os.environ.get('HOLMES_COMPOSE_SCRIPT', ROOT / 'holmes-extension/email-compose.js')).read_text()
    evaluate(production + '\nHolmesEmailCompose.setEnvironment({tabId:71,windowId:8,instanceId:"synthetic-chrome",app:"Google Chrome"}); window.sendCount=0; window.inputCount=0; document.querySelector("#send").addEventListener("click",()=>sendCount++); document.addEventListener("input",()=>inputCount++); true')
    snapshot = browser('snapshot', '-i')
    check('textbox "To"' in snapshot and 'textbox "Subject"' in snapshot and 'textbox "Message Body"' in snapshot, 'real browser renders labeled compose controls')
    check(evaluate('window.expected=HolmesEmailCompose.read(); expected.recipients[0]==="boss@gmail.com" && expected.subject==="Im gonna be late" && expected.bodyIsEmpty'), 'literal recipient + subject with verified empty body')
    browser('click', 'input[name="subjectbox"]')
    body = "Hi,\n\nI'm running late. Sorry for the delay.\n\nThank you for your understanding."
    stage = evaluate('HolmesEmailCompose.stage(' + json.dumps(body) + ', expected)')
    check(stage.get('ok') and stage.get('inserted'), 'reviewed body inserted while Subject had focus')
    readback = evaluate('HolmesEmailCompose.read().body')
    print('readback ' + json.dumps(readback), flush=True)
    check(readback == body, 'multiline body survives real DOM innerText readback')
    check(evaluate('document.querySelector("[aria-label=\\"Message Body\\"]").innerText.split("\\n").filter(Boolean).length === 3'),
          'normal white space editor shows three separate lines (no collapsed newlines)')
    check(evaluate('document.querySelector("[name=subjectbox]").value==="Im gonna be late" && document.querySelector("[name=to]").value==="boss@gmail.com"'), 'headers unchanged after body insertion')
    check(evaluate('sendCount===0 && inputCount===1'), 'one input event; Send never clicked')
    check(not evaluate('HolmesEmailCompose.stage("duplicate",expected)').get('ok'), 'old empty-body approval cannot overwrite inserted text')
    evaluate('window.rewriteExpected=HolmesEmailCompose.read(); true')
    check(evaluate('HolmesEmailCompose.stage("Hi, I am running late. Apologies for the delay.",rewriteExpected)').get('ok'), 'explicit rewrite uses unchanged nonempty body')
    evaluate('window.staleHeaders=HolmesEmailCompose.read(); true')
    browser('fill', 'input[name="subjectbox"]', 'Different topic')
    check(not evaluate('HolmesEmailCompose.stage("wrong draft",staleHeaders)').get('ok'), 'real user edit to subject invalidates old draft')
    check(evaluate('!HolmesEmailCompose.read().body.includes("wrong draft")'), 'stale subject failure leaves body untouched')
    evaluate('document.querySelector("[role=dialog]").insertAdjacentHTML("afterend",document.querySelector("[role=dialog]").outerHTML); document.activeElement.blur(); true')
    check(evaluate('HolmesEmailCompose.read()===null'), 'two composers without focus are ambiguous')
    evaluate('document.querySelectorAll("[role=dialog]")[1].querySelector("[name=subjectbox]").focus(); true')
    check(evaluate('HolmesEmailCompose.read()!==null'), 'focused composer chosen among two')
    evaluate('window.longExpected=HolmesEmailCompose.read(); true')
    check(evaluate('HolmesEmailCompose.stage("L".repeat(8000),longExpected)').get('ok'), '8000-character reviewed draft verifies full body after writing')
    check(evaluate('!HolmesEmailCompose.read().bodyReadable'), 'oversize existing body prevents incomplete future rewrites')
    check(evaluate('sendCount===0'), 'all cases completed without Send')
    browser('screenshot', str(OUTPUT / 'compose-fixture.png'))
    (OUTPUT / 'browser-snapshot.txt').write_text(browser('snapshot', '-i'))
    print(f'{checks} production browser checks passed. Artifacts: {OUTPUT}', flush=True)
finally:
    browser('close')
