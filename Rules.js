// Pure model logic: rule storage, JSON <-> Lua serialization, and the small
// Lua snippets executed through `hyprctl eval`.
//
// Nothing here touches QML or the filesystem, so it can be tested standalone
// and a parsing mistake cannot take the bar down with it.

var SCHEMA_VERSION = 6

// ------------------------------------------------------------------ state
//
// {
//   version: 2,
//   rules:      [ { class, workspace, silent, label, autostart, command,
//                   startupOnly, startupWindow } ],   // per app
//               `workspace` may be "" (any): an app can launch at login
//               without being placed. With `startupOnly` the workspace
//               applies only to windows the app opens within `startupWindow`
//               seconds of Hyprland starting. No counter: a window count
//               would be reset by a config reload during login.
//   workspaces: { "3": { monitor: "desc:LG ...", persistent: true } },
//   aliases:    { "steam_app_427520": "com.factorio.Factorio" }
// }
//
// `aliases` maps a class we had to GUESS from a .desktop file onto the class a
// real window turned out to use. Without it a Steam game shows up twice: once
// as its launcher entry and once as the window it actually opens.

function emptyState() {
  return { rules: [], workspaces: {}, aliases: {}, settings: { updateCheck: true } }
}

// Measured at login on a busy session, Steam's first window took up to 38 s and
// Discord's 22 s; most apps show up within 15 s. 20 covers the common case, and
// a slow app can be given longer under Advanced.
var DEFAULT_STARTUP_WINDOW = 20

function clampInt(value, low, high, fallback) {
  var n = parseInt(value, 10)
  if (isNaN(n)) return fallback
  return Math.max(low, Math.min(high, n))
}

// Every rule field in one place. Rules used to be rebuilt from a subset of
// their fields in several functions, and each new field was silently dropped
// by whichever one was forgotten; `ruleWith` copies everything and applies
// only the changes it is given.
function makeRule(fields) {
  var ws = String(fields["workspace"] === undefined || fields["workspace"] === null ? "" : fields["workspace"])
  var cls = String(fields["class"] || "")
  return {
    "class": cls,
    // "" means any: the app is not placed, it may still launch at login.
    "workspace": ws,
    "silent": fields["silent"] === true,
    "label": String(fields["label"] || cls),
    // Sticky: set once a real window has been seen using this class. Without
    // persisting it, closing the app would demote a confirmed rule back to a
    // guess and wrongly flag it as one that can never fire.
    "verified": fields["verified"] === true,
    "autostart": fields["autostart"] === true,
    // Kept even when autostart is off, so toggling it back on does not
    // require the desktop entry to still be around.
    "command": String(fields["command"] || ""),
    // The workspace is for the login start only, not for every later window.
    // Meaningless without a workspace, so it is switched off with it.
    "startupOnly": fields["startupOnly"] === true && ws.length > 0,
    "startupWindow": clampInt(fields["startupWindow"], 1, 604800, DEFAULT_STARTUP_WINDOW)
  }
}

function ruleWith(rule, changes) {
  var fields = {}
  for (var key in rule) fields[key] = rule[key]
  for (var change in changes) fields[change] = changes[change]
  return makeRule(fields)
}

// A rule that does not place the app, does not launch it and does not keep
// it from taking focus carries nothing.
function isEmptyRule(rule) {
  return !rule || (String(rule["workspace"] || "").length === 0
    && rule["autostart"] !== true && rule["silent"] !== true)
}

function normalize(raw) {
  var state = emptyState()
  if (!raw) return state

  var rules = Array.isArray(raw.rules) ? raw.rules : []
  for (var i = 0; i < rules.length; i++) {
    var entry = rules[i]
    if (!entry) continue
    var cls = String(entry["class"] || "")
    if (cls.length === 0) continue
    // A rule written for a placeholder class (see declaredClass) can never
    // fire, so it is dropped rather than carried around as a verified rule.
    if (declaredClass(cls) !== cls) continue
    var rule = makeRule(entry)
    if (isEmptyRule(rule)) continue
    state.rules.push(rule)
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
      // An entry with neither a monitor nor persistence produces no rule, but
      // it is still a workspace the user added: kept so it stays listed until
      // it is removed on purpose, instead of vanishing the moment it is
      // switched to on demand.
      state.workspaces[name] = entry
    }
  }

  // The only setting so far: whether the plugin asks its own remote for news
  // of a newer version. On unless explicitly switched off.
  if (raw.settings && raw.settings.updateCheck === false) state.settings.updateCheck = false

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
  out.settings = { updateCheck: updateCheckEnabled(state) }
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

