/* E2E report page (tests/e2e/report/index.html), drawn from data.js (window.E2E_REPORT).
   The data comes from VMs that ran pull request code, so every string is untrusted: it is only
   ever set with textContent, and links are built from values that pass a strict pattern. */
(function () {
  "use strict";

  var SVGNS = "http://www.w3.org/2000/svg";
  var OS_RE = /^[a-z0-9][a-z0-9.-]*$/;
  var ID_RE = /^[a-z0-9][a-z0-9-]*$/;
  // Same rule as build-report.sh: only these files are copied, so only these get a link.
  var FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*\.(log|txt|json|md|tsv|csv)$/;
  var REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
  var SHA_RE = /^[0-9a-f]{7,40}$/;
  var PR_RE = /^[1-9][0-9]{0,6}$/;
  var RUN_RE = /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/actions\/runs\/[0-9]+(\/attempts\/[0-9]+)?$/;
  var FILTERS = ["all", "failed", "passed", "skipped"];
  var LABEL = { all: "All", passed: "Passed", failed: "Failed", skipped: "Skipped", error: "No results" };
  var ICON = { passed: "check", failed: "x", skipped: "skip", error: "alert" };
  var MAX_FAILS = 40;

  // ---------- helpers ----------
  function $(id) { return document.getElementById(id); }
  function str(v) { return typeof v === "string" ? v : (typeof v === "number" && isFinite(v) ? String(v) : ""); }
  function num(v) { return typeof v === "number" && isFinite(v) && v >= 0 ? v : 0; }
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
  function dot(status) {
    var d = el("span", "dot " + status);
    d.appendChild(icon(ICON[status] || "alert"));
    return d;
  }
  function srText(t) { return el("span", "sr", t); }
  function extLink(href, text) {
    var a = el("a", null, text);
    a.href = href;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    return a;
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function dur(v) {
    var s = Math.round(num(v));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m " + pad(s % 60) + "s";
    return Math.floor(m / 60) + "h " + pad(m % 60) + "m";
  }
  function when(v) {
    var m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/.exec(str(v));
    return m ? m[1] + " " + m[2] + " UTC" : str(v);
  }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : (many || one + "s")); }
  function bytes(v) {
    var n = num(v);
    if (n < 1024) return n + " B";
    if (n < 1048576) return Math.round(n / 1024) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }
  var reduced = !!(window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches);

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
  var R = window.E2E_REPORT;
  if (!R || typeof R !== "object") {
    $("status").textContent = "No data";
    add($("alerts"), alertBox("bad", "Missing data", "data.js did not load. Build the report with tests/e2e/build-report.sh."));
    $("matrix").hidden = true;
    $("systems").hidden = true;
    return;
  }
  var meta = obj(R.meta);
  var repo = REPO_RE.test(str(meta.repo)) ? meta.repo : "";

  // The page checks every shape again, so a hand-made data.js cannot break it.
  function normScen(s, i) {
    s = obj(s);
    var st = ["passed", "failed", "skipped"].indexOf(s.status) >= 0 ? s.status : "failed";
    var id = ID_RE.test(str(s.id)) ? s.id : "scenario-" + (i + 1);
    var asserts = arr(s.assertions).map(function (a) { a = obj(a); return { name: str(a.name), ok: a.ok === true, detail: str(a.detail) }; });
    // failed checks first, then in run order
    asserts = asserts.filter(function (a) { return !a.ok; }).concat(asserts.filter(function (a) { return a.ok; }));
    return {
      id: id, title: str(s.title) || id, group: str(s.group), status: st, duration: num(s.duration_s),
      reason: str(s.reason), assertions: asserts,
      logs: arr(s.logs).map(str).filter(Boolean), order: i
    };
  }
  function normAudit(a) {
    if (!a || typeof a !== "object") return null;
    return { pass: num(a.pass), warn: num(a.warn), fail: num(a.fail), info: num(a.info), score: num(a.score) };
  }
  function normOs(o, i) {
    o = obj(o);
    var id = OS_RE.test(str(o.os)) ? o.os : "";
    var status = o.status === "passed" || o.status === "failed" ? o.status : "error";
    var att = new Map();
    arr(o.attachments).forEach(function (a) {
      a = obj(a);
      var n = str(a.name);
      if (n && !att.has(n)) att.set(n, { state: str(a.state), size: num(a.size) });
    });
    var audit = obj(o.audit), image = obj(o.image);
    var seen = new Set();
    var scens = arr(o.scenarios).map(normScen).filter(function (s) {
      if (seen.has(s.id)) return false;
      seen.add(s.id);
      return true;
    });
    return {
      idx: i, id: id, label: str(o.label) || id || "Unknown system", status: status, reason: str(o.reason),
      release: str(o.os_release), kernel: str(o.kernel), accel: str(o.accel), cpus: num(o.cpus), memory: num(o.memory_mb),
      started: str(o.started), duration: num(o.duration_s),
      image: { url: str(image.url), checksum: str(image.checksum) },
      audit: { fresh: normAudit(audit.fresh), prepared: normAudit(audit.prepared), rebooted: normAudit(audit.rebooted) },
      steps: arr(o.steps).map(function (s) { s = obj(s); return { step: str(s.step), label: str(s.label), first: str(s.first), second: str(s.second) }; }).filter(function (s) { return s.step; }),
      files: arr(o.files).map(function (f) { f = obj(f); return { name: str(f.name), title: str(f.title) }; }).filter(function (f) { return f.name; }),
      scenarios: scens, att: att
    };
  }
  var oses = arr(R.oses).map(normOs);
  var counts = { passed: 0, failed: 0, skipped: 0 };
  oses.forEach(function (o) { o.scenarios.forEach(function (s) { counts[s.status]++; }); });
  var total = counts.passed + counts.failed + counts.skipped;
  var overall = R.status === "passed" && oses.length > 0 && oses.every(function (o) { return o.status === "passed"; }) ? "passed" : "failed";

  // ---------- header ----------
  function alertBox(kind, title, text) {
    var a = el("div", "alert " + kind);
    a.appendChild(icon(kind === "info" ? "info" : "alert"));
    var d = el("div");
    add(d, el("b", null, title), el("span", null, text));
    a.appendChild(d);
    return a;
  }
  function renderHead() {
    var pill = $("status");
    pill.textContent = "";
    pill.className = "hpill " + (overall === "passed" ? "ok" : "bad");
    add(pill, icon(overall === "passed" ? "check" : "x"), overall === "passed" ? "Passed" : "Failed");

    var nOs = oses.length;
    var bad = oses.filter(function (o) { return o.status !== "passed"; }).length;
    var errs = oses.filter(function (o) { return o.status === "error"; }).length;
    var v;
    if (!nOs) v = "No system reported results.";
    else if (!bad) v = (nOs === 1 ? "The only system passed" : "All " + nOs + " systems passed") + (counts.skipped ? ". " + plural(counts.skipped, "scenario was", "scenarios were") + " skipped." : ", with every scenario green.");
    else {
      v = bad + " of " + plural(nOs, "system") + " failed.";
      if (counts.failed) v += " " + plural(counts.failed, "scenario") + " failed.";
      if (errs) v += " " + (errs === 1 ? "1 system has" : errs + " systems have") + " no results.";
    }
    $("verdict").textContent = v;
    document.title = (overall === "passed" ? "Passed" : "Failed") + " · E2E report · server-prep";

    var m = $("meta");
    function item(k, parts) {
      var s = el("span");
      add(s, el("span", "k", k));
      parts.forEach(function (p) { add(s, p); });
      m.appendChild(s);
    }
    var source = str(meta.source);
    var pr = PR_RE.test(str(meta.pr)) ? meta.pr : "";
    if (pr) {
      var prParts = [repo ? extLink("https://github.com/" + repo + "/pull/" + pr, "#" + pr) : "#" + pr];
      if (str(meta.pr_title)) prParts.push(el("span", "ttl", str(meta.pr_title)));
      item("Pull request", prParts);
    } else if (source === "main") {
      item("Branch", [el("code", null, "main")]);
    } else if (str(meta.ref)) {
      item("Ref", [el("code", null, str(meta.ref).replace(/^refs\/heads\//, ""))]);
    }
    var sha = SHA_RE.test(str(meta.sha)) ? meta.sha : "";
    if (sha) {
      var c = el("code", null, sha.slice(0, 7));
      if (repo) { var a = extLink("https://github.com/" + repo + "/commit/" + sha, ""); a.appendChild(c); item("Commit", [a]); }
      else item("Commit", [c]);
    }
    if (RUN_RE.test(str(meta.run_url))) item("Run", [extLink(meta.run_url, str(meta.run_id) ? "#" + meta.run_id : "GitHub Actions")]);
    else if (/^[0-9]{1,20}$/.test(str(meta.run_id))) item("Run", ["#" + meta.run_id]);
    var srcLabel = { pr: "pull request", main: "main", local: "local run", dispatch: "manual run" }[source];
    if (str(meta.event)) item("Event", [str(meta.event)]);
    else if (srcLabel) item("Source", [srcLabel]);
    if (str(meta.generated)) item("Generated", [when(meta.generated)]);

    // The list of reports is one folder up only on the site (e2e/main/, e2e/pr-<n>/). The e2e-report
    // artifact is built with the same source, and opened from disk its ../ is just the download folder.
    var onSite = location.protocol !== "file:" && /\/e2e\/(main|pr-[1-9][0-9]{0,6})\/(index\.html)?$/.test(location.pathname);
    if ((source === "pr" || source === "main") && onSite) $("nav-all").hidden = false;
    if (repo) $("nav-repo").href = "https://github.com/" + repo;
    $("foot-gen").textContent = str(meta.generated) ? "Report generated " + when(meta.generated) : "";
  }

  // ---------- KPIs ----------
  function renderKpis() {
    var k = $("kpis");
    function kpi(lbl, val, small, cap, cls) {
      var d = el("div");
      var v = el("span", "val" + (cls ? " " + cls : ""), val);
      if (small) v.appendChild(el("small", null, small));
      add(d, el("span", "lbl", lbl), v, el("span", "cap", cap));
      k.appendChild(d);
    }
    var nOs = oses.length;
    var okOs = oses.filter(function (o) { return o.status === "passed"; }).length;
    var errs = oses.filter(function (o) { return o.status === "error"; }).length;
    var failedOs = nOs - okOs - errs;
    var capOs = !nOs ? "no results" : okOs === nOs ? "all passed" : [failedOs ? failedOs + " failed" : "", errs ? errs + " without results" : ""].filter(Boolean).join(", ");
    kpi("Systems", String(okOs), "/ " + nOs + " passed", capOs, okOs === nOs && nOs ? "ok" : "bad");

    kpi("Scenarios", String(counts.passed), "/ " + total + " passed", counts.failed + " failed · " + counts.skipped + " skipped", counts.failed ? "bad" : "");

    var sum = 0, longest = null;
    oses.forEach(function (o) { sum += o.duration; if (!longest || o.duration > longest.duration) longest = o; });
    kpi("Total time", dur(sum), "", longest && longest.duration ? "VM time in all. Longest: " + (longest.id || longest.label) + ", " + dur(longest.duration) : "No VM time recorded");

    var worst = null, missing = 0;
    oses.forEach(function (o) {
      var a = o.audit.rebooted;
      if (!a) { missing++; return; }
      if (!worst || a.fail > worst.a.fail || (a.fail === worst.a.fail && (a.warn > worst.a.warn || (a.warn === worst.a.warn && a.score < worst.a.score)))) worst = { o: o, a: a };
    });
    var worstName = worst ? (worst.o.id || worst.o.label) : "";
    if (!nOs) {
      kpi("Audit after reboot", "-", "", "No results", "");
    } else if (!missing) {
      kpi("Audit after reboot", String(worst.a.fail), "FAIL", "Worst: " + worstName + ", " + worst.a.pass + " pass, " + worst.a.warn + " warn, score " + worst.a.score, worst.a.fail ? "bad" : "ok");
    } else {
      // A system that never got to this audit is worse than any score, so the tile is never green then:
      // it says how many got there, and the caption gives the worst of those.
      var capA = worst
        ? (missing === 1 ? "1 system did" : missing + " systems did") + " not get there. Worst of the others: " + worstName + ", " + worst.a.fail + " FAIL, " + worst.a.warn + " warn, score " + worst.a.score
        : "No system reached the audit after the reboot";
      kpi("Audit after reboot", String(nOs - missing), "/ " + nOs + " reached", capA, "bad");
    }
  }

  // ---------- alerts for systems without results or with an aborted run ----------
  function renderAlerts() {
    oses.forEach(function (o) {
      var name = o.label + (o.id && o.id !== o.label ? " (" + o.id + ")" : "");
      if (o.status === "error") add($("alerts"), alertBox("bad", "No results: " + name, o.reason || "The VM job ended without results."));
      else if (o.status === "failed" && o.reason) add($("alerts"), alertBox("warn", "Run stopped: " + name, o.reason));
    });
  }

  function scenHref(o, s) { return "#os=" + encodeURIComponent(o.id) + (s ? "&s=" + encodeURIComponent(s.id) : ""); }
  // The matrix and the system details filter on this same text, so a search never hides a row
  // whose scenario still shows below.
  function scenHay(s) { return (s.title + " " + s.id + " " + s.group + " " + s.reason).toLowerCase(); }

  // ---------- failures first ----------
  function renderFailures() {
    var list = $("fails"), n = 0;
    oses.forEach(function (o) {
      o.scenarios.forEach(function (s) {
        if (s.status !== "failed") return;
        n++;
        if (n > MAX_FAILS) return;
        var li = el("li", "card failx");
        var hd = el("div", "hd");
        add(hd, el("b", null, s.title), el("span", "where", (o.id || o.label) + (s.group ? " · " + s.group : "")));
        var go = el("a", "tbtn go", "Details");
        go.appendChild(icon("arrow"));
        go.setAttribute("aria-label", "Details: " + s.title + " on " + (o.id || o.label));
        if (o.id) go.href = scenHref(o, s);
        add(li, dot("failed"), hd, go);
        var first = s.assertions.filter(function (a) { return !a.ok; })[0];
        if (first) {
          var why = el("p", "why");
          add(why, el("b", null, "not ok"), " " + (first.name || "unnamed check"));
          li.appendChild(why);
          if (first.detail) li.appendChild(el("pre", null, first.detail));
        } else if (s.reason) {
          li.appendChild(el("p", "why", s.reason));
        }
        list.appendChild(li);
      });
    });
    if (n > MAX_FAILS) list.appendChild(el("li", "more", "And " + (n - MAX_FAILS) + " more failed scenarios. They are in the matrix below."));
    $("failures").hidden = n === 0;
  }

  // ---------- matrix ----------
  var rows = [], rowById = new Map(), mxBody = null;
  var state = { f: "all", q: "", failedFirst: true };
  var filterBtns = {};
  function buildMatrix() {
    oses.forEach(function (o, oi) {
      o.scenarios.forEach(function (s) {
        var r = rowById.get(s.id);
        if (!r) {
          r = { id: s.id, title: s.title, group: s.group, order: rows.length, cells: new Map(), failed: false };
          rowById.set(s.id, r);
          rows.push(r);
        }
        r.cells.set(oi, s);
        if (s.status === "failed") r.failed = true;
      });
    });

    var t = $("mx");
    var thead = el("thead"), hr = el("tr");
    var corner = el("th", "rowh", "Scenario");
    corner.scope = "col";
    hr.appendChild(corner);
    oses.forEach(function (o) {
      var th = el("th", "osh");
      th.scope = "col";
      var a = el("a");
      if (o.id) a.href = scenHref(o);
      add(a, el("span", "id", o.id || "unknown"), el("span", "lb", o.label));
      a.title = o.label;
      var st = el("span", "st " + o.status, o.status === "error" ? "no results" : o.status + (o.duration ? " · " + dur(o.duration) : ""));
      add(th, a, st);
      hr.appendChild(th);
    });
    thead.appendChild(hr);
    t.appendChild(thead);
    var tbody = el("tbody");
    t.appendChild(tbody);

    rows.forEach(function (r) {
      var tr = el("tr");
      if (r.failed) tr.className = "has-fail";
      var th = el("th", "rowh");
      th.scope = "row";
      add(th, el("span", "t", r.title), el("span", "g", (r.group ? r.group + " · " : "") + r.id));
      tr.appendChild(th);
      r.links = [];
      oses.forEach(function (o, oi) {
        var td = el("td");
        var s = r.cells.get(oi);
        if (s && o.id) {
          var a = el("a", "cell " + s.status);
          a.href = scenHref(o, s);
          add(a, dot(s.status), dur(s.duration), srText(" " + LABEL[s.status] + " on " + o.id));
          a.title = LABEL[s.status] + " on " + o.id + (s.reason ? ": " + s.reason.slice(0, 200) : "");
          r.links.push({ a: a, status: s.status, hay: scenHay(s) });
          td.appendChild(a);
        } else {
          var none = el("span", "cell none", "-");
          none.title = o.status === "error" ? "No results for this system" : "Not run on this system";
          add(none, srText(none.title));
          td.appendChild(none);
          // A system without a valid id still lists this scenario in its details: filter the row on it too.
          if (s) r.links.push({ a: null, status: s.status, hay: scenHay(s) });
        }
        tr.appendChild(td);
      });
      r.tr = tr;
      tbody.appendChild(tr);
    });
    if (!rows.length) {
      var tr0 = el("tr"), td0 = el("td", "none-note", "No scenario ran.");
      td0.colSpan = oses.length + 1;
      tr0.appendChild(td0);
      tbody.appendChild(tr0);
    }
    mxBody = tbody;

    var bar = $("filters");
    FILTERS.forEach(function (f) {
      var b = el("button");
      b.type = "button";
      b.setAttribute("data-f", f);
      var n = f === "all" ? total : counts[f];
      add(b, LABEL[f], el("span", "n" + (f === "failed" && n ? " has" : ""), String(n)));
      b.addEventListener("click", function () { setFilter(f); writeHash(); });
      filterBtns[f] = b;
      bar.appendChild(b);
    });
    var lg = $("mx-legend");
    ["passed", "failed", "skipped"].forEach(function (k) { var s = el("span"); add(s, dot(k), LABEL[k]); lg.appendChild(s); });
    add(lg, el("span", null, "Time is how long the scenario took."));
  }

  // ---------- systems ----------
  var osById = new Map();
  function isFail(v) { return v.toUpperCase().indexOf("FAIL") === 0; }
  function stepClass(v, second) {
    var u = v.toUpperCase();
    if (!u) return "none";
    if (isFail(u)) return "bad";
    if (u.indexOf("OK") === 0) return "ok";
    if (u.indexOf("SKIP") === 0) return "off";
    // CHANGED is expected on the first run; on the second run it means the step is not idempotent.
    return second ? "bad" : "chg";
  }
  function auditRow(name, hint, a) {
    var row = el("div", "aud-row");
    var lbl = el("span", "lbl", name);
    if (hint) lbl.appendChild(el("small", null, hint));
    row.appendChild(lbl);
    if (!a) {
      add(row, el("span", "score muted", "-"));
      var e = el("div", "sbar empty");
      e.setAttribute("role", "img");
      e.setAttribute("aria-label", name + ": did not run");
      add(row, e, add(el("div", "slegend"), el("span", null, "did not run")));
      return row;
    }
    var sc = el("span", "score", String(a.score));
    sc.appendChild(el("small", null, " /100"));
    row.appendChild(sc);
    var bar = el("div", "sbar");
    bar.setAttribute("role", "img");
    bar.setAttribute("aria-label", name + ": " + a.pass + " PASS, " + a.warn + " WARN, " + a.fail + " FAIL");
    [["p", a.pass], ["w", a.warn], ["f", a.fail]].forEach(function (p) {
      if (!p[1]) return;
      var i = el("i", p[0]);
      i.style.flexGrow = String(p[1]);   // CSSOM, allowed by the CSP
      bar.appendChild(i);
    });
    if (!bar.childNodes.length) bar.className = "sbar empty";
    var leg = el("div", "slegend");
    add(leg, el("span", "p", a.pass + " PASS"), el("span", "w", a.warn + " WARN"), el("span", "f" + (a.fail ? " has" : ""), a.fail + " FAIL"), el("span", "n", a.info + " INFO"));
    add(row, bar, leg);
    return row;
  }
  function logLink(o, name, title) {
    var info = o.att.get(name);
    var ok = info && (info.state === "ok" || info.state === "truncated") && FILE_RE.test(name) && o.id;
    if (ok) {
      var a = extLink(encodeURIComponent(o.id) + "/" + encodeURIComponent(name), "");
      a.className = "logl";
      a.appendChild(icon("file"));
      if (title) add(a, el("span", "ft", title));
      add(a, el("span", null, name), el("span", "sz", bytes(info.size)));
      if (info.state === "truncated") a.appendChild(el("span", "tag", "last 5 MB"));
      a.appendChild(srText(" (opens in a new tab)"));
      return a;
    }
    var why = !info || info.state === "refused" ? "not published" : "missing";
    var s = el("span", "logl na");
    s.appendChild(icon("file"));
    if (title) add(s, el("span", "ft", title));
    add(s, el("span", null, name), el("span", "sz", why));
    s.title = why === "missing" ? "The run listed this file but did not save it." : "Not copied: only plain files with a safe name and a text type (.log, .txt, .json, .md, .tsv, .csv) are published.";
    return s;
  }
  // Only the real run (prep-run) fills the step table, from the report it writes. The dry runs
  // before it also run server-prep, so say why that table is empty, not that nothing ran.
  function noSteps(o) {
    var run = o.scenarios.filter(function (s) { return s.id === "prep-run"; })[0];
    if (!run) {
      return o.reason
        ? "No step results: the run stopped before the real server-prep run (prep-run) finished."
        : "No step results: the real server-prep run (prep-run) was not part of this run.";
    }
    if (run.status === "skipped") return "No step results: the real server-prep run (prep-run) was skipped.";
    if (run.status === "failed") return "No step results: the real server-prep run (prep-run) did not finish or wrote no report.";
    return "No step results: the report of the real server-prep run lists no step.";
  }
  function renderOs(o) {
    var sec = el("section", "card os");
    sec.id = "os-" + o.idx;
    sec.tabIndex = -1;
    sec.setAttribute("aria-labelledby", "os-" + o.idx + "-h");
    var head = el("div", "os-head");
    var left = el("div");
    var h = el("h3", null, o.label);
    h.id = "os-" + o.idx + "-h";
    var sub = el("p", "sub");
    if (o.id) sub.appendChild(el("code", null, o.id));
    if (o.release) sub.appendChild(el("span", null, o.release));
    add(left, h, sub);
    var right = el("div", "right");
    var pillCls = o.status === "passed" ? "ok" : o.status === "failed" ? "bad" : "warn";
    var pill = el("span", "pill " + pillCls);
    add(pill, icon(ICON[o.status]), LABEL[o.status]);
    right.appendChild(pill);
    if (o.status !== "error") {
      var c = { passed: 0, failed: 0, skipped: 0 };
      o.scenarios.forEach(function (s) { c[s.status]++; });
      right.appendChild(el("span", "num", c.passed + " passed · " + c.failed + " failed · " + c.skipped + " skipped"));
    }
    add(head, left, right);
    sec.appendChild(head);
    var entry = { o: o, section: sec, details: new Map(), items: [] };
    if (o.id && !osById.has(o.id)) osById.set(o.id, entry);

    if (o.status === "error") {
      var body0 = el("div", "os-body");
      body0.appendChild(alertBox("bad", "No results", o.reason || "The VM job ended without results."));
      sec.appendChild(body0);
      return sec;
    }

    var facts = el("dl", "facts");
    function fact(k, v) {
      if (v == null || v === "") return;
      var d = el("div");
      var dd = el("dd");
      add(dd, v);
      add(d, el("dt", null, k), dd);
      facts.appendChild(d);
    }
    fact("Kernel", o.kernel ? el("code", null, o.kernel) : "");
    var vm = [];
    if (o.accel) vm.push(o.accel === "kvm" ? "KVM" : o.accel === "tcg" ? "TCG (no KVM, slower)" : o.accel);
    if (o.cpus) vm.push(plural(o.cpus, "vCPU"));
    if (o.memory) vm.push(o.memory >= 1024 && o.memory % 1024 === 0 ? o.memory / 1024 + " GB RAM" : o.memory + " MB RAM");
    fact("VM", vm.join(" · "));
    fact("Started", o.started ? when(o.started) : "");
    fact("Duration", dur(o.duration));
    if (o.image.url || o.image.checksum) {
      var img = el("span");
      var file = o.image.url.split("/").pop() || o.image.url;
      if (/^https:\/\//.test(o.image.url)) img.appendChild(extLink(o.image.url, file));
      else if (file) img.appendChild(document.createTextNode(file));
      if (o.image.checksum) {
        var ck = el("code", null, o.image.checksum.length > 26 ? o.image.checksum.slice(0, 26) + "…" : o.image.checksum);
        ck.title = o.image.checksum;
        add(img, file ? " " : "", ck);
      }
      fact("Cloud image", img);
    }
    sec.appendChild(facts);

    var body = el("div", "os-body");
    // An aborted run (time limit, cancelled job) explains why the scenarios after it are missing.
    if (o.status === "failed" && o.reason) body.appendChild(alertBox("warn", "Run stopped", o.reason));
    var grid = el("div", "os-grid");

    var ap = el("div");
    var aph = el("div", "ph");
    add(aph, el("h4", null, "Audit score"), el("p", null, "A fresh server must fail; then 0 FAIL."));
    var aud = el("div", "aud");
    add(aud, auditRow("Fresh server", "before server-prep", o.audit.fresh),
      auditRow("Prepared", "after the first run", o.audit.prepared),
      auditRow("After reboot", "", o.audit.rebooted));
    add(ap, aph, aud);

    var sp = el("div");
    var sph = el("div", "ph");
    sph.appendChild(el("h4", null, "server-prep steps"));
    // A step that failed on the second run did not change anything: count it apart from the
    // steps that changed something again (not idempotent).
    var failed2 = o.steps.filter(function (s) { return isFail(s.second); }).length;
    var changed2 = o.steps.filter(function (s) { return !isFail(s.second) && stepClass(s.second, true) === "bad"; }).length;
    if (o.steps.some(function (s) { return s.second; })) {
      var bad2 = [failed2 ? plural(failed2, "step") + " failed" : "", changed2 ? plural(changed2, "step") + " not idempotent" : ""].filter(Boolean);
      sph.appendChild(el("p", bad2.length ? "bad" : "ok", bad2.length ? "Second run: " + bad2.join(", ") : "Second run changed nothing"));
    }
    sp.appendChild(sph);
    if (o.steps.length) {
      var ts = el("div", "tscroll");
      var tbl = el("table", "tbl");
      var th = el("thead"), thr = el("tr");
      ["Step", "First run", "Second run"].forEach(function (x) { var c2 = el("th", null, x); c2.scope = "col"; thr.appendChild(c2); });
      th.appendChild(thr);
      var tb = el("tbody");
      o.steps.forEach(function (s) {
        var tr = el("tr");
        var c1 = stepClass(s.first, false), c2 = stepClass(s.second, true);
        if (c1 === "bad" || c2 === "bad") tr.className = "bad";
        var a = el("td", "step");
        add(a, el("span", "id", s.step), s.label && s.label !== s.step ? el("span", "lb", s.label) : null);
        var b = el("td"), d = el("td");
        b.appendChild(el("span", "badge " + c1, s.first || "-"));
        d.appendChild(el("span", "badge " + c2, s.second || "-"));
        add(tr, a, b, d);
        tb.appendChild(tr);
      });
      add(tbl, th, tb);
      ts.appendChild(tbl);
      sp.appendChild(ts);
    } else {
      sp.appendChild(el("p", "none-note", noSteps(o)));
    }
    add(grid, ap, sp);
    body.appendChild(grid);

    var scWrap = el("div");
    var sch = el("div", "ph");
    sch.appendChild(el("h4", null, "Scenarios"));
    scWrap.appendChild(sch);
    var list = el("div", "scens");
    o.scenarios.forEach(function (s, si) {
      var d = el("details", "scen");
      d.id = "os-" + o.idx + "-s-" + si;
      d.setAttribute("data-status", s.status);
      if (s.status === "failed") d.open = true;
      var sm = el("summary");
      var t = el("span", "t");
      add(t, el("b", null, s.title), el("span", "g", (s.group ? s.group + " · " : "") + s.id));
      add(sm, dot(s.status), t, el("span", "d", dur(s.duration)), el("span", "tw"), srText(" " + LABEL[s.status]));
      if (s.reason && s.status !== "passed") sm.appendChild(el("span", "why", s.reason));
      d.appendChild(sm);

      var b = el("div", "scen-body");
      if (s.reason) {
        var r = el("p", "reason");
        add(r, el("b", null, s.status === "skipped" ? "Skipped" : s.status === "failed" ? "Failed" : "Note"), s.reason);
        b.appendChild(r);
      }
      if (s.assertions.length) {
        var nok = s.assertions.filter(function (a) { return !a.ok; }).length;
        var ah = el("p", "sub-h", "Checks · " + (s.assertions.length - nok) + " of " + s.assertions.length + " ok");
        var at = el("table", "asrt");
        var cap = el("caption", "sr", "Checks for " + s.title + " on " + (o.id || o.label));
        at.appendChild(cap);
        var atb = el("tbody");
        s.assertions.forEach(function (a) {
          var tr = el("tr", a.ok ? "yes" : "no");
          var c1 = el("td", "res");
          c1.appendChild(el("span", "badge " + (a.ok ? "ok" : "bad"), a.ok ? "ok" : "not ok"));
          var c3 = el("td", "dt");
          if (a.detail) c3.appendChild(el("pre", null, a.detail));
          add(tr, c1, el("td", "nm", a.name || "unnamed check"), c3);
          atb.appendChild(tr);
        });
        at.appendChild(atb);
        add(b, ah, at);
      } else if (!s.reason) {
        b.appendChild(el("p", "none-note", s.status === "skipped" ? "Skipped, no checks ran." : "No checks recorded."));
      }
      if (s.logs.length) {
        var lh = el("p", "sub-h", "Logs");
        var ll = el("div", "links");
        s.logs.forEach(function (n) { ll.appendChild(logLink(o, n, "")); });
        add(b, lh, ll);
      }
      d.appendChild(b);
      list.appendChild(d);
      entry.details.set(s.id, d);
      entry.items.push({ s: s, d: d, hay: scenHay(s) });
    });
    var none = el("p", "none-note", o.scenarios.length ? "No scenario matches these filters." : "No scenario ran on this system.");
    none.hidden = o.scenarios.length > 0;
    entry.none = none;
    entry.list = list;
    if (o.scenarios.length) scWrap.appendChild(list);
    scWrap.appendChild(none);
    body.appendChild(scWrap);

    if (o.files.length) {
      var fw = el("div");
      var fh = el("div", "ph");
      fh.appendChild(el("h4", null, "Files"));
      var fl = el("div", "links");
      o.files.forEach(function (f) { fl.appendChild(logLink(o, f.name, f.title)); });
      add(fw, fh, fl);
      body.appendChild(fw);
    }
    sec.appendChild(body);
    entries.push(entry);
    return sec;
  }
  var entries = [];
  function renderOses() {
    var nav = $("osnav"), box = $("oses");
    oses.forEach(function (o) {
      var a = el("a");
      add(a, dot(o.status), o.id || o.label, srText(" " + LABEL[o.status]));
      a.href = o.id ? scenHref(o) : "#os-" + o.idx;
      nav.appendChild(a);
      box.appendChild(renderOs(o));
    });
    if (!oses.length) box.appendChild(alertBox("bad", "No systems", "The report has no results at all."));
  }

  // ---------- filters ----------
  function matchStatus(st) { return state.f === "all" || st === state.f; }
  function apply() {
    var q = state.q.toLowerCase().trim();
    var tbody = mxBody;
    var order = rows.slice();
    if (state.failedFirst) order.sort(function (a, b) { return (b.failed - a.failed) || (a.order - b.order); });
    var shown = 0;
    order.forEach(function (r) {
      // Same test as the details below, cell by cell: a row shows when one of its cells matches.
      var vis = false;
      r.links.forEach(function (l) {
        var m = matchStatus(l.status) && (!q || l.hay.indexOf(q) >= 0);
        if (m) vis = true;
        if (l.a) l.a.classList.toggle("dim", !m);
      });
      r.tr.hidden = !vis;
      if (vis) shown++;
      tbody.appendChild(r.tr);
    });
    $("mx-empty").hidden = shown > 0 || !rows.length;

    entries.forEach(function (e) {
      var items = e.items.slice();
      if (state.failedFirst) items.sort(function (a, b) { return ((b.s.status === "failed") - (a.s.status === "failed")) || (a.s.order - b.s.order); });
      var n = 0;
      items.forEach(function (it) {
        var vis = matchStatus(it.s.status) && (!q || it.hay.indexOf(q) >= 0);
        it.d.hidden = !vis;
        if (vis) n++;
        e.list.appendChild(it.d);
      });
      e.none.hidden = n > 0;
      e.list.hidden = n === 0;
    });
    FILTERS.forEach(function (f) { filterBtns[f].setAttribute("aria-pressed", String(state.f === f)); });
  }
  function setFilter(f) { state.f = FILTERS.indexOf(f) >= 0 ? f : "all"; apply(); }

  // ---------- hash routing: #os=debian-13&s=prep-run (also f=failed and q=text) ----------
  function parseHash() {
    var h = location.hash.replace(/^#/, "");
    if (h.indexOf("=") < 0) return {};
    var p;
    try { p = new URLSearchParams(h); } catch (e) { return {}; }
    return { os: p.get("os") || "", s: p.get("s") || "", f: p.get("f") || "", q: p.get("q") };
  }
  function writeHash() {
    var p = new URLSearchParams();
    if (state.f !== "all") p.set("f", state.f);
    if (state.q) p.set("q", state.q);
    var h = p.toString();
    try { history.replaceState(null, "", h ? "#" + h : location.pathname + location.search); } catch (e) { /* file:// in some browsers: the filters still work */ }
  }
  function route() {
    var h = parseHash();
    var changed = false;
    if (h.f && FILTERS.indexOf(h.f) >= 0 && h.f !== state.f) { state.f = h.f; changed = true; }
    if (typeof h.q === "string" && h.q.slice(0, 100) !== state.q) { state.q = h.q.slice(0, 100); $("q").value = state.q; changed = true; }
    if (changed) apply();
    if (!h.os) return;
    var e = osById.get(h.os);
    if (!e) return;
    var target = e.section, focus = e.section;
    if (h.s && e.details.has(h.s)) {
      var d = e.details.get(h.s);
      if (d.hidden) { state.f = "all"; state.q = ""; $("q").value = ""; apply(); }
      d.open = true;
      target = d;
      focus = d.querySelector("summary");
      d.classList.remove("flash");
      void d.offsetWidth;   // restart the highlight animation
      d.classList.add("flash");
    }
    target.scrollIntoView({ block: "start", behavior: reduced ? "auto" : "smooth" });
    try { focus.focus({ preventScroll: true }); } catch (err) { focus.focus(); }
  }

  // ---------- start ----------
  renderHead();
  renderKpis();
  renderAlerts();
  renderFailures();
  buildMatrix();
  renderOses();
  $("q").addEventListener("input", function () { state.q = this.value.slice(0, 100); apply(); writeHash(); });
  $("failed-first").addEventListener("change", function () { state.failedFirst = this.checked; apply(); });
  // A second click on the same cell does not change the hash, so route it by hand.
  document.addEventListener("click", function (ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[href^="#os="]') : null;
    if (a && a.getAttribute("href") === location.hash) { ev.preventDefault(); route(); }
  });
  window.addEventListener("hashchange", route);
  apply();
  route();
})();
