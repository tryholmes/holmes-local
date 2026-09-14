// Holmes — browser automation module (imported into the MV3 service worker).
//
// ============================================================================
//  SAFETY BOUNDARY — DRAFT-NEVER-SEND, ENFORCED IN CODE
// ============================================================================
//  Holmes may DRAFT but must never COMMIT. This module lets the Holmes Mac app
//  drive the browser (navigate, read, type a draft into a compose field), but it
//  will physically REFUSE to activate anything that sends, submits, posts,
//  publishes, pays, buys, orders, deletes or archives.
//
//  Concretely:
//    • fillField is ALLOWED to type into a compose field — that is the whole
//      point of the product: it stages a draft the human can review. Filling a
//      composer is fine.
//    • click and fillField REFUSE the moment their target looks like a commit
//      control: the target element (or its enclosing form's submit button) whose
//      text / aria-label / name / id / value matches
//        /\b(send|submit|post|publish|tweet|reply all|confirm|pay|buy|order|delete|archive)\b/i,
//      an <input type=submit> / <button type=submit> inside a compose form, or
//      any actionable element inside a known composer container. A refusal
//      returns { ok:false, refused:true, reason } and takes NO action.
//    • There is deliberately NO "force" flag. The guard cannot be bypassed.
//    • Dialogs are never auto-accepted: this module installs no confirm()/alert()
//      overrides and clicks no dialog buttons on the user's behalf.
//
//  So: filling a compose field is allowed; committing it is not. The commit is a
//  decision reserved for the human, every time.
// ============================================================================
//
//  Transport: the service worker polls GET /commands and POSTs to /command-result
//  (see background.js). This module only knows how to EXECUTE one command and
//  return a structured result. Every executor is wrapped so a broken page can
//  never throw into the poll loop.
//
//  Actions:
//    navigate {url, tabId?}              → { ok, tabId, url }
//    click {selector | text, tabId?}     → { ok, clicked } | { refused, reason }
//    fillField {selector|text, value}    → { ok, filled } | { refused, reason }
//    readSelection {tabId?}              → { ok, text, length, hasSelection }
//    extract {selector, tabId?}          → { ok, count, elements:[{tag,text,attrs,...}] }
//    scrollTo {selector | position}      → { ok, scrolledTo }
//    openTab {url, active?}              → { ok, tabId, url }
//    listTabs {}                         → { ok, tabs:[{id,title,url,active,...}] }
//    screenshotTab {tabId?}             → { ok, dataUrl, format }  (captureVisibleTab)
//    waitForSelector {selector, timeoutMs} → { ok, found, waitedMs }

