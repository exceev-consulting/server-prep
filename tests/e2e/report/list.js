/* E2E report list (tests/e2e/report/list.html), drawn from index.js (window.E2E_INDEX).
   Titles come from pull requests, so every string is untrusted: it is only ever set with
   textContent, and links are built from values that pass a strict pattern. */
(function () {
  "use strict";

  var SVGNS = "http://www.w3.org/2000/svg";
  // Same rule as build-report.sh --index: only the folders it can have built get a link.
  var PATH_RE = /^(main|pr-[1-9][0-9]{0,6})\/$/;
  var SHA_RE = /^[0-9a-f]{7,40}$/;
  var RUN_RE = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/actions\/runs\/([0-9]+)(\/attempts\/[0-9]+)?$/;

  // ---------- helpers ----------
  var OS_RE = /^[a-z0-9][a-z0-9.-]{0,39}$/;
  function $(id) { return document.getElementById(id); }
  function str(v) { return typeof v === "string" ? v : (typeof v === "number" && isFinite(v) ? String(v) : ""); }
  function arr(v) { return Array.isArray(v) ? v : []; }
  function obj(v) { return v && typeof v === "object" && !Array.isArray(v) ? v : {}; }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null && text !== "") e.textContent = String(text);
    return e;
  }
  function add(parent) {
    for (var i = 1; i < arguments.length; i++) {
      var c = arguments[i];
      if (c == null || c === false) continue;
      parent.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return parent;
  }
  function icon(name) {
    var s = document.createElementNS(SVGNS, "svg");
    s.setAttribute("class", "i");
    s.setAttribute("aria-hidden", "true");
    var u = document.createElementNS(SVGNS, "use");
    u.setAttribute("href", "#i-" + name);
    s.appendChild(u);
    return s;
  }
  function extLink(href, text) {
    var a = el("a", null, text);
    a.href = href;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    return a;
  }
  function when(v) {
    var m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(str(v));
    return m ? m[1] + " " + m[2] + " UTC" : str(v);
  }
  function alertBox(kind, title, text) {
    var a = el("div", "alert " + kind);
    a.appendChild(icon("alert"));
    var d = el("div");
    add(d, el("b", null, title), el("span", null, text));
    a.appendChild(d);
    return a;
  }

  // ---------- theme (per-viewer convenience, stored only in this browser; same key as the console) ----------
  var hostTheme = document.documentElement.getAttribute("data-theme");
  var theme = "system";
  function getTheme() { try { return localStorage.getItem("sp-theme") || "system"; } catch (e) { return "system"; } }
  function applyTheme(t) {
    if (t !== "system") document.documentElement.setAttribute("data-theme", t);
    else if (hostTheme) document.documentElement.setAttribute("data-theme", hostTheme);
    else document.documentElement.removeAttribute("data-theme");
    $("theme-label").textContent = t.charAt(0).toUpperCase() + t.slice(1);
    $("theme-btn").setAttribute("aria-label", "Theme: " + t + ". Change theme");
  }
  theme = getTheme();
  if (["system", "light", "dark"].indexOf(theme) < 0) theme = "system";
  applyTheme(theme);
  $("theme-btn").addEventListener("click", function () {
    var dark = hostTheme ? hostTheme === "dark" : !!(window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches);
    var order = dark ? ["system", "light", "dark"] : ["system", "dark", "light"];
    theme = order[(order.indexOf(theme) + 1) % order.length];
    applyTheme(theme);
    try { localStorage.setItem("sp-theme", theme); } catch (e) { /* storage blocked: the choice lasts for this visit */ }
  });

  // ---------- data ----------
  var X = window.E2E_INDEX;
  var list = $("reps");
  if (!X || typeof X !== "object") {
    add($("alerts"), alertBox("bad", "Missing data", "index.js did not load. Build the list with tests/e2e/build-report.sh --index."));
    list.hidden = true;
    return;
  }
  // The page checks every shape again, so a hand-made index.js cannot break it.
  var seen = {};
  var reps = arr(X.reports).map(function (r) {
    r = obj(r);
    var path = PATH_RE.test(str(r.path)) ? r.path : "";
    var run = RUN_RE.exec(str(r.run_url));
    return {
      path: path, main: path === "main/", pr: path && path !== "main/" ? path.slice(3, -1) : "",
      title: str(r.title), sha: SHA_RE.test(str(r.sha)) ? r.sha : "",
      status: r.status === "passed" ? "passed" : "failed", date: str(r.date),
      run: run ? { url: run[0], repo: run[1], id: run[2] } : null,
      counts: obj(r.counts),
      oses: arr(r.oses).map(obj).filter(function (o) { return OS_RE.test(str(o.os)); }).slice(0, 20)
    };
  }).filter(function (r) {
    if (!r.path || seen[r.path]) return false;
    seen[r.path] = true;
    return true;
  });
  // main first, then pull requests, newest number first
  reps.sort(function (a, b) { return (b.main - a.main) || (Number(b.pr) - Number(a.pr)); });

  // ---------- header ----------
  var prs = reps.filter(function (r) { return !r.main; }).length;
  var hasMain = reps.some(function (r) { return r.main; });
  var m = $("meta");
  function item(k, v) {
    var s = el("span");
    add(s, el("span", "k", k), v);
    m.appendChild(s);
  }
  item("Reports", (hasMain ? "main and " : "") + (prs === 1 ? "1 pull request" : prs + " pull requests"));
  // The headline is the state of main: what a visitor wants to know first.
  var mainRep = reps.filter(function (r) { return r.main; })[0];
  if (mainRep && mainRep.oses.length) {
    var good = mainRep.oses.filter(function (o) { return o.status === "passed"; }).length;
    $("verdict").textContent = good === mainRep.oses.length
      ? "On main, every system passes: " + good + " of " + good + ", from a fresh cloud image to 0 FAIL after a reboot."
      : "On main, " + good + " of " + mainRep.oses.length + " systems pass. Open the report to see the first failed check.";
  }
  if (str(X.generated)) item("Updated", when(X.generated));
  $("foot-gen").textContent = str(X.generated) ? "List updated " + when(X.generated) : "";

  // ---------- list ----------
  reps.forEach(function (r) {
    var li = el("li", "rep");
    var ok = r.status === "passed";
    var pill = el("span", "pill " + (ok ? "ok" : "bad"));
    add(pill, icon(ok ? "check" : "x"), ok ? "Passed" : "Failed");

    var main = el("div", "rep-main");
    var title = el("div", "rep-title");
    if (r.main) title.appendChild(el("span", "k", "main"));
    else if (r.run) title.appendChild(add(el("span", "k"), extLink("https://github.com/" + r.run.repo + "/pull/" + r.pr, "PR #" + r.pr)));
    else title.appendChild(el("span", "k", "PR #" + r.pr));
    var a = el("a", null, r.main ? "Latest run on main" : (r.title || "Pull request #" + r.pr));
    a.href = r.path;
    title.appendChild(a);

    var sub = el("div", "rep-sub");
    if (r.sha) {
      var c = el("code", null, r.sha.slice(0, 7));
      var cs = el("span");
      add(cs, "Commit ");
      if (r.run && r.sha.length === 40) { var ca = extLink("https://github.com/" + r.run.repo + "/commit/" + r.sha, ""); ca.appendChild(c); cs.appendChild(ca); }
      else cs.appendChild(c);
      sub.appendChild(cs);
    }
    if (r.date) sub.appendChild(el("span", null, when(r.date)));
    if (r.run) sub.appendChild(add(el("span"), extLink(r.run.url, "Run #" + r.run.id)));
    add(main, title, sub);

    // One chip per system: the matrix of the report at a glance.
    if (r.oses.length) {
      var chips = el("ul", "oschips");
      chips.setAttribute("aria-label", "Systems");
      r.oses.forEach(function (o) {
        var st = o.status === "passed" ? "ok" : o.status === "error" ? "warn" : "bad";
        var li2 = el("li", "osc " + st);
        var a2 = el("a");
        a2.href = r.path + "#os=" + encodeURIComponent(str(o.os));
        a2.title = (str(o.label) || str(o.os)) + ": " + (o.status === "passed" ? "passed" : o.status === "error" ? "no results" : "failed");
        add(a2, icon(st === "ok" ? "check" : st === "warn" ? "alert" : "x"), el("span", null, str(o.os)));
        var d = Number(o.duration_s);
        if (isFinite(d) && d > 0) a2.appendChild(el("span", "dur", Math.round(d / 60) + " min"));
        li2.appendChild(a2);
        chips.appendChild(li2);
      });
      main.appendChild(chips);
      var c = r.counts, n = function (v) { v = Number(v); return isFinite(v) && v >= 0 ? v : 0; };
      var total = n(c.passed) + n(c.failed) + n(c.skipped);
      var fails = r.oses.map(function (o) { return o.audit_fail; }).filter(function (v) { return typeof v === "number"; });
      var bits = [];
      if (total) bits.push(n(c.passed) + " of " + total + " scenarios passed" + (n(c.skipped) ? ", " + n(c.skipped) + " skipped" : ""));
      if (fails.length) bits.push("audit after reboot: " + Math.max.apply(null, fails) + " FAIL at worst" +
        (fails.length < r.oses.length ? " (" + fails.length + " of " + r.oses.length + " systems got there)" : ""));
      if (bits.length) main.appendChild(el("div", "rep-stats", bits.join(" · ")));
    }

    var go = el("a", "tbtn", "Open report");
    go.href = r.path;
    go.setAttribute("aria-label", "Open the report: " + (r.main ? "main" : "pull request #" + r.pr));
    go.appendChild(icon("arrow"));
    add(li, pill, main, go);
    list.appendChild(li);
  });
  if (!reps.length) {
    var e = el("li", "empty");
    add(e, el("b", null, "No report yet"), el("span", null, "A report appears here after the e2e workflow runs on main or on an open pull request."));
    list.appendChild(e);
  }
})();
