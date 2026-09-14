// Shared isolated-world reader and body-only writer. Never clicks, submits, or
// synthesizes keyboard events. The same extractor validates before every write.
(function (scope) {
  "use strict";
  if (scope.HolmesEmailCompose) return;
  var documentID = typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID() : Date.now() + ":" + Math.random();
  var ids = new WeakMap(), nextID = 1;
  var environment = { tabId: -1, windowId: -1, instanceId: "", app: "your browser" };
  var QUIET_MS = 1500;
  var undoRecords = new Map(), undoOrder = [];
  var lastUserInputAt = 0, composing = false, writing = false;

  // Holmes's own writes are excluded; anything else in the page is the person.
  function noteInput() { if (!writing) lastUserInputAt = Date.now(); }
  try {
    ["keydown", "input", "paste", "cut", "drop"].forEach(function (type) {
      document.addEventListener(type, noteInput, true);
    });
    document.addEventListener("compositionstart", function () { composing = true; noteInput(); }, true);
    document.addEventListener("compositionend", function () { composing = false; noteInput(); }, true);
  } catch (e) { /* no document */ }

  function visible(el) {
    if (!el || !el.isConnected || el.closest('[hidden], [aria-hidden="true"]')) return false;
    var style = scope.getComputedStyle(el);
    return style.display !== "none" && style.visibility !== "hidden"
      && !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  }
  function all(selector, root) { return selector ? Array.from((root || document).querySelectorAll(selector)) : []; }
  function first(selector, root) { return all(selector, root).find(visible) || null; }
  function field(el) { return el && typeof el.value === "string" ? el.value : rendered(el); }
  function blank(s) { return /^[\s\u00a0\u200B\uFEFF]*$/.test(s); }
  function address(s) {
    var match = String(s || "").match(/[^\s@,;<>()"]+@[^\s@,;<>()"]+\.[^\s@,;<>()"]+/g);
    return match ? match.map(function (x) { return x.toLowerCase(); }) : [];
  }
  function unique(xs) { return Array.from(new Set(xs)); }
  function clip(s, n) { s = String(s || "").trim(); return s.length > n ? s.slice(0, n) : s; }

  var BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TBODY|TD|TFOOT|TH|THEAD|TR|UL)$/;

  // The text a person sees, following the editor's CSS white space rules, so a
  // raw "\n" inside a normal white space editor reads as a space and
  // verification catches collapsed line breaks. One walker everywhere: Chrome's
  // innerText adds an extra newline around an empty <div><br></div>.
  function rendered(el, stopBefore, skip) {
    return el ? walkText(el, stopBefore, skip) : "";
  }
  function preserves(style) { return /^pre/.test(style.whiteSpace || "") || style.whiteSpace === "break-spaces"; }
  function walkText(root, stopBefore, skip) {
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
      if (skip && node.matches(skip)) return;
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
      if (block) pendingBreak = true;
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

  function label(el) { return String(el.getAttribute("aria-label") || "").toLowerCase(); }
  var HEADER_LABEL = /^(to|cc|bcc|from|subject|add a subject|search)\b/;

  // `header` marks what a composer (not a read-only message) carries near its
  // body: recipient or subject controls. Inline replies have no dialog wrapper,
  // so the composer root is found by climbing from the body to that header.
  // `signature` and `quote` mark regions Holmes never edits.
  function profile() {
    var host = location.hostname.toLowerCase();
    if (host === "mail.google.com") return {
      name: "Gmail", roots: '[role="dialog"], div.nH.Hd, div.AD',
      subject: 'input[name="subjectbox"], input[placeholder="Subject"]',
      body: '[aria-label="Message Body"][contenteditable="true"], [g_editable="true"], div.Am.Al.editable',
      header: 'input[name="subjectbox"], input[name="to"], textarea[name="to"], input[name="cc"], [data-recipient-type]',
      signature: '.gmail_signature_prefix, .gmail_signature, [data-smartmail="gmail_signature"]',
      quote: '.gmail_quote_container, .gmail_quote, blockquote.gmail_quote, .gmail_extra',
      attachment: '.aQH .aZo, [data-attachment-id], [aria-label^="Attachment:"]',
      thread: gmailThread
    };
    if (["outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.com"].includes(host)) return {
      name: "Outlook", roots: '[role="dialog"], [data-testid="compose-form"], [aria-label="New message"]',
      subject: 'input[aria-label="Add a subject"], input[placeholder="Add a subject"], input[aria-label="Subject"]',
      // Outlook's label varies ("Message body, press Alt+F10 to exit") and some
      // builds label only the role. Header fields are textboxes too; skip them.
      isBody: function (el) {
        var name = label(el);
        if (name.indexOf("message body") >= 0) return true;
        return el.getAttribute("role") === "textbox" && !HEADER_LABEL.test(name);
      },
      header: 'input[aria-label="Add a subject"], input[aria-label="Subject"], [aria-label="To"], [aria-label^="To "], [data-recipient-type]',
      signature: '#Signature, [id^="Signature"], #signature',
      quote: '#appendonsend, #divRplyFwdMsg, [id^="divRplyFwdMsg"], #mail-editor-reference-message-container, blockquote',
      attachment: '[data-attachment-id], [aria-label^="Attachment:"]',
      thread: outlookThread
    };
    if (host === "mail.proton.me") return {
      name: "Proton Mail", roots: '[data-testid="composer"], .composer',
      subject: 'input[data-testid="composer:subject"], input[name="subject"]',
      body: '[data-testid="composer:body"][contenteditable="true"], [contenteditable="true"][role="textbox"]',
      header: 'input[data-testid="composer:subject"], [data-testid="composer:to"]',
      signature: '.protonmail_signature_block',
      quote: '.protonmail_quote, blockquote.protonmail_quote, blockquote[type="cite"]',
      attachment: '[data-testid="attachment"], [data-attachment-id]',
      thread: protonThread
    };
    return null;
  }

  function isBody(p, el) {
    if (el.getAttribute("contenteditable") !== "true") return false;
    return p.isBody ? p.isBody(el) : el.matches(p.body);
  }
  function bodiesIn(p, scopeEl) {
    return all('[contenteditable="true"]', scopeEl).filter(function (el) {
      // A nested editable inside a body is part of that body, not another one.
      return isBody(p, el) && visible(el) && !(el.parentElement && el.parentElement.closest('[contenteditable="true"]'));
    });
  }
  function composerRoots(p) {
    var roots = all(p.roots).filter(function (root) {
      return visible(root) && (first(p.subject, root) || bodiesIn(p, root).length);
    });
    bodiesIn(p, document).forEach(function (body) {
      if (roots.some(function (root) { return root.contains(body); })) return;
      for (var node = body.parentElement, depth = 0; node && node !== document.documentElement && depth < 16; node = node.parentElement, depth++) {
        if (bodiesIn(p, node).length > 1) return;
        if (node.querySelector(p.header)) { roots.push(node); return; }
      }
    });
    return roots;
  }

  function senderParts(text) {
    var email = address(text)[0] || "";
    var name = String(text || "").replace(/<[^>]*>/g, "").replace(email, "").replace(/["()]/g, "").trim();
    return { name: clip(name, 120), email: email };
  }

  function recipientFields(root, kind, names) {
    var selector = '[name="' + kind + '"], [data-recipient-type="' + kind + '"], '
      + '[aria-label="' + kind.charAt(0).toUpperCase() + kind.slice(1) + ' recipients"], '
      + '[aria-label="' + kind.charAt(0).toUpperCase() + kind.slice(1) + '"], '
      + '[data-testid="composer:' + kind + '"]';
    var controls = all(selector, root).filter(function (el) { return visible(el) && el.type !== "hidden"; });
    var addresses = [], invalid = false;
    function remember(value, name) {
      var parts = senderParts(value);
      name = String(name || parts.name || "").trim();
      if (parts.email && name && name.indexOf("@") < 0) names[parts.email] = clip(name, 120);
    }
    if (!controls.length) {
      // Gmail inline replies keep committed recipients in hidden inputs.
      all('input[type="hidden"][name="' + kind + '"]', root).forEach(function (input) {
        String(input.value || "").split(/[;,](?=(?:[^"]*"[^"]*")*[^"]*$)/).forEach(function (token) { remember(token); });
        addresses = addresses.concat(address(input.value));
      });
    }
    controls.forEach(function (control) {
      var group = control.closest('tr, [data-recipient-type], [role="group"], .composer-addresses-field') || control;
      // A wrapper spanning Subject/the body is not a recipient row.
      if (!root.contains(group) || group.querySelector('input[name="subjectbox"], [contenteditable="true"]')) group = control;
      // Outlook chips carry the address only in their title.
      all('[email], [data-hovercard-id], [data-email], [title*="@"]', group).forEach(function (chip) {
        var value = chip.getAttribute("email") || chip.getAttribute("data-hovercard-id") || chip.getAttribute("data-email")
          || chip.getAttribute("title");
        var parsed = address(value);
        if (!parsed.length) invalid = true;
        addresses = addresses.concat(parsed);
        var shown = String(chip.textContent || "").trim();
        remember(value, chip.getAttribute("name") || chip.getAttribute("data-name") || (shown.indexOf("@") < 0 ? shown : ""));
      });
      var value = field(control).trim();
      // Container text can be a display name; an input's unfinished address
      // must block readiness instead of disappearing from the snapshot.
      if (value) {
        var parsed = address(value);
        addresses = addresses.concat(parsed);
        if (control.tagName === "INPUT" || control.tagName === "TEXTAREA") {
          var tokens = value.split(/[;,]/).filter(function (token) { return token.trim(); });
          var complete = tokens.every(function (token) {
            return /^(?:[^<>]*<)?[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+>?$/.test(token.trim());
          });
          tokens.forEach(function (token) { remember(token); });
          if (!parsed.length || !complete) invalid = true;
        }
      }
    });
    return invalid ? ["(recipient still being edited)"] : unique(addresses);
  }

  // MARK: Signature and quoted thread

  // The first protected node in document order, widened to include a Gmail
  // "-- " line or an Outlook separator right before it.
  function protectedStart(p, body) {
    var marks = all([p.signature, p.quote].filter(Boolean).join(", "), body);
    if (!marks.length) return null;
    var start = marks[0];
    var prev = start.previousSibling;
    while (prev && ((prev.nodeType === 3 && blank(prev.nodeValue)) || (prev.nodeType === 1 && prev.tagName === "BR"))) prev = prev.previousSibling;
    if (prev && ((prev.nodeType === 3 && /^\s*--\s*$/.test(prev.nodeValue)) || (prev.nodeType === 1 && prev.tagName === "HR"))) start = prev;
    return start;
  }
  function protectedNodes(body, start) {
    var nodes = [];
    if (!start) return nodes;
    for (var node = start; node && node !== body; node = node.parentNode) {
      for (var sibling = node === start ? node : node.nextSibling; sibling; sibling = sibling.nextSibling) nodes.push(sibling);
    }
    return nodes;
  }
  function protectedFingerprint(body, start) {
    return protectedNodes(body, start).map(function (node) {
      return node.nodeType === 1 ? node.outerHTML : String(node.nodeValue || "");
    }).join("");
  }
  function precedes(node, start) {
    return !start || !!(node.compareDocumentPosition(start) & Node.DOCUMENT_POSITION_FOLLOWING);
  }
  function layout(p, body) {
    var start = protectedStart(p, body);
    // Blank lines Gmail keeps before a signature are not the person's text.
    var ownText = walkText(body, start).replace(/^\n+|\n+$/g, "");
    var richOwn = all('img, video, audio, svg, canvas, iframe, object, embed, table, hr, [contenteditable="false"]', body)
      .some(function (el) { return precedes(el, start) && (!start || !start.contains(el)); });
    return {
      start: start, ownText: ownText, richOwn: richOwn,
      hasSignature: !!(p.signature && body.querySelector(p.signature)),
      hasQuote: !!(p.quote && body.querySelector(p.quote)),
      quoteElement: p.quote ? body.querySelector(p.quote) : null,
      fingerprint: protectedFingerprint(body, start)
    };
  }

  // MARK: Thread readers (newest first, bounded)

  var THREAD_MESSAGES = 6, MESSAGE_CHARS = 1500;
  function finishThread(rows) {
    return rows.filter(function (row) { return row && !blank(row.text); }).reverse().slice(0, THREAD_MESSAGES).map(function (row) {
      return { from: clip(row.from, 120), fromEmail: clip(row.fromEmail, 200).toLowerCase(), date: clip(row.date, 80), text: clip(row.text, MESSAGE_CHARS) };
    });
  }
  function gmailThread(root) {
    var rows = all("div.adn, div.kv, div.kQ", document).filter(function (message) {
      return !root.contains(message) && !message.parentElement.closest("div.adn, div.kv, div.kQ");
    }).map(function (message) {
      var sender = message.querySelector(".gD, span[email]");
      var date = message.querySelector(".g3");
      var bodies = all("div.a3s", message).filter(function (el) { return !root.contains(el); });
      var text = bodies.length ? bodies.map(function (el) { return rendered(el, null, ".gmail_quote, .adL > .im, blockquote"); }).join("\n")
        : rendered(message.querySelector(".iA.g6, span.y2"));
      return {
        from: sender ? sender.getAttribute("name") || sender.textContent : "",
        fromEmail: sender ? sender.getAttribute("email") || "" : "",
        date: date ? date.getAttribute("title") || date.textContent : "", text: text
      };
    });
    var heading = first("h2.hP", document);
    return { subject: heading ? clip(heading.textContent, 300) : "", messages: finishThread(rows) };
  }
  function outlookThread(root) {
    var rows = all('div[id^="UniqueMessageBody"], [role="document"][aria-label="Message body"], [aria-label="Message body"]:not([contenteditable="true"])', document)
      .filter(function (el) { return !root.contains(el) && !el.parentElement.closest('div[id^="UniqueMessageBody"], [role="document"]'); })
      .map(function (el) {
        var item = el.closest('[role="listitem"], [data-testid="message-item"], [aria-label^="Email from"]') || el.parentElement;
        var sender = item && item.querySelector('[data-testid="SenderPersona"], [title*="@"]');
        var parts = senderParts(sender ? sender.getAttribute("title") || sender.textContent : "");
        var when = item && item.querySelector('[data-testid="SentReceivedSavedTime"], time');
        return { from: parts.name || (sender ? sender.textContent : ""), fromEmail: parts.email,
          date: when ? when.getAttribute("datetime") || when.textContent : "", text: rendered(el, null, "blockquote, #divRplyFwdMsg") };
      });
    var heading = first('[data-testid="ConversationReadingPaneSubject"], #ConversationReadingPaneContainer [role="heading"]', document);
    return { subject: heading ? clip(heading.textContent, 300) : "", messages: finishThread(rows) };
  }
  function protonThread(root) {
    var rows = all('[data-testid="message-view"], .message-container', document).filter(function (el) {
      return !root.contains(el);
    }).map(function (el) {
      var sender = el.querySelector('[data-testid="recipient-address"], [data-testid="message-header:from"] [title]');
      var parts = senderParts(sender ? sender.getAttribute("title") || sender.textContent : "");
      var content = el.querySelector('[data-testid="message-content:body"], .message-content');
      var when = el.querySelector('[data-testid="item-date"], time');
      return { from: parts.name, fromEmail: parts.email, date: when ? when.textContent : "", text: rendered(content, null, "blockquote") };
    });
    var heading = first('[data-testid="conversation-header:subject"], h1[title]', document);
    return { subject: heading ? clip(heading.textContent, 300) : "", messages: finishThread(rows) };
  }
  // A popped out reply often has no visible conversation, only its quote.
  function quotedThread(quote) {
    if (!quote) return [];
    var text = rendered(quote);
    // "On Fri, Sep 11, 2026 at 9:00 AM Dana Lee <dana@example.com> wrote:" ends
    // its date at a time or a year; the sender follows.
    var tail = "\\s*,?\\s+(.+?)\\s+(?:wrote|a écrit|schrieb|escribió)\\s*:\\s*$";
    var header = text.match(new RegExp("^\\s*(?:On|Le|Am|El)\\s+(.+?\\d{1,2}[:h]\\d{2}(?:\\s?[AaPp]\\.?[Mm]\\.?)?)" + tail, "im"))
      || text.match(new RegExp("^\\s*(?:On|Le|Am|El)\\s+(.+?\\d{4})" + tail, "im"))
      || text.match(new RegExp("^\\s*(?:On|Le|Am|El)\\s+(.{4,120}?)" + tail, "im"));
    var from = header ? senderParts(header[2].replace(/^(?:at|um|à|a las)\s+/i, "")) : { name: "", email: "" };
    var messageText = text.replace(header ? header[0] : "", "").split("\n").map(function (line) {
      return line.replace(/^\s*>\s?/, "");
    }).join("\n").trim();
    return blank(messageText) ? [] : [{ from: from.name, fromEmail: from.email, date: header ? clip(header[1], 80) : "", text: clip(messageText, MESSAGE_CHARS) }];
  }

  // MARK: Reading

  function inspect() {
    var p = profile();
    if (!p || document.visibilityState !== "visible") return null;
    var roots = unique(composerRoots(p));
    // Gmail's nested wrappers refer to the same physical composer. Use the
    // innermost qualifying root before deciding whether multiple exist.
    roots = roots.filter(function (root) {
      return !roots.some(function (other) { return other !== root && root.contains(other); });
    });
    var focused = roots.filter(function (root) { return root.contains(document.activeElement); });
    var root = focused.length === 1 ? focused[0] : (roots.length === 1 ? roots[0] : null);
    if (!root) return null;
    // An inline reply keeps its "Re:" subject in a hidden input: readable, not editable.
    var subject = first(p.subject, root) || all(p.subject, root)[0] || null;
    var subjectEditable = !!subject && subject.type !== "hidden" && visible(subject) && !subject.disabled && !subject.readOnly;
    var body = bodiesIn(p, root)[0] || null;
    var text = rendered(body);
    var revision = body ? JSON.stringify([body.innerHTML, all(p.attachment, root).map(function (el) { return el.outerHTML; })]) : "";
    var readable = !!body && text.length <= 6000 && revision.length <= 12000;
    var rich = !!body && !!body.querySelector('img, video, audio, svg, canvas, iframe, object, embed, table, hr, [contenteditable="false"]');
    var attached = !!first(p.attachment, root);
    var regions = body ? layout(p, body) : null;
    var names = {};
    var subjectText = subject ? field(subject) : "";
    var recipients = recipientFields(root, "to", names), cc = recipientFields(root, "cc", names), bcc = recipientFields(root, "bcc", names);
    var isReply = !!subject && (!subjectEditable || /^\s*(re|aw|sv|antw|r|rif|tr|fwd?|wg)\s*:/i.test(subjectText))
      || !!(regions && regions.hasQuote);
    var thread = { subject: "", messages: [] };
    if (isReply && p.thread) {
      try { thread = p.thread(root); } catch (e) { thread = { subject: "", messages: [] }; }
      if (!thread.messages.length && regions) thread.messages = quotedThread(regions.quoteElement);
    }
    if (!ids.has(root)) ids.set(root, nextID++);
    var identity = environment.tabId >= 0 && environment.windowId >= 0 && environment.instanceId
      ? JSON.stringify([environment.instanceId, environment.windowId, environment.tabId,
          documentID, location.origin + location.pathname, ids.get(root)]) : "";
    return { root: root, bodyElement: body, subjectElement: subject, profile: p, regions: regions, snapshot: {
      source: "browser", identity: identity, provider: p.name, app: environment.app,
      recipients: recipients, cc: cc, bcc: bcc,
      subject: subjectText, subjectEditable: subjectEditable,
      body: text.slice(0, 6000), bodyRevision: revision.slice(0, 12000),
      bodyReadable: readable, bodyIsEmpty: readable && blank(text) && !rich && !attached,
      userText: regions ? regions.ownText.slice(0, 6000) : "",
      autoWritable: !!regions && readable && blank(regions.ownText) && !regions.richOwn,
      hasSignature: !!(regions && regions.hasSignature), hasQuote: !!(regions && regions.hasQuote),
      isReply: isReply, threadSubject: thread.subject, thread: thread.messages, recipientNames: names,
      capturedAt: Date.now()
    } };
  }

  function unchanged(actual, expected) {
    return ["identity", "recipients", "cc", "bcc", "subject", "body", "bodyRevision", "bodyReadable", "bodyIsEmpty"].every(function (key) {
      return JSON.stringify(actual[key]) === JSON.stringify(expected[key]);
    });
  }
  function refusal(reason, extra) { return Object.assign({ ok: false, refused: true, reason: reason }, extra || {}); }

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
  function blankLine() {
    var block = document.createElement("div");
    block.appendChild(document.createElement("br"));
    return block;
  }

  function setFieldValue(input, value) {
    var proto = input.tagName === "TEXTAREA" ? scope.HTMLTextAreaElement.prototype : scope.HTMLInputElement.prototype;
    var descriptor = Object.getOwnPropertyDescriptor(proto, "value");
    // React based pages (Outlook) track the native setter, not the property.
    if (descriptor && descriptor.set) descriptor.set.call(input, value); else input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // Every precondition for a write, without writing. Also answers the
  // extension's question "is this still the right composer?" before it
  // focuses any tab.
  function validate(body, expected, options) {
    options = options || {};
    var mode = options.mode || "replace";
    if (["auto", "replace", "insert"].indexOf(mode) < 0) return { refusal: refusal("Unknown write mode.") };
    if (typeof body !== "string" || blank(body) || body.length > 16000 || !expected) return { refusal: refusal("No usable draft body.") };
    var current = inspect();
    if (!current || !current.snapshot.identity || !unchanged(current.snapshot, expected)) {
      return { refusal: refusal("The composer or its headers changed. Refresh the draft.", { changed: true }) };
    }
    if (!current.snapshot.bodyReadable) return { refusal: refusal("The composer body cannot be fully verified.") };
    var target = current.bodyElement;
    if (!target || !target.isContentEditable || !visible(target)) return { refusal: refusal("The message body is not editable.") };
    if (mode === "auto") {
      if (!current.snapshot.autoWritable) {
        return { refusal: refusal("The email already has your own text, so Holmes did not write automatically.", { hasOwnText: true }) };
      }
      if (composing || Date.now() - lastUserInputAt < QUIET_MS) {
        return { refusal: refusal("You were typing, so Holmes did not write into the email.", { typing: true }) };
      }
    }
    return { current: current, target: target, mode: mode };
  }

  function check(expected, options) {
    var body = options && typeof options.body === "string" ? options.body : "check";
    var result = validate(body, expected, options);
    return result.refusal || { ok: true, identity: result.current.snapshot.identity };
  }

  function nativeInsert(target, start, text, mode) {
    if (typeof document.execCommand !== "function" || typeof scope.getSelection !== "function") return false;
    var selection = scope.getSelection();
    if (!selection) return false;
    var saved = [];
    for (var i = 0; i < selection.rangeCount; i++) saved.push(selection.getRangeAt(i).cloneRange());
    var active = document.activeElement;
    var range = document.createRange();
    if (mode === "insert") {
      if (start) range.setStartBefore(start); else range.setStart(target, target.childNodes.length);
      range.collapse(true);
    } else {
      range.setStart(target, 0);
      if (start) range.setEndBefore(start); else range.setEnd(target, target.childNodes.length);
    }
    var inserted = false;
    try {
      if (target.focus) target.focus({ preventScroll: true });
      selection.removeAllRanges();
      selection.addRange(range);
      var payload = (mode === "insert" && !blank(walkText(target, start)) ? "\n\n" : "") + text + (start ? "\n\n" : "");
      inserted = document.execCommand("insertText", false, payload) === true;
    } catch (e) {
      inserted = false;
    } finally {
      // Hand focus and the caret back to wherever the person left them.
      try {
        if (active && active !== target && active.focus) active.focus({ preventScroll: true });
        selection.removeAllRanges();
        saved.forEach(function (r) { if (r.startContainer.isConnected) selection.addRange(r); });
      } catch (e) { /* selection restore is best effort */ }
    }
    return inserted;
  }

  function domInsert(target, start, text, mode) {
    var fragment = paragraphs(text);
    if (mode !== "insert") {
      var range = document.createRange();
      range.setStart(target, 0);
      if (start) range.setEndBefore(start); else range.setEnd(target, target.childNodes.length);
      range.deleteContents();
    } else if (!blank(walkText(target, start))) {
      fragment.insertBefore(blankLine(), fragment.firstChild);
    }
    if (start) {
      fragment.appendChild(blankLine());
      start.parentNode.insertBefore(fragment, start);
    } else {
      target.appendChild(fragment);
    }
    target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
    return true;
  }

  function stage(body, expected, options) {
    options = options || {};
    var checked = validate(body, expected, options);
    if (checked.refusal) return checked.refusal;
    var current = checked.current, target = checked.target, mode = checked.mode;
    var p = current.profile;
    var before = Array.from(target.childNodes).map(function (node) { return node.cloneNode(true); });
    var beforeText = walkText(target);
    var ownBefore = current.regions.ownText;
    var fingerprint = current.regions.fingerprint;
    var subjectInput = current.subjectElement;
    var subjectText = typeof options.subject === "string" ? options.subject.replace(/\s+/g, " ").trim().slice(0, 200) : "";
    var fillSubject = !!subjectText && current.snapshot.subjectEditable && subjectInput && blank(subjectInput.value) && blank(expected.subject);
    var beforeSubject = subjectInput ? subjectInput.value : "";
    var expectedOwn = mode === "insert" && !blank(ownBefore) ? ownBefore + "\n" + body : body;

    function verified() {
      var after = inspect();
      if (!after || after.snapshot.identity !== expected.identity || after.bodyElement !== target) return false;
      if (!sameLines(after.regions.ownText, expectedOwn)) return false;
      // The signature and quoted thread must be byte for byte what they were.
      if (protectedFingerprint(target, protectedStart(p, target)) !== fingerprint) return false;
      return ["recipients", "cc", "bcc"].every(function (key) {
        return JSON.stringify(after.snapshot[key]) === JSON.stringify(expected[key]);
      }) && after.snapshot.subject === (fillSubject ? subjectText : expected.subject);
    }
    function restore() {
      if (target.isConnected) {
        target.replaceChildren.apply(target, before.map(function (node) { return node.cloneNode(true); }));
        target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "historyUndo" }));
      }
      if (subjectInput && subjectInput.value !== beforeSubject) setFieldValue(subjectInput, beforeSubject);
    }

    // No await, click or keyboard event occurs between the final compare and
    // this body-only mutation. Page reactions run after the write.
    writing = true;
    var method = "dom", ok = false;
    try {
      var start = current.regions.start;
      if (options.nativeEditing !== false && nativeInsert(target, start, body, mode)) {
        method = "native";
        if (fillSubject) setFieldValue(subjectInput, subjectText);
        ok = verified();
        if (!ok) restore();
      }
      if (!ok) {
        method = "dom";
        domInsert(target, protectedStart(p, target), body, mode);
        if (fillSubject) setFieldValue(subjectInput, subjectText);
        ok = verified();
      }
      if (!ok) restore();
    } finally {
      writing = false;
    }
    if (!ok) return refusal("The editor did not confirm the inserted draft, so Holmes restored the original body.");

    var token = typeof crypto !== "undefined" && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random();
    undoRecords.set(token, {
      identity: expected.identity, body: target, before: before, beforeText: beforeText, afterText: walkText(target),
      subject: fillSubject ? subjectInput : null, beforeSubject: beforeSubject, afterSubject: subjectText
    });
    undoOrder.push(token);
    while (undoOrder.length > 10) undoRecords.delete(undoOrder.shift());
    return { ok: true, inserted: true, identity: expected.identity, undoToken: token, subjectFilled: fillSubject, method: method };
  }

  // Restores exactly what was there before Holmes wrote, but only while the
  // email still holds exactly what Holmes wrote. Later edits are the person's.
  function undo(token) {
    var record = undoRecords.get(token);
    if (!record) return refusal("There is nothing of Holmes's left to undo in this email.");
    var current = inspect();
    if (!current || current.snapshot.identity !== record.identity || current.bodyElement !== record.body) {
      return refusal("The email Holmes wrote into is no longer the open composer.");
    }
    if (walkText(record.body) !== record.afterText || (record.subject && record.subject.value !== record.afterSubject)) {
      return refusal("You changed the email after Holmes wrote it, so Undo would erase your edits. Use Command Z in the email instead.", { edited: true });
    }
    writing = true;
    try {
      record.body.replaceChildren.apply(record.body, record.before.map(function (node) { return node.cloneNode(true); }));
      record.body.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "historyUndo" }));
      if (record.subject) setFieldValue(record.subject, record.beforeSubject);
    } finally {
      writing = false;
    }
    undoRecords.delete(token);
    undoOrder = undoOrder.filter(function (value) { return value !== token; });
    if (walkText(record.body) !== record.beforeText) return refusal("Holmes could not confirm the undo. Check the email.");
    return { ok: true, undone: true, identity: record.identity };
  }

  scope.HolmesEmailCompose = {
    setEnvironment: function (values) { Object.assign(environment, values || {}); },
    read: function () { var result = inspect(); return result ? result.snapshot : null; },
    check: check,
    stage: stage,
    undo: undo,
    renderedText: function (el) { return walkText(el); },
    // Test hook for the typing guard; real input events do the same.
    noteUserInput: function (at) { lastUserInputAt = typeof at === "number" ? at : Date.now(); }
  };
})(globalThis);
