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
  function field(el) { return el && typeof el.value === "string" ? el.value : rendered(el); }
  function blank(s) { return /^[\s\u00a0\u200B\uFEFF]*$/.test(s); }
  function address(s) {
    var match = String(s || "").match(/[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+/g);
    return match ? match.map(function (x) { return x.toLowerCase(); }) : [];
  }
  function unique(xs) { return Array.from(new Set(xs)); }

  var BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TBODY|TD|TFOOT|TH|THEAD|TR|UL)$/;

  // The text a person sees, following the editor's CSS. A browser's innerText
  // already does this; the walker is the same rule where innerText is missing.
  // Both honor white-space, so a raw "\n" inside a normal-white-space editor
  // renders as a space and verification catches collapsed line breaks.
  function rendered(el, stopBefore) {
    if (!el) return "";
    if (!stopBefore && typeof el.innerText === "string") return el.innerText;
    return walkText(el, stopBefore);
  }
  function preserves(style) { return /^pre/.test(style.whiteSpace || "") || style.whiteSpace === "break-spaces"; }
  function walkText(root, stopBefore) {
    var out = "", pendingBreak = false, stopped = false;
    function emit(text) {
      if (!text) return;
      if (pendingBreak && out && !/\n$/.test(out)) out += "\n";
      pendingBreak = false;
      out += text;
    }
    function visit(node, keep) {
      if (stopped) return;
      if (stopBefore && node === stopBefore) { stopped = true; return; }
      if (node.nodeType === 3) {
        var text = node.nodeValue || "";
        if (!keep) {
          text = text.replace(/[\t\n\r ]+/g, " ");
          if ((!out || /\n$/.test(out) || pendingBreak) && /^ /.test(text)) text = text.replace(/^ +/, "");
        }
        emit(text);
        return;
      }
      if (node.nodeType !== 1) return;
      var tag = node.tagName;
      if (tag === "SCRIPT" || tag === "STYLE" || tag === "TEMPLATE") return;
      var style = scope.getComputedStyle(node);
      if (style.display === "none") return;
      if (tag === "BR") {
        if (pendingBreak && out && !/\n$/.test(out)) out += "\n";
        pendingBreak = false;
        out = out.replace(/ +$/, "") + "\n";
        return;
      }
      var block = BLOCK.test(tag) || /^(block|list-item|table|flex|grid)/.test(style.display || "");
      if (block) pendingBreak = true;
      var preserve = keep || preserves(style);
      for (var child = node.firstChild; child; child = child.nextSibling) visit(child, preserve);
      if (block) {
        // A line-ending <br> is the line itself, not an additional blank line.
        pendingBreak = true;
      }
    }
    var rootStyle = scope.getComputedStyle(root);
    for (var child = root.firstChild; child; child = child.nextSibling) visit(child, preserves(rootStyle));
    return out.replace(/ +\n/g, "\n").replace(/\n$/, "");
  }
  function lines(text) {
    return String(text || "").replace(/\r\n?/g, "\n").replace(/[\u00a0\u200B\uFEFF]/g, " ").split("\n")
      .map(function (line) { return line.replace(/[\t ]+/g, " ").trim(); })
      .filter(function (line) { return line.length > 0; });
  }
  function sameLines(a, b) { return lines(a).join("\n") === lines(b).join("\n"); }

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
    var text = rendered(body);
    var revision = body ? JSON.stringify([body.innerHTML, all(p.attachment, root).map(function (el) { return el.outerHTML; })]) : "";
    var readable = !!body && text.length <= 6000 && revision.length <= 12000;
    var rich = !!body && !!body.querySelector('img, video, audio, svg, canvas, iframe, object, embed, table, hr, [contenteditable="false"]');
    var attached = !!first(p.attachment, root);
    if (!ids.has(root)) ids.set(root, nextID++);
    var identity = environment.tabId >= 0 && environment.windowId >= 0 && environment.instanceId
      ? JSON.stringify([environment.instanceId, environment.windowId, environment.tabId,
          documentID, location.origin + location.pathname, ids.get(root)]) : "";
    return { root: root, bodyElement: body, subjectElement: subject, snapshot: {
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

  // One block per line, the structure Gmail, Outlook web and Proton produce
  // when a person presses Return. Blank lines keep a <br> so they render.
  function paragraphs(text) {
    var fragment = document.createDocumentFragment();
    String(text).replace(/\r\n?/g, "\n").split("\n").forEach(function (line) {
      var block = document.createElement("div");
      if (blank(line)) block.appendChild(document.createElement("br"));
      else block.appendChild(document.createTextNode(line));
      fragment.appendChild(block);
    });
    return fragment;
  }

  function stage(body, expected) {
    if (typeof body !== "string" || blank(body) || body.length > 16000 || !expected) return refusal("No usable draft body.");
    var current = inspect();
    if (!current || !current.snapshot.identity || !unchanged(current.snapshot, expected)) return refusal("The composer or its headers changed. Refresh the draft.");
    if (!current.snapshot.bodyReadable) return refusal("The composer body cannot be fully verified.");
    var target = current.bodyElement;
    if (!target || !target.isContentEditable || !visible(target)) return refusal("The message body is not editable.");
    // Cloned nodes, not an HTML string: pages that enforce Trusted Types
    // (Gmail does) reject innerHTML string assignment.
    var before = Array.from(target.childNodes).map(function (node) { return node.cloneNode(true); });
    // No await, focus event, click or keyboard event occurs between the final
    // compare and this body-only mutation. Page reactions run after the write.
    target.replaceChildren(paragraphs(body));
    target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: body }));
    var after = inspect();
    if (!after || after.snapshot.identity !== expected.identity || after.bodyElement !== target
        || !sameLines(walkText(target), body)
        || !["recipients", "cc", "bcc", "subject"].every(function (key) {
          return JSON.stringify(after.snapshot[key]) === JSON.stringify(expected[key]);
        })) {
      // Never leave an unverified write behind: restore exactly what was there.
      if (target.isConnected) {
        target.replaceChildren.apply(target, before);
        target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "historyUndo" }));
      }
      return refusal("The editor did not confirm the inserted draft, so Holmes restored the original body.");
    }
    return { ok: true, inserted: true, identity: after.snapshot.identity };
  }

  scope.HolmesEmailCompose = {
    setEnvironment: function (values) { Object.assign(environment, values || {}); },
    read: function () { var result = inspect(); return result ? result.snapshot : null; },
    stage: stage,
    renderedText: function (el) { return walkText(el); }
  };
})(globalThis);
