// Holmes popup — connection status, the live read for THIS tab (the trust
// surface), the per-site read toggle, and last-POST telemetry.
//
// Everything is best-effort and defensive: the popup must render even when the
// Holmes app is down, the tab is a chrome:// page, or the content script hasn't
// booted. Nothing here ever throws into an unhandled rejection.

(function () {
  "use strict";

  var HEALTH_URL = "http://127.0.0.1:5766/health";
  var HEARTBEAT_URL = "http://127.0.0.1:5766/heartbeat";
  var EXCLUDE_KEY = "holmesExcludedHosts";
  var TOKEN_KEY = "holmesToken";

  var el = function (id) { return document.getElementById(id); };
  var currentTab = null;
  var currentHost = "";

  // ── storage helpers ──────────────────────────────────────────
  function getStore(keys) {
    return new Promise(function (resolve) {
      try { chrome.storage.local.get(keys, function (r) { void chrome.runtime.lastError; resolve(r || {}); }); }
      catch (e) { resolve({}); }
    });
  }
  function setStore(obj) {
    return new Promise(function (resolve) {
      try { chrome.storage.local.set(obj, function () { void chrome.runtime.lastError; resolve(); }); }
      catch (e) { resolve(); }
    });
  }
  async function getExcluded() {
    var r = await getStore([EXCLUDE_KEY]);
    return Array.isArray(r[EXCLUDE_KEY]) ? r[EXCLUDE_KEY] : [];
  }
  async function getToken() {
    var r = await getStore([TOKEN_KEY]);
    return typeof r[TOKEN_KEY] === "string" ? r[TOKEN_KEY] : "";
  }

  function normalizeHost(u) {
    try { return new URL(u).hostname.replace(/^www\./i, "").toLowerCase(); }
    catch (e) { return ""; }
  }

  // ── connection status ────────────────────────────────────────
  function setConn(dotClass, pillClass, pillText, msgHTML, showPair) {
    el("connDot").className = "dot " + dotClass;
    var pill = el("connPill");
    pill.className = "mono status-pill" + (pillClass ? " " + pillClass : "");
    pill.textContent = pillText;
    el("connMsg").innerHTML = msgHTML;
    el("pairBlock").hidden = !showPair;
  }

  async function checkConnection() {
    setConn("amber", "warn", "checking…",
      "Checking whether Holmes is listening on 127.0.0.1:5766…", false);

    var healthOk = false;
    try { var r = await fetch(HEALTH_URL, { method: "GET" }); healthOk = r.ok; }
    catch (e) { healthOk = false; }

    if (!healthOk) {
      setConn("red", "err", "offline",
        "Holmes isn’t running. Start the Holmes app, then reopen this popup.", false);
      return;
    }

    // Reachable — is our token accepted? A heartbeat from the extension origin is
    // 200 when paired, 401 when Holmes hasn't adopted this extension yet.
    var token = await getToken();
    var status = 0, netErr = false;
    try {
      var r2 = await fetch(HEARTBEAT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Holmes-Token": token || "" },
        body: "{}"
      });
      status = r2.status;
    } catch (e) { netErr = true; }

    if (netErr) {
      setConn("red", "err", "error",
        "Reached the port but the connection dropped. Is Holmes still running?", false);
    } else if (status === 200) {
      setConn("green", "ok", "connected",
        "Holmes is paired and reading page context from this browser.", false);
    } else if (status === 401) {
      setConn("amber", "warn", "not paired",
        "Holmes is running but hasn’t adopted this extension yet.", true);
    } else {
      setConn("red", "err", "error",
        "Holmes responded with HTTP " + status + ". Try re-pairing.", true);
    }
  }

  function showPairResult(text) {
    var p = el("pairResult");
    p.hidden = false;
    p.textContent = text;
  }

  function wirePairing() {
    el("pairBtn").addEventListener("click", function () {
      var btn = el("pairBtn");
      btn.disabled = true;
      showPairResult("Pairing… make sure the pairing window is open in Holmes.");
      try {
        chrome.runtime.sendMessage({ type: "holmes:pairPing" }, function (res) {
          void chrome.runtime.lastError;
          setTimeout(function () {
            checkConnection();
            btn.disabled = false;
            if (res && res.ok) showPairResult("Paired — Holmes adopted this extension.");
            else showPairResult("Not adopted yet. Open Settings ▸ Privacy ▸ Pair browser extension in Holmes, then press Pair again.");
          }, 700);
        });
      } catch (e) {
        btn.disabled = false;
        showPairResult("Couldn’t reach the extension worker. Reload the extension.");
      }
    });
  }

  // ── live context for this tab ────────────────────────────────
  function ctxUnavailable(msgHTML) {
    el("ctxHeadline").textContent = "Nothing to read here";
    el("ctxHeadline").classList.add("muted");
    el("ctxRows").hidden = true;
    var note = el("ctxNote");
    note.hidden = false;
    note.innerHTML = msgHTML;
  }

  function ctxExcluded(host) {
    el("ctxHeadline").textContent = "Reading is off for " + (host || "this site");
    el("ctxHeadline").classList.add("muted");
    el("ctxRows").hidden = true;
    var note = el("ctxNote");
    note.hidden = false;
    note.innerHTML = "You turned off <b>Don’t read this site</b> below — Holmes extracts nothing and sends nothing here.";
  }

  function renderContext(res) {
    var c = res.context || {};
    el("ctxHeadline").classList.remove("muted");
    el("ctxHeadline").textContent = c.headline || res.title || "(no readable headline yet)";
    el("ctxRows").hidden = false;
    el("ctxSite").textContent = c.site || res.host || "—";
    el("ctxSurface").textContent = c.surface || "—";
    el("ctxActivity").textContent = c.activity || "—";
    var note = el("ctxNote");
    if (res.isActiveTab === false || res.visible === false) {
      note.hidden = false;
      note.innerHTML = "This tab is in the background — Holmes won’t narrate it as what you’re doing.";
    } else {
      note.hidden = true;
    }
    updateFooter(res);
  }

  function loadContext(tab) {
    if (!tab || typeof tab.id !== "number") { ctxUnavailable("No active tab."); return; }
    if (!/^https?:/i.test(tab.url || "")) {
      ctxUnavailable("Holmes only reads normal web pages. This is a browser-internal or restricted page.");
      return;
    }
    try {
      chrome.tabs.sendMessage(tab.id, { type: "holmes:getContext" }, function (res) {
        var err = chrome.runtime.lastError;
        if (err || !res) {
          ctxUnavailable("The Holmes content script isn’t running on this tab yet. Reload the tab and reopen this popup.");
          return;
        }
        if (!res.ok) { ctxUnavailable("Couldn’t read this tab: " + (res.error || "unknown error")); return; }
        if (res.excluded) { ctxExcluded(res.host); return; }
        renderContext(res);
      });
    } catch (e) {
      ctxUnavailable("Couldn’t message this tab.");
    }
  }

  // ── footer telemetry ─────────────────────────────────────────
  function relTime(ms) {
    if (!ms) return "";
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (s < 2) return "just now";
    if (s < 60) return s + "s ago";
    var m = Math.round(s / 60);
    if (m < 60) return m + "m ago";
    return Math.round(m / 60) + "h ago";
  }
  function fmtBytes(n) {
    n = Number(n) || 0;
    if (n < 1024) return n + " B";
    return (n / 1024).toFixed(1) + " KB";
  }
  function updateFooter(res) {
    var icon = el("footIcon"), text = el("footText");
    if (res.lastAckAt) {
      icon.textContent = "↑";
      text.textContent = "last POST " + relTime(res.lastAckAt) + " · " + fmtBytes(res.lastPostBytes);
    } else if (res.lastPostAt) {
      icon.textContent = "↻";
      text.textContent = "sent " + relTime(res.lastPostAt) + " · " + fmtBytes(res.lastPostBytes) + " (unconfirmed)";
    } else {
      icon.textContent = "↑";
      text.textContent = "No POST yet";
    }
  }

  // ── per-site toggle ──────────────────────────────────────────
  function setSwitch(on) {
    var sw = el("excludeSwitch");
    sw.classList.toggle("on", !!on);
    sw.setAttribute("aria-checked", on ? "true" : "false");
  }
  async function toggleExclude() {
    var on = !el("excludeSwitch").classList.contains("on");
    setSwitch(on);
    var list = await getExcluded();
    if (on) { if (currentHost && list.indexOf(currentHost) === -1) list.push(currentHost); }
    else { list = list.filter(function (h) { return h !== currentHost; }); }
    await setStore({ holmesExcludedHosts: list });
    // Give the content script a beat to react to the storage change, then refresh.
    setTimeout(function () { loadContext(currentTab); }, 300);
  }

  // ── boot ─────────────────────────────────────────────────────
  function activeTab() {
    return new Promise(function (resolve) {
      try {
        chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
          void chrome.runtime.lastError;
          resolve(tabs && tabs[0] ? tabs[0] : null);
        });
      } catch (e) { resolve(null); }
    });
  }

  document.addEventListener("DOMContentLoaded", async function () {
    wirePairing();

    el("openOptions").addEventListener("click", function () {
      try { chrome.runtime.openOptionsPage(); } catch (e) { /* ignore */ }
    });
    el("recaptureBtn").addEventListener("click", function () {
      if (!currentTab) return;
      try { chrome.tabs.sendMessage(currentTab.id, { type: "holmes:recapture" }, function () { void chrome.runtime.lastError; }); } catch (e) { /* ignore */ }
      setTimeout(function () { loadContext(currentTab); }, 300);
    });

    var sw = el("excludeSwitch");
    sw.addEventListener("click", toggleExclude);
    sw.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggleExclude(); }
    });

    currentTab = await activeTab();
    currentHost = currentTab ? normalizeHost(currentTab.url) : "";
    el("toggleHost").textContent = currentHost || "this site";

    var excluded = await getExcluded();
    setSwitch(currentHost && excluded.indexOf(currentHost) > -1);

    checkConnection();
    loadContext(currentTab);
  });
})();
