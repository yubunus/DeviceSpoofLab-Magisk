/* DeviceSpoofLabs WebUI client; talks to common/webctl.sh via the KernelSU/APatch bridge. */
"use strict";

var BIN = "/data/adb/modules/devicespooflab/common/webctl.sh";
var CONFIG_FILES = [
  { name: "device_identity.conf", mode: "structured" },
  { name: "build_info.conf", mode: "structured" },
  { name: "identifiers.conf", mode: "structured" },
  { name: "custom.conf", mode: "raw" }
];

var STATE = null;
var CONFIGS_LOADED = false;
var CONFIG_SAVE_TIMERS = {};
var toastTimer = null;
var DEFAULT_TOAST_MS = 3500;
var REBOOT_TOAST_MS = 8000;

var cbCounter = 0;
function hasBridge() {
  return typeof ksu !== "undefined" && ksu && typeof ksu.exec === "function";
}

function exec(command, options) {
  options = options || {};
  return new Promise(function (resolve, reject) {
    if (!hasBridge()) { reject(new Error("no-bridge")); return; }
    var name = "dsl_cb_" + Date.now() + "_" + (cbCounter++);
    window[name] = function (errno, stdout, stderr) {
      delete window[name];
      resolve({ errno: errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      ksu.exec(command, JSON.stringify(options), name);
    } catch (e) {
      delete window[name];
      reject(e);
    }
  });
}

function $(sel, root) { return (root || document).querySelector(sel); }
function $all(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function buildCmd(args) { return BIN + " " + args.map(shQuote).join(" "); }

function toB64(str) { return btoa(unescape(encodeURIComponent(str))); }

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}

var overlayDepth = 0;
function showOverlay(on) {
  overlayDepth = Math.max(0, overlayDepth + (on ? 1 : -1));
  $("#overlay").classList.toggle("hidden", overlayDepth === 0);
}

function toast(msg, options) {
  options = options || {};
  var bar = $("#toast-bar");
  var message = $("#toast-message");
  var reboot = $("#toast-reboot");
  if (!bar || !message || !reboot) {
    try { if (typeof ksu !== "undefined" && ksu && ksu.toast) ksu.toast(msg); } catch (e) {}
    return;
  }

  if (toastTimer) clearTimeout(toastTimer);
  message.textContent = msg;
  reboot.classList.toggle("hidden", !options.reboot);
  bar.classList.remove("hidden");

  toastTimer = setTimeout(function () {
    bar.classList.add("hidden");
    reboot.classList.add("hidden");
    toastTimer = null;
  }, options.reboot ? REBOOT_TOAST_MS : DEFAULT_TOAST_MS);
}

async function webctl() {
  var args = Array.prototype.slice.call(arguments);
  var r = await exec(buildCmd(args));
  return r;
}

async function webctlJSON() {
  var args = Array.prototype.slice.call(arguments);
  var r = await webctl.apply(null, args);
  var raw = (r.stdout || "").trim();
  var data;
  try {
    data = JSON.parse(raw);
  } catch (e) {

    data = { ok: r.errno === 0, message: raw || (r.stderr || "").trim(), _parseError: true };
  }
  data._errno = r.errno;
  data._raw = raw;
  data._stderr = (r.stderr || "").trim();
  return data;
}

function uiLog(msg) {
  try { webctl("ui-log", toB64(String(msg))); } catch (e) {}
}

async function openExternalUrl(url) {
  try {
    var res = await webctlJSON("open-url", toB64(url));
    if (res && res.ok === false) toast(res.message || "Could not open link");
  } catch (e) {
    toast("Could not open link");
  }
}

function delay(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

function markRebootUI() {
  if (STATE) STATE.reboot_required = true;
}

function hasActivePersona() { return !!(STATE && STATE.active_persona); }

function statusIsUsable(s) {
  return !!s && s._errno === 0 && !s._parseError && typeof s.persona_active !== "undefined";
}

var STATUS_RETRIES = 3;

async function refresh() {
  showOverlay(true);
  try {
    var s = null, attempt = 0;
    for (attempt = 1; attempt <= STATUS_RETRIES; attempt++) {
      s = await webctlJSON("status");
      if (statusIsUsable(s)) break;
      if (attempt < STATUS_RETRIES) await delay(400 * attempt);
    }

    if (statusIsUsable(s)) {
      STATE = s;
      hideStatusError();
      renderStatus();
      if (attempt > 1) uiLog("status recovered on attempt " + attempt);
    } else {

      showStatusError();
      uiLog("status read failed after " + STATUS_RETRIES + " tries: errno=" + (s && s._errno) +
            " raw=" + JSON.stringify((s && s._raw || "").slice(0, 160)) +
            " stderr=" + JSON.stringify((s && s._stderr || "").slice(0, 160)));
    }
  } catch (e) {
    showNoBridge();
    uiLog("status read threw (bridge): " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

function renderStatus() {
  if (!STATE) return;
  $("#app-version").textContent = "v" + (STATE.version || "—");
  $("#settings-version").textContent = STATE.version || "—";

  var pill = $("#persona-status");
  if (STATE.persona_active) {
    pill.textContent = "Active";
    pill.className = "status-pill status-active";
  } else {
    pill.textContent = "Inactive";
    pill.className = "status-pill status-inactive";
  }
  var nameEl = $("#persona-active-name");
  if (nameEl) {
    if (STATE.persona_active && STATE.active_persona_name) {
      nameEl.textContent = STATE.active_persona_name;
      nameEl.classList.remove("hidden");
    } else {
      nameEl.classList.add("hidden");
    }
  }

  $("#settings-unsafe").textContent = STATE.unsafe_props ? "ENABLED (allowlist bypassed)" : "Off";
  $("#settings-backup").textContent = STATE.has_backup ? "Yes" : "Not yet (captured on first activation)";

  renderValues();
}

function renderValues() {
  var wrap = $("#values-table");
  wrap.innerHTML = "";
  var values = STATE.values || [];

  $("#values-note").textContent = "Live = current device values. Original appears when backup exists and differs.";

  if (!values.length) {
    var empty = document.createElement("div");
    empty.className = "muted-note";
    empty.textContent = "Live values are unavailable in this environment.";
    wrap.appendChild(empty);
    return;
  }

  values.forEach(function (v) {
    var row = document.createElement("div");
    row.className = "value-row";

    var label = document.createElement("div");
    label.className = "value-label";
    label.appendChild(document.createTextNode(v.label));
    if (Number(v.spoofable) === 0) {
      var tag = document.createElement("span");
      tag.className = "tag tag-hw";
      tag.textContent = "hardware tell";
      label.appendChild(tag);
    } else if (STATE.persona_active && v.configured && v.live !== v.configured) {
      var pend = document.createElement("span");
      pend.className = "tag tag-pending";
      pend.textContent = "reboot to apply";
      label.appendChild(pend);
    }

    var live = document.createElement("div");
    live.className = "value-live";
    live.textContent = v.live || "—";

    row.appendChild(label);
    row.appendChild(live);

    if (v.original && v.original !== v.live) {
      var orig = document.createElement("div");
      orig.className = "value-orig";
      orig.innerHTML = "real: <b>" + escapeHtml(v.original) + "</b>";
      row.appendChild(orig);
    }

    wrap.appendChild(row);
  });
}

function showNoBridge() {
  $("#no-bridge").classList.remove("hidden");
  $("#persona-status").textContent = "Unavailable";
  toast("WebUI bridge unavailable - use the devicespooflabs CLI");
}

function showStatusError() {
  var pill = $("#persona-status");
  pill.textContent = "Status unavailable";
  pill.className = "status-pill status-error";
  var banner = $("#status-error");
  if (banner) banner.classList.remove("hidden");
  $("#values-note").textContent =
    "Couldn't read module status. Spoofing may still be active - check Settings > Logs, or the boot log is the source of truth.";
  $("#values-table").innerHTML = "";
  toast("Couldn't read status - tap Retry");
}

function hideStatusError() {
  var banner = $("#status-error");
  if (banner) banner.classList.add("hidden");
}

async function runAction(action) {
  showOverlay(true);
  try {
    var res = await webctlJSON(action);
    uiLog("action " + action + ": errno=" + res._errno + " ok=" + (res.ok !== false) +
          (res._parseError ? " (non-JSON reply)" : ""));
    if (res.message) toast(res.message, { reboot: !!res.reboot_required });
    else if (res.reboot_required) toast("Reboot required to apply changes.", { reboot: true });

    await refresh();
  } catch (e) {
    toast("Action failed");
    uiLog("action " + action + " threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

async function doReboot() {
  toast("Rebooting…");
  try { await webctl("reboot"); } catch (e) {}
}

function parseConfig(text) {
  var hadTrailingNL = text.length > 0 && text.charAt(text.length - 1) === "\n";
  var rawLines = text.split("\n");
  if (hadTrailingNL) rawLines.pop();

  var lines = rawLines.map(function (line) {
    if (line === "FILE_ENABLED") return { type: "file", enabled: true };
    if (line === "FILE_DISABLED") return { type: "file", enabled: false };
    var trimmed = line.trim();
    if (trimmed === "" || trimmed.charAt(0) === "#") return { type: "raw", text: line };
    var m = line.match(/^(ENABLED|DISABLED),([^,]+),([\s\S]*)$/);
    if (m) return { type: "prop", status: m[1], prop: m[2], value: m[3] };
    return { type: "raw", text: line };
  });
  return { lines: lines, hadTrailingNL: hadTrailingNL };
}

function serializeConfig(model) {
  var out = model.lines.map(function (l) {
    if (l.type === "file") return l.enabled ? "FILE_ENABLED" : "FILE_DISABLED";
    if (l.type === "prop") return l.status + "," + l.prop + "," + l.value;
    return l.text;
  });
  return out.join("\n") + (model.hadTrailingNL ? "\n" : "");
}

function stripConfigNotes(text) {
  var lines = text.split("\n").filter(function (line) {
    var trimmed = line.trim();
    return trimmed !== "" && trimmed.charAt(0) !== "#";
  });
  return lines.join("\n") + (lines.length ? "\n" : "");
}

function makeSwitch(checked, onChange) {
  var label = document.createElement("label");
  label.className = "switch";
  var input = document.createElement("input");
  input.type = "checkbox";
  input.checked = !!checked;
  input.addEventListener("change", function () { onChange(input.checked); });
  var slider = document.createElement("span");
  slider.className = "slider";
  label.appendChild(input);
  label.appendChild(slider);
  return label;
}

function makeCfgHead(name) {
  var head = document.createElement("div");
  head.className = "cfg-file-head";
  var title = document.createElement("span");
  title.className = "cfg-file-name";
  title.textContent = name;
  head.appendChild(title);
  var saved = document.createElement("span");
  saved.className = "cfg-saved";
  head.appendChild(saved);
  return { head: head, saved: saved };
}

function setCfgSaved(el, text, cls) {
  if (!el) return;
  el.textContent = text || "";
  el.className = "cfg-saved" + (cls ? " " + cls : "");
}

function scheduleConfigSave(name, getContent, indicator) {
  setCfgSaved(indicator, "Editing…", "is-pending");
  if (CONFIG_SAVE_TIMERS[name]) clearTimeout(CONFIG_SAVE_TIMERS[name]);
  CONFIG_SAVE_TIMERS[name] = setTimeout(function () {
    CONFIG_SAVE_TIMERS[name] = null;
    saveConfigNow(name, getContent, indicator);
  }, 700);
}

async function saveConfigNow(name, getContent, indicator) {
  setCfgSaved(indicator, "Saving…", "is-pending");
  try {
    var res = await webctlJSON("write-config", name, toB64(getContent()));
    if (res && res.ok === false) {
      setCfgSaved(indicator, "Save failed", "is-error");
      toast(res.message || "Save failed");
      return;
    }
    setCfgSaved(indicator, "Saved", "is-ok");
    markRebootUI();
    setTimeout(function () {
      if (indicator && indicator.classList.contains("is-ok")) setCfgSaved(indicator, "", "");
    }, 2200);
  } catch (e) {
    setCfgSaved(indicator, "Save failed", "is-error");
    toast("Auto-save failed");
  }
}

function renderStructuredEditor(name, model) {
  var fileEl = document.createElement("div");
  fileEl.className = "cfg-file";

  var h = makeCfgHead(name);
  var save = function () {
    scheduleConfigSave(name, function () { return serializeConfig(model); }, h.saved);
  };

  var fileMarker = model.lines.filter(function (l) { return l.type === "file"; })[0];
  if (fileMarker) {
    h.head.appendChild(makeSwitch(fileMarker.enabled, function (on) { fileMarker.enabled = on; save(); }));
  }
  fileEl.appendChild(h.head);

  var rows = document.createElement("div");
  rows.className = "cfg-rows";

  model.lines.forEach(function (l) {
    if (l.type !== "prop") return;

    var row = document.createElement("div");
    row.className = "cfg-row";
    row.appendChild(makeSwitch(l.status === "ENABLED", function (on) {
      l.status = on ? "ENABLED" : "DISABLED";
      save();
    }));

    var main = document.createElement("div");
    main.className = "cfg-row-main";
    var propName = document.createElement("div");
    propName.className = "cfg-prop";
    propName.textContent = l.prop;
    var valWrap = document.createElement("div");
    valWrap.className = "cfg-val";
    var input = document.createElement("input");
    input.type = "text";
    input.value = l.value;
    input.spellcheck = false;
    input.autocapitalize = "none";
    input.addEventListener("input", function () { l.value = input.value; save(); });
    valWrap.appendChild(input);
    main.appendChild(propName);
    main.appendChild(valWrap);
    row.appendChild(main);
    rows.appendChild(row);
  });

  fileEl.appendChild(rows);
  return fileEl;
}

function renderRawEditor(name, text) {
  var fileEl = document.createElement("div");
  fileEl.className = "cfg-file";
  var h = makeCfgHead(name);
  fileEl.appendChild(h.head);

  var rows = document.createElement("div");
  rows.className = "cfg-rows";
  var ta = document.createElement("textarea");
  ta.className = "cfg-textarea";
  ta.spellcheck = false;
  ta.value = stripConfigNotes(text);
  ta.addEventListener("input", function () {
    scheduleConfigSave(name, function () { return ta.value; }, h.saved);
  });
  rows.appendChild(ta);
  fileEl.appendChild(rows);
  return fileEl;
}

async function loadConfigEditors() {
  if (CONFIGS_LOADED) return;
  var container = $("#config-editors");
  container.innerHTML = "";
  showOverlay(true);
  try {
    for (var i = 0; i < CONFIG_FILES.length; i++) {
      var cf = CONFIG_FILES[i];
      var r = await webctl("read-config", cf.name);
      if (r.errno !== 0) continue;
      if (cf.mode === "raw") {
        container.appendChild(renderRawEditor(cf.name, r.stdout));
      } else {
        container.appendChild(renderStructuredEditor(cf.name, parseConfig(r.stdout)));
      }
    }
    CONFIGS_LOADED = true;
  } catch (e) {
    toast("Could not load configs");
  } finally {
    showOverlay(false);
  }
}

function resetConfigEditors() {
  CONFIGS_LOADED = false;
  ANDROID_ID_LOADED = false;
  var c = $("#config-editors");
  if (c) c.innerHTML = "";
}

async function viewLogs() {
  showOverlay(true);
  try {
    var r = await webctl("logs", "300");
    var view = $("#logs-view");
    view.textContent = (r.stdout || "(no logs yet)").trim();
    view.classList.remove("hidden");
  } catch (e) {
    toast("Could not read logs");
  } finally {
    showOverlay(false);
  }
}

async function exportLogs() {
  showOverlay(true);
  try {
    var res = await webctlJSON("export-logs");
    toast(res.ok ? "Saved to " + res.path : (res.message || "Export failed"));
  } catch (e) {
    toast("Export failed");
  } finally {
    showOverlay(false);
  }
}

async function clearLogs() {
  showOverlay(true);
  try {
    var res = await webctlJSON("clear-logs");
    toast(res.message || "Logs cleared");
    var view = $("#logs-view");
    if (!view.classList.contains("hidden")) view.textContent = "";
  } catch (e) {
    toast("Could not clear logs");
  } finally {
    showOverlay(false);
  }
}

async function viewDiagnostics() {
  showOverlay(true);
  try {
    var r = await webctl("diagnose");
    var view = $("#logs-view");
    view.textContent = (r.stdout || "(no diagnostics)").trim();
    view.classList.remove("hidden");
  } catch (e) {
    toast("Could not run diagnostics");
  } finally {
    showOverlay(false);
  }
}

var AI_STATE = { enabled: false, value: "", user_id: "0", targets: [] };
var APPS = [];
var APPS_LOADED = false;
var ANDROID_ID_LOADED = false;
var APP_ICON_OBSERVER = null;

function validValue(v) { return /^[0-9a-f]{16}$/.test(v || ""); }

function genHex16() {
  var bytes = new Uint8Array(8), out = "", i;
  if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(bytes);
  else for (i = 0; i < 8; i++) bytes[i] = Math.floor(Math.random() * 256);
  for (i = 0; i < 8; i++) out += ("0" + bytes[i].toString(16)).slice(-2);
  return out;
}

function hashHue(s) {
  var h = 0, i;
  for (i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360;
  return h;
}

function bridgeSources() {
  var out = [], seen = [];
  function add(o) {
    if (!o || seen.indexOf(o) !== -1) return;
    seen.push(o);
    out.push(o);
  }
  add(window);
  if (typeof ksu !== "undefined") add(ksu);
  add(window.ksu);
  add(window.kernelsu);
  add(window.KernelSU);
  add(window.apatch);
  return out;
}

function parseMaybeJSON(raw) {
  if (raw == null) return null;
  if (typeof raw === "string") {
    try { return JSON.parse(raw); } catch (e) { return null; }
  }
  return raw;
}

async function callBridge(obj, name, args) {
  if (!obj || typeof obj[name] !== "function") return null;
  try {
    var raw = obj[name].apply(obj, args || []);
    if (raw && typeof raw.then === "function") raw = await raw;
    return parseMaybeJSON(raw);
  } catch (e) { return null; }
}

function normalizePackageList(raw) {
  if (!Array.isArray(raw)) return null;
  var pkgs = raw.map(function (item) {
    if (typeof item === "string") return item;
    return item && (item.packageName || item.pkg || item.name);
  }).filter(function (pkg) { return typeof pkg === "string" && pkg.length > 0; });
  return pkgs.length ? pkgs : null;
}

async function nativeListPackages(type) {
  var sources = bridgeSources();
  var perType = { all: "listAllPackages", user: "listUserPackages", system: "listSystemPackages" }[type];
  for (var i = 0; i < sources.length; i++) {
    var raw = perType ? await callBridge(sources[i], perType) : null;
    var pkgs = normalizePackageList(raw);
    if (pkgs) return pkgs;

    raw = await callBridge(sources[i], "listPackages", [type]);
    pkgs = normalizePackageList(raw);
    if (pkgs) return pkgs;
  }
  return null;
}

async function nativeGetPackagesInfo(pkgs) {
  var sources = bridgeSources();
  for (var i = 0; i < sources.length; i++) {
    var source = sources[i];
    var raw, directKsu = source === window.ksu || (typeof ksu !== "undefined" && source === ksu);
    if (directKsu) {
      raw = await callBridge(source, "getPackagesInfo", [JSON.stringify(pkgs)]);
      if (hasPackageInfo(raw)) return raw;
      raw = await callBridge(source, "getPackagesInfo", [pkgs]);
      if (hasPackageInfo(raw)) return raw;
    } else {
      raw = await callBridge(source, "getPackagesInfo", [pkgs]);
      if (hasPackageInfo(raw)) return raw;
      raw = await callBridge(source, "getPackagesInfo", [JSON.stringify(pkgs)]);
      if (hasPackageInfo(raw)) return raw;
    }
  }
  return null;
}

function hasPackageInfo(infos) {
  if (Array.isArray(infos)) return infos.length > 0;
  return !!infos && typeof infos === "object" && Object.keys(infos).length > 0;
}

function infoForPackage(infos, pkg, index) {
  if (!infos) return null;
  if (Array.isArray(infos)) return infos[index] || null;
  if (typeof infos === "object") return infos[pkg] || null;
  return null;
}

function normalizeApp(pkg, info, fallbackSystem) {
  info = info || {};
  var label = info.appLabel || info.appName || info.label || info.name || pkg;
  var system = info.isSystem != null ? !!info.isSystem :
               info.system != null ? !!info.system : !!fallbackSystem;
  return { pkg: pkg, label: String(label || pkg), system: system };
}

async function loadApps() {
  var pkgs = await nativeListPackages("all");
  if (pkgs && pkgs.length) {
    var infos = await nativeGetPackagesInfo(pkgs);
    APPS = pkgs.map(function (pkg, i) {
      return normalizeApp(pkg, infoForPackage(infos, pkg, i), false);
    });
  } else {

    var r = await webctlJSON("list-apps", "all");
    var arr = (r && r.apps) || [];
    APPS = arr.map(function (a) {
      return normalizeApp(a.pkg, { appLabel: a.label }, !!a.system);
    });
  }
  APPS = APPS.filter(function (app) { return app && app.pkg; });
  APPS.sort(function (a, b) {
    var x = a.label.toLowerCase(), y = b.label.toLowerCase();
    return x < y ? -1 : x > y ? 1 : 0;
  });
  APPS_LOADED = true;
}

function updatePickerSafeArea() {
  document.documentElement.style.setProperty("--picker-top-fallback", "24px");
}

function targetCountText(n) { return n + (n === 1 ? " app selected" : " apps selected"); }

function updateTargetCount() {
  var card = $("#ai-target-count");
  if (card) card.textContent = targetCountText(AI_STATE.targets.length);
  updatePickerCount();
}
function updatePickerCount() {
  var el = $("#picker-count");
  if (el) el.textContent = targetCountText(AI_STATE.targets.length);
}

function toggleTarget(pkg, on) {
  var i = AI_STATE.targets.indexOf(pkg);
  if (on && i === -1) AI_STATE.targets.push(pkg);
  else if (!on && i !== -1) AI_STATE.targets.splice(i, 1);
  updateTargetCount();
}

function loadAppIcon(img, pkg) {
  if (!img || !pkg || img.dataset.iconLoaded === "1") return;
  img.dataset.iconLoaded = "1";
  img.src = "ksu://icon/" + pkg;
  setTimeout(function () {
    if (!img.parentNode || img.classList.contains("is-loaded")) return;
    if (img.complete && img.naturalWidth > 0) img.classList.add("is-loaded");
    else img.remove();
  }, 3000);
}

function observeAppIcon(img, pkg) {
  if (!("IntersectionObserver" in window)) {
    loadAppIcon(img, pkg);
    return;
  }
  if (!APP_ICON_OBSERVER) {
    APP_ICON_OBSERVER = new IntersectionObserver(function (entries, observer) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        observer.unobserve(entry.target);
        loadAppIcon(entry.target, entry.target.dataset.pkg);
      });
    }, { root: $("#picker-list"), rootMargin: "240px 0px" });
  }
  img.dataset.pkg = pkg;
  APP_ICON_OBSERVER.observe(img);
}

function makeAppRow(app) {
  var row = document.createElement("label");
  row.className = "app-row";
  row.dataset.pkg = app.pkg;
  row.dataset.label = app.label.toLowerCase();
  row.dataset.system = app.system ? "1" : "0";

  var ic = document.createElement("div");
  ic.className = "app-ic";

  var fb = document.createElement("div");
  fb.className = "app-ic-fallback";
  fb.textContent = (app.label.charAt(0) || app.pkg.charAt(0) || "?").toUpperCase();
  fb.style.background = "hsl(" + hashHue(app.pkg) + ", 52%, 52%)";
  var img = document.createElement("img");
  img.className = "app-ic-img";
  img.alt = "";
  img.decoding = "async";
  img.addEventListener("load", function () { img.classList.add("is-loaded"); });
  img.addEventListener("error", function () { img.remove(); });
  ic.appendChild(fb);
  ic.appendChild(img);
  observeAppIcon(img, app.pkg);

  var txt = document.createElement("div");
  txt.className = "app-txt";
  var t = document.createElement("div");
  t.className = "app-title";
  t.textContent = app.label;
  var p = document.createElement("div");
  p.className = "app-pkg";
  p.textContent = app.pkg;
  txt.appendChild(t);
  txt.appendChild(p);

  var cb = document.createElement("input");
  cb.type = "checkbox";
  cb.className = "app-check";
  cb.checked = AI_STATE.targets.indexOf(app.pkg) !== -1;
  cb.addEventListener("change", function () { toggleTarget(app.pkg, cb.checked); filterPicker(); });

  row.appendChild(ic);
  row.appendChild(txt);
  row.appendChild(cb);
  return row;
}

function renderPickerList() {
  var list = $("#picker-list");
  if (APP_ICON_OBSERVER) APP_ICON_OBSERVER.disconnect();
  APP_ICON_OBSERVER = null;
  list.innerHTML = "";
  var frag = document.createDocumentFragment();
  APPS.forEach(function (app) { frag.appendChild(makeAppRow(app)); });
  list.appendChild(frag);
  filterPicker();
}

function syncPickerChecks() {
  $all(".app-row", $("#picker-list")).forEach(function (row) {
    var cb = row.querySelector(".app-check");
    if (cb) cb.checked = AI_STATE.targets.indexOf(row.dataset.pkg) !== -1;
  });
}

function filterPicker() {
  var q = ($("#picker-search-input").value || "").trim().toLowerCase();
  var showSys = $("#picker-show-system").checked;
  var rows = $all(".app-row", $("#picker-list"));
  var shown = 0;
  rows.forEach(function (row) {
    var selected = AI_STATE.targets.indexOf(row.dataset.pkg) !== -1;

    var sysOk = showSys || row.dataset.system !== "1" || selected;
    var hay = row.dataset.label + " " + row.dataset.pkg;
    var match = sysOk && (!q || hay.indexOf(q) !== -1);
    row.classList.toggle("hidden", !match);
    if (match) shown++;
  });
  var status = $("#picker-status");
  if (!APPS.length) { status.textContent = "No apps available."; status.classList.remove("hidden"); }
  else if (!shown) { status.textContent = "No apps match your search."; status.classList.remove("hidden"); }
  else status.classList.add("hidden");
}

async function openPicker() {
  var picker = $("#app-picker");
  updatePickerSafeArea();
  picker.classList.remove("hidden");
  picker.setAttribute("aria-hidden", "false");
  document.body.classList.add("picker-open");

  updatePickerCount();

  if (!APPS_LOADED) {
    $("#picker-status").textContent = "Loading apps…";
    $("#picker-status").classList.remove("hidden");
    showOverlay(true);
    try {
      await loadApps();
      renderPickerList();
    } catch (e) {
      $("#picker-status").textContent = "Could not load the app list.";
      uiLog("app list load failed: " + (e && e.message ? e.message : String(e)));
    } finally {
      showOverlay(false);
    }
  } else {
    syncPickerChecks();
    filterPicker();
  }
}

function closePicker() {
  var picker = $("#app-picker");
  picker.classList.add("hidden");
  picker.setAttribute("aria-hidden", "true");
  document.body.classList.remove("picker-open");
  updateTargetCount();
  persistSelection();
}

function syncValueFromField() {
  AI_STATE.value = ($("#ai-value").value || "").trim().toLowerCase();
}

function validateValueField() {
  var ok = validValue(AI_STATE.value);
  var input = $("#ai-value");
  var hint = $("#ai-value-hint");
  input.classList.toggle("invalid", !ok && (AI_STATE.value || "").length > 0);
  if (!AI_STATE.value) { hint.textContent = "16 lowercase hex characters (0–9, a–f)."; hint.className = "ai-hint"; }
  else if (ok) { hint.textContent = "Valid Android ID."; hint.className = "ai-hint ai-hint-ok"; }
  else { hint.textContent = "Must be exactly 16 hex characters (0–9, a–f)."; hint.className = "ai-hint ai-hint-bad"; }
}

function buildAndroidPayload(enabled) {
  var lines = [];
  lines.push("ENABLED=" + (enabled ? "1" : "0"));
  lines.push("VALUE=" + (AI_STATE.value || ""));
  lines.push("USER=" + (AI_STATE.user_id || "0"));
  AI_STATE.targets.forEach(function (p) { lines.push("PKG=" + p); });
  return lines.join("\n") + "\n";
}

var AI_SAVE_TIMER = null;

async function aiSaveNow() {
  syncValueFromField();
  if (!validValue(AI_STATE.value)) { validateValueField(); return; }
  try {
    var res = await webctlJSON("set-android-id", toB64(buildAndroidPayload(AI_STATE.enabled)));
    if (res && res.ok === false) { toast(res.message || "Could not save Android ID"); return; }
    markRebootUI();
  } catch (e) { uiLog("android-id save threw: " + (e && e.message ? e.message : String(e))); }
}

function aiAutoSave(immediate) {
  if (AI_SAVE_TIMER) { clearTimeout(AI_SAVE_TIMER); AI_SAVE_TIMER = null; }
  if (immediate) { aiSaveNow(); return; }
  AI_SAVE_TIMER = setTimeout(function () { AI_SAVE_TIMER = null; aiSaveNow(); }, 600);
}

function persistSelection() { aiAutoSave(true); }

function setAiEnabledUI(on) {
  AI_STATE.enabled = !!on;
  var box = $("#ai-enabled");
  if (box) box.checked = !!on;
  var card = $("#android-id-card");
  if (card) card.classList.toggle("ai-on", !!on);
}

function onAiEnabledToggle(on) {
  if (on) {
    syncValueFromField();
    if (!validValue(AI_STATE.value)) {
      AI_STATE.value = genHex16();
      $("#ai-value").value = AI_STATE.value;
      validateValueField();
    }
    if (!AI_STATE.targets.length) toast("Pick target apps below - they apply on the next reboot.");
  }
  setAiEnabledUI(on);
  aiAutoSave(true);
}

async function loadAndroidIdConfig() {
  if (ANDROID_ID_LOADED) return;
  try {
    var c = await webctlJSON("android-id-config");
    if (c && c.ok !== false && !c._parseError) {
      AI_STATE.enabled = !!c.enabled;
      AI_STATE.user_id = c.user_id || "0";
      AI_STATE.targets = Array.isArray(c.targets) ? c.targets.slice() : [];
      AI_STATE.value = c.value || "";
    }
  } catch (e) {  }
  if (!validValue(AI_STATE.value)) AI_STATE.value = genHex16();
  $("#ai-value").value = AI_STATE.value;
  validateValueField();
  setAiEnabledUI(AI_STATE.enabled);
  updateTargetCount();
  ANDROID_ID_LOADED = true;
}

function wireAndroidId() {
  $("#btn-open-apps").addEventListener("click", openPicker);
  $("#picker-back").addEventListener("click", closePicker);
  $("#picker-done").addEventListener("click", closePicker);
  $("#picker-search-input").addEventListener("input", filterPicker);
  $("#picker-show-system").addEventListener("change", filterPicker);
  $("#ai-generate").addEventListener("click", function () {
    AI_STATE.value = genHex16();
    $("#ai-value").value = AI_STATE.value;
    validateValueField();
    aiAutoSave(true);
  });
  $("#ai-value").addEventListener("input", function () { syncValueFromField(); validateValueField(); aiAutoSave(); });
  var aiEnabled = $("#ai-enabled");
  if (aiEnabled) aiEnabled.addEventListener("change", function () { onAiEnabledToggle(aiEnabled.checked); });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !$("#app-picker").classList.contains("hidden")) closePicker();
  });
  window.addEventListener("resize", function () {
    if (!$("#app-picker").classList.contains("hidden")) updatePickerSafeArea();
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", function () {
      if (!$("#app-picker").classList.contains("hidden")) updatePickerSafeArea();
    });
  }
}

var PERSONAS = [];

async function loadPersonas() {
  var listEl = $("#personas-list");
  showOverlay(true);
  try {
    var data = await webctlJSON("personas");
    if (data && data.ok !== false && Array.isArray(data.personas)) {
      PERSONAS = data.personas;
      renderPersonas();
    } else {
      if (listEl) listEl.innerHTML = "";
      toast(data && data.message ? data.message : "Could not load personas");
    }
  } catch (e) {
    toast("Could not load personas");
    uiLog("personas load threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

function personaSubtitle(p) {
  var bits = [];
  var dev = [p.brand, p.model].filter(Boolean).join(" ");
  if (dev) bits.push(dev);
  if (p.android_id_enabled && Number(p.android_id_targets) > 0) {
    bits.push("Android ID × " + p.android_id_targets);
  }
  return bits.join("  ·  ");
}

function renderPersonas() {
  var listEl = $("#personas-list");
  var emptyEl = $("#personas-empty");
  if (!listEl) return;
  listEl.innerHTML = "";
  if (!PERSONAS.length) {
    if (emptyEl) emptyEl.classList.remove("hidden");
    return;
  }
  if (emptyEl) emptyEl.classList.add("hidden");
  PERSONAS.forEach(function (p) { listEl.appendChild(makePersonaRow(p)); });
}

function makePersonaRow(p) {
  var row = document.createElement("div");
  row.className = "persona-row" + (p.active ? " is-active" : "");
  row.dataset.id = p.id;

  var main = document.createElement("div");
  main.className = "persona-main";

  var name = document.createElement("input");
  name.className = "persona-name";
  name.type = "text";
  name.value = p.name || "Persona";
  name.spellcheck = false;
  name.autocapitalize = "words";
  name.setAttribute("aria-label", "Persona name");
  name.addEventListener("change", function () { commitPersonaRename(p, name); });
  name.addEventListener("keydown", function (e) { if (e.key === "Enter") name.blur(); });
  main.appendChild(name);

  var sub = document.createElement("div");
  sub.className = "persona-sub";
  sub.textContent = personaSubtitle(p) || "Rename above · toggle to activate";
  main.appendChild(sub);

  var actions = document.createElement("div");
  actions.className = "persona-actions";

  var sw = makeSwitch(p.active, function (on) { setPersonaActive(p.id, on); });
  sw.classList.add("persona-switch");
  actions.appendChild(sw);

  var del = document.createElement("button");
  del.className = "persona-del";
  del.type = "button";
  del.setAttribute("aria-label", "Delete persona");
  del.innerHTML = "&#10005;";
  var armed = false, armTimer = null;
  del.addEventListener("click", function () {
    if (!armed) {
      armed = true;
      del.classList.add("armed");
      del.textContent = "Delete?";
      armTimer = setTimeout(function () {
        armed = false; del.classList.remove("armed"); del.innerHTML = "&#10005;";
      }, 2500);
      return;
    }
    if (armTimer) clearTimeout(armTimer);
    deletePersona(p);
  });
  actions.appendChild(del);

  row.appendChild(main);
  row.appendChild(actions);
  return row;
}

async function commitPersonaRename(p, inputEl) {
  var newName = (inputEl.value || "").trim();
  if (!newName || newName === p.name) { inputEl.value = p.name || "Persona"; return; }
  try {
    var res = await webctlJSON("persona-rename", p.id, toB64(newName));
    if (res && res.ok === false) { toast(res.message || "Rename failed"); inputEl.value = p.name; return; }
    p.name = newName;
    if (p.active && STATE) { STATE.active_persona_name = newName; renderStatus(); }
  } catch (e) { toast("Rename failed"); inputEl.value = p.name; }
}

async function setPersonaActive(id, on) {
  showOverlay(true);
  try {
    var res = on ? await webctlJSON("persona-activate", id) : await webctlJSON("deactivate");
    if (res && res.ok === false) { toast(res.message || "Action failed"); await loadPersonas(); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    resetConfigEditors();
    await refresh();
    await loadPersonas();
  } catch (e) {
    toast("Action failed");
  } finally {
    showOverlay(false);
  }
}

async function generatePersona() {
  showOverlay(true);
  try {
    var res = await webctlJSON("generate-persona");
    if (res && res.ok === false) { toast(res.message || "Could not generate persona"); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    resetConfigEditors();
    await refresh();
    await loadPersonas();
  } catch (e) {
    toast("Could not generate persona");
    uiLog("generate persona threw: " + (e && e.message ? e.message : String(e)));
  } finally {
    showOverlay(false);
  }
}

async function deletePersona(p) {
  showOverlay(true);
  try {
    var res = await webctlJSON("persona-delete", p.id);
    if (res && res.ok === false) { toast(res.message || "Delete failed"); return; }
    if (res && res.message) toast(res.message, { reboot: !!res.reboot_required });
    if (p.active) { resetConfigEditors(); await refresh(); }
    await loadPersonas();
  } catch (e) {
    toast("Delete failed");
  } finally {
    showOverlay(false);
  }
}

function switchTab(tab) {
  $all(".tab").forEach(function (b) { b.classList.toggle("is-active", b.dataset.tab === tab); });
  $all(".tab-panel").forEach(function (p) { p.classList.toggle("is-active", p.id === "panel-" + tab); });
  if (!hasBridge()) return;
  if (tab === "personas") loadPersonas();
  if (tab === "config") showConfigTab();
}

function showConfigTab() {
  var notice = $("#config-no-persona");
  var body = $("#config-body");
  if (!hasActivePersona()) {
    if (notice) notice.classList.remove("hidden");
    if (body) body.classList.add("hidden");
    return;
  }
  if (notice) notice.classList.add("hidden");
  if (body) body.classList.remove("hidden");
  loadConfigEditors();
  loadAndroidIdConfig();
}

function wire() {

  $("#tabs").addEventListener("click", function (e) {
    var btn = e.target.closest(".tab");
    if (btn) switchTab(btn.dataset.tab);
  });

  document.body.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-action]");
    if (!btn) return;
    var action = btn.dataset.action;
    if (action === "reboot") { doReboot(); return; }
    runAction(action);
  });

  document.body.addEventListener("click", function (e) {
    var t = e.target.closest("[data-go-tab]");
    if (t) switchTab(t.dataset.goTab);
  });

  document.body.addEventListener("click", function (e) {
    var link = e.target.closest("[data-external-url]");
    if (!link || !hasBridge()) return;
    e.preventDefault();
    openExternalUrl(link.dataset.externalUrl || link.href);
  });

  var gen = $("#btn-generate-persona");
  if (gen) gen.addEventListener("click", generatePersona);

  var retry = $("#btn-retry-status");
  if (retry) retry.addEventListener("click", refresh);

  $("#btn-view-logs").addEventListener("click", viewLogs);
  $("#btn-export-logs").addEventListener("click", exportLogs);
  $("#btn-clear-logs").addEventListener("click", clearLogs);
  var diag = $("#btn-diagnostics");
  if (diag) diag.addEventListener("click", viewDiagnostics);

  wireAndroidId();
}

function init() {
  wire();
  if (!hasBridge()) {
    showNoBridge();
    return;
  }

  refresh();
  uiLog("webui init: bridge available; ua=" + (navigator.userAgent || "?").slice(0, 120));
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