// Sets where an app opens. An empty workspace means "any": the app keeps
// whatever launch-at-login setting it has but is not placed, and a rule with
// nothing left on it disappears.
function upsert(state, cls, workspace, silent, label, verified, command) {
  var next = cloneState(state)
  var needle = String(cls).toLowerCase()
  var previous = null
  var kept = []
  for (var i = 0; i < next.rules.length; i++) {
    if (next.rules[i]["class"].toLowerCase() === needle) {
      previous = next.rules[i]
      continue
    }
    kept.push(next.rules[i])
  }
  var supplied = String(command || "")
  var base = previous || {}
  var rule = ruleWith(base, {
    "class": String(cls),
    "workspace": String(workspace === undefined || workspace === null ? "" : workspace),
    "silent": silent === true,
    "label": String(label || cls),
    // Confirmation never regresses: editing a rule cannot un-verify a class a
    // real window already proved.
    "verified": verified === true || (!!previous && previous["verified"] === true),
    "command": supplied.length > 0 ? supplied : (previous ? previous["command"] : "")
  })
  if (!isEmptyRule(rule)) kept.push(rule)
  next.rules = sorted(kept)
  return next
}

// Autostart needs a command; a rule created from a window with no desktop entry
// has none, and turning it on would generate a launch line that does nothing.
function canAutostart(state, cls) {
  var rule = findCI(state.rules, cls)
  return !!rule && String(rule["command"] || "").length > 0
}

function isAutostart(state, cls) {
  var rule = findCI(state.rules, cls)
  return !!rule && rule["autostart"] === true
}

// Takes the command as well: a rule written before commands were recorded has
// none stored, and the caller knows the desktop entry it is looking at.
// Turning it on for an app with no rule creates one with no workspace, so an
// app can launch at login without being placed; turning it off leaves a rule
// with no workspace with nothing to say, and it goes.
function setAutostart(state, cls, on, command, label) {
  var needle = String(cls).toLowerCase()
  var supplied = String(command || "")
  var next = cloneState(state)
  var out = []
  var found = false
  for (var i = 0; i < next.rules.length; i++) {
    var rule = next.rules[i]
    if (rule["class"].toLowerCase() === needle) {
      found = true
      var existing = String(rule["command"] || "")
      rule = ruleWith(rule, { "autostart": on === true, "command": supplied.length > 0 ? supplied : existing })
    }
    if (!isEmptyRule(rule)) out.push(rule)
  }
  if (!found && on === true)
    out.push(makeRule({ "class": String(cls), "workspace": "", "label": label || cls, "autostart": true, "command": supplied }))
  next.rules = sorted(out)
  return next
}

// "Only at startup": the workspace applies to every window the app opens
// within `seconds` of Hyprland starting, and never again. Needs a workspace;
// without one there is nothing to apply.
function setStartupOnly(state, cls, on, seconds) {
  var needle = String(cls).toLowerCase()
  var next = cloneState(state)
  var changed = false
  next.rules = next.rules.map(function(rule) {
    if (rule["class"].toLowerCase() !== needle || String(rule["workspace"]).length === 0) return rule
    changed = true
    return ruleWith(rule, {
      "startupOnly": on === true,
      "startupWindow": seconds === undefined ? rule["startupWindow"] : seconds
    })
  })
  return changed ? next : state
}

// Quickshell hands over an argv array with the .desktop field codes already
// resolved. Quote only what a shell would otherwise mangle, so the generated
// Lua stays readable for the common `spotify` case.
// What goes into the launch line. `uwsm-app`, which o.launch() wraps around,
// resolves a Desktop Entry ID directly — which handles field codes properly and
// names the transient scope after the app. Passing the resolved argv instead would
// carry artefacts like the empty `--uri=` left behind by Spotify's `%u`.
function launchTarget(entryId, parts) {
  var id = String(entryId || "")
  if (id.length > 0)
    return id.substring(id.length - 8) === ".desktop" ? id : id + ".desktop"
  return shellCommand(parts)
}

