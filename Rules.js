// Pure model logic: rule storage, JSON <-> Lua serialization, and the small
// Lua snippets executed through `hyprctl eval`.
//
// Nothing here touches QML or the filesystem, so it can be tested standalone
// and a parsing mistake cannot take the bar down with it.

var SCHEMA_VERSION = 4

// ------------------------------------------------------------------ state
//
// {
//   version: 2,
//   rules:      [ { class, workspace, silent, label } ],   // app  -> workspace
//   workspaces: { "3": { monitor: "desc:LG ...", persistent: true } },
//   aliases:    { "steam_app_427520": "com.factorio.Factorio" }
// }
//
// `aliases` maps a class we had to GUESS from a .desktop file onto the class a
// real window turned out to use. Without it a Steam game shows up twice: once
// as its launcher entry and once as the window it actually opens.

function emptyState() {
  return { rules: [], workspaces: {}, aliases: {} }
}

function normalize(raw) {
  var state = emptyState()
  if (!raw) return state

  var rules = Array.isArray(raw.rules) ? raw.rules : []
  for (var i = 0; i < rules.length; i++) {
    var entry = rules[i]
    if (!entry) continue
    var cls = String(entry["class"] || "")
    var ws = String(entry["workspace"] || "")
    if (cls.length === 0 || ws.length === 0) continue
    state.rules.push({
      "class": cls,
      "workspace": ws,
      "silent": entry["silent"] === true,
      "label": String(entry["label"] || cls),
      // Sticky: set once a real window has been seen using this class. Without
      // persisting it, closing the app would demote a confirmed rule back to a
      // guess and wrongly flag it as one that can never fire.
      "verified": entry["verified"] === true
    })
  }
  state.rules = sorted(state.rules)

  // Schema 1 had no workspaces section at all; schema 2 stored a bare monitor
  // string. Both load here without a separate migration pass: an absent key is
  // an empty map, and a string value becomes { monitor: <string> }.
  var ws_map = raw.workspaces
  if (ws_map && typeof ws_map === "object") {
    for (var key in ws_map) {
      var name = String(key)
      if (name.length === 0) continue
      var value = ws_map[key]
      var entry = typeof value === "string"
        ? { "monitor": value, "persistent": false }
        : {
            "monitor": String((value && value["monitor"]) || ""),
            "persistent": !!(value && value["persistent"] === true)
          }
      // A workspace with neither a monitor nor persistence carries no rule.
      if (entry["monitor"].length === 0 && !entry["persistent"]) continue
      state.workspaces[name] = entry
    }
  }

  var alias_map = raw.aliases
  if (alias_map && typeof alias_map === "object") {
    for (var from in alias_map) {
      var to = String(alias_map[from] || "")
      if (String(from).length === 0 || to.length === 0 || String(from) === to) continue
      state.aliases[String(from)] = to
    }
  }

  return state
}

function sorted(rules) {
  var copy = rules.slice()
  copy.sort(function(a, b) {
    var aw = parseInt(a["workspace"], 10)
    var bw = parseInt(b["workspace"], 10)
    if (isNaN(aw)) aw = 999
    if (isNaN(bw)) bw = 999
    if (aw !== bw) return aw - bw
    return a["class"] < b["class"] ? -1 : (a["class"] > b["class"] ? 1 : 0)
  })
  return copy
}

function cloneState(state) {
  var out = emptyState()
  out.rules = state.rules.slice()
  for (var key in state.workspaces) {
    var entry = state.workspaces[key]
    out.workspaces[key] = { "monitor": entry["monitor"], "persistent": entry["persistent"] }
  }
  for (var from in state.aliases) out.aliases[from] = state.aliases[from]
  return out
}

function find(rules, cls) {
  for (var i = 0; i < rules.length; i++)
    if (rules[i]["class"] === cls) return rules[i]
  return null
}

// Case-insensitive lookup. Hyprland matches classes case-sensitively, so the
// STORED class must stay exact — but a .desktop file can declare a different
// case than the window actually uses (brave-browser vs Brave-browser), and
// treating those as two separate apps would show two rows and two rules for
// one program. Display and replacement therefore match case-insensitively
// while storage keeps whichever spelling we trust most.
function findCI(rules, cls) {
  var needle = String(cls || "").toLowerCase()
  for (var i = 0; i < rules.length; i++)
    if (rules[i]["class"].toLowerCase() === needle) return rules[i]
  return null
}

