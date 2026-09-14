// Holmes — universal page context extraction engine (isolated-world content script).
//
// This file is the single most important piece of the Holmes context pipeline. Holmes
// hallucinates about "what you're doing" precisely when this returns nothing, so the
// contract here is: on EVERY page, produce a literal, factual, one-line `headline`
// built out of real DOM values — never a guess, never "Browsing the web", and when the
// page genuinely cannot be read, say exactly what is missing instead of inventing.
//
// Architecture:
//   1. A pile of small, safe DOM readers (text, focus, selection, media, article).
//   2. A registry of SITE ADAPTERS keyed on hostname, each returning
//      { activity, headline, detail, entities, bodyText, media, thread }.
//   3. A generic adapter that is still precise (title + article + focused field +
//      selection + media + scroll depth) for everything else.
//   4. A delivery layer that pushes the payload the instant anything changes — focus,
//      typing, selection, SPA navigation, mutation — deduped by hash, throttled to one
//      POST per 200ms, with a 5s heartbeat purely as a safety net.
//
// Everything is wrapped in try/catch at every boundary: a broken selector on one site
// must never break the user's browsing, and must never stop the other adapters.

(function () {
  "use strict";

  // Content scripts can be injected twice: bfcache restores, and the worker
  // reinjecting already open tabs after an install or update. A second copy defers
  // to a LIVE first copy, but takes over from an orphan left behind by the previous
  // extension version: that copy's runtime is gone, so it can never send again.
  // (An older build stored a plain `true` here; that copy is orphaned by definition.)
  var RUNTIME = (typeof chrome !== "undefined" && chrome.runtime) || null;
  var existingCopy = window.__holmesContentScript;
  if (existingCopy && typeof existingCopy === "object" && typeof existingCopy.alive === "function" && existingCopy.alive()) return;
  try { if (existingCopy && typeof existingCopy.teardown === "function") existingCopy.teardown(); } catch (_) { /* ignore */ }
  var tornDown = false;
  window.__holmesContentScript = {
    alive: function () { return !tornDown && runtimeAlive(); },
    teardown: function () { teardown(); }
  };

  // MARK: - Configuration

  var ENDPOINT = "http://127.0.0.1:5766/context";
  var MAX_BODY_TEXT = 4000;      // hard cap on extracted article/body text
  var MAX_PAYLOAD_BYTES = 24000; // keeps a single POST inside one comfortable read
  var MIN_POST_INTERVAL_MS = 200;
  var COALESCE_MS = 40;          // burst-coalescing window; still effectively "instant"
  var HEARTBEAT_MS = 5000;
  var FORCE_RESEND_MS = 60000;   // ignore dedupe this often, so an app restart re-syncs
  var SELECTION_DEBOUNCE_MS = 150;
  var INPUT_DEBOUNCE_MS = 400;
  var MUTATION_DEBOUNCE_MS = 250;
  var MAX_THREAD_MESSAGES = 12;
  var MAX_MESSAGE_CHARS = 400;

  // Per-site controls + telemetry, hydrated from chrome.storage.local by loadSettings().
  // EXCLUDED_HOSTS is the user's "Don't read this site" switch (set from the popup /
  // options page): an excluded host is honored by BAILING out of capture() entirely, so
  // it produces no extraction and no POST — the strongest possible off-switch.
  var EXCLUDED_HOSTS = [];        // lowercased, www-stripped hostnames
  var HEARTBEAT_MS_OVERRIDE = 0;  // options-page heartbeat override; 0 = use HEARTBEAT_MS
  var lastPayloadInfo = null;     // { headline, site, surface, adapter, activity, url, title, bytes }
  var lastPostAtMs = 0;           // when the most recent payload was handed to the transport
  var lastPostBytes = 0;          // serialized byte length of that payload
  var lastAckAtMs = 0;            // when the relay last confirmed a POST reached the app
  var lastAckOk = false;

  // MARK: - Redaction
  //
  // Applied before anything leaves the page. This content script runs on <all_urls>
  // and whatever survives here is POSTed to the app, quoted into the headline, and
  // persisted to memory.db for 45 days — so the list below is the single
  // highest-consequence constant in this file.
  //
  // Five independent gates:
  //   - input[type=password] is never read, ever;
  //   - the HTML autofill vocabulary (autocomplete="cc-number", "one-time-code",
  //     "current-password", …) — the ONE place a payment field reliably identifies
  //     itself. Stripe Elements, Braintree and Shopify checkout name their inputs
  //     "number"/"cardnumber"/nothing, but they all carry an autocomplete token;
  //   - any field whose name/id/label smells like a credential or a payment field;
  //   - input[type=tel] inside a checkout/billing form — that is how card-number
  //     inputs get a numeric keypad, and guessing wrong the other way leaks a PAN;
  //   - anything the site (or the user, via a userscript) marked data-holmes-ignore.

  var SENSITIVE_RE = /pass|phrase|otp|2fa|mfa|cvv|cvc|csc|\bcvn\b|\bssn\b|\bsin\b|secret|token|card|cc[-_]?(num|number|no|exp|csc|code|name|type)|creditcard|iban|swift|sort[-_ ]?code|routing|account|acct|\bpin\b|mnemonic|seed|private[-_ ]?key|security[-_ ]?(code|answer)|expir/i;

  // Exact autocomplete tokens that are always sensitive. Anything starting with
  // "cc-" is treated the same way without being enumerated, so a token added to the
  // spec later still redacts.
  var SENSITIVE_AUTOCOMPLETE = {
    "cc-number": 1, "cc-exp": 1, "cc-exp-month": 1, "cc-exp-year": 1, "cc-csc": 1,
    "cc-name": 1, "cc-given-name": 1, "cc-family-name": 1, "cc-additional-name": 1,
    "cc-type": 1, "current-password": 1, "new-password": 1, "one-time-code": 1
  };

  var CHECKOUT_RE = /checkout|payment|billing|purchase|donate|subscribe|\border\b|\bpay\b|\bcart\b/i;
  var REDACTED = "[redacted]";

  // "shipping cc-number", "section-pay cc-csc" — autocomplete is a token LIST, and
  // real checkouts use the sectioned form.
  function hasSensitiveAutocomplete(value) {
    var tokens = String(value || "").trim().toLowerCase().split(/\s+/);
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i];
      if (!t) continue;
      if (SENSITIVE_AUTOCOMPLETE[t] === 1) return true;
      if (t.indexOf("cc-") === 0) return true;
    }
    return false;
  }

  // Is this element inside something that looks like a checkout? Deliberately
  // coarse: over-redacting a phone number costs one field of context, under-
  // redacting costs a card number.
  function isPaymentContext(el) {
    try {
      var form = el.closest ? el.closest("form") : null;
      var bag = [
        form ? form.getAttribute("action") : "",
        form ? form.getAttribute("id") : "",
        form ? form.getAttribute("name") : "",
        form ? String(form.className || "") : "",
        location.pathname,
        location.hostname
      ].filter(Boolean).join(" ");
      return CHECKOUT_RE.test(bag);
    } catch (e) {
      return true;
    }
  }

  function isRedactedElement(el) {
    try {
      if (!el || el.nodeType !== 1) return false;
      var type = el.tagName === "INPUT" ? String(el.type).toLowerCase() : "";
      if (type === "password") return true;
      if (el.closest && el.closest("[data-holmes-ignore]")) return true;
      if (hasSensitiveAutocomplete(el.getAttribute("autocomplete"))) return true;
      if (type === "tel" && isPaymentContext(el)) return true;
      var bag = [
        el.getAttribute("name"),
        el.id,
        el.getAttribute("autocomplete"),
        el.getAttribute("aria-label"),
        el.getAttribute("placeholder"),
        el.getAttribute("data-testid"),
        el.getAttribute("aria-labelledby")
      ].filter(Boolean).join(" ");
      return SENSITIVE_RE.test(bag);
    } catch (e) {
      // If we cannot prove a field is safe, treat it as unsafe.
      return true;
    }
  }

  // Self-test. The redaction list is the one constant here whose silent decay is
  // unrecoverable — a card number that escapes is already in the app's database by
  // the time anyone notices. So it checks itself once at load: microseconds, and it
  // fails loudly in the console rather than quietly in production.
  (function selfTestRedaction() {
    try {
      var mustRedact = [
        "password", "current-password", "new-password", "one-time-code",
        "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc", "cc-name",
        "cardnumber", "creditCardNumber", "cvv", "cvc", "csc", "expiry",
        "ssn", "sin", "iban", "routingNumber", "accountNumber", "sort-code",
        "pin", "otp", "2fa", "mfa", "seedPhrase", "mnemonic", "private-key",
        "api_token", "clientSecret", "security-code", "security answer"
      ];
      var mustNotRedact = [
        "email", "subject", "message", "search", "firstName", "lastName",
        "comment", "title", "body", "address-line1", "city", "postal-code"
      ];
      var leaked = [];
      for (var i = 0; i < mustRedact.length; i++) {
        var s = mustRedact[i];
        if (!SENSITIVE_RE.test(s) && !hasSensitiveAutocomplete(s)) leaked.push(s);
      }
      var overreach = [];
      for (var j = 0; j < mustNotRedact.length; j++) {
        var v = mustNotRedact[j];
        if (SENSITIVE_RE.test(v) || hasSensitiveAutocomplete(v)) overreach.push(v);
      }
      if (leaked.length) {
        console.error("[Holmes] REDACTION SELF-TEST FAILED — these are no longer redacted: " + leaked.join(", "));
      }
      if (overreach.length) {
        console.warn("[Holmes] redaction self-test: now over-redacting " + overreach.join(", "));
      }
    } catch (e) { /* a broken self-test must never break the page */ }
  })();

  // MARK: - Small utilities

  function squish(s) {
    if (!s) return "";
    return String(s)
      .replace(/[ \t ]+/g, " ")
      .replace(/ *\n */g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  function clip(s, n) {
    s = String(s || "");
    if (s.length <= n) return s;
    return s.slice(0, Math.max(0, n - 1)).trimEnd() + "…";
  }

  function oneLine(s, n) {
    return clip(squish(s).replace(/\n+/g, " · "), n || 140);
  }

  function qs(sel, root) {
    try { return (root || document).querySelector(sel); } catch (e) { return null; }
  }

  function qsa(sel, root) {
    try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); } catch (e) { return []; }
  }

  // First selector in the list that matches something. Site DOMs churn constantly, so
  // every adapter passes a fallback chain rather than a single brittle selector.
  function qsAny(selectors, root) {
    for (var i = 0; i < selectors.length; i++) {
      var el = qs(selectors[i], root);
      if (el) return el;
    }
    return null;
  }

  function isHidden(el) {
    try {
      if (!el || el.nodeType !== 1) return false;
      if (el.hidden) return true;
      if (el.getAttribute("aria-hidden") === "true") return true;
      // Layout is already computed at document_idle, so these reads are cheap; we avoid
      // getComputedStyle entirely because it is the expensive one on huge pages.
      if (el.offsetWidth === 0 && el.offsetHeight === 0 && el.getClientRects().length === 0) return true;
      return false;
    } catch (e) { return false; }
  }

  function txt(el, max) {
    if (!el) return "";
    var raw = "";
    try { raw = el.innerText || el.textContent || ""; } catch (e) { raw = ""; }
    return clip(squish(raw), max || MAX_BODY_TEXT);
  }

  function attr(el, name) {
    try { return (el && el.getAttribute(name)) || ""; } catch (e) { return ""; }
  }

  function wordCount(s) {
    s = squish(s);
    if (!s) return 0;
    return s.split(/\s+/).length;
  }

  // FNV-1a. Only used for dedupe + fingerprints, so speed beats cryptographic strength.
  function hash32(str) {
    var h = 0x811c9dc5;
    for (var i = 0; i < str.length; i++) {
      h ^= str.charCodeAt(i);
      h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    }
    return ("00000000" + h.toString(16)).slice(-8);
  }

  function fmtTime(seconds) {
    if (!isFinite(seconds) || seconds < 0) return "0:00";
    var s = Math.floor(seconds % 60);
    var m = Math.floor((seconds / 60) % 60);
    var h = Math.floor(seconds / 3600);
    var mm = h > 0 && m < 10 ? "0" + m : String(m);
    var ss = s < 10 ? "0" + s : String(s);
    return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss;
  }

  function put(entities, key, value) {
    if (value === null || value === undefined) return;
    var v = squish(String(value));
    if (!v) return;
    entities[key] = clip(v, 300);
  }

  // MARK: - Location helpers

  var HOST = "";
  var PATH = "";
  var SEG = [];

  function refreshLocation() {
    try {
      HOST = String(location.hostname || "").replace(/^www\./i, "").toLowerCase();
      PATH = String(location.pathname || "");
      SEG = PATH.split("/").filter(Boolean);
    } catch (e) {
      HOST = ""; PATH = ""; SEG = [];
    }
  }
  refreshLocation();

  function hostMatches(patterns) {
    for (var i = 0; i < patterns.length; i++) {
      var p = patterns[i];
      if (p.indexOf("*.") === 0) {
        var suffix = p.slice(1); // ".shopify.com"
        if (HOST.length > suffix.length && HOST.slice(-suffix.length) === suffix) return true;
      } else if (p.slice(-2) === ".*") {
        // "amazon.*" — any TLD (amazon.co.uk) and any subdomain (smile.amazon.com).
        var prefix = p.slice(0, -1); // "amazon."
        if (HOST === p.slice(0, -2) || HOST.indexOf(prefix) === 0 || HOST.indexOf("." + prefix) > -1) return true;
      } else if (HOST === p || HOST.slice(-(p.length + 1)) === "." + p) {
        return true;
      }
    }
    return false;
  }

  var BROWSER = (function () {
    var ua = navigator.userAgent || "";
    if (/Comet/i.test(ua)) return "Comet";
    if (/Edg\//.test(ua)) return "Edge";
    if (/OPR\//.test(ua)) return "Opera";
    if (navigator.brave || /Brave/i.test(ua)) return "Brave";
    if (/Arc\//i.test(ua)) return "Arc";
    if (/Chrome\//.test(ua)) return "Chrome";
    if (/Safari\//.test(ua)) return "Safari";
    return "Browser";
  })();

  // MARK: - Text extraction (Readability-lite)

  // Subtrees that are never article content. FILTER_REJECT on a TreeWalker skips the
  // whole subtree in one step, which is what makes this cheap enough to run inline.
  var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, NAV: 1, FOOTER: 1, ASIDE: 1, BUTTON: 1, SELECT: 1, OPTION: 1, IFRAME: 1, CANVAS: 1 };
  var SKIP_ROLES = { navigation: 1, banner: 1, contentinfo: 1, complementary: 1, search: 1, toolbar: 1, tablist: 1, menu: 1, menubar: 1 };
  var BLOCK_TAGS = { P: 1, DIV: 1, LI: 1, TR: 1, SECTION: 1, ARTICLE: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, BLOCKQUOTE: 1, PRE: 1, BR: 1, TD: 1, DD: 1, DT: 1 };

  function collectText(root, maxChars, budget) {
    if (!root) return "";
    var out = [];
    var total = 0;
    var seen = 0;
    var nodeBudget = budget || 20000;
    var walker;
    try {
      walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: function (node) {
          if (node.nodeType === 3) return NodeFilter.FILTER_ACCEPT;
          var el = node;
          if (SKIP_TAGS[el.tagName]) return NodeFilter.FILTER_REJECT;
          if (el.hasAttribute("data-holmes-ignore")) return NodeFilter.FILTER_REJECT;
          var role = el.getAttribute("role");
          if (role && SKIP_ROLES[role]) return NodeFilter.FILTER_REJECT;
          if (isHidden(el)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
    } catch (e) { return txt(root, maxChars); }

    var node;
    while ((node = walker.nextNode())) {
      if (++seen > nodeBudget || total >= maxChars) break;
      if (node.nodeType === 3) {
        var t = node.nodeValue;
        if (!t) continue;
        t = t.replace(/[ \t ]+/g, " ");
        if (!t.trim()) continue;
        out.push(t);
        total += t.length;
      } else if (BLOCK_TAGS[node.tagName]) {
        out.push("\n");
      }
    }
    return clip(squish(out.join("")), maxChars);
  }

  // Density score: real prose beats link farms. We reward paragraph count and length and
  // punish link-heavy blocks (nav lists, related-articles rails, comment sidebars).
  function scoreCandidate(el) {
    try {
      var text = collectText(el, 20000, 8000);
      var len = text.length;
      if (len < 120) return { score: 0, text: text };
      var paras = qsa("p", el).length;
      var links = qsa("a", el).length;
      var linkChars = 0;
      var anchors = qsa("a", el);
      for (var i = 0; i < anchors.length && i < 200; i++) {
        linkChars += (anchors[i].textContent || "").length;
      }
      var linkDensity = Math.min(1, linkChars / Math.max(1, len));
      var score = len * (1 + Math.min(1, paras / 10)) * (1 - 0.8 * linkDensity);
      if (links > 60 && paras < 3) score *= 0.25; // almost certainly a nav / index block
      return { score: score, text: text };
    } catch (e) {
      return { score: 0, text: "" };
    }
  }

  function extractArticle() {
    var candidates = qsa("article, main, [role=main], #content, #main, #main-content, .content, .post, .entry-content, [itemprop=articleBody]");
    if (candidates.length > 12) candidates = candidates.slice(0, 12);
    if (document.body) candidates.push(document.body);
    var best = { score: 0, text: "" };
    for (var i = 0; i < candidates.length; i++) {
      if (isHidden(candidates[i])) continue;
      var r = scoreCandidate(candidates[i]);
      if (r.score > best.score) best = r;
    }
    return clip(best.text, MAX_BODY_TEXT);
  }

  // MARK: - Focus, selection, media, dialogs, scroll

  // Walks shadow roots and (same-origin) iframes, because the element the user is typing
  // into is the single strongest signal we have and it is frequently nested.
  function deepActiveElement() {
    var el = null;
    try { el = document.activeElement; } catch (e) { return null; }
    var guard = 0;
    while (el && guard++ < 10) {
      if (el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; continue; }
      if (el.tagName === "IFRAME") {
        try {
          var inner = el.contentDocument && el.contentDocument.activeElement;
          if (inner && inner !== el.contentDocument.body) { el = inner; continue; }
        } catch (e) { /* cross-origin frame — stop here */ }
      }
      break;
    }
    return el;
  }

  function labelFor(el) {
    if (!el) return "";
    var aria = attr(el, "aria-label");
    if (aria) return squish(aria);
    var labelledBy = attr(el, "aria-labelledby");
    if (labelledBy) {
      var parts = labelledBy.split(/\s+/).map(function (id) {
        var n = document.getElementById(id);
        return n ? squish(n.textContent || "") : "";
      }).filter(Boolean);
      if (parts.length) return clip(parts.join(" "), 120);
    }
    var ph = attr(el, "placeholder") || attr(el, "data-placeholder") || attr(el, "aria-placeholder");
    if (ph) return squish(ph);
    if (el.id) {
      try {
        var lab = qs('label[for="' + (window.CSS && CSS.escape ? CSS.escape(el.id) : el.id) + '"]');
        if (lab) return clip(squish(lab.textContent || ""), 120);
      } catch (e) { /* an id that cannot be escaped is not worth a label lookup */ }
    }
    try {
      var wrapping = el.closest && el.closest("label");
      if (wrapping) return clip(squish(wrapping.textContent || ""), 120);
    } catch (e) { /* ignore */ }
    var name = attr(el, "name") || attr(el, "data-testid");
    if (name) return squish(name);
    return "";
  }

  function isEditableElement(el) {
    if (!el || el.nodeType !== 1) return false;
    var tag = el.tagName;
    if (tag === "TEXTAREA") return true;
    if (tag === "SELECT") return true;
    if (tag === "INPUT") {
      var t = String(el.type || "text").toLowerCase();
      return ["button", "submit", "reset", "image", "checkbox", "radio", "file", "hidden", "range", "color"].indexOf(t) === -1;
    }
    try {
      if (el.isContentEditable) return true;
      // Explicit attribute fallback: some editors (Slate, ProseMirror, Quill) mount the
      // editable host inside a shadow root or re-parent it, and the inherited
      // isContentEditable property is not always reflected by the time we read it.
      var ce = el.getAttribute("contenteditable");
      if (ce === "" || String(ce).toLowerCase() === "true") return true;
      if (el.getAttribute("role") === "textbox") return true;
      return !!(el.closest && el.closest('[contenteditable="true"], [contenteditable=""]'));
    } catch (e) { return false; }
  }

  // True when the element edits rich text rather than exposing a .value string.
  function isRichEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") return false;
    return isEditableElement(el);
  }

  function elementValue(el) {
    if (!el) return "";
    if (isRedactedElement(el)) return REDACTED;
    var tag = el.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA") return clip(squish(el.value || ""), 2000);
    if (tag === "SELECT") {
      var opt = el.selectedOptions && el.selectedOptions[0];
      return opt ? squish(opt.textContent || "") : "";
    }
    return clip(squish(el.innerText || el.textContent || ""), 2000);
  }

  function focusedField() {
    var el = deepActiveElement();
    if (!el || el === document.body || el === document.documentElement) return null;
    if (!isEditableElement(el)) {
      // A focused non-editable is still useful (a link/button the user tabbed to), but
      // only when it carries a real label — otherwise it is noise.
      var lbl = labelFor(el) || clip(squish(el.innerText || el.textContent || ""), 80);
      if (!lbl) return null;
      return {
        role: String(el.tagName || "").toLowerCase(),
        label: lbl,
        value: "",
        isEditable: false
      };
    }
    var role = String(el.tagName || "").toLowerCase();
    if (el.tagName === "INPUT") role = "input[" + String(el.type || "text").toLowerCase() + "]";
    else if (isRichEditable(el)) role = "contenteditable";
    return {
      role: role,
      label: labelFor(el) || role,
      value: elementValue(el),
      isEditable: true
    };
  }

  function selectionText() {
    try {
      var sel = window.getSelection();
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) return "";
      var node = sel.anchorNode;
      var host = node && (node.nodeType === 1 ? node : node.parentElement);
      if (host && host.closest && host.closest("[data-holmes-ignore]")) return "";
      return clip(squish(sel.toString()), 1200);
    } catch (e) { return ""; }
  }

  // Returns the most relevant media element: whatever is actually playing, else the
  // largest one that has been played at all.
  function mediaState(defaultTitle) {
    try {
      var els = qsa("video, audio");
      if (!els.length) return null;
      var chosen = null;
      for (var i = 0; i < els.length; i++) {
        var m = els[i];
        if (!isFinite(m.duration) || m.duration <= 0) continue;
        if (!chosen) { chosen = m; continue; }
        var chosenPlaying = !chosen.paused && !chosen.ended;
        var candidatePlaying = !m.paused && !m.ended;
        if (candidatePlaying && !chosenPlaying) { chosen = m; continue; }
        if (candidatePlaying === chosenPlaying && m.duration > chosen.duration) chosen = m;
      }
      if (!chosen) return null;
      return {
        title: clip(squish(defaultTitle || chosen.title || document.title || ""), 200),
        positionSeconds: Math.max(0, Math.round((chosen.currentTime || 0) * 10) / 10),
        durationSeconds: Math.max(0, Math.round((chosen.duration || 0) * 10) / 10),
        isPlaying: !chosen.paused && !chosen.ended
      };
    } catch (e) { return null; }
  }

  function openDialogText() {
    try {
      var dialogs = qsa("dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]");
      for (var i = dialogs.length - 1; i >= 0; i--) {
        if (isHidden(dialogs[i])) continue;
        var t = collectText(dialogs[i], 900, 3000);
        if (t.length > 10) return t;
      }
    } catch (e) { /* ignore */ }
    return "";
  }

  function scrollPercent() {
    try {
      var doc = document.documentElement;
      var max = Math.max(0, (doc.scrollHeight || 0) - window.innerHeight);
      if (max < 40) return 0; // an app shell that scrolls internally, not a long document
      return Math.max(0, Math.min(100, Math.round((window.scrollY / max) * 100)));
    } catch (e) { return 0; }
  }

  // The heading immediately above the fold — "where in this document am I".
  function currentHeading() {
    try {
      var heads = qsa("h1, h2, h3, [role=heading]");
      var current = "";
      for (var i = 0; i < heads.length && i < 400; i++) {
        var h = heads[i];
        if (isHidden(h)) continue;
        var top = h.getBoundingClientRect().top;
        if (top <= 140) current = squish(h.innerText || h.textContent || "");
        else break;
      }
      return clip(current, 160);
    } catch (e) { return ""; }
  }

  function metaContent(names) {
    for (var i = 0; i < names.length; i++) {
      var el = qs('meta[property="' + names[i] + '"], meta[name="' + names[i] + '"]');
      var c = attr(el, "content");
      if (c) return squish(c);
    }
    return "";
  }

  function canonicalURL() {
    var el = qs('link[rel="canonical"]');
    var href = attr(el, "href");
    return href || location.href;
  }

  function pageTitle() {
    return squish(document.title || "");
  }

  // MARK: - Generic signal bag
  //
  // Computed once per capture and handed to whichever adapter runs, so adapters can lean
  // on the generic signals (typed text, selection, media) without recomputing them. The
  // expensive ones (article extraction) are lazy — a chat adapter never pays for them.

  function makeSignals() {
    var cache = {};
    var g = {
      focused: focusedField(),
      selection: selectionText(),
      dialog: openDialogText(),
      scroll: scrollPercent(),
      heading: currentHeading(),
      title: pageTitle(),
      url: location.href,
      canonical: canonicalURL(),
      ogTitle: metaContent(["og:title", "twitter:title"]),
      description: metaContent(["description", "og:description", "twitter:description"]),
      siteName: metaContent(["og:site_name"])
    };
    Object.defineProperty(g, "article", {
      get: function () {
        if (!("article" in cache)) cache.article = extractArticle();
        return cache.article;
      }
    });
    Object.defineProperty(g, "h1", {
      get: function () {
        if (!("h1" in cache)) {
          var h = qsa("h1").filter(function (e) { return !isHidden(e); })[0];
          cache.h1 = h ? clip(squish(h.innerText || h.textContent || ""), 200) : "";
        }
        return cache.h1;
      }
    });
    return g;
  }

  // The text the user is currently typing, if any. Adapters use this constantly, because
  // "what is being typed" outranks everything else as an activity signal.
  function typedText(g) {
    if (g.focused && g.focused.isEditable && g.focused.value && g.focused.value !== REDACTED) return g.focused.value;
    return "";
  }

  // MARK: - Thread helpers (chat-shaped adapters)
  //
  // "Did the USER write this line?" is the single most consequential fact a chat
  // adapter publishes. Holmes drafts replies to INBOUND messages, and a reply
  // drafted to the user's own words is the worst thing the feature can produce —
  // so every chat adapter answers it from DOM ground truth (an outgoing-bubble
  // class where the site has one, otherwise the signed-in account name the site
  // renders in its own chrome) and publishes the answer for the LAST line as
  // `lastFromMe`. A speaker LABEL is not that ground truth: Slack, Discord and
  // WhatsApp all label the user's own messages with their service display name,
  // which is not the macOS account name the app can check.
  //
  // When an adapter cannot tell, it publishes NOTHING and the macOS side fails
  // closed. Silence is a correct answer; a guess is not.

  function message(speaker, text, fromMe) {
    var m = { speaker: clip(squish(speaker || ""), 80), text: clip(squish(text || ""), MAX_MESSAGE_CHARS) };
    // Only ever set when it is KNOWN — an absent flag is not a claim of either.
    if (fromMe === true || fromMe === false) m.fromMe = fromMe;
    return m;
  }

  // Does this row, or anything inside it, carry this class? Message rows are
  // sometimes the wrapper and sometimes the bubble, depending on which selector
  // matched, so an outgoing/incoming marker has to be looked for both ways.
  function hasClassDeep(row, cls) {
    try {
      if (!row || row.nodeType !== 1) return false;
      if (row.classList.contains(cls)) return true;
      return !!qs("." + cls, row);
    } catch (e) { return false; }
  }

  // Same name, ignoring case and stray whitespace. Used to recognize the user's
  // own messages by comparing a bubble's author with the account name the site
  // shows for whoever is signed in.
  function sameSpeaker(a, b) {
    a = squish(String(a || "")).toLowerCase();
    b = squish(String(b || "")).toLowerCase();
    return !!a && !!b && a === b;
  }

  // The display name of the SIGNED-IN account, read from the site's own chrome.
  // `strip` removes the framing a site wraps it in ("User menu: Alex Rivera").
  function accountName(selectors, strip) {
    for (var i = 0; i < selectors.length; i++) {
      var sel = selectors[i];
      var el = qs(sel.q, document);
      if (!el) continue;
      var raw = sel.attr ? attr(el, sel.attr) : txt(el, 80);
      raw = squish(raw);
      if (strip) raw = squish(raw.replace(strip, ""));
      if (raw) return clip(raw, 80);
    }
    return "";
  }

  // Publishes the from-me marker for the last line of a transcript. Absent when
  // the adapter could not attribute that line — see the note above.
  function putLastFromMe(entities, thread) {
    var last = lastFrom(thread);
    if (!last || typeof last.fromMe !== "boolean") return;
    put(entities, "lastFromMe", last.fromMe ? "yes" : "no");
  }

  function lastMessages(nodes, mapper, limit) {
    var out = [];
    var n = Math.min(nodes.length, limit || MAX_THREAD_MESSAGES);
    for (var i = nodes.length - n; i < nodes.length; i++) {
      if (i < 0) continue;
      try {
        var m = mapper(nodes[i]);
        if (m && m.text) out.push(m);
      } catch (e) { /* one malformed row must not kill the thread */ }
    }
    return out;
  }

  function threadDetail(thread) {
    if (!thread || !thread.length) return "";
    return thread.map(function (m) {
      return (m.speaker ? m.speaker + ": " : "") + m.text;
    }).join("\n");
  }

  function lastFrom(thread) {
    if (!thread || !thread.length) return null;
    return thread[thread.length - 1];
  }

  // MARK: - Site adapters
  //
  // Each adapter returns a partial context. `headline` is a literal sentence assembled
  // from values we actually read — if a value is missing the sentence changes shape
  // rather than inventing the value.

  var ADAPTERS = [];

  function adapter(id, hosts, run) {
    ADAPTERS.push({ id: id, hosts: hosts, run: run });
  }

  // MARK: Gmail
  //
  // Gmail's class names are obfuscated but the ones used here (hP subject, gD sender,
  // a3s message body, zA/zE list rows, bog subject cell, yP/zF sender cell) have been
  // stable for the better part of a decade. If Gmail ever breaks them, the adapter
  // degrades to the inbox branch rather than lying.
  adapter("gmail", ["mail.google.com"], function (g) {
    var entities = {};

    // --- Compose ---
    var composeRoots = qsa('[role="dialog"], div.nH.Hd, div.AD').filter(function (el) {
      return !isHidden(el) && (qs('input[name="subjectbox"]', el) || qs('[g_editable="true"]', el) || qs('[aria-label="Message Body"]', el));
    });
    if (composeRoots.length) {
      var box = composeRoots[composeRoots.length - 1];
      var chips = qsa('span[email], [data-hovercard-id]', box).map(function (el) {
        return attr(el, "email") || attr(el, "data-hovercard-id");
      }).filter(Boolean);
      var toInput = qs('input[name="to"], textarea[name="to"]', box);
      var to = chips.length ? chips.join(", ") : squish(toInput ? toInput.value : "");
      var cc = qsa('input[name="cc"], textarea[name="cc"]', box).map(function (el) { return squish(el.value); }).filter(Boolean).join(", ");
      var subjEl = qs('input[name="subjectbox"], input[placeholder="Subject"]', box);
      var subject = squish(subjEl ? subjEl.value : "");
      var bodyEl = qs('[aria-label="Message Body"], [g_editable="true"], div.Am.Al.editable, [contenteditable="true"]', box);
      var body = txt(bodyEl, MAX_BODY_TEXT);

      put(entities, "to", to);
      put(entities, "cc", cc);
      put(entities, "subject", subject);
      put(entities, "draftWords", wordCount(body));

      var who = to ? " to " + to : " — no recipient yet";
      var subjPart = subject ? ' with subject "' + subject + '"' : " with an empty subject line";
      var bodyPart = body ? ", " + wordCount(body) + " words drafted" : ", body still empty";
      return {
        activity: "composing",
        headline: "Composing an email in Gmail" + who + subjPart + bodyPart,
        detail: "To: " + (to || "(empty)") + (cc ? "\nCc: " + cc : "") + "\nSubject: " + (subject || "(empty)") + "\n\n" + body,
        entities: entities,
        bodyText: body,
        legacy: { type: "gmail_compose", recipient: to, subject: subject, body: body }
      };
    }

    // --- Reading an open thread ---
    var subjectEl = qsAny(["h2.hP", '[data-thread-perm-id] h2', "h2[data-legacy-thread-id]"]);
    var openSubject = txt(subjectEl, 220);
    if (openSubject) {
      var senderEl = qsAny([".gD", ".go", "span[email]"]);
      var senderName = squish(attr(senderEl, "name") || (senderEl ? senderEl.innerText : ""));
      var senderEmail = attr(senderEl, "email");
      var messages = qsa("div.adn.ads, .h7").filter(function (el) { return !isHidden(el); });
      var bodyEl2 = qsa("div.a3s.aiL, div.a3s").filter(function (el) { return !isHidden(el); }).pop();
      var mailBody = collectText(bodyEl2, MAX_BODY_TEXT, 12000);

      put(entities, "subject", openSubject);
      put(entities, "sender", senderName);
      put(entities, "senderEmail", senderEmail);
      put(entities, "messagesInThread", messages.length || 1);

      var whoStr = senderName && senderEmail ? senderName + " <" + senderEmail + ">" : (senderName || senderEmail || "an unnamed sender");
      var countStr = messages.length > 1 ? " (" + messages.length + " messages in the thread)" : "";
      return {
        activity: "reading",
        headline: 'Reading a Gmail message from ' + whoStr + ' — "' + openSubject + '"' + countStr,
        detail: "From: " + whoStr + "\nSubject: " + openSubject + "\n\n" + mailBody,
        entities: entities,
        bodyText: mailBody,
        legacy: { type: "gmail_read", sender: senderEmail || senderName, subject: openSubject, body: mailBody }
      };
    }

    // --- Inbox / list view ---
    var rows = qsa("tr.zA").filter(function (el) { return !isHidden(el); });
    var unread = rows.filter(function (r) { return r.classList.contains("zE"); });
    var top = rows[0];
    var topSubject = top ? txt(qs(".bog", top), 160) : "";
    var topSender = top ? squish(attr(qs(".yP, .zF", top), "email") || txt(qs(".yP, .zF", top), 80)) : "";
    var label = squish((pageTitle().split(" - ")[0]) || "Inbox");

    put(entities, "mailbox", label);
    put(entities, "unreadCount", unread.length);
    put(entities, "visibleRows", rows.length);
    put(entities, "topSubject", topSubject);
    put(entities, "topSender", topSender);

    if (!rows.length) {
      return {
        activity: "other",
        headline: "Gmail is open at " + (label || "the mailbox") + " but no message list has rendered yet",
        detail: "URL: " + location.href,
        entities: entities,
        bodyText: "",
        legacy: { type: "gmail_inbox", subject: label }
      };
    }
    var newest = topSubject ? ' — newest: "' + topSubject + '"' + (topSender ? " from " + topSender : "") : "";
    return {
      activity: "reading",
      headline: "Scanning the Gmail " + label + " — " + unread.length + " unread of " + rows.length + " visible" + newest,
      detail: rows.slice(0, 12).map(function (r) {
        var s = txt(qs(".bog", r), 90);
        var f = txt(qs(".yP, .zF", r), 40);
        return (r.classList.contains("zE") ? "• " : "  ") + (f ? f + " — " : "") + s;
      }).join("\n"),
      entities: entities,
      bodyText: "",
      legacy: { type: "gmail_inbox", subject: label, sender: topSender, body: topSubject }
    };
  });

  // MARK: X / Twitter
  //
  // X is a React app with stable data-testid hooks — these are the most reliable
  // selectors on the site and survive redesigns far better than class names.
  adapter("x", ["x.com", "twitter.com"], function (g) {
    var entities = {};
    var typing = typedText(g);
    var composer = qsAny(['[data-testid="tweetTextarea_0"]', '[data-testid="tweetTextarea_0RichTextInputContainer"]']);
    var composerText = composer ? txt(composer, 1000) : "";
    var draft = typing || composerText;

    function readTweet(article) {
      var nameBlock = qs('[data-testid="User-Name"]', article);
      var spans = nameBlock ? qsa("span", nameBlock).map(function (s) { return squish(s.textContent); }).filter(Boolean) : [];
      var handle = "";
      for (var i = 0; i < spans.length; i++) { if (spans[i].charAt(0) === "@") { handle = spans[i]; break; } }
      var display = spans.length ? spans[0] : "";
      var link = qs('a[href*="/status/"]', article);
      var href = attr(link, "href");
      var idMatch = href.match(/status\/(\d+)/);
      return {
        display: display && display.charAt(0) !== "@" ? display : "",
        handle: handle,
        text: txt(qs('[data-testid="tweetText"]', article), 700),
        id: idMatch ? idMatch[1] : "",
        replies: txt(qs('[data-testid="reply"]', article), 20),
        likes: txt(qs('[data-testid="like"]', article), 20)
      };
    }

    var isStatus = /\/status\/\d+/.test(PATH);
    var articles = qsa('article[data-testid="tweet"]').filter(function (el) { return !isHidden(el); });

    // --- Composing (reply or new post) ---
    if (draft) {
      var replyTarget = isStatus && articles.length ? readTweet(articles[0]) : null;
      put(entities, "draft", draft);
      if (replyTarget) {
        put(entities, "replyingTo", replyTarget.handle || replyTarget.display);
        put(entities, "replyingToPost", replyTarget.text);
        return {
          activity: "composing",
          headline: 'Typing a reply to ' + (replyTarget.handle || replyTarget.display || "a post") + ' on ' + HOST + ': "' + oneLine(draft, 120) + '"',
          detail: "Replying to " + (replyTarget.display || "") + " " + replyTarget.handle + ":\n" + replyTarget.text + "\n\nDraft:\n" + draft,
          entities: entities,
          bodyText: draft,
          thread: replyTarget.text ? [message(replyTarget.handle || replyTarget.display, replyTarget.text)] : []
        };
      }
      return {
        activity: "composing",
        headline: 'Typing a new post on ' + HOST + ': "' + oneLine(draft, 140) + '"',
        detail: "Draft post:\n" + draft,
        entities: entities,
        bodyText: draft
      };
    }

    // --- Single post ---
    if (isStatus && articles.length) {
      var main = readTweet(articles[0]);
      var replies = articles.slice(1, 6).map(function (a) {
        var t = readTweet(a);
        return message(t.handle || t.display, t.text);
      }).filter(function (m) { return m.text; });
      put(entities, "author", main.display);
      put(entities, "handle", main.handle);
      put(entities, "postId", main.id);
      put(entities, "replyCount", replies.length);
      var author = main.display && main.handle ? main.display + " (" + main.handle + ")" : (main.handle || main.display || "an unnamed account");
      return {
        activity: "reading",
        headline: 'Reading a post by ' + author + ' on ' + HOST + ': "' + oneLine(main.text || "(no text — media only)", 120) + '"',
        detail: author + ":\n" + main.text + (replies.length ? "\n\nReplies:\n" + threadDetail(replies) : ""),
        entities: entities,
        bodyText: main.text,
        thread: [message(main.handle || main.display, main.text)].concat(replies)
      };
    }

    // --- Timeline / profile / search ---
    var kind = "timeline";
    var where = "the timeline";
    if (PATH === "/home") { kind = "home"; where = "the Home timeline"; }
    else if (PATH.indexOf("/search") === 0) {
      kind = "search";
      var qParam = "";
      try { qParam = new URLSearchParams(location.search).get("q") || ""; } catch (e) { qParam = ""; }
      where = qParam ? 'search results for "' + qParam + '"' : "search results";
      put(entities, "query", qParam);
    } else if (PATH.indexOf("/messages") === 0) { kind = "messages"; where = "Direct Messages"; }
    else if (PATH.indexOf("/notifications") === 0) { kind = "notifications"; where = "Notifications"; }
    else if (SEG.length === 1) { kind = "profile"; where = "the @" + SEG[0] + " profile"; put(entities, "profile", "@" + SEG[0]); }

    var topPosts = articles.slice(0, 5).map(function (a) {
      var t = readTweet(a);
      return message(t.handle || t.display, t.text);
    }).filter(function (m) { return m.text; });

    put(entities, "section", kind);
    put(entities, "visiblePosts", articles.length);

    if (!topPosts.length) {
      return {
        activity: "browsing",
        headline: "On " + HOST + " at " + where + " — no posts have rendered yet",
        detail: "URL: " + location.href,
        entities: entities,
        bodyText: ""
      };
    }
    var first = topPosts[0];
    return {
      activity: kind === "search" ? "searching" : "reading",
      headline: "Scrolling " + where + " on " + HOST + " — top post by " + (first.speaker || "an unnamed account") + ': "' + oneLine(first.text, 100) + '"',
      detail: threadDetail(topPosts),
      entities: entities,
      bodyText: topPosts.map(function (m) { return m.speaker + ": " + m.text; }).join("\n\n"),
      thread: topPosts
    };
  });

  // MARK: LinkedIn
  //
  // LinkedIn ships both a legacy class scheme (msg-*, feed-shared-*) and newer
  // artdeco components. The msg-* names below are the stable ones in messaging.
  adapter("linkedin", ["linkedin.com"], function (g) {
    var entities = {};
    var typing = typedText(g);

    // --- Messaging ---
    if (PATH.indexOf("/messaging") === 0) {
      var who = txt(qsAny([
        ".msg-entity-lockup__entity-title",
        ".msg-thread__link-to-profile",
        ".msg-title-bar h2",
        '[data-testid="conversation-title"]'
      ]), 120);
      var rows = qsa(".msg-s-event-listitem, .msg-s-message-list__event").filter(function (el) { return !isHidden(el); });
      var thread = lastMessages(rows, function (row) {
        var speaker = txt(qs(".msg-s-message-group__name, .msg-s-event-listitem__name", row), 80);
        var body = txt(qs(".msg-s-event-listitem__body, .msg-s-event__content", row), MAX_MESSAGE_CHARS);
        // LinkedIn tags INCOMING rows with `--other`; everything else in the list is
        // the user's own. Reading it in that direction fails closed on purpose: if
        // LinkedIn ever drops the class, every row reads as the user's and Holmes
        // goes quiet rather than drafting a reply to the user's own words.
        var mine = !(hasClassDeep(row, "msg-s-event-listitem--other"));
        return message(speaker, body, mine);
      }, 8);
      // LinkedIn only labels the first row of a run of consecutive messages, so fill down.
      var lastSpeaker = "";
      for (var i = 0; i < thread.length; i++) {
        if (thread[i].speaker) lastSpeaker = thread[i].speaker;
        else thread[i].speaker = lastSpeaker;
      }
      var draft = typing || txt(qs(".msg-form__contenteditable"), 1000);
      put(entities, "correspondent", who);
      put(entities, "messageCount", thread.length);
      putLastFromMe(entities, thread);
      if (draft) {
        put(entities, "draft", draft);
        return {
          activity: "composing",
          headline: 'Typing a LinkedIn message to ' + (who || "an unnamed contact") + ': "' + oneLine(draft, 120) + '"',
          detail: (thread.length ? threadDetail(thread) + "\n\n" : "") + "Draft:\n" + draft,
          entities: entities,
          bodyText: draft,
          thread: thread
        };
      }
      var last = lastFrom(thread);
      return {
        activity: "chatting",
        headline: who
          ? "In a LinkedIn conversation with " + who + (last ? " — last message from " + (last.speaker || "them") + ': "' + oneLine(last.text, 90) + '"' : " — no messages loaded yet")
          : "In LinkedIn messaging — no conversation is open",
        detail: threadDetail(thread),
        entities: entities,
        bodyText: threadDetail(thread),
        thread: thread
      };
    }

    // --- Profile ---
    if (PATH.indexOf("/in/") === 0) {
      var name = txt(qsAny(["h1.text-heading-xlarge", "main h1", "h1"]), 120);
      var tagline = txt(qsAny([".text-body-medium.break-words", ".pv-text-details__left-panel .text-body-medium"]), 200);
      put(entities, "person", name);
      put(entities, "headlineText", tagline);
      return {
        activity: "reading",
        headline: name
          ? "Viewing the LinkedIn profile of " + name + (tagline ? " — " + oneLine(tagline, 90) : "")
          : "On a LinkedIn profile page that has not finished loading",
        detail: (name ? name + "\n" : "") + tagline + "\n\n" + collectText(qs("main"), 2000, 8000),
        entities: entities,
        bodyText: collectText(qs("main"), MAX_BODY_TEXT, 12000)
      };
    }

    // --- Feed / single post ---
    var posts = qsa(".feed-shared-update-v2, [data-urn*='activity']").filter(function (el) { return !isHidden(el); });
    if (posts.length) {
      var p = posts[0];
      var author = txt(qsAny([".update-components-actor__title", ".update-components-actor__name"], p), 120)
        .split("\n")[0];
      var body2 = txt(qsAny([".update-components-text", ".feed-shared-inline-show-more-text"], p), 900);
      put(entities, "author", author);
      put(entities, "postText", oneLine(body2, 200));
      put(entities, "visiblePosts", posts.length);
      var isSingle = PATH.indexOf("/posts/") === 0 || PATH.indexOf("/feed/update") === 0;
      return {
        activity: "reading",
        headline: (isSingle ? "Reading a LinkedIn post by " : "Scrolling the LinkedIn feed — top post by ") +
          (author || "an unnamed author") + ': "' + oneLine(body2 || "(no text)", 110) + '"',
        detail: posts.slice(0, 5).map(function (el) {
          var a = txt(qsAny([".update-components-actor__title"], el), 80).split("\n")[0];
          return a + ": " + txt(qsAny([".update-components-text"], el), 300);
        }).join("\n\n"),
        entities: entities,
        bodyText: body2,
        thread: [message(author, body2)]
      };
    }

    put(entities, "section", SEG[0] || "feed");
    return {
      activity: "browsing",
      headline: "On LinkedIn at /" + (SEG.join("/") || "") + " — the page has not rendered any posts or profile data",
      detail: "Title: " + g.title + "\nURL: " + location.href,
      entities: entities,
      bodyText: collectText(qs("main"), 1500, 8000)
    };
  });

  // MARK: GitHub
  adapter("github", ["github.com"], function (g) {
    var entities = {};
    var owner = SEG[0] || "";
    var repo = SEG[1] || "";
    var slug = owner && repo ? owner + "/" + repo : "";
    put(entities, "owner", owner);
    put(entities, "repo", repo);

    function issueTitle() {
      // bdi.js-issue-title is the classic markup; the React issues rewrite uses
      // data-testid="issue-title". Both are checked so either shell works.
      return txt(qsAny(["bdi.js-issue-title", ".js-issue-title", '[data-testid="issue-title"]', 'h1 .markdown-title', "h1"]), 220);
    }
    function stateLabel() {
      return txt(qsAny(['[data-testid="header-state"]', ".State", ".gh-header-meta .State"]), 40).toLowerCase();
    }

    // --- Pull request ---
    var prMatch = PATH.match(/\/pull\/(\d+)/);
    if (slug && prMatch) {
      var prNum = prMatch[1];
      var prTitle = issueTitle();
      var state = stateLabel();
      var filesTab = txt(qs("#files_tab_counter"), 12);
      var diffText = txt(qsAny(["#diffstat", ".diffstat", ".js-diff-progressive-container .diffstat"]), 60);
      var adds = txt(qs(".color-fg-success, .text-green"), 20);
      var dels = txt(qs(".color-fg-danger, .text-red"), 20);
      var tab = PATH.indexOf("/files") > -1 ? "the diff" : (PATH.indexOf("/commits") > -1 ? "the commits" : "the conversation");
      put(entities, "pr", "#" + prNum);
      put(entities, "title", prTitle);
      put(entities, "state", state);
      put(entities, "filesChanged", filesTab);
      var stats = [];
      if (filesTab) stats.push(filesTab + " file" + (filesTab === "1" ? "" : "s") + " changed");
      if (adds && /\+/.test(adds)) stats.push(adds);
      if (dels && /−|-/.test(dels)) stats.push(dels);
      if (!stats.length && diffText) stats.push(squish(diffText));
      return {
        activity: "coding",
        headline: "Viewing " + tab + " of pull request #" + prNum + ' "' + (prTitle || "untitled") + '" in ' + slug +
          (state ? " (" + state + ")" : "") + (stats.length ? " — " + stats.join(", ") : ""),
        detail: collectText(qs("#partial-discussion-header") || qs("main"), 2500, 10000),
        entities: entities,
        bodyText: collectText(qs("main"), MAX_BODY_TEXT, 14000)
      };
    }

    // --- Issue ---
    var issueMatch = PATH.match(/\/issues\/(\d+)/);
    if (slug && issueMatch) {
      var isNum = issueMatch[1];
      var isTitle = issueTitle();
      var isState = stateLabel();
      var labels = qsa('.js-issue-labels a, [data-testid="issue-labels"] a').map(function (a) { return squish(a.textContent); }).filter(Boolean);
      put(entities, "issue", "#" + isNum);
      put(entities, "title", isTitle);
      put(entities, "state", isState);
      put(entities, "labels", labels.join(", "));
      return {
        activity: "coding",
        headline: "Reading issue #" + isNum + ' "' + (isTitle || "untitled") + '" in ' + slug +
          (isState ? " (" + isState + ")" : "") + (labels.length ? " — labels: " + labels.join(", ") : ""),
        detail: collectText(qs("main"), 2500, 12000),
        entities: entities,
        bodyText: collectText(qs("main"), MAX_BODY_TEXT, 14000)
      };
    }

    // --- File view ---
    if (slug && (SEG[2] === "blob" || SEG[2] === "tree")) {
      var branch = SEG[3] || "";
      var filePath = SEG.slice(4).join("/");
      var isFile = SEG[2] === "blob";
      var lineInfo = txt(qsAny(['[data-testid="blob-size"]', ".text-mono.f6"]), 80);
      var code = collectText(qsAny(["#read-only-cursor-text-area", ".react-code-lines", "table.highlight", ".Box-body"]), MAX_BODY_TEXT, 20000);
      put(entities, "path", filePath || "(repository root)");
      put(entities, "branch", branch);
      put(entities, "kind", isFile ? "file" : "directory");
      return {
        activity: "coding",
        headline: isFile
          ? "Viewing the file " + slug + "/" + filePath + " on branch " + branch + (lineInfo ? " (" + oneLine(lineInfo, 40) + ")" : "")
          : "Browsing the directory " + slug + "/" + (filePath || "") + " on branch " + branch,
        detail: (filePath ? "Path: " + filePath + "\n" : "") + code,
        entities: entities,
        bodyText: code
      };
    }

    // --- Actions ---
    if (slug && SEG[2] === "actions") {
      var runTitle = txt(qsAny([".PageHeader-title", "h1", ".d-flex .f1"]), 160);
      var status = txt(qsAny(['[data-testid="run-status"]', ".State", ".octicon-check, .octicon-x"]), 40);
      put(entities, "section", "actions");
      put(entities, "run", runTitle);
      return {
        activity: "coding",
        headline: "Viewing GitHub Actions in " + slug + (runTitle ? ' — run "' + runTitle + '"' : " — the workflow run list") + (status ? " (" + status + ")" : ""),
        detail: collectText(qs("main"), 2000, 10000),
        entities: entities,
        bodyText: collectText(qs("main"), MAX_BODY_TEXT, 12000)
      };
    }

    // --- Repo home / everything else on github.com ---
    if (slug) {
      var desc = txt(qsAny(['[data-testid="repository-description"]', ".f4.my-3", ".BorderGrid-cell .f4"]), 300);
      var lang = txt(qs(".Progress + ul li:first-child .text-bold, .BorderGrid-row .color-fg-default"), 40);
      var section = SEG[2] || "code";
      put(entities, "section", section);
      put(entities, "description", desc);
      return {
        activity: "coding",
        headline: "Viewing the " + section + " tab of the repository " + slug + (desc ? " — " + oneLine(desc, 110) : ""),
        detail: (desc ? desc + "\n\n" : "") + collectText(qs("main"), 2000, 10000),
        entities: entities,
        bodyText: collectText(qs("main"), MAX_BODY_TEXT, 12000)
      };
    }

    var ghSection = SEG[0] || "dashboard";
    put(entities, "section", ghSection);
    return {
      activity: "coding",
      headline: g.title
        ? "On GitHub at /" + SEG.join("/") + ' — page titled "' + g.title + '"'
        : "On GitHub at github.com/" + SEG.join("/") + " — no repository, issue or file content has rendered yet",
      detail: collectText(qs("main"), 2000, 10000),
      entities: entities,
      bodyText: collectText(qs("main"), MAX_BODY_TEXT, 12000)
    };
  });

  // MARK: YouTube
  //
  // YouTube is a Polymer app: `ytd-*` element names are the durable hooks, the id-based
  // selectors inside them (#title, #owner) change less often than class names.
  adapter("youtube", ["youtube.com", "youtu.be", "music.youtube.com"], function (g) {
    var entities = {};
    var typing = typedText(g);

    if (PATH.indexOf("/watch") === 0 || HOST === "youtu.be") {
      var title = txt(qsAny([
        "h1.ytd-watch-metadata yt-formatted-string",
        "#title h1",
        "h1.title.ytd-video-primary-info-renderer",
        'meta[name="title"]'
      ]), 200) || metaContent(["og:title"]);
      var channel = txt(qsAny(["#owner #channel-name a", "ytd-channel-name#channel-name a", "#upload-info #channel-name a"]), 120);
      var media = mediaState(title);
      var views = txt(qsAny(["#info-container #info span", "ytd-watch-info-text #info"]), 80);
      put(entities, "video", title);
      put(entities, "channel", channel);
      if (media) {
        put(entities, "position", fmtTime(media.positionSeconds));
        put(entities, "duration", fmtTime(media.durationSeconds));
        put(entities, "playing", media.isPlaying ? "yes" : "no");
      }

      // A typed comment outranks passive watching as the activity.
      var commentBox = qsAny(["#contenteditable-root", "#commentbox #contenteditable-root"]);
      var commentDraft = typing || txt(commentBox, 800);
      if (commentDraft) {
        put(entities, "commentDraft", commentDraft);
        return {
          activity: "composing",
          headline: 'Typing a YouTube comment on "' + (title || "an untitled video") + '": "' + oneLine(commentDraft, 110) + '"',
          detail: "Video: " + title + (channel ? "\nChannel: " + channel : "") + "\n\nComment draft:\n" + commentDraft,
          entities: entities,
          bodyText: commentDraft,
          media: media
        };
      }

      var timePart = media ? " — " + fmtTime(media.positionSeconds) + " of " + fmtTime(media.durationSeconds) + ", " + (media.isPlaying ? "playing" : "paused") : "";
      return {
        activity: "watching",
        headline: title
          ? 'Watching "' + title + '"' + (channel ? " by " + channel : "") + " on YouTube" + timePart
          : "On a YouTube watch page whose title has not loaded yet" + timePart,
        detail: "Video: " + title + "\nChannel: " + channel + (views ? "\n" + views : "") +
          "\n\nDescription:\n" + txt(qsAny(["#description-inline-expander", "#description"]), 1500),
        entities: entities,
        bodyText: txt(qsAny(["#description-inline-expander", "#description"]), MAX_BODY_TEXT),
        media: media
      };
    }

    if (PATH.indexOf("/shorts") === 0) {
      var reel = qsAny(["ytd-reel-video-renderer[is-active]", "ytd-reel-video-renderer"]);
      var shortTitle = txt(qsAny(["h2.title", "#overlay .title", "yt-formatted-string.title"], reel || document), 160);
      var shortChannel = txt(qsAny(["#channel-name a", ".ytReelChannelBarViewModelChannelName"], reel || document), 80);
      var shortMedia = mediaState(shortTitle);
      put(entities, "short", shortTitle);
      put(entities, "channel", shortChannel);
      return {
        activity: "watching",
        headline: 'Watching a YouTube Short' + (shortTitle ? ' — "' + shortTitle + '"' : "") + (shortChannel ? " by " + shortChannel : ""),
        detail: "Short: " + shortTitle + "\nChannel: " + shortChannel,
        entities: entities,
        bodyText: shortTitle,
        media: shortMedia
      };
    }

    if (PATH.indexOf("/results") === 0) {
      var query = "";
      try { query = new URLSearchParams(location.search).get("search_query") || ""; } catch (e) { query = ""; }
      var top = qsa("ytd-video-renderer #video-title").slice(0, 5).map(function (a) { return squish(a.getAttribute("title") || a.textContent); }).filter(Boolean);
      put(entities, "query", query);
      return {
        activity: "searching",
        headline: 'Searching YouTube for "' + query + '"' + (top.length ? ' — top result: "' + oneLine(top[0], 90) + '"' : " — no results rendered yet"),
        detail: top.join("\n"),
        entities: entities,
        bodyText: top.join("\n")
      };
    }

    var ytTitle = g.title.replace(/ - YouTube$/, "");
    put(entities, "section", SEG[0] || "home");
    return {
      activity: "browsing",
      headline: "On YouTube at " + (SEG.length ? "/" + SEG.join("/") : "the home feed") + ' — page titled "' + ytTitle + '"',
      detail: "URL: " + location.href,
      entities: entities,
      bodyText: "",
      media: mediaState(ytTitle)
    };
  });

  // MARK: Reddit
  //
  // New Reddit is web components (`shreddit-post`) whose attributes carry the data
  // directly — far more reliable than scraping the rendered text.
  adapter("reddit", ["reddit.com"], function (g) {
    var entities = {};
    var typing = typedText(g);
    var subreddit = "";
    var idx = SEG.indexOf("r");
    if (idx > -1 && SEG[idx + 1]) subreddit = "r/" + SEG[idx + 1];

    var postEl = qs("shreddit-post");
    var title = postEl ? squish(attr(postEl, "post-title")) : "";
    var author = postEl ? squish(attr(postEl, "author")) : "";
    var subFromEl = postEl ? squish(attr(postEl, "subreddit-prefixed-name")) : "";
    var score = postEl ? squish(attr(postEl, "score")) : "";
    var commentCount = postEl ? squish(attr(postEl, "comment-count")) : "";
    if (!title) title = txt(qsAny(['[slot="title"]', "h1", '[data-testid="post-content"] h1']), 250);
    if (!author) author = txt(qsAny(['[data-testid="post_author_link"]', 'a[href^="/user/"]']), 60);
    if (subFromEl) subreddit = subFromEl;

    put(entities, "subreddit", subreddit);
    put(entities, "postTitle", title);
    put(entities, "author", author);
    put(entities, "score", score);
    put(entities, "comments", commentCount);

    var isComments = PATH.indexOf("/comments/") > -1;

    if (typing) {
      put(entities, "draft", typing);
      return {
        activity: "composing",
        headline: 'Typing a Reddit comment' + (title ? ' on "' + oneLine(title, 70) + '"' : "") + (subreddit ? " in " + subreddit : "") + ': "' + oneLine(typing, 100) + '"',
        detail: (title ? "Post: " + title + "\n" : "") + "Draft:\n" + typing,
        entities: entities,
        bodyText: typing
      };
    }

    if (isComments && title) {
      var comments = qsa("shreddit-comment").slice(0, 8).map(function (c) {
        return message(squish(attr(c, "author")), txt(qs('[slot="comment"]', c) || c, 300));
      }).filter(function (m) { return m.text; });
      var postBody = txt(qsAny(['[slot="text-body"]', '[data-post-click-location="text-body"]']), MAX_BODY_TEXT);
      return {
        activity: "reading",
        headline: 'Reading the ' + (subreddit || "Reddit") + ' post "' + title + '"' +
          (author ? " by u/" + author.replace(/^u\//, "") : "") +
          (commentCount ? " — " + commentCount + " comments" : "") + (score ? ", " + score + " points" : ""),
        detail: postBody + (comments.length ? "\n\nTop comments:\n" + threadDetail(comments) : ""),
        entities: entities,
        bodyText: postBody || title,
        thread: comments
      };
    }

    var feedPosts = qsa("shreddit-post").slice(0, 6).map(function (p) {
      return message(squish(attr(p, "author")), squish(attr(p, "post-title")));
    }).filter(function (m) { return m.text; });
    var where2 = subreddit ? subreddit : (PATH === "/" ? "the Reddit home feed" : "reddit.com" + PATH);
    return {
      activity: "reading",
      headline: feedPosts.length
        ? "Scrolling " + where2 + " — top post: \"" + oneLine(feedPosts[0].text, 100) + "\" by u/" + feedPosts[0].speaker
        : "On " + where2 + " — no posts have rendered yet",
      detail: feedPosts.map(function (m) { return "u/" + m.speaker + ": " + m.text; }).join("\n"),
      entities: entities,
      bodyText: feedPosts.map(function (m) { return m.text; }).join("\n")
    };
  });

  // MARK: Google Docs / Sheets / Slides
  //
  // Docs renders text to a canvas, so there is no readable body DOM. What IS reliable:
  // the title input, the document outline's highlighted entry (= the section you are
  // scrolled to), and whether a selection overlay exists.
  adapter("gdocs", ["docs.google.com"], function (g) {
    var entities = {};
    var kindMap = { document: "Google Doc", spreadsheets: "Google Sheet", presentation: "Google Slides deck", forms: "Google Form", drawings: "Google Drawing" };
    var kind = kindMap[SEG[0]] || "Google Docs file";
    var titleInput = qs(".docs-title-input");
    var title = squish(titleInput ? (titleInput.value || titleInput.textContent) : "") ||
      squish(g.title.replace(/ - Google (Docs|Sheets|Slides|Forms|Drawings)$/, ""));
    // The outline panel highlights the heading you are currently scrolled to — the only
    // reliable "where am I in this document" signal Docs exposes to the DOM.
    var outlineHere = txt(qs(".navigation-item.location-indicator-highlight .navigation-item-content"), 160);
    // Docs draws its own selection overlay; window.getSelection() is usually empty there.
    var hasSelection = !!qs(".kix-selection-overlay") || !!g.selection;
    var nameBox = qs("#t-name-box");
    var cellRef = squish(nameBox ? (nameBox.value || attr(nameBox, "value")) : "");

    put(entities, "docTitle", title);
    put(entities, "docType", kind);
    put(entities, "heading", outlineHere);
    put(entities, "cell", cellRef);

    var mode = /\/edit/.test(PATH) ? "Editing" : (/\/preview|\/view/.test(PATH) ? "Viewing" : "Editing");
    var parts = [];
    if (outlineHere) parts.push('at the section "' + outlineHere + '"');
    if (cellRef) parts.push("with cell " + cellRef + " selected");
    if (hasSelection && g.selection) parts.push('with "' + oneLine(g.selection, 70) + '" selected');
    else if (hasSelection) parts.push("with text selected");

    return {
      activity: mode === "Editing" ? "composing" : "reading",
      headline: title
        ? mode + ' the ' + kind + ' "' + title + '"' + (parts.length ? " " + parts.join(", ") : "")
        : "In a " + kind + " whose title has not loaded — Holmes cannot read Google Docs body text (it renders to a canvas)",
      detail: "Type: " + kind + "\nTitle: " + title + (outlineHere ? "\nCurrent section: " + outlineHere : "") +
        (cellRef ? "\nSelected cell: " + cellRef : "") + (g.selection ? "\nSelection:\n" + g.selection : "") +
        "\n\nNote: Google Docs body text is drawn to a canvas and is not present in the DOM.",
      entities: entities,
      bodyText: g.selection || ""
    };
  });

  // MARK: Notion
  adapter("notion", ["notion.so", "notion.site"], function (g) {
    var entities = {};
    var title = txt(qsAny([".notion-page-block .notranslate", "[placeholder='Untitled']", "h1"]), 200) ||
      squish(g.title.replace(/\s*\|\s*Notion\s*$/i, ""));
    var crumbs = qsa(".notion-topbar [class*='breadcrumb'] div, .notion-topbar-breadcrumb").map(function (el) {
      return squish(el.textContent);
    }).filter(Boolean).slice(0, 5);
    var typing = typedText(g);
    var body = collectText(qsAny([".notion-page-content", ".notion-frame", "[role=main]"]), MAX_BODY_TEXT, 15000);

    put(entities, "pageTitle", title);
    put(entities, "breadcrumb", crumbs.join(" / "));

    if (typing) {
      put(entities, "block", typing);
      return {
        activity: "composing",
        headline: 'Editing the Notion page "' + (title || "Untitled") + '" — typing in a block: "' + oneLine(typing, 100) + '"',
        detail: (crumbs.length ? crumbs.join(" / ") + "\n\n" : "") + "Current block:\n" + typing + "\n\nPage:\n" + body,
        entities: entities,
        bodyText: body || typing
      };
    }
    return {
      activity: "reading",
      headline: title
        ? 'Reading the Notion page "' + title + '"' + (crumbs.length ? " under " + crumbs.join(" / ") : "")
        : "In Notion — the page content has not rendered yet",
      detail: (crumbs.length ? crumbs.join(" / ") + "\n\n" : "") + body,
      entities: entities,
      bodyText: body
    };
  });

  // MARK: AI assistants (ChatGPT / Claude / Perplexity / Gemini / Copilot)
  //
  // The prompt currently typed is the highest-value signal on the whole web, so each
  // site gets an explicit composer selector chain plus a message-node selector for the
  // last exchange. Roles are derived from an explicit user-selector, never guessed.
  var AI_SITES = {
    "chatgpt.com": {
      name: "ChatGPT",
      composer: ["#prompt-textarea", 'form div[contenteditable="true"]', "form textarea"],
      messages: "[data-message-author-role]",
      roleOf: function (el) { return attr(el, "data-message-author-role") === "user" ? "You" : "ChatGPT"; }
    },
    "chat.openai.com": {
      name: "ChatGPT",
      composer: ["#prompt-textarea", "form textarea"],
      messages: "[data-message-author-role]",
      roleOf: function (el) { return attr(el, "data-message-author-role") === "user" ? "You" : "ChatGPT"; }
    },
    "claude.ai": {
      name: "Claude",
      composer: ['div[contenteditable="true"].ProseMirror', '[aria-label="Write your prompt to Claude"]', 'div[contenteditable="true"]'],
      messages: '[data-testid="user-message"], .font-claude-message, [data-testid="assistant-message"]',
      roleOf: function (el) {
        try { return el.matches('[data-testid="user-message"]') ? "You" : "Claude"; } catch (e) { return "Claude"; }
      }
    },
    "perplexity.ai": {
      name: "Perplexity",
      composer: ["#ask-input", 'textarea[placeholder*="Ask"]', 'div[contenteditable="true"]', "textarea"],
      messages: '[class*="prose"], [data-testid="answer"]',
      roleOf: function () { return "Perplexity"; }
    },
    "gemini.google.com": {
      name: "Gemini",
      composer: ['.ql-editor[contenteditable="true"]', 'rich-textarea div[contenteditable="true"]'],
      messages: "user-query, model-response",
      roleOf: function (el) { return el.tagName === "USER-QUERY" ? "You" : "Gemini"; }
    },
    "copilot.microsoft.com": {
      name: "Copilot",
      composer: ["#userInput", "textarea", 'div[contenteditable="true"]'],
      messages: "[data-content='user-message'], [data-content='ai-message']",
      roleOf: function (el) { return attr(el, "data-content") === "user-message" ? "You" : "Copilot"; }
    }
  };

  adapter("ai-chat", Object.keys(AI_SITES), function (g) {
    var entities = {};
    var cfg = null;
    var keys = Object.keys(AI_SITES);
    for (var i = 0; i < keys.length; i++) {
      if (HOST === keys[i] || HOST.slice(-(keys[i].length + 1)) === "." + keys[i]) { cfg = AI_SITES[keys[i]]; break; }
    }
    if (!cfg) cfg = { name: "the assistant", composer: ["textarea"], messages: "[data-message-author-role]", roleOf: function () { return "assistant"; } };

    var composerEl = qsAny(cfg.composer);
    var draft = typedText(g) || (composerEl ? (composerEl.value !== undefined && composerEl.value !== null && composerEl.tagName === "TEXTAREA" ? squish(composerEl.value) : txt(composerEl, 2000)) : "");
    var nodes = qsa(cfg.messages).filter(function (el) { return !isHidden(el); });
    var thread = lastMessages(nodes, function (el) {
      return message(cfg.roleOf(el), txt(el, MAX_MESSAGE_CHARS));
    }, 4);

    put(entities, "assistant", cfg.name);
    put(entities, "turns", nodes.length);
    if (draft) put(entities, "prompt", draft);

    if (draft) {
      return {
        activity: "composing",
        headline: 'Typing a prompt to ' + cfg.name + ': "' + oneLine(draft, 150) + '"',
        detail: (thread.length ? "Recent exchange:\n" + threadDetail(thread) + "\n\n" : "") + "Prompt being typed:\n" + draft,
        entities: entities,
        bodyText: draft,
        thread: thread
      };
    }

    var lastUser = null, lastAssistant = null;
    for (var j = thread.length - 1; j >= 0; j--) {
      if (!lastAssistant && thread[j].speaker !== "You") lastAssistant = thread[j];
      if (!lastUser && thread[j].speaker === "You") lastUser = thread[j];
    }
    if (lastUser || lastAssistant) {
      return {
        activity: "reading",
        headline: lastUser
          ? 'Reading ' + cfg.name + '\'s answer to "' + oneLine(lastUser.text, 110) + '"'
          : 'Reading a ' + cfg.name + ' response: "' + oneLine(lastAssistant.text, 110) + '"',
        detail: threadDetail(thread),
        entities: entities,
        bodyText: lastAssistant ? lastAssistant.text : "",
        thread: thread
      };
    }
    return {
      activity: "other",
      headline: "On " + cfg.name + " with an empty composer — no conversation has been started on this page",
      detail: "URL: " + location.href,
      entities: entities,
      bodyText: ""
    };
  });

  // MARK: WhatsApp Web
  //
  // The `data-pre-plain-text` attribute on each bubble is gold for INCOMING messages:
  // it literally reads "[10:42, 21/07/2026] Alice: ", giving speaker attribution without
  // class scraping. It is a trap for OUTGOING ones — WhatsApp puts it on those too, where
  // it carries the user's OWN profile name, which reads exactly like a third party's.
  // So `message-out` is consulted FIRST and wins: it is the DOM's own statement that the
  // bubble is the user's, and it is the fact `lastFromMe` publishes.
  adapter("whatsapp", ["web.whatsapp.com"], function (g) {
    var entities = {};
    var main = qs("#main");
    if (!main) {
      var chats = qsa('[aria-label="Chat list"] [role="listitem"]').slice(0, 6).map(function (row) {
        return oneLine(txt(row, 120), 100);
      }).filter(Boolean);
      return {
        activity: "chatting",
        headline: chats.length
          ? "In WhatsApp Web with no chat open — top of the chat list: " + chats[0]
          : "WhatsApp Web is open but has not loaded the chat list yet",
        detail: chats.join("\n"),
        entities: entities,
        bodyText: ""
      };
    }
    var who = squish(attr(qsAny(["header span[title]", 'header [data-testid="conversation-info-header-chat-title"]'], main), "title")) ||
      txt(qs("header span[dir=auto]", main), 100);
    var bubbles = qsa("div.message-in, div.message-out", main).filter(function (el) { return !isHidden(el); });
    var thread = lastMessages(bubbles, function (b) {
      // Ground truth first, attribute second. A `message-out` bubble is the user's
      // own, full stop — reading pre-plain-text there would label their words with
      // their own profile name and let Holmes draft a reply to the user themself.
      var mine = b.classList.contains("message-out");
      var speaker = "You";
      if (!mine) {
        var pre = attr(qs("[data-pre-plain-text]", b) || b, "data-pre-plain-text");
        var m = pre.match(/\]\s*([^:]+):\s*$/);
        speaker = m ? m[1] : (who || "Them");
      }
      var body = txt(qsAny(["span.selectable-text", ".copyable-text .selectable-text", ".copyable-text"], b), MAX_MESSAGE_CHARS);
      return message(speaker, body, mine);
    }, 8);

    var composer = qsAny(['footer div[contenteditable="true"]', 'footer [role="textbox"]'], main);
    var draft = typedText(g) || txt(composer, 800);

    put(entities, "chat", who);
    put(entities, "messageCount", thread.length);
    putLastFromMe(entities, thread);

    if (draft) {
      put(entities, "draft", draft);
      return {
        activity: "composing",
        headline: 'Typing a WhatsApp message to ' + (who || "an unnamed chat") + ': "' + oneLine(draft, 120) + '"',
        detail: threadDetail(thread) + "\n\nDraft:\n" + draft,
        entities: entities,
        bodyText: draft,
        thread: thread
      };
    }
    var last = lastFrom(thread);
    return {
      activity: "chatting",
      headline: who
        ? "In a WhatsApp chat with " + who + (last ? ' — last message from ' + last.speaker + ': "' + oneLine(last.text, 90) + '"' : " — no messages have loaded")
        : "In a WhatsApp chat whose title has not loaded",
      detail: threadDetail(thread),
      entities: entities,
      bodyText: threadDetail(thread),
      thread: thread
    };
  });

  // MARK: Discord
  //
  // Discord hashes every class name (e.g. `title_a1b2c3`), so everything here matches on
  // attribute PREFIXES and stable ids (`chat-messages-*`, `message-content-*`). Those id
  // patterns have survived every redesign so far; the class prefixes are the fragile part.
  adapter("discord", ["discord.com"], function (g) {
    var entities = {};
    var isDM = PATH.indexOf("/channels/@me") === 0;
    var channel = txt(qsAny([
      'section[aria-label="Channel header"] h1',
      "[class^='title_'] h1",
      "[class*='titleWrapper'] h1",
      "h1"
    ]), 120);
    var guild = isDM ? "Direct Messages" : txt(qsAny([
      "[class*='guildName']",
      "header[class*='header_'] h1",
      "[class*='name_'][class*='guild']"
    ]), 120);
    var rows = qsa('li[id^="chat-messages-"], [class*="message_"][class*="cozy"]').filter(function (el) { return !isHidden(el); });
    // Discord puts no "this one is yours" class on a message row, so the ground truth
    // is the account panel in the bottom-left corner: it renders the signed-in user's
    // own name, and a row authored by that name is the user's. When the panel can't be
    // read, `me` is empty, sameSpeaker returns false for everything, and the adapter
    // publishes no marker at all rather than a guess.
    var me = accountName([
      { q: 'section[aria-label="User area"] [class*="nameTag"]' },
      { q: 'section[class*="panels_"] [class*="nameTag"]' },
      { q: '[class*="accountProfileCard"] [class*="username"]' },
      { q: 'section[aria-label="User area"] [class*="title_"]' }
    ]);
    var lastAuthor = "";
    var thread = lastMessages(rows, function (row) {
      var author = txt(qsAny(["[class*='username']", "h3 span"], row), 80);
      if (author) lastAuthor = author; else author = lastAuthor; // grouped consecutive messages
      var body = txt(qsAny(["[id^='message-content-']", "[class*='messageContent']"], row), MAX_MESSAGE_CHARS);
      return message(author, body, me ? sameSpeaker(author, me) : undefined);
    }, 10);
    var composer = qsAny(['div[role="textbox"][class*="slateTextArea"]', '[data-slate-editor="true"]', 'div[role="textbox"]']);
    var draft = typedText(g) || txt(composer, 800);

    put(entities, "server", guild);
    put(entities, "channel", channel);
    put(entities, "isDM", isDM ? "yes" : "no");
    putLastFromMe(entities, thread);

    var place = isDM
      ? "a Discord DM with " + (channel || "an unnamed contact")
      : "#" + (channel || "unknown-channel") + (guild ? " in the " + guild + " Discord server" : " on Discord");

    if (draft) {
      put(entities, "draft", draft);
      return {
        activity: "composing",
        headline: 'Typing a Discord message in ' + place + ': "' + oneLine(draft, 110) + '"',
        detail: threadDetail(thread) + "\n\nDraft:\n" + draft,
        entities: entities,
        bodyText: draft,
        thread: thread
      };
    }
    var lastMsg = lastFrom(thread);
    return {
      activity: "chatting",
      headline: "Reading " + place + (lastMsg ? ' — last message from ' + (lastMsg.speaker || "an unnamed user") + ': "' + oneLine(lastMsg.text, 90) + '"' : " — no messages have rendered yet"),
      detail: threadDetail(thread),
      entities: entities,
      bodyText: threadDetail(thread),
      thread: thread
    };
  });

  // MARK: Slack
  //
  // Slack's data-qa attributes are its public-ish test hooks and are the stable choice.
  adapter("slack", ["app.slack.com", "slack.com"], function (g) {
    var entities = {};
    var channel = txt(qsAny(['[data-qa="channel_name"]', ".p-view_header__channel_title", '[data-qa="channel_header_name"]']), 120);
    var workspace = txt(qsAny(['[data-qa="team_name"]', ".p-ia__sidebar_header__team_name"]), 120);
    if (!workspace) {
      // Slack's document.title is "channel (workspace) - Slack" — parse the parenthetical.
      var m = g.title.match(/\(([^)]+)\)\s*-\s*Slack/);
      if (m) workspace = squish(m[1]);
    }
    var rows = qsa('[data-qa="message_container"], .c-virtual_list__item[data-qa="virtual-list-item"]').filter(function (el) { return !isHidden(el); });
    // Slack labels the user's own messages with their Slack display name, so the only
    // way to recognize them is to read that name out of Slack's own chrome — the user
    // button in the sidebar, whose aria-label is "User menu: Alex Rivera". No name read,
    // no marker published.
    var slackMe = accountName([
      { q: '[data-qa="user-button"]', attr: "aria-label" },
      { q: ".p-ia__nav__user__button", attr: "aria-label" },
      { q: '[data-qa="user-button"] img', attr: "alt" }
    ], /^user\s*menu\s*:?\s*/i);
    var lastSpeaker = "";
    var thread = lastMessages(rows, function (row) {
      var speaker = txt(qsAny(['[data-qa="message_sender_name"]', ".c-message__sender_button"], row), 80);
      if (speaker) lastSpeaker = speaker; else speaker = lastSpeaker;
      var body = txt(qsAny(['[data-qa="message-text"]', ".c-message__body", ".p-rich_text_section"], row), MAX_MESSAGE_CHARS);
      return message(speaker, body, slackMe ? sameSpeaker(speaker, slackMe) : undefined);
    }, 10);
    var composer = qsAny(['[data-qa="message_input"] .ql-editor', '.ql-editor[contenteditable="true"]']);
    var draft = typedText(g) || txt(composer, 800);

    put(entities, "workspace", workspace);
    put(entities, "channel", channel);
    put(entities, "messageCount", thread.length);
    putLastFromMe(entities, thread);

    var where = (channel ? (channel.charAt(0) === "#" ? channel : "#" + channel) : "an unnamed conversation") +
      (workspace ? " in the " + workspace + " Slack workspace" : " on Slack");

    if (draft) {
      put(entities, "draft", draft);
      return {
        activity: "composing",
        headline: 'Typing a Slack message in ' + where + ': "' + oneLine(draft, 110) + '"',
        detail: threadDetail(thread) + "\n\nDraft:\n" + draft,
        entities: entities,
        bodyText: draft,
        thread: thread
      };
    }
    var last2 = lastFrom(thread);
    return {
      activity: "chatting",
      headline: "Reading " + where + (last2 ? ' — last message from ' + (last2.speaker || "an unnamed user") + ': "' + oneLine(last2.text, 90) + '"' : " — no messages have rendered yet"),
      detail: threadDetail(thread),
      entities: entities,
      bodyText: threadDetail(thread),
      thread: thread
    };
  });

  // MARK: Messenger
  //
  // Facebook ships fully-hashed class names, so ARIA structure is the only durable hook:
  // the conversation is a [role=main] with [role=row] message rows.
  adapter("messenger", ["messenger.com"], function (g) {
    var entities = {};
    var main = qs('[role="main"]');
    var who = txt(qsAny(['[role="main"] h1', '[role="main"] [role="heading"]', 'h2 span']), 100);
    var rows = qsa('[role="row"]', main || document).filter(function (el) { return !isHidden(el); });
    var thread = lastMessages(rows, function (row) {
      var body = txt(qsAny(['[dir="auto"]'], row), MAX_MESSAGE_CHARS);
      // Messenger exposes the speaker only in the row's aria-label ("Alice sent ...").
      // For the user's own rows it writes "You sent ..." — that literal "You" IS the
      // ground truth, and it is the same string Messenger uses for no one else.
      var aria = attr(row, "aria-label");
      var speaker = "";
      var mine;
      var m = aria.match(/^([^:]+?)\s+(?:sent|said)/i);
      if (m) {
        speaker = m[1];
        mine = /^you$/i.test(squish(speaker));
      }
      return message(speaker, body, mine);
    }, 8);
    var draft = typedText(g) || txt(qsAny(['[role="textbox"][contenteditable="true"]', 'div[aria-label*="message"][contenteditable="true"]']), 800);

    put(entities, "correspondent", who);
    put(entities, "messageCount", thread.length);
    putLastFromMe(entities, thread);

    if (draft) {
      put(entities, "draft", draft);
      return {
        activity: "composing",
        headline: 'Typing a Messenger message to ' + (who || "an unnamed contact") + ': "' + oneLine(draft, 110) + '"',
        detail: threadDetail(thread) + "\n\nDraft:\n" + draft,
        entities: entities,
        bodyText: draft,
        thread: thread
      };
    }
    var last3 = lastFrom(thread);
    return {
      activity: "chatting",
      headline: who
        ? "In a Messenger conversation with " + who + (last3 ? ' — last message: "' + oneLine(last3.text, 90) + '"' : " — no messages have loaded")
        : "In Messenger with no conversation open",
      detail: threadDetail(thread),
      entities: entities,
      bodyText: threadDetail(thread),
      thread: thread
    };
  });

  // MARK: Proton Mail / Outlook (same shape as the Gmail reading adapter)
  adapter("mail-generic", ["mail.proton.me", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "outlook.com"], function (g) {
    var entities = {};
    var isProton = HOST.indexOf("proton") > -1;
    var provider = isProton ? "Proton Mail" : "Outlook";

    var subject = txt(qsAny(isProton
      ? ['[data-testid="message-header:subject"]', "h1.text-ellipsis", ".message-conversation-summary h1", "h1"]
      : ['[role="main"] [role="heading"][aria-level="2"]', '[aria-label="Message subject"]', "h1"]), 220);
    var sender = txt(qsAny(isProton
      ? ['[data-testid="message-header:sender-address"]', '[data-testid="message:sender-address"]', ".sender-name"]
      : ['[role="main"] span[title*="@"]', ".OZZZK", '[aria-label*="From"]']), 160);
    var body = collectText(qsAny(isProton
      ? ['[data-testid="message-content:body"]', ".message-content", "iframe + div"]
      : ['[role="main"] [aria-label="Message body"]', '[role="main"] .allowTextSelection', '[role="document"]']), MAX_BODY_TEXT, 14000);
    var composer = qsAny(isProton
      ? ['[data-testid="composer:body"]', ".composer iframe"]
      : ['[aria-label="Message body"][contenteditable="true"]', 'div[role="textbox"][contenteditable="true"]']);
    var draft = typedText(g) || txt(composer, 2000);
    var to = txt(qsAny(isProton ? ['[data-testid="composer:to"]', ".composer-addresses-item"] : ['[aria-label="To"]', '[aria-label*="To recipients"]']), 200);

    put(entities, "provider", provider);
    put(entities, "subject", subject);
    put(entities, "sender", sender);

    if (draft) {
      put(entities, "to", to);
      put(entities, "draftWords", wordCount(draft));
      return {
        activity: "composing",
        headline: "Composing an email in " + provider + (to ? " to " + to : " — no recipient yet") +
          (subject ? ' with subject "' + subject + '"' : "") + ", " + wordCount(draft) + " words drafted",
        detail: "To: " + to + "\nSubject: " + subject + "\n\n" + draft,
        entities: entities,
        bodyText: draft,
        legacy: { type: "mail_compose", recipient: to, subject: subject, body: draft }
      };
    }
    if (subject || body) {
      return {
        activity: "reading",
        headline: "Reading a message in " + provider + (sender ? " from " + sender : "") + (subject ? ' — "' + subject + '"' : " with no subject line"),
        detail: "From: " + sender + "\nSubject: " + subject + "\n\n" + body,
        entities: entities,
        bodyText: body,
        legacy: { type: "mail_read", sender: sender, subject: subject, body: body }
      };
    }
    var listRows = qsa('[data-testid="message-list"] > *, [role="listbox"] [role="option"]').slice(0, 10)
      .map(function (r) { return oneLine(txt(r, 140), 120); }).filter(Boolean);
    return {
      activity: "reading",
      headline: listRows.length
        ? "Scanning the " + provider + " message list — newest: " + listRows[0]
        : provider + " is open but no message or list has rendered yet",
      detail: listRows.join("\n"),
      entities: entities,
      bodyText: "",
      legacy: { type: "mail_inbox", subject: g.title }
    };
  });

  // MARK: Stack Overflow / Stack Exchange
  adapter("stackoverflow", ["stackoverflow.com", "stackexchange.com", "superuser.com", "serverfault.com", "askubuntu.com"], function (g) {
    var entities = {};
    var title = txt(qsAny(["#question-header h1 a", "#question-header h1", "h1.fs-headline1 a", "h1"]), 250);
    var tags = qsa("#question .post-tag, .post-taglist .post-tag").map(function (t) { return squish(t.textContent); }).filter(Boolean).slice(0, 8);
    var answerHeader = txt(qs("#answers-header h2"), 60);
    var questionBody = collectText(qs("#question .s-prose, #question .post-text"), 2500, 10000);
    var topAnswer = collectText(qs(".answer .s-prose, .answer .post-text"), 2000, 10000);
    var viewingAnswer = /#answer-/.test(location.hash) || (g.scroll > 40 && !!topAnswer);

    put(entities, "question", title);
    put(entities, "tags", tags.join(", "));
    put(entities, "answers", answerHeader);

    if (!title) {
      var qLinks = qsa(".s-post-summary--content-title a, .question-hyperlink").slice(0, 6).map(function (a) { return squish(a.textContent); }).filter(Boolean);
      return {
        activity: qLinks.length ? "searching" : "browsing",
        headline: qLinks.length
          ? "Browsing a Stack Overflow question list — top question: \"" + oneLine(qLinks[0], 100) + '"'
          : 'On ' + HOST + PATH + ' — page titled "' + g.title + '"',
        detail: qLinks.join("\n"),
        entities: entities,
        bodyText: qLinks.join("\n")
      };
    }
    return {
      activity: "reading",
      headline: (viewingAnswer ? "Reading an answer to the " : "Reading the ") + HOST + ' question "' + title + '"' +
        (tags.length ? " — tagged " + tags.join(", ") : "") + (answerHeader ? ", " + oneLine(answerHeader, 30) : ""),
      detail: "Question:\n" + questionBody + (topAnswer ? "\n\nTop answer:\n" + topAnswer : ""),
      entities: entities,
      bodyText: clip(questionBody + (topAnswer ? "\n\n" + topAnswer : ""), MAX_BODY_TEXT)
    };
  });

  // MARK: Linear
  //
  // Linear's DOM is fully hashed; the issue key in the URL is the one guaranteed value,
  // so it anchors the headline and the DOM only supplies extras.
  adapter("linear", ["linear.app"], function (g) {
    var entities = {};
    var keyMatch = PATH.match(/\/issue\/([A-Z][A-Z0-9]*-\d+)/i);
    var key = keyMatch ? keyMatch[1].toUpperCase() : "";
    var title = txt(qsAny(['[data-testid="issue-title"]', "h1", '[contenteditable="true"][data-placeholder="Issue title"]']), 220);
    if (!title) title = squish(g.title.replace(/\s*[·|]\s*Linear\s*$/i, ""));
    var status = squish(attr(qsAny(['[aria-label^="Status"]', 'button[aria-label*="status" i]']), "aria-label")).replace(/^Status[:,]?\s*/i, "");
    if (!status) status = txt(qs('[aria-label^="Status"]'), 40);
    var assignee = squish(attr(qs('[aria-label^="Assignee"]'), "aria-label")).replace(/^Assignee[:,]?\s*/i, "");
    var typing = typedText(g);

    put(entities, "issueKey", key);
    put(entities, "title", title);
    put(entities, "status", status);
    put(entities, "assignee", assignee);

    if (key) {
      if (typing) {
        return {
          activity: "composing",
          headline: 'Typing in Linear issue ' + key + ' "' + oneLine(title, 70) + '": "' + oneLine(typing, 90) + '"',
          detail: key + ": " + title + (status ? "\nStatus: " + status : "") + "\n\nTyping:\n" + typing,
          entities: entities,
          bodyText: typing
        };
      }
      return {
        activity: "coding",
        headline: "Viewing Linear issue " + key + ' "' + (title || "untitled") + '"' + (status ? " (" + status + ")" : "") + (assignee ? ", assigned to " + assignee : ""),
        detail: collectText(qs("main") || document.body, 2500, 10000),
        entities: entities,
        bodyText: collectText(qs("main") || document.body, MAX_BODY_TEXT, 12000)
      };
    }
    var view = SEG.slice(-1)[0] || "workspace";
    var viewTitle = squish(g.title.replace(/\s*[·|]\s*Linear\s*$/i, ""));
    put(entities, "view", view);
    return {
      activity: "coding",
      headline: viewTitle
        ? 'In Linear on the "' + viewTitle + '" view (/' + SEG.join("/") + ")"
        : "In Linear at /" + SEG.join("/") + " — no issue is open and the view has not rendered a title yet",
      detail: collectText(qs("main") || document.body, 2000, 8000),
      entities: entities,
      bodyText: ""
    };
  });

  // MARK: Jira / Confluence (Atlassian Cloud)
  adapter("atlassian", ["atlassian.net", "jira.com"], function (g) {
    var entities = {};
    var key = "";
    var m = PATH.match(/\/browse\/([A-Z][A-Z0-9]*-\d+)/i);
    if (m) key = m[1].toUpperCase();
    if (!key) {
      try {
        var sel = new URLSearchParams(location.search).get("selectedIssue");
        if (sel) key = sel.toUpperCase();
      } catch (e) { /* ignore */ }
    }
    var title = txt(qsAny([
      '[data-testid="issue.views.issue-base.foundation.summary.heading"]',
      '[data-test-id="issue.views.issue-base.foundation.summary.heading"]',
      "h1"
    ]), 220);
    var status = txt(qsAny([
      '[data-testid*="status-field"] button',
      '[data-testid*="status"] span',
      'button[aria-label*="Status"]'
    ]), 60);

    put(entities, "issueKey", key);
    put(entities, "title", title);
    put(entities, "status", status);

    if (key) {
      return {
        activity: "coding",
        headline: "Viewing Jira issue " + key + ' "' + (title || "untitled") + '"' + (status ? " — status " + status : ""),
        detail: collectText(qs('[data-testid="issue.views.issue-base.foundation.summary.heading"]') ? qs("main") : qs("main"), 2500, 10000),
        entities: entities,
        bodyText: collectText(qs("main") || document.body, MAX_BODY_TEXT, 12000)
      };
    }
    if (PATH.indexOf("/wiki/") === 0) {
      var pageTitleC = txt(qsAny(['[data-testid="title-text"]', "#title-text", "h1"]), 220) || squish(g.title.split(" - ")[0]);
      put(entities, "confluencePage", pageTitleC);
      return {
        activity: "reading",
        headline: 'Reading the Confluence page "' + pageTitleC + '" on ' + HOST,
        detail: collectText(qsAny(['[data-testid="ak-renderer-document"]', "main"]), 3000, 12000),
        entities: entities,
        bodyText: collectText(qsAny(['[data-testid="ak-renderer-document"]', "main"]), MAX_BODY_TEXT, 14000)
      };
    }
    return {
      activity: "other",
      headline: 'In Atlassian on ' + HOST + PATH + ' — page titled "' + g.title + '"',
      detail: collectText(qs("main") || document.body, 2000, 8000),
      entities: entities,
      bodyText: ""
    };
  });

  // MARK: Amazon / Shopify storefronts
  adapter("shopping", ["amazon.*", "*.myshopify.com", "*.shopify.com"], function (g) {
    var entities = {};
    var isAmazon = HOST.indexOf("amazon.") === 0 || HOST.indexOf(".amazon.") > -1;
    var store = isAmazon ? HOST : (g.siteName || HOST);

    if (isAmazon && (PATH.indexOf("/cart") > -1 || PATH.indexOf("/gp/cart") > -1)) {
      var subtotal = txt(qsAny(["#sc-subtotal-amount-activecart", "#sc-subtotal-label-activecart"]), 60);
      var items = qsa('[data-name="Active Items"] .sc-list-item, [data-itemtype="active"]').length;
      put(entities, "cartSubtotal", subtotal);
      put(entities, "cartItems", items);
      return {
        activity: "shopping",
        headline: "Reviewing the Amazon cart — " + items + " item" + (items === 1 ? "" : "s") + (subtotal ? ", subtotal " + oneLine(subtotal, 40) : ""),
        detail: collectText(qs("#sc-active-cart") || qs("main"), 2000, 10000),
        entities: entities,
        bodyText: ""
      };
    }
    if (isAmazon && (PATH.indexOf("/gp/buy") > -1 || PATH.indexOf("/checkout") > -1)) {
      return {
        activity: "shopping",
        headline: "In the Amazon checkout flow at " + HOST + PATH + " — payment fields are redacted and never sent",
        detail: "URL: " + location.href,
        entities: entities,
        bodyText: ""
      };
    }

    var product = isAmazon
      ? txt(qs("#productTitle"), 250)
      : txt(qsAny(["h1.product__title", ".product-single__title", '[class*="product"] h1', "h1"]), 250);
    var price = isAmazon
      ? txt(qsAny(["#corePrice_feature_div .a-offscreen", ".a-price .a-offscreen", "#priceblock_ourprice"]), 40)
      : txt(qsAny([".price-item--regular", ".price__current", '[class*="price"] .money', '[data-product-price]']), 40);
    var rating = isAmazon ? txt(qsAny(["#acrPopover", '[data-hook="rating-out-of-text"]']), 40) : "";
    var inCheckout = /\/checkout|\/cart/.test(PATH);

    put(entities, "store", store);
    put(entities, "product", product);
    put(entities, "price", price);
    put(entities, "rating", rating);

    if (product) {
      return {
        activity: "shopping",
        headline: 'Looking at "' + oneLine(product, 120) + '" on ' + store + (price ? " — " + oneLine(price, 30) : " — no price shown") + (rating ? ", rated " + oneLine(rating, 30) : ""),
        detail: "Product: " + product + "\nPrice: " + price + (rating ? "\nRating: " + rating : "") + "\n\n" +
          collectText(qsAny(["#feature-bullets", "#productDescription", ".product__description", "main"]), 1800, 10000),
        entities: entities,
        bodyText: collectText(qsAny(["#feature-bullets", "#productDescription", ".product__description", "main"]), MAX_BODY_TEXT, 12000)
      };
    }
    if (inCheckout) {
      return {
        activity: "shopping",
        headline: "In the checkout flow on " + store + " — payment fields are redacted and never sent",
        detail: "URL: " + location.href,
        entities: entities,
        bodyText: ""
      };
    }
    var results = qsa('[data-component-type="s-search-result"] h2, .product-card__title, .grid-product__title')
      .slice(0, 6).map(function (el) { return oneLine(txt(el, 120), 100); }).filter(Boolean);
    var query = "";
    try { query = new URLSearchParams(location.search).get("k") || new URLSearchParams(location.search).get("q") || ""; } catch (e) { query = ""; }
    put(entities, "query", query);
    return {
      activity: "shopping",
      headline: results.length
        ? (query ? 'Searching ' + store + ' for "' + query + '"' : "Browsing " + store) + ' — top result: "' + results[0] + '"'
        : 'On ' + store + ' at ' + PATH + ' — page titled "' + g.title + '"',
      detail: results.join("\n"),
      entities: entities,
      bodyText: results.join("\n")
    };
  });

  // MARK: - Generic adapter
  //
  // Runs for every site without a bespoke adapter, and must still be specific. Priority
  // order mirrors how much a signal tells us about intent:
  //   typing > media > selection > article > title. Only when literally none of those
  //   exist do we emit a "cannot read" headline that names what is missing.
  function genericAdapter(g) {
    var entities = {};
    var site = HOST || "this page";
    var docTitle = g.ogTitle || g.title || "";
    var article = g.article;
    var media = mediaState(docTitle);
    var typing = typedText(g);

    put(entities, "site", site);
    put(entities, "pageTitle", docTitle);
    put(entities, "h1", g.h1);
    put(entities, "canonical", g.canonical);
    if (g.description) put(entities, "description", oneLine(g.description, 250));
    if (g.heading && g.heading !== g.h1) put(entities, "sectionHeading", g.heading);
    put(entities, "scrollPercent", g.scroll + "%");

    var detailParts = [];
    if (docTitle) detailParts.push("Title: " + docTitle);
    if (g.h1 && g.h1 !== docTitle) detailParts.push("H1: " + g.h1);
    if (g.heading && g.heading !== g.h1) detailParts.push("Currently at section: " + g.heading);
    if (g.description) detailParts.push("Description: " + g.description);
    detailParts.push("URL: " + location.href);
    if (g.selection) detailParts.push("Selected text:\n" + g.selection);
    if (g.dialog) detailParts.push("Open dialog:\n" + g.dialog);
    if (article) detailParts.push("\n" + article);

    // 1. Typing — the strongest possible signal.
    if (typing && typing !== REDACTED) {
      put(entities, "typedInto", g.focused.label);
      put(entities, "typedText", oneLine(typing, 250));
      return {
        activity: "composing",
        headline: 'Typing into "' + oneLine(g.focused.label, 60) + '" on ' + site +
          (docTitle ? ' ("' + oneLine(docTitle, 60) + '")' : "") + ': "' + oneLine(typing, 110) + '"',
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article || typing,
        media: media
      };
    }
    if (g.focused && g.focused.isEditable && g.focused.value === REDACTED) {
      return {
        activity: "composing",
        headline: 'Typing into a sensitive field ("' + oneLine(g.focused.label, 60) + '") on ' + site + " — the value is redacted and was not sent",
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: "",
        media: media
      };
    }

    // 2. Media.
    if (media && (media.isPlaying || media.positionSeconds > 1)) {
      put(entities, "media", media.title);
      put(entities, "position", fmtTime(media.positionSeconds));
      put(entities, "duration", fmtTime(media.durationSeconds));
      return {
        activity: "watching",
        headline: (media.isPlaying ? "Playing " : "Paused at ") + '"' + oneLine(media.title || docTitle || "untitled media", 90) + '" on ' + site +
          " — " + fmtTime(media.positionSeconds) + " of " + fmtTime(media.durationSeconds),
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 3. Selection.
    if (g.selection) {
      return {
        activity: "reading",
        headline: 'Selected text on ' + site + (docTitle ? ' ("' + oneLine(docTitle, 60) + '")' : "") + ': "' + oneLine(g.selection, 110) + '"',
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 4. Open modal.
    if (g.dialog) {
      return {
        activity: "other",
        headline: 'A dialog is open on ' + site + ': "' + oneLine(g.dialog, 120) + '"',
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 5. Article body.
    if (article && article.length > 300) {
      var label = g.h1 || docTitle;
      var where = g.heading && g.heading !== label ? ', at the section "' + oneLine(g.heading, 50) + '"' : "";
      return {
        activity: "reading",
        headline: 'Reading "' + oneLine(label || "an untitled page", 90) + '" on ' + site + where + " — " + g.scroll + "% scrolled, " + wordCount(article) + " words on the page",
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 6. Search results pages of any engine.
    var query2 = "";
    try {
      var params = new URLSearchParams(location.search);
      query2 = params.get("q") || params.get("query") || params.get("search") || params.get("s") || "";
    } catch (e) { query2 = ""; }
    if (query2) {
      put(entities, "query", query2);
      return {
        activity: "searching",
        headline: 'Searching ' + site + ' for "' + oneLine(query2, 90) + '"' + (article ? " — " + wordCount(article) + " words of results on screen" : ""),
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 7. Title only.
    if (docTitle) {
      return {
        activity: "browsing",
        headline: 'On ' + site + PATH + ' — the page is titled "' + oneLine(docTitle, 100) + '"' +
          (g.description ? ' and describes itself as "' + oneLine(g.description, 80) + '"' : " and has no readable body text"),
        detail: detailParts.join("\n"),
        entities: entities,
        bodyText: article,
        media: media
      };
    }

    // 8. Nothing at all — say exactly what is missing. Never invent.
    return {
      activity: "other",
      headline: "Can't read this page — " + site + PATH + " has no title and no extractable text in the DOM (it may render to a canvas or a cross-origin frame)",
      detail: "URL: " + location.href + "\nReadable characters found: 0",
      entities: entities,
      bodyText: "",
      media: media
    };
  }

  // MARK: - Payload assembly

  function pickAdapter() {
    for (var i = 0; i < ADAPTERS.length; i++) {
      try {
        if (hostMatches(ADAPTERS[i].hosts)) return ADAPTERS[i];
      } catch (e) { /* a bad host pattern must not block the rest */ }
    }
    return null;
  }

  function buildPayload() {
    refreshLocation();
    var g = makeSignals();
    var chosen = pickAdapter();
    var result = null;
    var adapterId = "generic";

    if (chosen) {
      try {
        result = chosen.run(g);
        adapterId = chosen.id;
      } catch (e) {
        // A thrown adapter falls back to the generic reader rather than producing nothing.
        console.warn("[Holmes] adapter " + chosen.id + " failed, falling back to generic:", e);
        result = null;
      }
    }
    if (!result || !result.headline) {
      result = genericAdapter(g);
      adapterId = chosen ? chosen.id + "+generic" : "generic";
    }

    var entities = result.entities || {};
    var media = result.media !== undefined ? result.media : mediaState(result.entities && result.entities.pageTitle);
    var bodyText = clip(squish(result.bodyText || ""), MAX_BODY_TEXT);
    var thread = (result.thread || []).slice(-MAX_THREAD_MESSAGES);
    var legacy = result.legacy || {};
    var compose = scopeComposeRead();
    if (compose) {
      // Preserve literal empty fields. The page title is never a subject.
      entities.recipient = compose.recipients.join(", ");
      entities.subject = compose.subject;
      entities.surface = "emailCompose";
      bodyText = compose.body;
      result.activity = "composing";
      result.headline = "Composing an email in " + compose.provider
        + (entities.recipient ? " to " + entities.recipient : " — no recipient yet")
        + (compose.subject ? ' with subject "' + compose.subject + '"' : " with an empty subject line")
        + (compose.bodyIsEmpty ? ", body still empty" : ", " + wordCount(compose.body) + " words drafted");
      result.detail = "To: " + entities.recipient + "\nSubject: " + compose.subject + "\n\n" + compose.body;
      legacy.type = "email_compose";
      legacy.recipient = entities.recipient;
      legacy.subject = compose.subject;
      legacy.body = compose.body;
    }

    var payload = {
      v: 2,
      source: "browserExtension",
      confidence: "exact",     // read from the live DOM — Holmes may state these facts literally
      adapter: adapterId,
      browser: BROWSER,
      app: BROWSER,
      site: HOST,
      url: location.href,
      canonicalURL: g.canonical,
      title: g.title,
      activity: result.activity || "browsing",
      headline: clip(squish(result.headline), 400),
      detail: clip(squish(result.detail || ""), 6000),
      entities: entities,
      selection: g.selection || null,
      focusedField: g.focused || null,
      media: media || null,
      bodyText: bodyText,
      thread: thread,
      heading: g.heading || "",
      dialog: g.dialog || "",
      scrollPercent: g.scroll,
      isActiveTab: IS_ACTIVE_TAB && document.visibilityState === "visible",
      tabId: TAB_ID,
      windowId: WINDOW_ID,
      browserInstanceId: BROWSER_INSTANCE_ID,
      visible: document.visibilityState === "visible",
      focused: document.hasFocus(),
      capturedAt: compose ? compose.capturedAt : Date.now(),
      emailCompose: compose,
      emailComposeProtocolVersion: window.HolmesEmailCompose ? 1 : 0,
      extensionVersion: extensionVersion(),
      fingerprint: hash32([HOST, PATH, result.activity || "", g.title].join("|")),

      // Legacy keys: the current Swift BrowserBridge parses these five. Kept populated so
      // the extension keeps working against the old bridge during the migration.
      type: legacy.type || adapterId,
      sender: legacy.sender || "",
      recipient: legacy.recipient || "",
      subject: Object.prototype.hasOwnProperty.call(legacy, "subject") ? legacy.subject : g.title,
      body: legacy.body || bodyText.slice(0, 800)
    };
    return payload;
  }

  function scopeComposeRead() {
    if (!window.HolmesEmailCompose || isExcludedHost()) return null;
    return window.HolmesEmailCompose.read();
  }

  function extensionVersion() {
    try { return chrome.runtime.getManifest().version || ""; } catch (_) { return ""; }
  }

  function byteLength(s) {
    try { return new TextEncoder().encode(s).length; } catch (e) { return s.length; }
  }

  // Shed the least valuable fields until the JSON fits, so a huge page degrades instead
  // of being dropped on the floor.
  function serialize(payload) {
    var json = JSON.stringify(payload);
    if (byteLength(json) <= MAX_PAYLOAD_BYTES) return json;
    var steps = [
      function () { payload.bodyText = clip(payload.bodyText, 2000); },
      function () { payload.detail = clip(payload.detail, 2000); },
      function () { payload.thread = payload.thread.slice(-6); },
      function () { payload.dialog = clip(payload.dialog, 300); },
      function () { payload.body = clip(payload.body, 400); },
      function () { payload.bodyText = clip(payload.bodyText, 800); },
      function () { payload.thread = payload.thread.slice(-3); },
      function () { payload.detail = clip(payload.detail, 800); },
      function () { payload.bodyText = ""; }
    ];
    for (var i = 0; i < steps.length; i++) {
      steps[i]();
      json = JSON.stringify(payload);
      if (byteLength(json) <= MAX_PAYLOAD_BYTES) return json;
    }
    return json;
  }

  // Dedupe key ignores the clock and quantises playback position, so a paused video does
  // not generate a POST every heartbeat while a seek still does.
  function dedupeKey(payload) {
    var copy = {};
    for (var k in payload) {
      if (!Object.prototype.hasOwnProperty.call(payload, k)) continue;
      if (k === "capturedAt") continue;
      if (k === "emailCompose" && payload[k]) {
        copy[k] = Object.assign({}, payload[k]);
        delete copy[k].capturedAt;
        continue;
      }
      copy[k] = payload[k];
    }
    if (copy.media) {
      copy.media = {
        title: copy.media.title,
        positionSeconds: Math.round(copy.media.positionSeconds / 5) * 5,
        durationSeconds: Math.round(copy.media.durationSeconds),
        isPlaying: copy.media.isPlaying
      };
    }
    return hash32(JSON.stringify(copy));
  }

  // MARK: - Per-site exclusion + settings

  function normalizeHosts(list) {
    var out = [];
    try {
      for (var i = 0; i < (list || []).length; i++) {
        var h = String(list[i] || "").trim().toLowerCase()
          .replace(/^https?:\/\//, "").replace(/^www\./, "").split("/")[0];
        if (h) out.push(h);
      }
    } catch (e) { /* a bad exclusion list must never break the page */ }
    return out;
  }

  // Excluded when the current host equals an entry, or is a subdomain of one.
  function isExcludedHost() {
    try {
      var h = String(location.hostname || "").replace(/^www\./i, "").toLowerCase();
      for (var i = 0; i < EXCLUDED_HOSTS.length; i++) {
        var e = EXCLUDED_HOSTS[i];
        if (!e) continue;
        if (h === e || (h.length > e.length && h.slice(-(e.length + 1)) === "." + e)) return true;
      }
    } catch (e) { /* fail open to reading — the toggle is a convenience, not a security gate */ }
    return false;
  }

  function friendlySurface(adapterId) {
    var map = {
      gmail: "Gmail", x: "X / Twitter", linkedin: "LinkedIn", github: "GitHub",
      youtube: "YouTube", reddit: "Reddit", generic: "Generic reader"
    };
    var base = String(adapterId || "generic").replace("+generic", "");
    if (map[base]) return map[base] + (String(adapterId).indexOf("+generic") > -1 ? " (fallback)" : "");
    return base ? base.charAt(0).toUpperCase() + base.slice(1) : "Generic reader";
  }

  function clampHeartbeat(ms) {
    ms = Number(ms) || 0;
    if (!ms) return 0;
    return Math.max(2000, Math.min(120000, Math.round(ms)));
  }

  function effectiveHeartbeat() {
    return HEARTBEAT_MS_OVERRIDE || HEARTBEAT_MS;
  }

  // A read-only snapshot handed to the popup so the user can see EXACTLY what Holmes is
  // reading on this tab — headline, site, detected surface — the trust surface.
  function recordPayloadInfo(payload) {
    lastPayloadInfo = {
      headline: payload.headline || "",
      site: payload.site || "",
      surface: friendlySurface(payload.adapter),
      adapter: payload.adapter || "generic",
      activity: payload.activity || "",
      url: payload.url || "",
      title: payload.title || "",
      bytes: lastPostBytes
    };
  }

  // MARK: - Transport

  var TOKEN = "";
  var TAB_ID = -1;
  var WINDOW_ID = -1;
  var BROWSER_INSTANCE_ID = "";
  var IS_ACTIVE_TAB = true; // assumed until the background worker says otherwise
  // relay -> (no runtime) fetch -> xhr, demoted on failure and remembered.
  //
  // The background worker is the primary transport, not the fallback: the Holmes
  // bridge answers CORS only for chrome-extension:// origins, so a fetch from the
  // PAGE's origin can never clear the preflight (that wildcard was how a hostile
  // page could reach the port at all). The worker holds host_permissions and isn't
  // subject to CORS. Direct fetch/XHR remain for an environment with no extension
  // runtime — a userscript build — where the token has to be pasted in anyway.
  var transportMode = hasRuntime() ? "relay" : "fetch";

  function hasRuntime() {
    return runtimeAlive();
  }

  // MARK: - Lifecycle (orphan detection)
  //
  // After the extension reloads or updates, this copy's runtime is invalidated
  // (chrome.runtime.id becomes undefined) but its timers and listeners keep running,
  // silently failing every send while the worker's own heartbeats keep the app
  // saying "connected". Detect that on every activity and stop quietly; the worker
  // reinjects a fresh copy, which takes over the page.

  function runtimeAlive() {
    try { return !!(RUNTIME && RUNTIME.id); } catch (_) { return false; }
  }

  var HAD_RUNTIME = runtimeAlive();

  function teardown() {
    if (tornDown) return;
    tornDown = true;
    try { if (heartbeatTimer) clearInterval(heartbeatTimer); } catch (_) { /* ignore */ }
    try { if (keepaliveTimer) clearInterval(keepaliveTimer); } catch (_) { /* ignore */ }
    try { if (flushTimer) clearTimeout(flushTimer); } catch (_) { /* ignore */ }
    try { if (mutationObserver) mutationObserver.disconnect(); } catch (_) { /* ignore */ }
    heartbeatTimer = null;
    keepaliveTimer = null;
    flushTimer = null;
  }

  // True once this copy is stopped. Only a copy that HAD a runtime can be orphaned;
  // a runtime-less (userscript) build keeps its direct transport.
  function checkOrphaned() {
    if (!tornDown && HAD_RUNTIME && !runtimeAlive()) teardown();
    return tornDown;
  }

  // An evicted MV3 worker only wakes for events. While the user is looking at this
  // tab, ping it so queued browser commands are picked up promptly.
  var KEEPALIVE_MS = (window.__holmesContentConfig && Number(window.__holmesContentConfig.keepaliveMs)) || 20000;
  var keepaliveTimer = null;

  function armKeepalive() {
    if (!HAD_RUNTIME || tornDown) return;
    try { if (keepaliveTimer) clearInterval(keepaliveTimer); } catch (_) { /* ignore */ }
    keepaliveTimer = setInterval(function () {
      if (checkOrphaned()) return;
      if (document.visibilityState !== "visible" || !IS_ACTIVE_TAB) return;
      try {
        RUNTIME.sendMessage({ type: "holmes:keepalive" }, function () { void (RUNTIME && RUNTIME.lastError); });
      } catch (_) {
        checkOrphaned();
      }
    }, KEEPALIVE_MS);
  }

  function loadToken() {
    if (!hasRuntime()) return;
    try {
      chrome.storage.local.get("holmesToken", function (res) {
        if (res && res.holmesToken) TOKEN = res.holmesToken;
      });
      chrome.storage.onChanged.addListener(function (changes, area) {
        if (area === "local" && changes.holmesToken && changes.holmesToken.newValue) {
          TOKEN = changes.holmesToken.newValue;
        }
      });
    } catch (e) { /* storage unavailable — the app can still accept an empty token */ }
    try {
      chrome.runtime.sendMessage({ type: "holmes:hello" }, function (res) {
        // Reading lastError suppresses the "unchecked runtime.lastError" console noise
        // when the service worker is still starting up.
        var err = chrome.runtime.lastError;
        if (err || !res) return;
        if (res.token) TOKEN = res.token;
        if (typeof res.tabId === "number") TAB_ID = res.tabId;
        if (typeof res.windowId === "number") WINDOW_ID = res.windowId;
        if (typeof res.instanceId === "string") BROWSER_INSTANCE_ID = res.instanceId;
        if (window.HolmesEmailCompose) window.HolmesEmailCompose.setEnvironment({
          tabId: res.tabId, windowId: res.windowId, instanceId: res.instanceId, app: BROWSER
        });
        if (typeof res.isActiveTab === "boolean") IS_ACTIVE_TAB = res.isActiveTab;
      });
    } catch (e) { /* ignore */ }
  }

  function sendViaRelay(json) {
    if (!hasRuntime()) { checkOrphaned(); return; }
    try {
      chrome.runtime.sendMessage({ type: "holmes:post", body: json }, function (res) {
        void chrome.runtime.lastError;
        // The background worker answers with the real result of the loopback POST, so
        // the popup can show a genuine "last successful POST" time rather than a guess.
        if (res && typeof res.ok === "boolean") {
          lastAckOk = res.ok;
          if (res.ok) lastAckAtMs = Date.now();
        }
      });
    } catch (e) { /* extension context invalidated (reload) — next capture retries */ }
  }

  function sendViaXHR(json, onFail) {
    try {
      var xhr = new XMLHttpRequest();
      xhr.open("POST", ENDPOINT, true);
      xhr.setRequestHeader("Content-Type", "application/json");
      try { xhr.setRequestHeader("X-Holmes-Token", TOKEN); } catch (e) { /* header blocked */ }
      xhr.timeout = 2000;
      xhr.onerror = function () { if (onFail) onFail(); };
      xhr.ontimeout = function () { if (onFail) onFail(); };
      xhr.send(json);
    } catch (e) {
      if (onFail) onFail();
    }
  }

  function deliver(json) {
    if (transportMode === "relay") { sendViaRelay(json); return; }
    if (transportMode === "xhr") {
      sendViaXHR(json, function () { transportMode = "relay"; sendViaRelay(json); });
      return;
    }
    try {
      fetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Holmes-Token": TOKEN },
        body: json,
        keepalive: true,
        mode: "cors",
        credentials: "omit"
      }).catch(function () {
        // Mixed-content and CORS refusals both land here. Demote once and retry.
        transportMode = "xhr";
        sendViaXHR(json, function () { transportMode = "relay"; sendViaRelay(json); });
      });
    } catch (e) {
      transportMode = "xhr";
      sendViaXHR(json, function () { transportMode = "relay"; sendViaRelay(json); });
    }
  }

  // MARK: - Delivery scheduler
  //
  // Every trigger calls schedule(); the scheduler coalesces bursts into a single POST and
  // enforces a hard floor of one POST per 200ms. Latency from "user typed a key" to
  // "Holmes has it" is therefore the input debounce plus ~40ms, never the old 3s poll.

  var lastHash = "";
  var lastPostAt = 0;
  var flushTimer = null;
  var lastURL = location.href;

  function capture(force) {
    if (checkOrphaned()) return;
    try {
      // Honor the per-site "Don't read this site" switch BEFORE any extraction runs:
      // an excluded host builds no payload and sends nothing at all.
      if (isExcludedHost()) { refreshLocation(); lastPayloadInfo = null; return; }
      var payload = buildPayload();
      var key = dedupeKey(payload);
      recordPayloadInfo(payload); // refresh the popup snapshot on every capture
      if (!force && key === lastHash) return;
      lastHash = key;
      lastPostAt = Date.now();
      var json = serialize(payload);
      lastPostAtMs = Date.now();
      lastPostBytes = byteLength(json);
      if (lastPayloadInfo) lastPayloadInfo.bytes = lastPostBytes;
      deliver(json);
    } catch (e) {
      // Extraction must never surface an exception into the page.
      console.warn("[Holmes] capture failed:", e);
    }
  }

  function schedule(force) {
    if (checkOrphaned()) return;
    if (flushTimer) return;
    var since = Date.now() - lastPostAt;
    var wait = Math.max(COALESCE_MS, MIN_POST_INTERVAL_MS - since);
    flushTimer = setTimeout(function () {
      flushTimer = null;
      capture(!!force);
    }, wait);
  }

  function debounce(fn, ms) {
    var t = null;
    return function () {
      if (t) clearTimeout(t);
      t = setTimeout(function () { t = null; fn(); }, ms);
    };
  }

  function onNavigated() {
    if (location.href === lastURL) return;
    lastURL = location.href;
    refreshLocation();
    lastHash = ""; // a navigation always deserves a fresh POST
    attachMutationObserver();
    schedule(true);
    // SPAs paint the new route asynchronously; re-read once it has settled.
    setTimeout(function () { schedule(false); }, 500);
    setTimeout(function () { schedule(false); }, 1500);
  }

  // MARK: - Triggers

  function attachListeners() {
    // Focus in/out of any field — tells us the instant the user starts or stops typing.
    document.addEventListener("focusin", function () { schedule(false); }, true);
    document.addEventListener("focusout", function () { schedule(false); }, true);

    document.addEventListener("selectionchange", debounce(function () { schedule(false); }, SELECTION_DEBOUNCE_MS), true);

    var onInput = debounce(function () { schedule(false); }, INPUT_DEBOUNCE_MS);
    document.addEventListener("input", function (e) {
      var active = deepActiveElement();
      if (e.target === active || isEditableElement(e.target)) onInput();
    }, true);

    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "visible") { lastHash = ""; schedule(true); }
    }, true);

    window.addEventListener("focus", function () { schedule(false); }, true);
    window.addEventListener("blur", function () { schedule(false); }, true);

    // SPA navigation: popstate/hashchange fire in the isolated world, while the MAIN-world
    // history-hook.js relays page-initiated pushState/replaceState as holmes:navigated.
    window.addEventListener("popstate", onNavigated, true);
    window.addEventListener("hashchange", onNavigated, true);
    window.addEventListener("holmes:navigated", onNavigated, true);

    // Also patch history here so navigations initiated from this world are caught. This
    // does NOT see the page's own calls (separate JS worlds) — history-hook.js does.
    try {
      ["pushState", "replaceState"].forEach(function (name) {
        var original = history[name];
        if (typeof original !== "function") return;
        history[name] = function () {
          var r = original.apply(this, arguments);
          onNavigated();
          return r;
        };
      });
    } catch (e) { /* ignore */ }

    window.addEventListener("scroll", debounce(function () { schedule(false); }, 400), { passive: true, capture: true });

    if (hasRuntime()) {
      try {
        chrome.runtime.onMessage.addListener(function (msg) {
          if (!msg || msg.type !== "holmes:active") return;
          var becameActive = msg.isActiveTab && !IS_ACTIVE_TAB;
          IS_ACTIVE_TAB = !!msg.isActiveTab;
          if (typeof msg.tabId === "number") TAB_ID = msg.tabId;
          if (typeof msg.windowId === "number") WINDOW_ID = msg.windowId;
          if (typeof msg.instanceId === "string") BROWSER_INSTANCE_ID = msg.instanceId;
          if (window.HolmesEmailCompose) window.HolmesEmailCompose.setEnvironment({
            tabId: msg.tabId, windowId: msg.windowId, instanceId: msg.instanceId, app: BROWSER
          });
          if (becameActive) { lastHash = ""; schedule(true); }
        });
      } catch (e) { /* ignore */ }

      // The popup's trust surface: hand back exactly what Holmes is currently reading on
      // this tab, plus the exclusion state and the last-POST telemetry for the footer.
      try {
        chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
          if (!msg || typeof msg.type !== "string") return false;

          // Liveness and visibility probe from the worker: heartbeat health checks
          // and the wait for a just activated tab to become visible before insert.
          if (msg.type === "holmes:ping") {
            if (tornDown) return false;
            sendResponse({ ok: true, visible: document.visibilityState === "visible", isActiveTab: IS_ACTIVE_TAB,
              focused: typeof document.hasFocus === "function" ? document.hasFocus() : false });
            return false;
          }

          if (msg.type === "holmes:readEmailCompose" || msg.type === "holmes:fillEmailDraft") {
            if (isExcludedHost() || !IS_ACTIVE_TAB || document.visibilityState !== "visible") {
              sendResponse({ ok: false, refused: true, reason: "The composer is no longer in the active tab." });
              return false;
            }
            if (window.HolmesEmailCompose && msg.environment) {
              window.HolmesEmailCompose.setEnvironment(Object.assign({ app: BROWSER }, msg.environment));
            }
            if (msg.type === "holmes:readEmailCompose") {
              sendResponse({ ok: true, payload: buildPayload() });
            } else {
              var staged = window.HolmesEmailCompose
                ? window.HolmesEmailCompose.stage(msg.body, msg.expected)
                : { ok: false, refused: true, reason: "Reload the extension to enable precise draft insertion." };
              lastHash = "";
              schedule(true);
              sendResponse(staged);
            }
            return false;
          }

          if (msg.type === "holmes:getContext") {
            try {
              refreshLocation();
              var excluded = isExcludedHost();
              var info = lastPayloadInfo;
              // Build a fresh read on demand when we don't have one yet (popup opened
              // before the first capture) and the site isn't excluded.
              if (!excluded && !info) {
                try { recordPayloadInfo(buildPayload()); info = lastPayloadInfo; } catch (e) { info = null; }
              }
              sendResponse({
                ok: true,
                excluded: excluded,
                host: String(location.hostname || "").replace(/^www\./i, "").toLowerCase(),
                href: location.href,
                title: pageTitle(),
                context: excluded ? null : info,
                lastPostAt: lastPostAtMs,
                lastPostBytes: lastPostBytes,
                lastAckAt: lastAckAtMs,
                lastAckOk: lastAckOk,
                isActiveTab: IS_ACTIVE_TAB,
                visible: document.visibilityState === "visible"
              });
            } catch (e) {
              sendResponse({ ok: false, error: String(e && e.message ? e.message : e) });
            }
            return true; // async response
          }

          if (msg.type === "holmes:recapture") {
            lastHash = "";
            schedule(true);
            sendResponse({ ok: true });
            return true;
          }
          return false;
        });
      } catch (e) { /* ignore */ }
    }
  }

  var mutationObserver = null;
  var onMutation = debounce(function () {
    // A mutation can also mean the SPA swapped routes without a history event.
    if (location.href !== lastURL) { onNavigated(); return; }
    schedule(false);
  }, MUTATION_DEBOUNCE_MS);

  function attachMutationObserver() {
    try {
      if (mutationObserver) mutationObserver.disconnect();
      var target = qsAny(["main", "[role=main]", "#main", "#content", "#app", "#root"]) || document.body;
      if (!target) return;
      mutationObserver = new MutationObserver(onMutation);
      mutationObserver.observe(target, { childList: true, subtree: true, characterData: true });
    } catch (e) { /* ignore */ }
  }

  // MARK: - Heartbeat (re-armable so the options page can change the interval live)

  var heartbeatTimer = null;
  var heartbeatBeats = 0;
  function armHeartbeat() {
    if (tornDown) return;
    try { if (heartbeatTimer) clearInterval(heartbeatTimer); } catch (e) { /* ignore */ }
    var period = effectiveHeartbeat();
    heartbeatTimer = setInterval(function () {
      if (checkOrphaned()) return;
      heartbeatBeats++;
      var forceResend = heartbeatBeats % Math.max(1, Math.round(FORCE_RESEND_MS / period)) === 0;
      if (forceResend) lastHash = "";
      schedule(forceResend);
    }, period);
  }

  // MARK: - Settings (exclusion list + heartbeat interval)

  function loadSettings() {
    if (!hasRuntime()) return;
    try {
      chrome.storage.local.get(["holmesExcludedHosts", "holmesHeartbeatMs"], function (res) {
        if (res && Array.isArray(res.holmesExcludedHosts)) EXCLUDED_HOSTS = normalizeHosts(res.holmesExcludedHosts);
        if (res && typeof res.holmesHeartbeatMs === "number") {
          HEARTBEAT_MS_OVERRIDE = clampHeartbeat(res.holmesHeartbeatMs);
          armHeartbeat();
        }
      });
      chrome.storage.onChanged.addListener(function (changes, area) {
        if (area !== "local") return;
        if (changes.holmesExcludedHosts) {
          EXCLUDED_HOSTS = normalizeHosts(changes.holmesExcludedHosts.newValue || []);
          // Exclusion just turned OFF for this host → resume with a fresh read; turned
          // ON → the next scheduled capture bails on its own, so nothing to do here.
          if (!isExcludedHost()) { lastHash = ""; schedule(true); }
        }
        if (changes.holmesHeartbeatMs) {
          HEARTBEAT_MS_OVERRIDE = clampHeartbeat(changes.holmesHeartbeatMs.newValue);
          armHeartbeat();
        }
      });
    } catch (e) { /* storage unavailable — defaults stand */ }
  }

  // MARK: - Boot

  function boot() {
    loadToken();
    loadSettings();
    attachListeners();
    attachMutationObserver();

    // Instant first read at document_idle, then two catch-up reads for app shells that
    // hydrate their real content after idle.
    schedule(true);
    setTimeout(function () { schedule(false); }, 800);
    setTimeout(function () { schedule(false); }, 2500);

    // Safety net only — every real update arrives via the event triggers above. Once a
    // minute the heartbeat ignores the dedupe hash and re-sends anyway, so a Holmes app
    // that restarted mid-session gets the current page back without the user touching it.
    // Re-armable so the options page's heartbeat-interval setting takes effect live.
    armHeartbeat();
    armKeepalive();
  }

  try {
    boot();
  } catch (e) {
    console.warn("[Holmes] content script failed to start:", e);
  }
})();
