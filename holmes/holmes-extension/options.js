// Holmes options page — manage the exclusion list, view/copy the token, re-pair,
// and set the heartbeat interval. Same loopback bridge, same storage keys the
// content script reads. Defensive throughout: the Holmes app may be down.

(function () {
  "use strict";

  var HEALTH_URL = "http://127.0.0.1:5766/health";
  var HEARTBEAT_URL = "http://127.0.0.1:5766/heartbeat";
  var EXCLUDE_KEY = "holmesExcludedHosts";
  var HEARTBEAT_KEY = "holmesHeartbeatMs";
  var TOKEN_KEY = "holmesToken";

  var el = function (id) { return document.getElementById(id); };
  var token = "";
  var revealed = false;

  // ── storage ──────────────────────────────────────────────────
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

  function normalizeHost(raw) {
    return String(raw || "").trim().toLowerCase()
      .replace(/^https?:\/\//, "").replace(/^www\./, "").split("/")[0].split("?")[0];
  }

  // ── pairing / connection ─────────────────────────────────────
  function setPair(dotClass, pillClass, pillText, msgHTML) {
    el("pairDot").className = "dot " + dotClass;
    var pill = el("pairPill");
    pill.className = "mono status-pill" + (pillClass ? " " + pillClass : "");
    pill.textContent = pillText;
    el("pairMsg").innerHTML = msgHTML;
  }

  async function checkPairing() {
    setPair("amber", "warn", "checking…", "Checking the Holmes bridge on 127.0.0.1:5766…");
    var healthOk = false;
    try { var r = await fetch(HEALTH_URL, { method: "GET" }); healthOk = r.ok; }
    catch (e) { healthOk = false; }
    if (!healthOk) {
      setPair("red", "err", "offline", "Holmes isn’t running. Start the Holmes app to pair.");
      return;
    }
    var status = 0, netErr = false;
    try {
      var r2 = await fetch(HEARTBEAT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Holmes-Token": token || "" },
        body: "{}"
      });
      status = r2.status;
    } catch (e) { netErr = true; }

    if (netErr) setPair("red", "err", "error", "Reached the port but the connection dropped.");
    else if (status === 200) setPair("green", "ok", "paired", "Holmes has adopted this extension’s token — you’re paired.");
    else if (status === 401) setPair("amber", "warn", "not paired", "Holmes is running but hasn’t adopted this token yet. Re-pair below.");
    else setPair("red", "err", "error", "Holmes responded with HTTP " + status + ".");
  }

  // ── token ────────────────────────────────────────────────────
  function maskToken(t) {
    if (!t) return "—";
    if (t.length <= 10) return t;
    return t.slice(0, 6) + "…" + t.slice(-4);
  }
  function renderToken() {
    el("tokenValue").textContent = revealed ? (token || "—") : maskToken(token);
    el("revealBtn").textContent = revealed ? "HIDE" : "REVEAL";
  }

  function wireToken() {
    el("revealBtn").addEventListener("click", function () { revealed = !revealed; renderToken(); });
    el("copyBtn").addEventListener("click", function () {
      if (!token) return;
      var done = function () {
        var b = el("copyBtn"); var prev = b.textContent;
        b.textContent = "COPIED"; setTimeout(function () { b.textContent = prev; }, 1200);
      };
      try {
        navigator.clipboard.writeText(token).then(done, function () { legacyCopy(token); done(); });
      } catch (e) { legacyCopy(token); done(); }
    });
  }
  function legacyCopy(text) {
    try {
      var ta = document.createElement("textarea");
      ta.value = text; document.body.appendChild(ta); ta.select();
      document.execCommand("copy"); document.body.removeChild(ta);
    } catch (e) { /* ignore */ }
  }

  function wireRepair() {
    el("repairBtn").addEventListener("click", function () {
      var btn = el("repairBtn"); btn.disabled = true;
      var out = el("repairResult"); out.hidden = false;
      out.textContent = "Pairing… open the pairing window in Holmes (Settings ▸ Privacy).";
      try {
        chrome.runtime.sendMessage({ type: "holmes:pairPing" }, function (res) {
          void chrome.runtime.lastError;
          setTimeout(function () {
            checkPairing(); btn.disabled = false;
            out.textContent = (res && res.ok)
              ? "Paired — Holmes adopted this extension."
              : "Not adopted yet. Arm the pairing window in Holmes, then press Re-pair again.";
          }, 700);
        });
      } catch (e) {
        btn.disabled = false;
        out.textContent = "Couldn’t reach the extension worker.";
      }
    });
  }

  // ── exclusion list ───────────────────────────────────────────
  async function getExcluded() {
    var r = await getStore([EXCLUDE_KEY]);
    return Array.isArray(r[EXCLUDE_KEY]) ? r[EXCLUDE_KEY] : [];
  }
  function renderExcluded(list) {
    var wrap = el("excludeList");
    wrap.innerHTML = "";
    el("excludeEmpty").hidden = list.length > 0;
    el("excludeCount").textContent = list.length + (list.length === 1 ? " site" : " sites");
    list.forEach(function (host) {
      var chip = document.createElement("span");
      chip.className = "chip";
      var label = document.createElement("span");
      label.textContent = host;
      var x = document.createElement("button");
      x.textContent = "✕";
      x.title = "Remove " + host;
      x.addEventListener("click", async function () {
        var cur = await getExcluded();
        cur = cur.filter(function (h) { return h !== host; });
        await setStore({ holmesExcludedHosts: cur });
        renderExcluded(cur);
      });
      chip.appendChild(label);
      chip.appendChild(x);
      wrap.appendChild(chip);
    });
  }
  function wireExclude() {
    async function add() {
      var host = normalizeHost(el("excludeInput").value);
      if (!host) return;
      var cur = await getExcluded();
      if (cur.indexOf(host) === -1) cur.push(host);
      await setStore({ holmesExcludedHosts: cur });
      el("excludeInput").value = "";
      renderExcluded(cur);
    }
    el("excludeAdd").addEventListener("click", add);
    el("excludeInput").addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.preventDefault(); add(); }
    });
  }

  // ── heartbeat ────────────────────────────────────────────────
  function markHeartbeat(ms) {
    var segs = document.querySelectorAll("#heartbeatSeg .seg");
    segs.forEach(function (s) {
      s.classList.toggle("active", Number(s.getAttribute("data-ms")) === ms);
    });
  }
  function wireHeartbeat(currentMs) {
    markHeartbeat(currentMs);
    document.querySelectorAll("#heartbeatSeg .seg").forEach(function (s) {
      s.addEventListener("click", async function () {
        var ms = Number(s.getAttribute("data-ms")) || 0;
        await setStore({ holmesHeartbeatMs: ms });
        markHeartbeat(ms);
      });
    });
  }

  // ── boot ─────────────────────────────────────────────────────
  document.addEventListener("DOMContentLoaded", async function () {
    wireToken();
    wireRepair();
    wireExclude();

    var store = await getStore([TOKEN_KEY, EXCLUDE_KEY, HEARTBEAT_KEY]);
    token = typeof store[TOKEN_KEY] === "string" ? store[TOKEN_KEY] : "";
    renderToken();
    renderExcluded(Array.isArray(store[EXCLUDE_KEY]) ? store[EXCLUDE_KEY] : []);
    var hb = typeof store[HEARTBEAT_KEY] === "number" ? store[HEARTBEAT_KEY] : 0;
    wireHeartbeat(hb);

    checkPairing();
  });
})();