// ---------------------------------------------------------------------------
// PAGE-SIDE RUNNER
//
// Injected verbatim into the target tab via chrome.scripting.executeScript, so it
// MUST be fully self-contained: every helper it needs is nested inside it, and it
// captures nothing from this module's scope. It returns a serializable object, or
// a Promise of one (waitForSelector). This is where the click/fill guard actually
// runs, because the guard needs the live DOM.
// ---------------------------------------------------------------------------
function holmesPageAction(action, params) {
  "use strict";
  params = params || {};

  // ===== DRAFT-NEVER-SEND GUARD (self-contained; runs in the page) =====
  var SEND_RE = /\b(send|submit|post|publish|tweet|reply all|confirm|pay|buy|order|delete|archive)\b/i;

  // Containers that mean "the user is composing something here". A click on an
  // actionable control inside any of these is treated as a commit and refused.
  var COMPOSER_SELECTORS = [
    '[aria-label*="compose" i]', '[class*="compose" i]', '[data-compose]',
    '[data-testid="tweetTextarea_0"]', '[data-testid="tweetButton"]',
    '[data-testid="tweetButtonInline"]', '[data-testid="toolBar"]',
    '.msg-form', '.public-DraftEditor-content', '.msg-form__contenteditable',
    'div[role="dialog"] form', 'form[class*="reply" i]', 'form[class*="comment" i]',
    '[aria-label*="message body" i]', '[g_editable="true"]'
  ];

  function textOf(el) { try { return String(el.innerText || el.textContent || ""); } catch (e) { return ""; } }
  function attrOf(el, n) { try { return (el && el.getAttribute && el.getAttribute(n)) || ""; } catch (e) { return ""; } }

  function isVisible(el) {
    try {
      if (!el || el.nodeType !== 1) return false;
      if (el.hidden) return false;
      if (el.offsetWidth === 0 && el.offsetHeight === 0 && el.getClientRects().length === 0) return false;
      var cs = window.getComputedStyle(el);
      if (cs && (cs.visibility === "hidden" || cs.display === "none")) return false;
      return true;
    } catch (e) { return true; }
  }

  // Everything about an element that could reveal a commit intent.
  function bagFor(el) {
    if (!el) return "";
    return [
      textOf(el).slice(0, 120), attrOf(el, "aria-label"), attrOf(el, "name"),
      el.id || "", attrOf(el, "value"), attrOf(el, "title"), attrOf(el, "data-testid")
    ].filter(Boolean).join(" ");
  }

  function inComposer(el) {
    try {
      for (var i = 0; i < COMPOSER_SELECTORS.length; i++) {
        if (el.closest && el.closest(COMPOSER_SELECTORS[i])) return true;
      }
    } catch (e) { /* a broken selector must not disable the guard */ }
    return false;
  }

  function isSubmitControl(el) {
    if (!el) return false;
    var tag = el.tagName, type = String(el.type || "").toLowerCase();
    // A <button> with no explicit type defaults to type=submit inside a form.
    if (tag === "BUTTON" && (type === "submit" || type === "")) return true;
    if (tag === "INPUT" && (type === "submit" || type === "image" || type === "button")) return true;
    return false;
  }

  function isActionable(el) {
    if (!el) return false;
    var tag = el.tagName;
    if (tag === "BUTTON" || tag === "A" || tag === "SUMMARY") return true;
    if (tag === "INPUT") {
      var t = String(el.type || "").toLowerCase();
      return ["submit", "button", "image", "reset"].indexOf(t) > -1;
    }
    var role = attrOf(el, "role");
    if (role === "button" || role === "link" || role === "menuitem") return true;
    return false;
  }

  function isEditable(el) {
    if (!el || el.nodeType !== 1) return false;
    var tag = el.tagName;
    if (tag === "TEXTAREA") return true;
    if (tag === "INPUT") {
      var t = String(el.type || "text").toLowerCase();
      return ["button", "submit", "reset", "image", "checkbox", "radio", "file", "hidden", "range", "color"].indexOf(t) === -1;
    }
    try {
      if (el.isContentEditable) return true;
      var ce = el.getAttribute("contenteditable");
      if (ce === "" || String(ce).toLowerCase() === "true") return true;
      if (el.getAttribute("role") === "textbox") return true;
    } catch (e) { /* ignore */ }
    return false;
  }

  function enclosingFormSubmitBag(el) {
    try {
      var form = el.closest ? el.closest("form") : null;
      if (!form) return "";
      var submits = form.querySelectorAll('button[type="submit"], input[type="submit"], button:not([type])');
      var out = [];
      for (var i = 0; i < submits.length; i++) out.push(bagFor(submits[i]));
      return out.join(" ");
    } catch (e) { return ""; }
  }

  // Returns a human reason if this CLICK must be refused, else "".
  function clickRefusal(el) {
    if (!el) return "";
    if (SEND_RE.test(bagFor(el))) return "target's text/label/name/id/value matches a send/submit/commit keyword";
    if (SEND_RE.test(enclosingFormSubmitBag(el))) return "the enclosing form's submit button matches a commit keyword";
    if (isSubmitControl(el) && (el.closest && el.closest("form")) && inComposer(el)) return "a submit control inside a compose form";
    if (isSubmitControl(el) && inComposer(el)) return "a submit control inside a composer";
    if (isActionable(el) && inComposer(el)) return "an actionable control inside a known composer container";
    return "";
  }

  // Returns a human reason if this FILL must be refused, else "". Filling a compose
  // field is ALLOWED, so this only blocks non-fields and commit controls; it checks
  // the field's structural identity (name/id/value), NOT its aria-label/placeholder,
  // so a composer labelled "Tweet" or "Post your reply" stays fillable.
  function fillRefusal(el) {
    if (!el) return "no field matched the selector/text";
    if (isSubmitControl(el)) return "target is a submit control, not a text field";
    if (!isEditable(el)) return "target is not an editable field";
    var identity = [attrOf(el, "name"), el.id || "", attrOf(el, "value")].filter(Boolean).join(" ");
    if (SEND_RE.test(identity)) return "field identity (name/id/value) matches a commit keyword";
    return "";
  }

  function describe(el) {
    return {
      tag: el.tagName ? el.tagName.toLowerCase() : "",
      id: el.id || "",
      text: textOf(el).trim().slice(0, 80),
      ariaLabel: attrOf(el, "aria-label"),
      name: attrOf(el, "name"),
      type: attrOf(el, "type")
    };
  }

  // Selector wins; text is a fallback that matches label/placeholder/name/text.
  function resolveEl(preferClickable) {
    if (params.selector) {
      try { var e = document.querySelector(params.selector); if (e) return e; } catch (_) { /* invalid selector */ }
    }
    if (params.text) {
      var needle = String(params.text).trim().toLowerCase();
      var pool = preferClickable
        ? document.querySelectorAll('button, a, [role="button"], [role="link"], [role="menuitem"], input[type="submit"], input[type="button"], summary, [onclick]')
        : document.querySelectorAll('input, textarea, [contenteditable=""], [contenteditable="true"], [role="textbox"]');
      var fallback = null;
      for (var i = 0; i < pool.length; i++) {
        var el = pool[i];
        var hay = (textOf(el) + " " + attrOf(el, "aria-label") + " " + attrOf(el, "placeholder") + " " +
          attrOf(el, "name") + " " + attrOf(el, "title") + " " + (typeof el.value === "string" ? el.value : "")).toLowerCase();
        if (hay.indexOf(needle) > -1) {
          if (isVisible(el)) return el;
          if (!fallback) fallback = el;
        }
      }
      return fallback;
    }
    return null;
  }

  // Bypass React/Vue value trackers by calling the native setter, then fire the
  // input+change events frameworks listen for.
  function setNativeValue(el, value) {
    try {
      var proto = el.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      var desc = Object.getOwnPropertyDescriptor(proto, "value");
      if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    } catch (e) { el.value = value; }
  }

  function fireInput(el) {
    try { el.dispatchEvent(new InputEvent("input", { bubbles: true, cancelable: true })); }
    catch (e) { try { el.dispatchEvent(new Event("input", { bubbles: true })); } catch (_) { /* ignore */ } }
  }

  try {
    switch (action) {
      case "readSelection": {
        var sel = window.getSelection ? window.getSelection() : null;
        var text = sel ? String(sel.toString()) : "";
        return { ok: true, text: text.slice(0, 20000), length: text.length, hasSelection: !!(sel && !sel.isCollapsed) };
      }

      case "extract": {
        if (!params.selector) return { ok: false, error: "extract requires a selector" };
        var nodes;
        try { nodes = document.querySelectorAll(params.selector); }
        catch (e) { return { ok: false, error: "invalid selector: " + (e && e.message) }; }
        var max = Math.min(nodes.length, 50), items = [];
        for (var i = 0; i < max; i++) {
          var el = nodes[i], attrs = {};
          try {
            for (var a = 0; a < el.attributes.length; a++) {
              var at = el.attributes[a];
              attrs[at.name] = String(at.value).slice(0, 300);
            }
          } catch (e) { /* ignore */ }
          items.push({
            tag: el.tagName.toLowerCase(),
            text: textOf(el).trim().slice(0, 2000),
            href: attrOf(el, "href"),
            value: (typeof el.value === "string") ? el.value.slice(0, 500) : "",
            attrs: attrs,
            visible: isVisible(el)
          });
        }
        return { ok: true, count: nodes.length, returned: items.length, elements: items };
      }

      case "scrollTo": {
        if (params.selector) {
          var target;
          try { target = document.querySelector(params.selector); }
          catch (e) { return { ok: false, error: "invalid selector" }; }
          if (!target) return { ok: false, error: "selector matched nothing" };
          target.scrollIntoView({ behavior: "smooth", block: "center" });
          return { ok: true, scrolledTo: "selector", selector: params.selector };
        }
        var pos = params.position;
        if (pos === "top" || pos === 0) { window.scrollTo({ top: 0, behavior: "smooth" }); return { ok: true, scrolledTo: "top" }; }
        if (pos === "bottom") { window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" }); return { ok: true, scrolledTo: "bottom" }; }
        if (typeof pos === "number") { window.scrollTo({ top: pos, behavior: "smooth" }); return { ok: true, scrolledTo: pos }; }
        if (pos && typeof pos.y === "number") { window.scrollTo({ top: pos.y, left: pos.x || 0, behavior: "smooth" }); return { ok: true, scrolledTo: pos }; }
        return { ok: false, error: "scrollTo requires a selector or position" };
      }

      case "click": {
        var elc = resolveEl(true);
        if (!elc) return { ok: false, error: "no element matched selector/text" };
        var refusalC = clickRefusal(elc);
        if (refusalC) return { ok: false, refused: true, reason: refusalC, matched: describe(elc) };
        try { elc.scrollIntoView({ block: "center" }); } catch (e) { /* ignore */ }
        elc.click();
        return { ok: true, clicked: describe(elc) };
      }

      case "fillField": {
        if (params.value === undefined || params.value === null) return { ok: false, error: "fillField requires a value" };
        var elf = resolveEl(false);
        var refusalF = fillRefusal(elf);
        if (refusalF) return { ok: false, refused: true, reason: refusalF, matched: elf ? describe(elf) : null };
        var value = String(params.value);
        try { elf.focus(); } catch (e) { /* ignore */ }
        if (elf.tagName === "INPUT" || elf.tagName === "TEXTAREA") {
          setNativeValue(elf, value);
          fireInput(elf);
          try { elf.dispatchEvent(new Event("change", { bubbles: true })); } catch (e) { /* ignore */ }
        } else {
          // contenteditable / rich editor — set text and fire input so the editor re-reads it.
          try { elf.textContent = value; } catch (e) { /* ignore */ }
          fireInput(elf);
        }
        return { ok: true, filled: describe(elf), length: value.length };
      }

      case "waitForSelector": {
        if (!params.selector) return { ok: false, error: "waitForSelector requires a selector" };
        var timeout = Math.max(0, Math.min(15000, Number(params.timeoutMs) || 8000));
        return new Promise(function (resolve) {
          var start = Date.now();
          function found() { try { return document.querySelector(params.selector); } catch (e) { return null; } }
          var hit = found();
          if (hit) { resolve({ ok: true, found: true, waitedMs: 0, visible: isVisible(hit) }); return; }
          var iv = setInterval(function () {
            var f = found(), waited = Date.now() - start;
            if (f) { clearInterval(iv); resolve({ ok: true, found: true, waitedMs: waited, visible: isVisible(f) }); }
            else if (waited >= timeout) { clearInterval(iv); resolve({ ok: true, found: false, waitedMs: waited }); }
          }, 120);
        });
      }

      default:
        return { ok: false, error: "unknown page action: " + action };
    }
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

// ---------------------------------------------------------------------------
// WORKER-SIDE DISPATCH
//
// navigate / openTab / listTabs / screenshotTab are pure chrome.* API calls and
// run here. The DOM actions inject holmesPageAction into the resolved tab.
// ---------------------------------------------------------------------------
self.HolmesAutomation = (function () {
  "use strict";

  var PAGE_ACTIONS = { click: 1, fillField: 1, readSelection: 1, extract: 1, scrollTo: 1, waitForSelector: 1 };

  // Tunables (tests shorten them through self.__holmesBridgeConfig). Local to this
  // closure so they never collide with the worker's own names.
  var TUNING = (typeof self !== "undefined" && self.__holmesBridgeConfig) || {};
  // A PNG of a Retina viewport is easily 5 to 15 MB of base64; results travel
  // over the loopback bridge, so screenshots are JPEG and kept under this size.
  var MAX_SCREENSHOT_CHARS = Number(TUNING.maxScreenshotChars) || 4 * 1024 * 1024;
  var SCREENSHOT_MAX_WIDTH = 1600;
  // How long navigate waits for the page to finish loading. Below the app's 20s
  // result timeout so a slow page reports loaded:false instead of timing out.
  var NAVIGATE_TIMEOUT_MS = Number(TUNING.navigateTimeoutMs) || 15000;

  // Resolves when the tab reports status "complete" after arm() (so a completion
  // from the page being replaced is ignored), when it closes, or at the timeout.
  // Listeners are attached before navigation starts so a fast load is never missed.
  function waitForTabComplete(tabId, timeoutMs, targetUrl) {
    var started = Date.now(), armed = false, done = false, timer = null, finish;
    // Chrome resolves tabs.update before the new load begins, while the tab still
    // reports the PREVIOUS page as complete. So "complete" only counts once this
    // navigation was seen loading, or when the tab is complete at the target URL
    // with nothing pending (which also covers same document navigations).
    var sawLoading = false;
    function sameUrl(a, b) {
      try { return new URL(a).href === new URL(b).href; } catch (e) { return a === b; }
    }
    function landedOn(tab) {
      return !!tab && tab.status === "complete" && !tab.pendingUrl && !!targetUrl && sameUrl(tab.url, targetUrl);
    }
    var promise = new Promise(function (resolve) { finish = resolve; });
    function settle(result) {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      try { chrome.tabs.onUpdated.removeListener(onUpdated); } catch (_) { /* ignore */ }
      try { chrome.tabs.onRemoved.removeListener(onRemoved); } catch (_) { /* ignore */ }
      result.waitedMs = Date.now() - started;
      finish(result);
    }
    function onUpdated(id, info, tab) {
      if (id !== tabId || !info) return;
      if (info.status === "loading") { sawLoading = true; return; }
      if (!armed) return;
      if ((info.status === "complete" && sawLoading) || landedOn(tab)) settle({ complete: true });
    }
    function onRemoved(id) {
      if (id === tabId) settle({ complete: false, closed: true });
    }
    chrome.tabs.onUpdated.addListener(onUpdated);
    chrome.tabs.onRemoved.addListener(onRemoved);
    timer = setTimeout(function () { settle({ complete: false, timedOut: true }); }, timeoutMs);
    return {
      promise: promise,
      arm: async function () {
        armed = true;
        try {
          var tab = await chrome.tabs.get(tabId);
          if (tab && tab.status === "complete" && (sawLoading || landedOn(tab))) settle({ complete: true });
        } catch (e) {
          settle({ complete: false, closed: true });
        }
      },
      cancel: function () { settle({ complete: false, cancelled: true }); }
    };
  }

  function toBase64(buffer) {
    var bytes = new Uint8Array(buffer), binary = "";
    for (var i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  // Downscales a captured image to at most SCREENSHOT_MAX_WIDTH wide and re-encodes
  // it as JPEG until it fits. Null when the worker has no OffscreenCanvas.
  async function downscaleDataUrl(dataUrl, maxChars) {
    try {
      if (typeof OffscreenCanvas !== "function" || typeof createImageBitmap !== "function") return null;
      var blob = await (await fetch(dataUrl)).blob();
      var bitmap = await createImageBitmap(blob);
      var scale = Math.min(1, SCREENSHOT_MAX_WIDTH / bitmap.width);
      var width = Math.max(1, Math.round(bitmap.width * scale));
      var height = Math.max(1, Math.round(bitmap.height * scale));
      var canvas = new OffscreenCanvas(width, height);
      canvas.getContext("2d").drawImage(bitmap, 0, 0, width, height);
      if (bitmap.close) bitmap.close();
      var quality = 0.7, out = "";
      for (;;) {
        var jpeg = await canvas.convertToBlob({ type: "image/jpeg", quality: quality });
        out = "data:image/jpeg;base64," + toBase64(await jpeg.arrayBuffer());
        if (out.length <= maxChars || quality <= 0.3) break;
        quality -= 0.2;
      }
      return { dataUrl: out, width: width, height: height };
    } catch (e) {
      return null;
    }
  }

  async function resolveTabId(params) {
    if (params && typeof params.tabId === "number" && params.tabId >= 0) return params.tabId;
    try {
      var tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
      if (tabs && tabs[0] && typeof tabs[0].id === "number") return tabs[0].id;
      tabs = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tabs && tabs[0] && typeof tabs[0].id === "number") return tabs[0].id;
    } catch (e) { /* no tabs available */ }
    return -1;
  }

  async function runInTab(tabId, action, params) {
    try {
      var results = await chrome.scripting.executeScript({
        target: { tabId: tabId },
        func: holmesPageAction,
        args: [action, params || {}]
      });
      if (results && results[0] && results[0].result !== undefined) return results[0].result;
      return { ok: false, error: "no result returned from the page (restricted page?)" };
    } catch (e) {
      return { ok: false, error: "cannot run in tab: " + String(e && e.message ? e.message : e) };
    }
  }

  async function execute(cmd) {
    var action = cmd && cmd.action;
    var params = (cmd && cmd.params) || {};
    if (!action) return { ok: false, error: "command has no action" };

    try {
      switch (action) {
        case "navigate": {
          if (!params.url) return { ok: false, error: "navigate requires a url" };
          var navTabId = await resolveTabId(params);
          if (navTabId < 0) return { ok: false, error: "no target tab" };
          // Resolving right after tabs.update let the next command (click, extract)
          // run against the page being replaced. Wait for the load, bounded.
          var loading = waitForTabComplete(navTabId, NAVIGATE_TIMEOUT_MS, String(params.url));
          var navTab;
          try {
            navTab = await chrome.tabs.update(navTabId, { url: String(params.url) });
          } catch (e) {
            loading.cancel();
            throw e;
          }
          await loading.arm();
          var loaded = await loading.promise;
          if (loaded.closed) {
            return { ok: false, tabId: navTabId, url: String(params.url), error: "the tab was closed while navigating" };
          }
          var landed = null;
          try { landed = await chrome.tabs.get(navTabId); } catch (_) { /* closed after load */ }
          return { ok: true, tabId: navTab.id, url: (landed && landed.url) || String(params.url),
            title: landed ? landed.title : undefined, loaded: !!loaded.complete, waitedMs: loaded.waitedMs };
        }

        case "openTab": {
          var newTab = await chrome.tabs.create({
            url: params.url ? String(params.url) : undefined,
            active: params.active !== false
          });
          return { ok: true, tabId: newTab.id, url: newTab.url || newTab.pendingUrl || params.url || "", active: newTab.active };
        }

        case "listTabs": {
          var allTabs = await chrome.tabs.query({});
          return {
            ok: true,
            tabs: allTabs.map(function (t) {
              return { id: t.id, title: t.title, url: t.url, active: t.active, windowId: t.windowId, index: t.index };
            })
          };
        }

        case "screenshotTab": {
          var shotTabId = await resolveTabId(params);
          var shotTab = shotTabId >= 0 ? await chrome.tabs.get(shotTabId) : null;
          var windowId = shotTab ? shotTab.windowId : undefined;
          // captureVisibleTab grabs the ACTIVE tab of the window; note that if the
          // requested tab isn't active this returns whatever is frontmost there.
          var quality = 70;
          var dataUrl = await chrome.tabs.captureVisibleTab(windowId, { format: "jpeg", quality: quality });
          var downscaled = false;
          if (dataUrl && dataUrl.length > MAX_SCREENSHOT_CHARS) {
            var scaled = await downscaleDataUrl(dataUrl, MAX_SCREENSHOT_CHARS);
            if (scaled && scaled.dataUrl.length < dataUrl.length) { dataUrl = scaled.dataUrl; downscaled = true; }
          }
          // No canvas in this worker: fall back to recapturing at lower quality.
          while (!downscaled && dataUrl && dataUrl.length > MAX_SCREENSHOT_CHARS && quality > 30) {
            quality -= 20;
            dataUrl = await chrome.tabs.captureVisibleTab(windowId, { format: "jpeg", quality: quality });
          }
          return { ok: true, tabId: shotTab ? shotTab.id : -1, format: "jpeg", quality: quality, downscaled: downscaled,
            dataUrl: dataUrl, bytes: dataUrl ? dataUrl.length : 0 };
        }

        default: {
          if (PAGE_ACTIONS[action]) {
            var tabId = await resolveTabId(params);
            if (tabId < 0) return { ok: false, error: "no target tab" };
            return await runInTab(tabId, action, params);
          }
          return { ok: false, error: "unknown action: " + action };
        }
      }
    } catch (e) {
      return { ok: false, error: String(e && e.message ? e.message : e) };
    }
  }

  return { execute: execute };
})();