function shellCommand(parts) {
  if (typeof parts === "string") return parts
  if (!parts || !parts.length) return ""
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var token = String(parts[i])
    if (token.length === 0) { out.push("''"); continue }
    if (/^[A-Za-z0-9_.:\/=@%+-]+$/.test(token)) out.push(token)
    else out.push("'" + token.split("'").join("'\\''") + "'")
  }
  return out.join(" ")
}

function markVerified(state, cls) {
  var needle = String(cls).toLowerCase()
  var changed = false
  var next = cloneState(state)
  var out = []
  for (var i = 0; i < next.rules.length; i++) {
    var rule = next.rules[i]
    if (rule["class"].toLowerCase() === needle && rule["verified"] !== true) {
      rule = ruleWith(rule, { "verified": true })
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

// A rule written against a guessed class follows the alias to the class the
// window really uses, or the launcher row would lose its rule while an
// orphan rule for the guess lingered on. Returns null when there is nothing
// to move.
function migrateRule(state, from, to) {
  var source = String(from || "")
  var target = String(to || "")
  if (source.length === 0 || target.length === 0 || source === target) return null
  var rule = find(state.rules, source)
  if (!rule || findCI(state.rules, target)) return null
  var next = remove(state, source)
  next.rules = sorted(next.rules.concat([ruleWith(rule, { "class": target, "verified": true })]))
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

function putWorkspace(state, workspace, monitor, persistent) {
  var next = cloneState(state)
  next.workspaces[String(workspace)] = { "monitor": String(monitor || ""), "persistent": persistent === true }
  return next
}

// Removes a workspace: its monitor and persistence, and the placement of
// every app pinned to it. Leaving those would only bring the row straight
// back, since a workspace with rules is always listed. An app that also
// launches at login keeps that and simply stops being placed.
function removeWorkspace(state, workspace) {
  var name = String(workspace)
  var next = cloneState(state)
  delete next.workspaces[name]
  var out = []
  for (var i = 0; i < next.rules.length; i++) {
    var rule = next.rules[i]
    if (String(rule["workspace"]) === name) rule = ruleWith(rule, { "workspace": "" })
    if (!isEmptyRule(rule)) out.push(rule)
  }
  next.rules = sorted(out)
  return next
}

// A workspace entry that would generate no rule at all.
function workspaceIsEmpty(entry) {
  return !entry || (String(entry["monitor"] || "").length === 0 && entry["persistent"] !== true)
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
    "aliases": state.aliases,
    "settings": { "updateCheck": updateCheckEnabled(state) }
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

// Text that goes after "--" in the generated file. A label comes from a
// window class or a desktop entry name, which an application controls; a
// newline in it would end the comment and turn the rest into executed Lua.
// Line breaks and control characters become spaces, and long text is cut.
function luaComment(value) {
  var text = String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  if (text.length > 80) text = text.substring(0, 79) + "\u2026"
  return text
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

// `guards` maps a rule's class to the process names to look for before
// launching it, for apps found to start themselves through an XDG autostart
// entry. Any other app is launched unconditionally.
function toLua(state, guards) {
  var lines = []
  lines.push("-- Generated by the dominikzajac.appspace plugin. Do not edit by hand.")
  lines.push("-- Source of truth: ~/.local/state/omarchy/appspace/rules.json")
  lines.push("")
  // Loaded through require() from hyprland.lua, but if this file ever ends up
  // somewhere else a missing `o`/`hl` must not blow up the whole config.
  lines.push("if type(hl) ~= \"table\" or type(o) ~= \"table\" then return end")
  lines.push("")

  var names = sortedWorkspaceNames(state).filter(function(name) {
    return !workspaceIsEmpty(state.workspaces[name])
  })
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

  lines.push("-- Application -> workspace, and apps kept from taking focus, every time they open")
  var placed = 0
  var atStartup = []
  for (var j = 0; j < state.rules.length; j++) {
    var rule = state.rules[j]
    var pattern = luaString(classPattern(rule["class"]))
    var comment = "  -- " + luaComment(rule["label"])
    if (String(rule["workspace"]).length === 0) {
      // Not placed, but kept from taking focus whenever it opens.
      if (rule["silent"] === true) {
        lines.push("o.window(" + pattern + ", { no_initial_focus = true })" + comment)
        placed++
      }
      continue
    }
    if (rule["startupOnly"] === true) { atStartup.push(rule); continue }
    var target = rule["workspace"] + (rule["silent"] ? " silent" : "")
    lines.push("o.window(" + pattern + ", { workspace = " + luaString(target) + " })" + comment)
    placed++
  }
  if (placed === 0) lines.push("-- (none)")

  if (atStartup.length > 0) {
    lines.push("")
    lines.push("-- Application -> workspace, only while Hyprland is starting up. Once its")
    lines.push("-- seconds have passed, an app opens wherever it likes.")
    lines.push("if type(hl.on) == \"function\" then")
    lines.push("  local placements = {")
    for (var q = 0; q < atStartup.length; q++) {
      var rr = atStartup[q]
      lines.push("    { class = " + luaString(rr["class"]) + ", workspace = " + luaString(rr["workspace"])
        + ", follow = " + (rr["silent"] ? "false" : "true")
        + ", within = " + rr["startupWindow"] + " },"
        + "  -- " + luaComment(rr["label"]))
    }
    lines.push("  }")
    lines.push("")
    lines.push("  -- Seconds since the compositor process started, read from /proc. A config")
    lines.push("  -- reload does not restart that process, so this stays correct across reloads")
    lines.push("  -- and a change made later in the session never re-arms the placement.")
    lines.push("  local function seconds_since_start()")
    lines.push("    local up = io.open(\"/proc/uptime\", \"r\")")
    lines.push("    if not up then return nil end")
    lines.push("    local uptime = tonumber((up:read(\"*l\") or \"\"):match(\"^(%S+)\"))")
    lines.push("    up:close()")
    lines.push("    local st = io.open(\"/proc/self/stat\", \"r\")")
    lines.push("    if not st then return nil end")
    lines.push("    local stat = st:read(\"*l\") or \"\"")
    lines.push("    st:close()")
    lines.push("    -- The command name may contain spaces and brackets, so count from the last \")\".")
    lines.push("    local rest = stat:match(\"^.*%)%s+(.*)$\")")
    lines.push("    if not uptime or not rest then return nil end")
    lines.push("    local n = 0")
    lines.push("    for field in rest:gmatch(\"%S+\") do")
    lines.push("      n = n + 1")
    lines.push("      if n == 20 then")
    lines.push("        local started = tonumber(field)")
    lines.push("        return started and (uptime - started / 100) or nil")
    lines.push("      end")
    lines.push("    end")
    lines.push("    return nil")
    lines.push("  end")
    lines.push("")
    lines.push("  hl.on(\"window.open\", function(window)")
    lines.push("    local elapsed = seconds_since_start()")
    lines.push("    if not elapsed then return end")
    lines.push("    for _, p in ipairs(placements) do")
    lines.push("      -- Compared without case: a desktop entry can spell the class differently")
    lines.push("      -- from the window (brave-browser, Brave-browser) and the first window of the")
    lines.push("      -- session may arrive before the stored spelling has been corrected.")
    lines.push("      if (window.class or \"\"):lower() == p.class:lower() and elapsed <= p.within then")
    lines.push("        hl.dispatch(hl.dsp.window.move({ workspace = p.workspace, follow = p.follow, window = \"address:\" .. window.address }))")
    lines.push("        return")
    lines.push("      end")
    lines.push("    end")
    lines.push("  end)")
    lines.push("end")
  }
  var launched = []
  for (var k = 0; k < state.rules.length; k++) {
    var candidate = state.rules[k]
    if (candidate["autostart"] !== true) continue
    if (String(candidate["command"] || "").length === 0) continue
    launched.push(candidate)
  }

  if (launched.length > 0) {
    lines.push("")
    lines.push("-- Launch at login. An app that also starts itself through an XDG autostart")
    lines.push("-- entry is given two seconds to do so, and is launched here only if its")
    lines.push("-- process is not already running, so the order is not a race.")
    // Older Omarchy builds may not carry this helper; a missing one must not
    // take the whole config down with it.
    lines.push("if type(o.exec_on_start) == \"function\" then")
    for (var m = 0; m < launched.length; m++) {
      var guard = guards && guards[launched[m]["class"]]
      lines.push("  o.exec_on_start(" + luaString(launchCommand(launched[m]["command"], guard))
        + ")  -- " + luaComment(launched[m]["label"]))
    }
    lines.push("end")
  }

  lines.push("")
  return lines.join("\n")
}

// Launchers and interpreters that front many unrelated programs. A process
// of this name says nothing about one particular app: "steam" is running for
// every Steam game, "flatpak" for every Flatpak app.
var GENERIC_LAUNCHERS = ["steam", "flatpak", "env", "sh", "bash", "zsh", "fish", "sleep", "uwsm", "uwsm-app",
  "gtk-launch", "xdg-open", "xdg-terminal-exec", "python", "python3", "node", "java", "electron", "wine", "proton",
  "omarchy-launch-webapp", "omarchy-launch-tui", "omarchy-launch-browser"]

// The process name to look for when deciding whether an app is already
// running: the binary's basename, cut to the 15 characters the kernel keeps
// in a process's comm name. "" when the Exec line names a generic launcher
// or a Steam URL, where no single process identifies the app.
function guardBinary(execString) {
  var exec = String(execString || "")
  if (/steam:\/\//.test(exec)) return ""
  var bin = execBinary(exec)
  if (bin.length === 0 || GENERIC_LAUNCHERS.indexOf(bin) !== -1) return ""
  if (/^omarchy-launch-/.test(bin)) return ""
  return bin.substring(0, 15)
}

// The shell line behind "Launch at startup". With no process names the app
// is simply launched. With names, the launch waits for the XDG autostart pass
// and goes ahead only if none of them is running, so an app that starts
// itself is not started twice.
function launchCommand(target, processNames) {
  var names = []
  for (var i = 0; i < (processNames || []).length; i++)
    if (processNames[i] && names.indexOf(processNames[i]) === -1) names.push(processNames[i])
  var launch = "uwsm-app -- " + shellCommand([target])
  if (names.length === 0) return launch
  var checks = names.map(function(name) { return "pgrep -x -- " + shellCommand([name]) + " >/dev/null" })
  return "sleep 2; " + checks.join(" || ") + " || " + launch
}

// A user can hide an installed app by dropping a stub with `Hidden=true` over
// it in ~/.local/share/applications. Launchers resolve that stub first, and it
// is not a valid entry on its own: launching it fails with "Key 'Type' is
// missing". The probe prints one basename per such file.
function parseHiddenEntries(text) {
  var out = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var name = lines[i].trim()
    if (name.length > 0) out[classFromDesktopId(name)] = true
  }
  return out
}

// Parses the probe output: one tab-separated line per autostart file,
// system directory first, user directory last so it overrides by basename.
//   basename \t Hidden \t OnlyShowIn \t NotShowIn \t Exec
// Returns the entries that would actually start under the given desktop.
function parseAutostart(text, desktop) {
  var byName = ({})
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length < 5 || parts[0].length === 0) continue
    byName[parts[0]] = {
      basename: parts[0],
      hidden: parts[1].trim().toLowerCase() === "true",
      onlyShowIn: parts[2].split(";").filter(function(v) { return v.length > 0 }),
      notShowIn: parts[3].split(";").filter(function(v) { return v.length > 0 }),
      exec: parts.slice(4).join("\t").trim()
    }
  }
  var current = String(desktop || "Hyprland")
  var out = []
  for (var name in byName) {
    var entry = byName[name]
    if (entry.hidden) continue
    if (entry.onlyShowIn.length > 0 && entry.onlyShowIn.indexOf(current) === -1) continue
    if (entry.notShowIn.indexOf(current) !== -1) continue
    out.push(entry)
  }
  return out
}

function execBinary(execString) {
  var value = String(execString || "").trim()
  var m = value.match(/^"([^"]+)"|^(\S+)/)
  var first = m ? (m[1] || m[2]) : ""
  var slash = first.lastIndexOf("/")
  return slash === -1 ? first : first.substring(slash + 1)
}

// Does the app with this desktop id and Exec line start itself at login?
// Matched by entry name first (1password.desktop both places), then by the
// binary the Exec line runs. Returns the autostart basename, or "".
function ownAutostartFor(entries, desktopId, execString) {
  var id = classFromDesktopId(desktopId)
  for (var i = 0; i < (entries || []).length; i++)
    if (classFromDesktopId(entries[i].basename) === id) return entries[i].basename
  // By binary only when the binary identifies the app: every Steam game's
  // Exec runs "steam", which would otherwise match Steam's own login entry.
  var bin = guardBinary(execString)
  if (bin.length === 0) return ""
  for (var j = 0; j < (entries || []).length; j++)
    if (guardBinary(entries[j].exec) === bin) return entries[j].basename
  return ""
}

// The process names that tell "already running" for an app that starts
// itself: its own binary and the one its autostart entry runs.
function guardBinaries(entries, ownBasename, execString) {
  var out = []
  var own = ""
  for (var i = 0; i < (entries || []).length; i++)
    if (entries[i].basename === ownBasename) own = guardBinary(entries[i].exec)
  var mine = guardBinary(execString)
  if (mine.length > 0) out.push(mine)
  if (own.length > 0 && out.indexOf(own) === -1) out.push(own)
  return out
}

// ------------------------------------------------------------- update check

function updateCheckEnabled(state) {
  return !state || !state.settings || state.settings.updateCheck !== false
}

function setUpdateCheck(state, on) {
  var next = cloneState(state)
  next.settings = { updateCheck: on === true }
  return next
}

// The script prints one word. Anything else is "unknown": a plugin that trusts
// whatever came back from a subprocess would show nonsense for a broken script.
function parseUpdateProbe(text) {
  var word = String(text || "").trim().split(/\s+/)[0]
  return ["current", "available", "unmanaged"].indexOf(word) !== -1 ? word : "unknown"
}

// "just now", "23 minutes ago", "1 hour ago", "3 days ago".
function relativeTime(thenMs, nowMs) {
  var seconds = Math.max(0, Math.round((Number(nowMs) - Number(thenMs)) / 1000))
  if (seconds < 45) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago")
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.round(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

// What the panel shows beside the title, from the last probe's state and time.
//   state: "pending" | "checking" | "current" | "available" | "unknown" | "unmanaged"
// `canCheck` drives the manual button, `canUpdate` swaps it for Update.
function updateSummary(info, nowMs, enabled) {
  var state = String((info && info.state) || "pending")
  var checkedAt = Number((info && info.checkedAt) || 0)
  var ago = checkedAt > 0 ? relativeTime(checkedAt, nowMs) : ""
  if (state === "unmanaged") return { text: "", canCheck: false, canUpdate: false }
  if (state === "checking") return { text: "Checking for updates\u2026", canCheck: false, canUpdate: false }
  if (state === "available")
    return { text: "Update available" + (ago ? " \u00b7 checked " + ago : ""), canCheck: true, canUpdate: true }
  if (state === "current")
    return { text: "No updates \u00b7 checked " + ago, canCheck: true, canUpdate: false }
  if (state === "unknown")
    return { text: "Couldn\u2019t check" + (ago ? " \u00b7 tried " + ago : ""), canCheck: true, canUpdate: false }
  // Nothing checked yet in this session.
  return { text: enabled ? "Not checked yet" : "Update checks are off", canCheck: true, canUpdate: false }
}

// ------------------------------------------------------------- monitors

// "eDP-1" means nothing to most people; "Laptop screen" does. Connector
// names follow DRM: eDP (built-in panel), DP, HDMI-A, DVI-I/-D, VGA.
function connectorLabel(name) {
  var value = String(name || "")
  var m = value.match(/^([A-Za-z]+)(?:-[A-Z])?-(\d+)$/)
  if (!m) return value
  var kind = m[1].toLowerCase(), n = m[2]
  if (kind === "edp") return "Laptop screen"
  if (kind === "dp") return "DisplayPort " + n
  if (kind === "hdmi") return "HDMI " + n
  if (kind === "dvi") return "DVI " + n
  if (kind === "vga") return "VGA " + n
  return value
}

// Hyprland's description is "<make> <model> <serial>" in one string. The
// make can be two words ("LG Electronics", "Dell Inc.", "AU Optronics"); the
// model is where digits start. Returns the make only, since model strings are
// mostly codes.
function monitorVendor(description) {
  var words = String(description || "").trim().split(/\s+/)
  var out = []
  for (var i = 0; i < words.length && out.length < 2; i++) {
    if (/\d/.test(words[i]) || /^0x/i.test(words[i])) break
    out.push(words[i])
  }
  return out.join(" ")
}

// One label per monitor, with the position added only when there is more
// than one: "Laptop screen", "LG Electronics (DisplayPort 2) · right".
// `monitors` are { name, description, x, y } sorted by x; `index` is the
// one to label.
function monitorLabel(monitors, index) {
  var mon = monitors[index]
  var isBuiltIn = /^edp/i.test(String(mon.name || ""))
  var vendor = monitorVendor(mon.description)
  var label = isBuiltIn ? "Laptop screen"
    : (vendor.length > 0 ? vendor + " (" + connectorLabel(mon.name) + ")" : connectorLabel(mon.name))
  if (monitors.length < 2) return label

  var stacked = monitors.every(function(m) { return Number(m.x) === Number(monitors[0].x) })
  var position
  if (stacked) {
    var byY = monitors.slice().sort(function(a, b) { return Number(a.y) - Number(b.y) })
    var k = byY.indexOf(mon)
    position = monitors.length === 2 ? (k === 0 ? "top" : "bottom") : (k === 0 ? "top" : (k === byY.length - 1 ? "bottom" : "middle"))
  } else if (monitors.length === 2) {
    position = index === 0 ? "left" : "right"
  } else if (monitors.length === 3) {
    position = index === 0 ? "left" : (index === 2 ? "right" : "middle")
  } else {
    position = String(index + 1) + " of " + monitors.length
  }
  return label + " · " + position
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
// Arch's chromium.desktop ships `StartupWMClass=@@startup_wm_class`: a build
// template placeholder nobody filled in. Trusting it produced a rule for a
// class no window will ever carry, flagged as verified. A declared class is
// only usable when it looks like one: no template markers, no whitespace, no
// shell or field-code characters.
function declaredClass(startupClass) {
  var value = String(startupClass || "").trim()
  if (value.length === 0) return ""
  if (/[@$%"'`\s]/.test(value)) return ""
  return value
}

// Flatpak exports copy StartupWMClass from the upstream desktop file, but a
// sandboxed Wayland window carries the Flatpak app id, which is also the
// desktop id: Discord declares "discord", its window is com.discordapp.Discord.
function isFlatpakExec(execString) {
  return /(^|[\s\/])flatpak\s+run\b/.test(String(execString || ""))
}

// Terminal launchers name the window themselves, so the class is in the Exec
// line: `xdg-terminal-exec --app-id=TUI.tile -e lazydocker`, or
// `omarchy-launch-tui btop`, which becomes org.omarchy.btop.
function terminalAppId(execString) {
  var exec = String(execString || "")
  var flag = exec.match(/--app-id[= ]([^\s"']+)/)
  if (flag) return flag[1]
  var tui = exec.match(/omarchy-launch-tui\s+([^\s"']+)/)
  if (tui) return "org.omarchy." + classFromDesktopId(tui[1])
  return ""
}

// omarchy-launch-webapp opens the URL in the default browser's --app mode, and
// Chromium names such a window "<product>-<host>_<path>-<profile>" with every
// "/" in the path turned into "_": https://chatgpt.com/ becomes
// chrome-chatgpt.com__-Default. The product prefix is the one part that
// depends on which browser is the default, so the caller supplies it.
function webappClass(execString, browserPrefix) {
  var prefix = String(browserPrefix || "")
  if (prefix.length === 0) return ""
  var m = String(execString || "").match(/omarchy-launch-webapp\s+["']?(https?:\/\/[^\s"']+)/)
  if (!m) return ""
  var rest = m[1].replace(/^https?:\/\//, "").replace(/[?#].*$/, "")
  var slash = rest.indexOf("/")
  var host = slash === -1 ? rest : rest.substring(0, slash)
  var path = slash === -1 ? "/" : rest.substring(slash)
  if (host.length === 0) return ""
  return prefix + "-" + host + "_" + path.replace(/\//g, "_") + "-Default"
}

// Mirrors omarchy-launch-webapp: anything outside its list of Chromium
// derivatives is launched through chromium.desktop, whose product name is
// "chrome".
function browserPrefix(defaultBrowserDesktopId) {
  var id = classFromDesktopId(defaultBrowserDesktopId).toLowerCase()
  if (id.indexOf("google-chrome") === 0) return "chrome"
  if (id.indexOf("brave") === 0) return "brave"
  if (id.indexOf("microsoft-edge") === 0) return "msedge"
  if (id.indexOf("opera") === 0) return "opera"
  if (id.indexOf("vivaldi") === 0) return "vivaldi"
  if (id.indexOf("helium") === 0) return "helium"
  return "chrome"
}

function classFromEntry(startupClass, execString, id, browserPrefix) {
  var exec = String(execString || "")

  var declared = declaredClass(startupClass)
  if (declared.length > 0 && !isFlatpakExec(exec)) return declared

  var steam = exec.match(/steam:\/\/rungameid\/(\d+)/)
  if (steam) return "steam_app_" + steam[1]

  var tui = terminalAppId(exec)
  if (tui.length > 0) return tui

  var web = webappClass(exec, browserPrefix)
  if (web.length > 0) return web

  return classFromDesktopId(id)
}

// Rules are matched case-insensitively for display, but Hyprland compares the
// stored spelling exactly. Once a live window shows the real spelling the rule
// is rewritten to it, or "^brave-browser$" keeps missing "Brave-browser".
// Returns null when the spelling already agrees.
function respell(state, cls) {
  var live = String(cls || "")
  var rule = findCI(state.rules, live)
  if (!rule || rule["class"] === live) return null
  return upsert(state, live, rule["workspace"], rule["silent"], rule["label"], true, rule["command"])
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
    canAutostart: canAutostart,
    isAutostart: isAutostart,
    setAutostart: setAutostart,
    setStartupOnly: setStartupOnly,
    makeRule: makeRule,
    ruleWith: ruleWith,
    isEmptyRule: isEmptyRule,
    DEFAULT_STARTUP_WINDOW: DEFAULT_STARTUP_WINDOW,
    shellCommand: shellCommand,
    launchTarget: launchTarget,
    isVerified: isVerified,
    putAlias: putAlias,
    migrateRule: migrateRule,
    resolveAlias: resolveAlias,
    upsert: upsert,
    remove: remove,
    workspaceEntry: workspaceEntry,
    workspaceMonitor: workspaceMonitor,
    workspacePersistent: workspacePersistent,
    setWorkspaceMonitor: setWorkspaceMonitor,
    setWorkspacePersistent: setWorkspacePersistent,
    removeWorkspace: removeWorkspace,
    workspaceIsEmpty: workspaceIsEmpty,
    rulesForWorkspace: rulesForWorkspace,
    sortedWorkspaceNames: sortedWorkspaceNames,
    toJson: toJson,
    toLua: toLua,
    guardBinary: guardBinary,
    guardBinaries: guardBinaries,
    launchCommand: launchCommand,
    parseAutostart: parseAutostart,
    parseHiddenEntries: parseHiddenEntries,
    updateCheckEnabled: updateCheckEnabled,
    setUpdateCheck: setUpdateCheck,
    parseUpdateProbe: parseUpdateProbe,
    relativeTime: relativeTime,
    updateSummary: updateSummary,
    ownAutostartFor: ownAutostartFor,
    classPattern: classPattern,
    luaString: luaString,
    luaComment: luaComment,
    moveWindowLua: moveWindowLua,
    connectorLabel: connectorLabel,
    monitorVendor: monitorVendor,
    monitorLabel: monitorLabel,
    classFromDesktopId: classFromDesktopId,
    declaredClass: declaredClass,
    isFlatpakExec: isFlatpakExec,
    terminalAppId: terminalAppId,
    webappClass: webappClass,
    browserPrefix: browserPrefix,
    classFromEntry: classFromEntry,
    respell: respell,
    matches: matches
  }
}
