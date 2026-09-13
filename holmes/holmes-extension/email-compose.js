// Shared isolated-world reader and body-only writer. Never clicks, submits, or
// synthesizes keyboard events. The same extractor validates before every write.
(function (scope) {
  "use strict";
  if (scope.HolmesEmailCompose) return;
  var documentID = typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID() : Date.now() + ":" + Math.random();
  var ids = new WeakMap(), nextID = 1;
  var environment = { tabId: -1, windowId: -1, instanceId: "", app: "your browser" };

  function visible(el) {
    if (!el || !el.isConnected || el.closest('[hidden], [aria-hidden="true"]')) return false;
    var style = scope.getComputedStyle(el);
    return style.display !== "none" && style.visibility !== "hidden"
      && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  }
  function all(selector, root) { return Array.from((root || document).querySelectorAll(selector)); }
  function first(selector, root) { return all(selector, root).find(visible) || null; }
  function plain(el) { return el ? String(el.innerText || el.textContent || "") : ""; }
  function field(el) { return el && typeof el.value === "string" ? el.value : plain(el); }
  function blank(s) { return /^[\s\u200B\uFEFF]*$/.test(s); }
  function address(s) {
    var match = String(s || "").match(/[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+/g);
    return match ? match.map(function (x) { return x.toLowerCase(); }) : [];
  }
  function unique(xs) { return Array.from(new Set(xs)); }

  function profile() {
    var host = location.hostname.toLowerCase();
    if (host === "mail.google.com") return {
      name: "Gmail", roots: '[role="dialog"], div.nH.Hd, div.AD',
      subject: 'input[name="subjectbox"], input[placeholder="Subject"]',
      body: '[aria-label="Message Body"][contenteditable="true"], [g_editable="true"], div.Am.Al.editable',
      attachment: '.aQH .aZo, [data-attachment-id], [aria-label^="Attachment:"]'
    };
    if (["outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.com"].includes(host)) return {
      name: "Outlook", roots: '[role="dialog"], [data-testid="compose-form"], [aria-label="New message"]',
      subject: 'input[aria-label="Add a subject"], input[placeholder="Add a subject"], input[aria-label="Subject"]',
      body: '[aria-label="Message body"][contenteditable="true"]',
      attachment: '[data-attachment-id], [aria-label^="Attachment:"]'
    };
    if (host === "mail.proton.me") return {
      name: "Proton Mail", roots: '[data-testid="composer"], .composer',
      subject: 'input[data-testid="composer:subject"], input[name="subject"]',
      body: '[data-testid="composer:body"][contenteditable="true"], [contenteditable="true"][role="textbox"]',
      attachment: '[data-testid="attachment"], [data-attachment-id]'
    };
    return null;
  }

  function recipientFields(root, kind) {
    var selector = '[name="' + kind + '"], [data-recipient-type="' + kind + '"], '
      + '[aria-label="' + kind.charAt(0).toUpperCase() + kind.slice(1) + ' recipients"], '
      + '[aria-label="' + kind.charAt(0).toUpperCase() + kind.slice(1) + '"], '
      + '[data-testid="composer:' + kind + '"]';
    var controls = all(selector, root).filter(visible), addresses = [], invalid = false;
    controls.forEach(function (control) {
      var group = control.closest('tr, [data-recipient-type], [role="group"], .composer-addresses-field') || control;
      // A wrapper spanning Subject/the body is not a recipient row.
      if (!root.contains(group) || group.querySelector('input[name="subjectbox"], [contenteditable="true"]')) group = control;
      all('[email], [data-hovercard-id], [data-email]', group).forEach(function (chip) {
        var value = chip.getAttribute("email") || chip.getAttribute("data-hovercard-id") || chip.getAttribute("data-email");
        var parsed = address(value);
        if (!parsed.length) invalid = true;
        addresses = addresses.concat(parsed);
      });
      var value = field(control).trim();
      // Container text can be a display name; an input's unfinished address
      // must block readiness instead of disappearing from the snapshot.
      if (value) {
        var parsed = address(value);
        addresses = addresses.concat(parsed);
        if (control.tagName === "INPUT" || control.tagName === "TEXTAREA") {
          var complete = value.split(/[;,]/).filter(function (token) { return token.trim(); }).every(function (token) {
            return /^(?:[^<>]*<)?[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+>?$/.test(token.trim());
          });
          if (!parsed.length || !complete) invalid = true;
        }
      }
    });
    return invalid ? ["(recipient still being edited)"] : unique(addresses);
  }

  function inspect() {
    var p = profile();
    if (!p || document.visibilityState !== "visible") return null;
    var roots = unique(all(p.roots).filter(function (root) {
      return visible(root) && (first(p.subject, root) || first(p.body, root));
    }));
    // Gmail's nested wrappers refer to the same physical composer. Use the
    // innermost qualifying root before deciding whether multiple exist.
    roots = roots.filter(function (root) {
      return !roots.some(function (other) { return other !== root && root.contains(other); });
    });
    var focused = roots.filter(function (root) { return root.contains(document.activeElement); });
    var root = focused.length === 1 ? focused[0] : (roots.length === 1 ? roots[0] : null);
    if (!root) return null;
    var subject = first(p.subject, root), body = first(p.body, root);
    var text = plain(body);
    var revision = body ? JSON.stringify([body.innerHTML, all(p.attachment, root).map(function (el) { return el.outerHTML; })]) : "";
    var readable = !!body && text.length <= 6000 && revision.length <= 12000;
    var rich = !!body && !!body.querySelector('img, video, audio, svg, canvas, iframe, object, embed, table, hr, [contenteditable="false"]');
    var attached = !!first(p.attachment, root);
    if (!ids.has(root)) ids.set(root, nextID++);
    var identity = environment.tabId >= 0 && environment.windowId >= 0 && environment.instanceId
      ? JSON.stringify([environment.instanceId, environment.windowId, environment.tabId,
          documentID, location.origin + location.pathname, ids.get(root)]) : "";
    return { root: root, bodyElement: body, snapshot: {
      source: "browser", identity: identity, provider: p.name, app: environment.app,
      recipients: recipientFields(root, "to"), cc: recipientFields(root, "cc"), bcc: recipientFields(root, "bcc"),
      subject: subject ? field(subject) : "", body: text.slice(0, 6000), bodyRevision: revision.slice(0, 12000),
      bodyReadable: readable, bodyIsEmpty: readable && blank(text) && !rich && !attached,
      capturedAt: Date.now()
    } };
  }

  function unchanged(actual, expected) {
    return ["identity", "recipients", "cc", "bcc", "subject", "body", "bodyRevision", "bodyReadable", "bodyIsEmpty"].every(function (key) {
      return JSON.stringify(actual[key]) === JSON.stringify(expected[key]);
    });
  }
  function refusal(reason) { return { ok: false, refused: true, reason: reason }; }

  function stage(body, expected) {
    if (typeof body !== "string" || blank(body) || body.length > 16000 || !expected) return refusal("No usable draft body.");
    var current = inspect();
    if (!current || !current.snapshot.identity || !unchanged(current.snapshot, expected)) return refusal("The composer or its headers changed. Refresh the draft.");
    if (!current.snapshot.bodyReadable) return refusal("The composer body cannot be fully verified.");
    var target = current.bodyElement;
    if (!target || !target.isContentEditable || !visible(target)) return refusal("The message body is not editable.");
    // No await, focus event, click or keyboard event occurs between the final
    // compare and this body-only mutation. Page reactions run after the write.
    target.replaceChildren(document.createTextNode(body));
    target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: body }));
    var after = inspect();
    if (!after || after.snapshot.identity !== expected.identity || plain(target) !== body
        || !["recipients", "cc", "bcc", "subject"].every(function (key) {
          return JSON.stringify(after.snapshot[key]) === JSON.stringify(expected[key]);
        })) return refusal("The editor did not confirm the inserted draft. Check the composer before retrying.");
    return { ok: true, inserted: true, identity: after.snapshot.identity };
  }

  scope.HolmesEmailCompose = {
    setEnvironment: function (values) { Object.assign(environment, values || {}); },
    read: function () { var result = inspect(); return result ? result.snapshot : null; },
    stage: stage
  };
})(globalThis);
