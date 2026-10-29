// Brand guidelines page: the theme (one choice shared with the setup console) and the copy buttons.
// Loaded in <head> so the stored theme applies before the first paint. No inline script: the CSP
// allows scripts from this site only.
(function () {
  "use strict";

  // ---------- theme (per-viewer convenience, stored only in this browser) ----------
  var KEY = "sp-theme";                                   // the setup console's key
  var BAR = { light: "#FFFFFF", dark: "#121920" };        // --panel, the top bar under the browser bar
  var root = document.documentElement;

  function getTheme() {
    try { var t = localStorage.getItem(KEY); return t === "light" || t === "dark" ? t : "system"; } catch (e) { return "system"; }
  }
  function applyTheme(t) {
    if (t === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", t);
    // theme-color follows the system through its media query; a choice in the page overrides both
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    for (var i = 0; i < metas.length; i++) {
      var dark = /dark/.test(metas[i].getAttribute("media") || "");
      metas[i].setAttribute("content", t === "system" ? BAR[dark ? "dark" : "light"] : BAR[t]);
    }
  }
  var theme = getTheme();
  applyTheme(theme);

  document.addEventListener("DOMContentLoaded", function () {
    var btn = document.getElementById("theme-btn"), label = document.getElementById("theme-label");
    function show() {
      label.textContent = theme.charAt(0).toUpperCase() + theme.slice(1);
      btn.setAttribute("aria-label", "Theme: " + theme + ". Change theme");
    }
    show();
    btn.addEventListener("click", function () {
      var dark = !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches);
      var order = dark ? ["system", "light", "dark"] : ["system", "dark", "light"];
      theme = order[(order.indexOf(theme) + 1) % order.length];
      applyTheme(theme);
      show();
      try { localStorage.setItem(KEY, theme); } catch (e) { /* storage blocked: the choice lasts for this visit */ }
    });
    // a change made in the console in another tab
    window.addEventListener("storage", function (e) {
      if (e.key !== KEY && e.key !== null) return;
      theme = getTheme();
      applyTheme(theme);
      show();
    });

    // ---------- copy buttons: a colour value (data-copy) or an SVG source (data-copy-from) ----------
    // the toast is for the eyes; screen readers hear the live region, which stays in the page
    var toast = document.querySelector(".toast"), live = document.getElementById("copy-status"), timer;
    function say(msg) {
      live.textContent = "";                              // so the same message twice is read twice
      setTimeout(function () { live.textContent = msg; }, 50);
      toast.textContent = msg;
      toast.hidden = false;
      clearTimeout(timer);
      timer = setTimeout(function () { toast.hidden = true; }, 2200);
    }
    function selectNode(node) {
      var range = document.createRange();
      range.selectNodeContents(node);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
    }
    document.addEventListener("click", function (e) {
      var b = e.target.closest && e.target.closest("[data-copy], [data-copy-from]");
      if (!b) return;
      var text, node, what;
      if (b.hasAttribute("data-copy")) {
        text = b.getAttribute("data-copy"); node = b; what = text;
      } else {
        node = document.getElementById(b.getAttribute("data-copy-from"));
        if (!node) return;
        text = node.textContent; what = "the SVG";
        var det = document.getElementById("d-" + node.id);
        if (det) det.open = true;
      }
      function fallback() { selectNode(node); say("Selected. Press Ctrl+C or ⌘C to copy."); }
      try {
        if (!navigator.clipboard || !navigator.clipboard.writeText) return fallback();
        navigator.clipboard.writeText(text).then(function () { say("Copied " + what); }, fallback);
      } catch (err) { fallback(); }
    });
  });
})();
