// Holmes — MAIN-world history hook.
//
// Why this file exists at all: a content script runs in an *isolated world*, which has
// its own copy of every JS global. Patching `history.pushState` there does NOT intercept
// the page's own calls — the page holds a different History.prototype function object.
// So the only reliable way to hear SPA navigations the instant they happen is to run a
// tiny patch in the page's own world and relay it back over a DOM CustomEvent (DOM events
// are shared across worlds even though the JS heaps are not).
//
// This runs at document_start on every page the user visits, so it must be minimal,
// leak nothing into the page's global scope, and never throw.

(function () {
  "use strict";
  try {
    // Guard against double-injection (bfcache restores, extension reloads).
    if (window.__holmesHistoryHook) return;
    Object.defineProperty(window, "__holmesHistoryHook", { value: true, configurable: true });

    var fire = function (kind) {
      try {
        window.dispatchEvent(new CustomEvent("holmes:navigated", { detail: { kind: kind } }));
      } catch (e) { /* the page may have frozen CustomEvent — nothing we can do, and nothing we should break */ }
    };

    var wrap = function (name) {
      var original = history[name];
      if (typeof original !== "function") return;
      history[name] = function () {
        var result = original.apply(this, arguments);
        // Fire *after* the URL has actually changed so listeners read the new location.
        fire(name);
        return result;
      };
    };

    wrap("pushState");
    wrap("replaceState");

    window.addEventListener("popstate", function () { fire("popstate"); }, true);
    window.addEventListener("hashchange", function () { fire("hashchange"); }, true);
  } catch (e) {
    // A broken hook must never break the user's browsing.
  }
})();