function upsert(state, cls, workspace, silent, label, verified) {
  var next = cloneState(state)
  var needle = String(cls).toLowerCase()
  var wasVerified = false
  var kept = []
  for (var i = 0; i < next.rules.length; i++) {
    if (next.rules[i]["class"].toLowerCase() === needle) {
      wasVerified = next.rules[i]["verified"] === true
      continue
    }
    kept.push(next.rules[i])
  }
  kept.push({
    "class": String(cls),
    "workspace": String(workspace),
    "silent": silent === true,
    "label": String(label || cls),
    // Confirmation never regresses: editing a rule cannot un-verify a class a
    // real window already proved.
    "verified": verified === true || wasVerified
  })
  next.rules = sorted(kept)
  return next
}

function markVerified(state, cls) {
  var needle = String(cls).toLowerCase()
  var changed = false
  var next = cloneState(state)
  var out = []
  for (var i = 0; i < next.rules.length; i++) {
    var rule = next.rules[i]
    if (rule["class"].toLowerCase() === needle && rule["verified"] !== true) {
      rule = {
        "class": rule["class"], "workspace": rule["workspace"],
        "silent": rule["silent"], "label": rule["label"], "verified": true
      }
      changed = true
    }
    out.push(rule)
  }
  next.rules = out
  return changed ? next : null
}

function isVerified(state, cls) {
  var rule = findCI(state.rules, cls)
  return !!rule && rule["verified"] === true
}

// Records that a guessed class really opens as another one. Returns null when
// nothing changed, so callers can skip a pointless write.
function putAlias(state, from, to) {
  var source = String(from || "")
  var target = String(to || "")
  if (source.length === 0 || target.length === 0 || source === target) return null
  if (state.aliases[source] === target) return null
  var next = cloneState(state)
  next.aliases[source] = target
  return next
}

function resolveAlias(state, cls) {
  var value = String(cls || "")
  var mapped = state.aliases[value]
  return mapped ? String(mapped) : value
}

function remove(state, cls) {
  var next = cloneState(state)
  var needle = String(cls).toLowerCase()
  var kept = []
  for (var i = 0; i < next.rules.length; i++)
    if (next.rules[i]["class"].toLowerCase() !== needle) kept.push(next.rules[i])
  next.rules = kept
  return next
}

function workspaceEntry(state, workspace) {
  var value = state.workspaces[String(workspace)]
  if (!value) return { "monitor": "", "persistent": false }
  return { "monitor": String(value["monitor"] || ""), "persistent": value["persistent"] === true }
}

function workspaceMonitor(state, workspace) {
  return workspaceEntry(state, workspace)["monitor"]
}

function workspacePersistent(state, workspace) {
  return workspaceEntry(state, workspace)["persistent"]
}

// An entry with no monitor and no persistence carries no rule, so it is
// dropped rather than written out as an empty stanza.
function putWorkspace(state, workspace, monitor, persistent) {
  var next = cloneState(state)
  var name = String(workspace)
  var value = { "monitor": String(monitor || ""), "persistent": persistent === true }
  if (value["monitor"].length === 0 && !value["persistent"]) delete next.workspaces[name]
  else next.workspaces[name] = value
  return next
}

function setWorkspaceMonitor(state, workspace, monitor) {
  return putWorkspace(state, workspace, monitor, workspacePersistent(state, workspace))
}

function setWorkspacePersistent(state, workspace, persistent) {
  return putWorkspace(state, workspace, workspaceMonitor(state, workspace), persistent)
}

// Which apps are pinned to a workspace — the workspace view reads the same
// rule list from the other direction.
function rulesForWorkspace(state, workspace) {
  var name = String(workspace)
  var out = []
  for (var i = 0; i < state.rules.length; i++)
    if (String(state.rules[i]["workspace"]) === name) out.push(state.rules[i])
  return out
}

function toJson(state) {
  return JSON.stringify({
    "version": SCHEMA_VERSION,
    "rules": state.rules,
    "workspaces": state.workspaces,
    "aliases": state.aliases
  }, null, 2) + "\n"
}

// ------------------------------------------------------------------ Lua

// Hyprland matches window classes with a regex (RE2). Classes are stored
// verbatim in JSON; anchoring and escaping happen only here, so the same
// escaping never passes through two layers.
function regexEscape(value) {
  return String(value).replace(/[.^$*+?()[\]{}|\\]/g, "\\$&")
}

function classPattern(cls) {
  return "^" + regexEscape(cls) + "$"
}

function luaString(value) {
  var s = String(value === undefined || value === null ? "" : value)
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i)
    var code = s.charCodeAt(i)
    if (ch === "\\") out += "\\\\"
    else if (ch === "\"") out += "\\\""
    else if (ch === "\n") out += "\\n"
    else if (ch === "\r") out += "\\r"
    else if (code < 32 || code === 127) out += "\\" + code
    else out += ch
  }
  return "\"" + out + "\""
}

function sortedWorkspaceNames(state) {
  var names = []
  for (var key in state.workspaces) names.push(key)
  names.sort(function(a, b) {
    var na = parseInt(a, 10), nb = parseInt(b, 10)
    if (isNaN(na)) na = 999
    if (isNaN(nb)) nb = 999
    return na - nb
  })
  return names
}

function toLua(state) {
  var lines = []
  lines.push("-- Generated by the zabka.appws plugin. Do not edit by hand.")
  lines.push("-- Source of truth: ~/.local/state/omarchy/appws/rules.json")
  lines.push("")
  // Loaded through require() from hyprland.lua, but if this file ever ends up
  // somewhere else a missing `o`/`hl` must not blow up the whole config.
  lines.push("if type(hl) ~= \"table\" or type(o) ~= \"table\" then return end")
  lines.push("")

  var names = sortedWorkspaceNames(state)
  lines.push("-- Workspace rules: monitor pinning and always-present workspaces")
  if (names.length === 0) lines.push("-- (none)")
  for (var i = 0; i < names.length; i++) {
    var entry = state.workspaces[names[i]]
    var parts = ["workspace = " + luaString(names[i])]
    if (entry["monitor"].length > 0) parts.push("monitor = " + luaString(entry["monitor"]))
    if (entry["persistent"]) parts.push("persistent = true")
    lines.push("hl.workspace_rule({ " + parts.join(", ") + " })")
  }
  lines.push("")

  lines.push("-- Application -> workspace")
  if (state.rules.length === 0) lines.push("-- (none)")
  for (var j = 0; j < state.rules.length; j++) {
    var rule = state.rules[j]
    var target = rule["workspace"] + (rule["silent"] ? " silent" : "")
    lines.push("o.window(" + luaString(classPattern(rule["class"]))
      + ", { workspace = " + luaString(target) + " })"
      + "  -- " + rule["label"])
  }
  lines.push("")
  return lines.join("\n")
}

// Move an already-open window. `follow = false` keeps focus from jumping to
// another monitor while you are still assigning rules.
//
// The `window` key is required. Hyprland silently ignores unknown keys and
// falls back to the ACTIVE window, so a typo here would move whatever the
// user happens to be looking at.
function moveWindowLua(address, workspace) {
  return "hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(String(workspace))
    + ", follow = false, window = " + luaString("address:" + String(address)) + " }))"
}

// ------------------------------------------------------------------ helpers

// A .desktop id is the fallback when StartupWMClass is absent. It is a guess:
// only 36% of desktop entries on a typical system declare the real class.
function classFromDesktopId(id) {
  var value = String(id || "")
  var slash = value.lastIndexOf("/")
  if (slash !== -1) value = value.substring(slash + 1)
  if (value.length > 8 && value.substring(value.length - 8) === ".desktop")
    value = value.substring(0, value.length - 8)
  return value
}

// Steam writes a .desktop file per game with no StartupWMClass and a launcher
// Exec, so the filename fallback yields "Factorio" while the actual XWayland
// window is "steam_app_427520". The game id in the Exec line is the reliable
// bridge between the two.
function classFromEntry(startupClass, execString, id) {
  var declared = String(startupClass || "")
  if (declared.length > 0) return declared

  var steam = String(execString || "").match(/steam:\/\/rungameid\/(\d+)/)
  if (steam) return "steam_app_" + steam[1]

  return classFromDesktopId(id)
}

function matches(query, row) {
  if (!query) return true
  var q = String(query).toLowerCase()
  var haystack = (String(row.name || "") + " " + String(row.cls || "") + " " + String(row.subtitle || "")).toLowerCase()
  return haystack.indexOf(q) !== -1
}

// QML loads this file with `import "Rules.js" as Rules` and has no `module`
// object, so the guard keeps that path untouched while letting Node require
// the same source for tests.
if (typeof module !== "undefined") {
  module.exports = {
    SCHEMA_VERSION: SCHEMA_VERSION,
    emptyState: emptyState,
    normalize: normalize,
    find: find,
    findCI: findCI,
    markVerified: markVerified,
    isVerified: isVerified,
    putAlias: putAlias,
    resolveAlias: resolveAlias,
    upsert: upsert,
    remove: remove,
    workspaceEntry: workspaceEntry,
    workspaceMonitor: workspaceMonitor,
    workspacePersistent: workspacePersistent,
    setWorkspaceMonitor: setWorkspaceMonitor,
    setWorkspacePersistent: setWorkspacePersistent,
    rulesForWorkspace: rulesForWorkspace,
    sortedWorkspaceNames: sortedWorkspaceNames,
    toJson: toJson,
    toLua: toLua,
    classPattern: classPattern,
    luaString: luaString,
    moveWindowLua: moveWindowLua,
    classFromDesktopId: classFromDesktopId,
    classFromEntry: classFromEntry,
    matches: matches
  }
}
