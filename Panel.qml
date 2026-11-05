import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Rules.js" as Rules

// Bar widget: pick an app or window on the left, set its workspace (and which
// monitor that workspace lives on) on the right. Writes rules.json, regenerates
// ~/.local/state/omarchy/toggles/hypr/appspace.lua and reloads Hyprland.
Panel {
  id: root
  moduleName: "dominikzajac.appspace"
  ipcTarget: "dominikzajac.appspace"
  // We own the single IpcHandler the target allows, so it can carry
  // list/set/unset on top of the base open/close/toggle.
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")
  readonly property string rulesPath: root.stateHome + "/omarchy/appspace/rules.json"
  // Omarchy loads every *.lua in this directory on each config reload (see
  // default/hypr/toggles.lua), so nothing in ~/.config/hypr has to change.
  readonly property string luaPath: root.stateHome + "/omarchy/toggles/hypr/appspace.lua"

  // Model
  property var state: Rules.emptyState()
  property var rows: []
  property string filterText: ""
  property string selectedKey: ""
  // "apps" = app -> workspace, "workspaces" = workspace -> monitor + contents
  property string view: "apps"

  // Write pipeline
  property string rollbackLua: ""
  property string rollbackJson: ""
  property string errorBaseline: ""
  property var stagedState: null
  property bool rollingBack: false
  property bool applying: false
  property string pendingMoveAddress: ""
  property string pendingMoveWorkspace: ""
  property string status: ""
  property bool statusError: false

  // pid -> Steam app id, read from the running processes' environment. This is
  // the only reliable bridge between a Steam .desktop entry and the window the
  // game actually opens: Factorio's launcher says rungameid/427520 while its
  // window is "com.factorio.Factorio".
  property var steamPids: ({})

  // "chrome", "brave", ... — the product name Chromium puts in front of a web
  // app's class, taken from the default browser the same way
  // omarchy-launch-webapp picks it.
  property string browserPrefix: ""

  // XDG autostart entries that would start under this desktop, from
  // /etc/xdg/autostart and ~/.config/autostart. An app that starts itself at
  // login (1Password writes its own entry) must not be launched a second time
  // by this plugin: at login the two launches raced within the same second
  // and whichever lost closed on the app's single-instance lock.
  property var autostartEntries: []

  // Desktop ids hidden by a user stub (Hidden=true). Such an app cannot be
  // launched by its entry, so it is not offered.
  property var hiddenEntries: ({})

  // Every app row before the search filter is applied: the generated Lua
  // must not change depending on what happens to be typed in the box.
  property var allApps: []

  // The bar sizes each widget from its root implicitWidth/Height. Without
  // these the slot collapses to 0x0 and the icon never appears on the bar.
  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  readonly property string panelTitle: "AppSpace"

  readonly property string panelDescription: "Manage where apps open: which workspace, and on which monitor"

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- updates
  //
  // Is a newer version published? Read-only: update-check.sh asks the plugin's
  // own remote for its HEAD and compares it with the installed commit. Nothing
  // is ever installed from here; the Update button opens Omarchy's own
  // updater in a terminal, which shows the diff and asks first.
  property string updateState: "pending"
  property real updateCheckedAt: 0
  property real nowMs: Date.now()
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/+$/, "")
  readonly property string updateScript: root.pluginDir + "/update-check.sh"
  readonly property var updateInfo: Rules.updateSummary(
    { state: root.updateState, checkedAt: root.updateCheckedAt }, root.nowMs, Rules.updateCheckEnabled(root.state))

  function checkForUpdates() {
    if (updateProbe.running) return
    root.updateState = "checking"
    updateProbe.running = true
  }

  function runUpdate() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      Rules.shellCommand(["sh", root.updateScript, "apply", root.moduleName, root.pluginDir])])
  }

  // ------------------------------------------------------------- monitors

  // Hyprland matches monitors by `desc:` (make + model + serial) rather than
  // by connector, so moving a cable to another port keeps the layout.
  readonly property var monitorOptions: {
    var out = [{ value: "", label: "Auto", tooltip: "Wherever the workspace is opened" }]
    var mons = []
    try { mons = Hyprland.monitors.values || [] } catch (e) { mons = [] }

    var sortable = []
    for (var i = 0; i < mons.length; i++) {
      var m = mons[i]
      if (!m) continue
      sortable.push({ x: Number(m.x) || 0, y: Number(m.y) || 0,
                      description: String(m.description || ""), name: String(m.name || ""),
                      focused: m.focused === true })
    }
    sortable.sort(function(a, b) { return a.x - b.x })

    // Named by connector and vendor ("Laptop screen", "LG Electronics
    // (DisplayPort 2) · right"); the value Hyprland matches on stays desc:.
    for (var j = 0; j < sortable.length; j++) {
      var mon = sortable[j]
      if (mon.description.length === 0) continue
      out.push({
        value: "desc:" + mon.description,
        label: Rules.monitorLabel(sortable, j) + (mon.focused && sortable.length > 1 ? " (this screen)" : ""),
        tooltip: mon.name + " — " + mon.description
      })
    }
    return out
  }

  // "Any" is the default: the app is not placed anywhere in particular.
  readonly property var workspaceOptions: {
    var out = [{ value: "", label: "Any", tooltip: "Open wherever it normally would" }]
    for (var i = 1; i <= 9; i++) out.push({ value: String(i), label: String(i) })
    return out
  }

  // What the apps list shows next to an app that has a rule.
  function ruleBadge(rule) {
    if (!rule) return ""
    var ws = String(rule["workspace"] || "")
    if (ws.length > 0 && rule["startupOnly"] === true) return "login → " + ws
    if (ws.length > 0) return "→ " + ws
    if (rule["autostart"] === true) return "login"
    return rule["silent"] === true ? "silent" : ""
  }

  property bool advancedOpen: false

  // The same set Omarchy's bar shows: 1-5 always, plus any live workspace up
  // to 10 (see shell/plugins/bar/widgets/Workspaces.qml). Anything this plugin
  // has a rule for is added too, otherwise pinning a monitor to an empty
  // workspace would make its own row disappear.
  readonly property var barWorkspaces: {
    var seen = ({})
    var ids = []
    function add(value) {
      var id = parseInt(value, 10)
      if (isNaN(id) || id < 1) return
      if (seen[id]) return
      seen[id] = true
      ids.push(id)
    }

    for (var i = 1; i <= 5; i++) add(i)

    var live = []
    try { live = Hyprland.workspaces.values || [] } catch (e) { live = [] }
    for (var j = 0; j < live.length; j++)
      if (live[j] && live[j].id > 0 && live[j].id <= 10) add(live[j].id)

    for (var key in root.state.workspaces) add(key)
    for (var k = 0; k < root.state.rules.length; k++) add(root.state.rules[k]["workspace"])

    ids.sort(function(a, b) { return a - b })
    return ids
  }

  // ------------------------------------------------------------- monitors

  // What Hyprland reports now: connector, description, current mode, position,
  // scale, rotation and every mode the screen offers.
  property var monitorList: []

  function readMonitors() {
    if (!monitorsProc.running) monitorsProc.running = true
  }

  function parseMonitors(text) {
    var parsed = []
    try { parsed = JSON.parse(text) } catch (e) { return }
    if (!Array.isArray(parsed)) return
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var m = parsed[i]
      if (!m || m.disabled === true || !m.description) continue
      var modes = []
      var seen = ({})
      var list = m.availableModes || []
      for (var j = 0; j < list.length; j++) {
        var mode = String(list[j]).replace(/Hz$/, "")
        if (seen[mode]) continue
        seen[mode] = true
        var parts = /^([0-9]+)x([0-9]+)@([0-9.]+)$/.exec(mode)
        modes.push({ value: mode, label: mode.replace("x", "\u00d7").replace("@", " @ ") + " Hz",
                     w: parts ? parseInt(parts[1], 10) : 0, h: parts ? parseInt(parts[2], 10) : 0,
                     hz: parts ? parseFloat(parts[3]) : 0 })
      }
      // Largest resolution first, and within one the highest refresh rate.
      modes.sort(function(a, b) {
        if (a.w * a.h !== b.w * b.h) return b.w * b.h - a.w * a.h
        if (a.w !== b.w) return b.w - a.w
        return b.hz - a.hz
      })
      out.push({
        name: String(m.name), description: String(m.description),
        mode: m.width + "x" + m.height + "@" + Number(m.refreshRate).toFixed(2),
        x: Math.round(m.x), y: Math.round(m.y), scale: Number(m.scale),
        transform: Number(m.transform) || 0, modes: modes
      })
    }
    out.sort(function(a, b) { return a.x - b.x })
    root.monitorList = out
  }

  // A monitor's size in layout units: pixels divided by scale, swapped when it
  // is turned on its side.
  function logicalSize(mode, scale, transform) {
    var m = /^([0-9]+)x([0-9]+)/.exec(String(mode))
    var w = m ? parseInt(m[1], 10) : 1920
    var h = m ? parseInt(m[2], 10) : 1080
    if (transform % 2 === 1) { var t = w; w = h; h = t }
    return { w: Math.round(w / scale), h: Math.round(h / scale) }
  }

  // The layout a monitor has now: the saved one, else what Hyprland reports.
  function monitorNow(m) {
    var saved = Rules.monitorEntry(root.state, m.description)
    return saved ? saved : { mode: m.mode, x: m.x, y: m.y, scale: m.scale, transform: m.transform, enabled: true }
  }

  // Every connected monitor gets an entry on the first change, so the others
  // keep exactly the position they have instead of falling back to "auto".
  function seedMonitors(state) {
    var next = state
    for (var i = 0; i < root.monitorList.length; i++) {
      var m = root.monitorList[i]
      if (Rules.monitorEntry(next, m.description)) continue
      var seeded = Rules.setMonitor(next, m.description, { mode: m.mode, x: m.x, y: m.y, scale: m.scale, transform: m.transform })
      if (seeded) next = seeded
    }
    return next
  }

  // After a change the previous state is kept for `confirmLeft` seconds. A
  // layout that blanks the screen can't be confirmed, so it reverts itself.
  property var revertState: null
  property int confirmLeft: 0

  function applyMonitor(description, fields) {
    if (root.applying) return
    var base = root.seedMonitors(root.state)
    var next = Rules.setMonitor(base, description, fields)
    if (!next) {
      root.status = "That display setting isn't valid"
      root.statusError = true
      return
    }
    // Further changes while one is waiting for confirmation revert to the
    // layout from before the first of them.
    if (root.confirmLeft <= 0) root.revertState = root.state
    root.confirmLeft = 15
    confirmTimer.restart()
    root.apply(next, "", "", "Display changed")
  }

  function keepMonitors() {
    confirmTimer.stop()
    root.confirmLeft = 0
    root.revertState = null
    root.status = "Display layout kept ✓"
  }

  function revertMonitors() {
    confirmTimer.stop()
    root.confirmLeft = 0
    var back = root.revertState
    root.revertState = null
    if (!back) return
    if (root.applying) { Qt.callLater(function() { root.apply(back, "", "", "Reverted") }); return }
    root.apply(back, "", "", "Reverted")
  }

  Timer {
    id: confirmTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.confirmLeft -= 1
      if (root.confirmLeft <= 0) root.revertMonitors()
    }
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector { onStreamFinished: root.parseMonitors(text) }
  }

  readonly property var layoutBounds: {
    var minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9
    for (var i = 0; i < root.monitorList.length; i++) {
      var now = root.monitorNow(root.monitorList[i])
      var size = root.logicalSize(now.mode, now.scale, now.transform)
      minX = Math.min(minX, now.x); minY = Math.min(minY, now.y)
      maxX = Math.max(maxX, now.x + size.w); maxY = Math.max(maxY, now.y + size.h)
    }
    if (minX > maxX) return { x: 0, y: 0, w: 1, h: 1 }
    // Room around the screens, so one can be dragged beyond the others.
    var roomX = (maxX - minX) * 0.10
    var roomY = (maxY - minY) * 0.45
    return { x: minX - roomX, y: minY - roomY, w: maxX - minX + 2 * roomX, h: maxY - minY + 2 * roomY }
  }

  // Where a dragged monitor lands. Screens always touch: it is placed flush
  // against a side of another screen (the one nearest to where it was dropped),
  // sharing at least part of that edge, and along the edge it snaps to the
  // other screen's start, end or middle within `tol`. A spot on top of a third
  // screen is never offered, so `null` only when there is no room at all.
  function snapped(description, nx, ny, tol) {
    var mine = null
    var others = []
    for (var i = 0; i < root.monitorList.length; i++) {
      var m = root.monitorList[i]
      var now = root.monitorNow(m)
      var size = root.logicalSize(now.mode, now.scale, now.transform)
      var box = { x: now.x, y: now.y, w: size.w, h: size.h }
      if (m.description === description) mine = box
      else others.push(box)
    }
    if (!mine) return null
    if (others.length === 0) return { x: Math.round(nx), y: Math.round(ny) }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
    function along(v, size, start, length, tolerance) {
      // snap start-to-start, end-to-end or middle-to-middle
      var options = [start, start + length - size, start + (length - size) / 2]
      var best = v, bestD = tolerance
      for (var a = 0; a < options.length; a++) {
        var d = Math.abs(v - options[a])
        if (d < bestD) { bestD = d; best = options[a] }
      }
      return best
    }

    var candidates = []
    for (var j = 0; j < others.length; j++) {
      var o = others[j]
      var keep = Math.min(100, mine.w, mine.h, o.w, o.h)
      var yLo = o.y - mine.h + keep, yHi = o.y + o.h - keep
      var xLo = o.x - mine.w + keep, xHi = o.x + o.w - keep
      var y = along(clamp(ny, yLo, yHi), mine.h, o.y, o.h, tol)
      var x = along(clamp(nx, xLo, xHi), mine.w, o.x, o.w, tol)
      candidates.push({ x: o.x + o.w, y: y })
      candidates.push({ x: o.x - mine.w, y: y })
      candidates.push({ x: x, y: o.y + o.h })
      candidates.push({ x: x, y: o.y - mine.h })
    }

    var best = null, bestDist = 1e18
    for (var c = 0; c < candidates.length; c++) {
      var cand = candidates[c]
      var clear = true
      for (var k = 0; k < others.length; k++) {
        var q = others[k]
        if (cand.x < q.x + q.w && cand.x + mine.w > q.x && cand.y < q.y + q.h && cand.y + mine.h > q.y) { clear = false; break }
      }
      if (!clear) continue
      var dist = (cand.x - nx) * (cand.x - nx) + (cand.y - ny) * (cand.y - ny)
      if (dist < bestDist) { bestDist = dist; best = cand }
    }
    return best ? { x: Math.round(best.x), y: Math.round(best.y) } : null
  }

  // "LG", "Samsung": the make from the description, with the connector added
  // only when two screens would otherwise carry the same name.
  function shortName(m) {
    var make = String(m.description).split(" ")[0]
    var same = 0
    for (var i = 0; i < root.monitorList.length; i++)
      if (String(root.monitorList[i].description).split(" ")[0] === make) same++
    return same > 1 ? make + " (" + m.name + ")" : make
  }

  // Omarchy's own scale shortcut (Super+/) and its monitor panel write the new
  // scale into ~/.config/hypr/monitors.lua and reload. AppSpace's saved layout
  // loads after that file, so it would quietly undo the change. Instead a scale
  // written there for a screen AppSpace manages is taken over as the saved one.
  function adoptOmarchyScales(text) {
    if (root.applying || root.confirmLeft > 0 || root.monitorList.length === 0) return
    var next = root.state
    var changed = false
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var hit = /output\s*=\s*"([^"]+)".*scale\s*=\s*([0-9]+(?:\.[0-9]+)?)/.exec(lines[i])
      if (!hit || /^\s*--/.test(lines[i])) continue
      for (var j = 0; j < root.monitorList.length; j++) {
        var m = root.monitorList[j]
        var saved = Rules.monitorEntry(next, m.description)
        if (m.name !== hit[1] || !saved) continue
        var scale = parseFloat(hit[2])
        if (Math.abs(saved.scale - scale) < 0.005) continue
        var updated = Rules.setMonitor(next, m.description, { scale: scale })
        if (updated) { next = updated; changed = true }
      }
    }
    if (changed) root.apply(next, "", "", "Scale taken over from Omarchy")
  }

  // Turns the workspace strip on or off, swapping Omarchy's own workspaces widget
  // for it. This widget is never moved: where it sits in the bar is the position
  // chosen when it was installed, and the numbers appear there. Run through the
  // bar so a rebuild of this widget cannot cut the command short. Off puts
  // Omarchy's widget back after the menu.
  function setBarStrip(on) {
    var next = Rules.setWorkspaceBar(root.state, on)
    root.state = next
    rulesFile.setText(Rules.toJson(next))
    var cmd = on
      ? "omarchy plugin disable omarchy.workspaces"
      : "omarchy plugin enable omarchy.workspaces; omarchy bar move omarchy.workspaces --after omarchy.menu || omarchy bar move omarchy.workspaces --section left"
    if (root.bar) root.bar.run(cmd)
    root.status = on ? "Workspaces now shown by AppSpace" : "Omarchy's workspaces widget is back"
    root.statusError = false
  }

  function setBarNumber(on) {
    var next = Rules.setWorkspaceNumber(root.state, on)
    root.state = next
    rulesFile.setText(Rules.toJson(next))
  }

  function placement(description, spec) {
    // spec is "right:<description>", "left:…", "above:…" or "below:…"
    var cut = spec.indexOf(":")
    var side = spec.substring(0, cut)
    var otherDesc = spec.substring(cut + 1)
    var me = null, other = null
    for (var i = 0; i < root.monitorList.length; i++) {
      if (root.monitorList[i].description === description) me = root.monitorList[i]
      if (root.monitorList[i].description === otherDesc) other = root.monitorList[i]
    }
    if (!me || !other) return null
    var a = root.monitorNow(me), b = root.monitorNow(other)
    var sa = root.logicalSize(a.mode, a.scale, a.transform)
    var sb = root.logicalSize(b.mode, b.scale, b.transform)
    if (side === "right") return { x: b.x + sb.w, y: b.y }
    if (side === "left") return { x: b.x - sa.w, y: b.y }
    if (side === "above") return { x: b.x, y: b.y - sa.h }
    if (side === "below") return { x: b.x, y: b.y + sb.h }
    return null
  }

  // ------------------------------------------------------------- settings

  // The six sections Omarchy offers when a bar widget is installed.
  readonly property var barSections: [
    { value: "left", label: "Left" },
    { value: "centerBegin", label: "Center, start" },
    { value: "center", label: "Center" },
    { value: "centerEnd", label: "Center, end" },
    { value: "tray", label: "Tray" },
    { value: "right", label: "Right" }
  ]
  property string barSection: ""

  function readBarSection(text) {
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { return }
    var layout = parsed && parsed.bar && parsed.bar.layout ? parsed.bar.layout : null
    if (!layout) return
    for (var section in layout) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === "dominikzajac.appspace") { root.barSection = section; return }
    }
    root.barSection = ""
  }

  // Moving rebuilds this widget, so the command goes through the bar.
  function moveToSection(section) {
    var known = root.barSections.some(function(o) { return o.value === section })
    if (!known || !root.bar) return
    root.bar.run("omarchy bar move dominikzajac.appspace --section " + section)
  }

  // With no icon and no shortcut the panel could not be opened from the bar, so
  // the icon is only hidden while a shortcut is set (and the shortcut only
  // cleared while the icon is shown).
  function setShowIcon(on) {
    root.status = ""
    root.statusError = false
    if (!on && Rules.shortcutOf(root.state).length === 0) {
      root.status = "Set a shortcut first, or there would be no way to open this"
      root.statusError = true
      return
    }
    var next = Rules.setShowIcon(root.state, on)
    root.state = next
    rulesFile.setText(Rules.toJson(next))
  }

  property string pendingShortcut: ""

  function applyShortcut(text) {
    root.status = ""
    root.statusError = false
    var typed = String(text || "").trim()
    var clean = typed.length === 0 ? "" : Rules.cleanShortcut(typed)
    if (typed.length > 0 && !clean) {
      root.status = "Use modifiers and a key, like SUPER + ALT + A"
      root.statusError = true
      return
    }
    if (clean.length === 0 && !Rules.showIconEnabled(root.state)) {
      root.status = "Show the icon first, or there would be no way to open this"
      root.statusError = true
      return
    }
    if (clean === Rules.shortcutOf(root.state)) return
    root.pendingShortcut = clean
    if (clean.length === 0) root.commitShortcut()
    else if (!bindsProc.running) bindsProc.running = true
  }

  function commitShortcut() {
    var next = Rules.setShortcut(root.state, root.pendingShortcut)
    if (!next) return
    root.apply(next, "", "", root.pendingShortcut.length > 0 ? "Shortcut saved" : "Shortcut removed")
  }

  // A shortcut another bind already uses is refused, not silently doubled.
  function checkShortcutConflict(text) {
    var parts = Rules.shortcutParts(root.pendingShortcut)
    var list = []
    try { list = JSON.parse(text) } catch (e) { list = [] }
    if (parts && Array.isArray(list)) {
      for (var i = 0; i < list.length; i++) {
        var b = list[i]
        if (!b || b.description === "Open AppSpace") continue
        if (Number(b.modmask) === parts.mask && String(b.key).toLowerCase() === parts.key.toLowerCase()) {
          root.status = "Already used by: " + (b.description || "another shortcut")
          root.statusError = true
          return
        }
      }
    }
    root.commitShortcut()
  }

  Process {
    id: bindsProc
    command: ["hyprctl", "-j", "binds"]
    stdout: StdioCollector { onStreamFinished: root.checkShortcutConflict(text) }
  }

  FileView {
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBarSection(text())
  }

  // Omarchy 4.5 numbers every monitor's workspaces in a block of ten, and keeps
  // which monitor owns which block in this file (block, connector, identity).
  // A tool that plans workspaces globally (hyprmoncfg) switches that off, in which
  // case a slot is just the workspace number, as before.
  property var monitorBlocks: ({})
  property bool globalPlan: false

  readonly property bool perMonitor: Object.keys(root.monitorBlocks).length > 0 && !root.globalPlan

  function readBlocks(text) {
    var next = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f.length >= 3) next[f[2].replace(/ #[0-9]+$/, "")] = parseInt(f[0], 10)
    }
    root.monitorBlocks = next
  }

  // The real workspace id of a slot on the monitor that owns it.
  function resolvedId(slot, monitor) {
    var id = parseInt(slot, 10)
    var key = String(monitor || "").replace(/^desc:/, "")
    if (root.perMonitor && key.length > 0 && root.monitorBlocks[key] !== undefined)
      return root.monitorBlocks[key] * 10 + id
    return id
  }

  function monitorHeading(value) {
    var opts = root.monitorOptions
    for (var i = 0; i < opts.length; i++)
      if (opts[i].value === value && value.length > 0) return opts[i].label
    return "Not assigned to a monitor"
  }

  // Rows of the workspaces view. With per-monitor workspaces they are grouped
  // under the monitor that owns the slot, so each monitor lists only its own.
  readonly property var workspaceRows: {
    var ids = root.barWorkspaces
    if (!root.perMonitor) return ids.map(function(id) { return { id: id, heading: "" } })

    var order = root.monitorOptions.map(function(o) { return o.value })
    var groups = ({})
    ids.forEach(function(id) {
      var owner = Rules.workspaceMonitor(root.state, String(id))
      if (order.indexOf(owner) === -1) owner = ""
      if (!groups[owner]) groups[owner] = []
      groups[owner].push(id)
    })

    var out = []
    var keys = order.filter(function(v) { return v.length > 0 }).concat([""])
    keys.forEach(function(k) {
      var list = groups[k] || []
      list.forEach(function(id, i) {
        out.push({ id: id, heading: i === 0 ? root.monitorHeading(k) : "" })
      })
    })
    return out
  }

  readonly property int nextFreeWorkspace: {
    var taken = root.barWorkspaces
    for (var i = 1; i <= 10; i++)
      if (taken.indexOf(i) === -1) return i
    return 0
  }

  function workspaceOccupied(id) {
    var live = []
    try { live = Hyprland.workspaces.values || [] } catch (e) { live = [] }
    for (var i = 0; i < live.length; i++) {
      if (!live[i] || live[i].id !== id) continue
      try { return (live[i].toplevels.values || []).length > 0 } catch (e) { return false }
    }
    return false
  }

  // ------------------------------------------------------------- model

  function loadState() {
    var parsed = null
    try { parsed = JSON.parse(rulesFile.text() || "{}") } catch (e) { parsed = null }
    root.state = Rules.normalize(parsed)
    root.rebuild()
  }

  function iconSource(name) {
    var value = String(name || "")
    if (value.length === 0) return ""
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    return themed && themed.length > 0 ? themed : ""
  }

  // Live windows are the authoritative source for window classes. Desktop
  // entries fill in everything that is installed but not running; their class
  // is only trustworthy when the entry declares StartupWMClass, which most
  // do not, so those rows are flagged as guesses.
  function rebuild() {
    var byClass = ({})
    var order = []
    var learned = []
    var confirm = []
    var respell = []

    // Keyed case-insensitively. A .desktop file can declare a different case
    // than the window actually uses (brave-browser vs Brave-browser); keying
    // on the exact string would split one program into two rows and let the
    // user create a rule that never matches. Live windows are processed first,
    // so their spelling — the one Hyprland will compare against — wins.
    function put(row) {
      var key = row.cls.toLowerCase()
      var existing = byClass[key]
      if (!existing) {
        byClass[key] = row
        order.push(key)
        return byClass[key]
      }
      return existing
    }

    var tops = []
    try { tops = Hyprland.toplevels.values || [] } catch (e) { tops = [] }
    for (var i = 0; i < tops.length; i++) {
      var top = tops[i]
      if (!top) continue
      var ipc = top.lastIpcObject || ({})
      var cls = String(ipc["class"] || "")
      if (cls.length === 0) continue
      var wsName = ""
      try { wsName = top.workspace ? String(top.workspace.name) : "" } catch (e) { wsName = "" }

      // A live window is proof: remember the class so the rule stays confirmed
      // after the app closes. If the rule was written from a desktop entry
      // with different casing, the stored spelling has to follow the window.
      var matched = Rules.findCI(root.state.rules, cls)
      if (matched && matched["class"] !== cls) respell.push(cls)
      else if (matched && !Rules.isVerified(root.state, cls)) confirm.push(cls)

      var appId = root.steamPids[String(ipc["pid"] || "")]
      if (appId) learned.push({ from: "steam_app_" + appId, to: cls })

      put({
        cls: cls,
        name: cls,
        icon: "",
        running: true,
        verified: true,
        command: "",
        address: String(top.address || ""),
        ws: wsName
      })
    }

    var entries = []
    try { entries = DesktopEntries.applications.values || [] } catch (e) { entries = [] }
    for (var j = 0; j < entries.length; j++) {
      var entry = entries[j]
      if (!entry || entry.noDisplay === true) continue
      if (root.hiddenEntries[Rules.classFromDesktopId(entry.id)] === true) continue
      var derived = Rules.classFromEntry(entry.startupClass, entry.execString, entry.id,
                                         root.browserPrefix)
      // A TUI that opens inside the default terminal gets the terminal's class,
      // which this plugin cannot know, unless the launcher sets an app id.
      if (entry.runInTerminal === true && Rules.terminalAppId(entry.execString).length === 0) continue
      // A learned alias replaces the guess outright, which is what collapses a
      // Steam game's launcher entry and its real window into one row.
      var guessed = Rules.resolveAlias(root.state, derived)
      if (guessed.length === 0) continue

      var own = Rules.ownAutostartFor(root.autostartEntries, entry.id, entry.execString)
      var guards = own.length > 0 ? Rules.guardBinaries(root.autostartEntries, own, entry.execString) : []
      var row = put({
        cls: guessed,
        name: String(entry.name || guessed),
        icon: root.iconSource(entry.icon),
        ownAutostart: own,
        guards: guards,
        running: false,
        // Only a live window proves a class. A declared StartupWMClass is a
        // guess like any other: Obsidian declares md.Obsidian and opens as
        // md.obsidian.Obsidian, Pinta declares Pinta and opens as
        // com.github.PintaProject.Pinta.
        verified: guessed !== derived,
        command: Rules.launchTarget(entry.id, entry.command),
        address: "",
        ws: ""
      })
      // A running window already owns this class: keep its live data but take
      // the nicer display name and icon from the desktop entry.
      if (row.running) {
        row.name = String(entry.name || row.name)
        if (!row.icon) row.icon = root.iconSource(entry.icon)
        if (!row.ownAutostart) { row.ownAutostart = own; row.guards = guards }
        // A running window has no command of its own; the desktop entry is the
        // only place a launch line can come from.
        if (!row.command) row.command = Rules.launchTarget(entry.id, entry.command)
      }
    }

    // Rules whose class matches neither a window nor an installed app.
    for (var k = 0; k < root.state.rules.length; k++) {
      var rule = root.state.rules[k]
      put({
        cls: rule["class"],
        name: rule["label"],
        icon: "",
        running: false,
        verified: rule["verified"] === true,
        command: String(rule["command"] || ""),
        // Nothing on this system uses this class: no window, no desktop entry.
        // The rule can never fire, so the detail pane says so out loud instead
        // of leaving it to look like every other unlaunched app.
        orphan: rule["verified"] !== true,
        address: "",
        ws: ""
      })
    }

    var apps = []
    for (var n = 0; n < order.length; n++) {
      var item = byClass[order[n]]
      item.rule = Rules.findCI(root.state.rules, item.cls)
      // A row built from a desktop entry carries the entry's guess of the
      // class. Once a rule exists its spelling is the one to keep, or editing
      // the rule of an app that is not running would rewrite it to the guess.
      if (item.rule && !item.running) item.cls = item.rule["class"]
      if (item.rule && item.rule["verified"] === true) item.verified = true
      if (!item.command && item.rule) item.command = String(item.rule["command"] || "")
      apps.push(item)
    }

    // Running first, then anything with a rule, then the rest — alphabetical
    // inside each group so the list does not reshuffle while typing.
    apps.sort(function(a, b) {
      var ga = a.running ? 0 : (a.rule ? 1 : 2)
      var gb = b.running ? 0 : (b.rule ? 1 : 2)
      if (ga !== gb) return ga - gb
      var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
      return na < nb ? -1 : (na > nb ? 1 : 0)
    })

    // The list is split into RUNNING, PINNED (a rule, not open) and INSTALLED
    // by header rows, the way the Bluetooth panel splits CONNECTED from
    // AVAILABLE. Headers carry the same fields as app rows so delegate
    // bindings never dereference a missing property.
    var groups = [
      { label: "RUNNING", keep: function(a) { return a.running } },
      { label: "PINNED", keep: function(a) { return !a.running && !!a.rule } },
      { label: "INSTALLED", keep: function(a) { return !a.running && !a.rule } }
    ]
    var out = []
    for (var g = 0; g < groups.length; g++) {
      var members = []
      for (var p = 0; p < apps.length; p++)
        if (groups[g].keep(apps[p]) && Rules.matches(root.filterText, apps[p])) members.push(apps[p])
      if (members.length === 0) continue
      out.push({ kind: "header", label: groups[g].label, count: members.length,
                 cls: "", name: "", icon: "", running: false, rule: null, command: "" })
      for (var q = 0; q < members.length; q++) out.push(members[q])
    }

    root.allApps = apps
    root.rows = out
    if (!root.rowForKey(root.selectedKey)) root.selectKey(root.firstAppKey())

    root.rememberFindings(learned, confirm, respell)
  }

  // Aliases and confirmations are bookkeeping: they change nothing Hyprland
  // reads, so they go straight to rules.json with no reload and no rollback
  // dance. Writing only when something actually changed keeps the FileView
  // watch from bouncing. A respelled class is the exception: the Lua has to
  // be regenerated for the rule to start matching, so that goes through the
  // full write pipeline.
  function rememberFindings(learned, confirm, respell) {
    if (root.applying) return
    var next = root.state
    var changed = false
    var corrected = ""

    for (var i = 0; i < learned.length; i++) {
      var aliased = Rules.putAlias(next, learned[i].from, learned[i].to)
      if (aliased) { next = aliased; changed = true }
      var moved = Rules.migrateRule(next, learned[i].from, learned[i].to)
      if (moved) { next = moved; changed = true; corrected = learned[i].to }
    }
    for (var j = 0; j < confirm.length; j++) {
      var marked = Rules.markVerified(next, confirm[j])
      if (marked) { next = marked; changed = true }
    }
    for (var k = 0; k < (respell || []).length; k++) {
      var spelled = Rules.respell(next, respell[k])
      if (spelled) { next = spelled; changed = true; corrected = respell[k] }
    }

    if (!changed) return
    if (corrected.length > 0) {
      root.apply(next, "", "", "Class corrected to " + corrected)
      return
    }
    root.state = next
    rulesFile.setText(Rules.toJson(next))
  }

  function isHeader(row) {
    return !!row && row.kind === "header"
  }

  function rowForKey(key) {
    if (String(key || "").length === 0) return null
    for (var i = 0; i < root.rows.length; i++)
      if (!root.isHeader(root.rows[i]) && root.rows[i].cls === key) return root.rows[i]
    return null
  }

  function firstAppKey() {
    for (var i = 0; i < root.rows.length; i++)
      if (!root.isHeader(root.rows[i])) return root.rows[i].cls
    return ""
  }

  readonly property var selectedRow: root.rowForKey(root.selectedKey)

  function selectKey(key) {
    root.selectedKey = String(key)
  }

  // Walks app rows only; header rows are skipped over in either direction.
  function moveSelection(delta) {
    if (root.rows.length === 0) return
    var index = -1
    for (var i = 0; i < root.rows.length; i++)
      if (!root.isHeader(root.rows[i]) && root.rows[i].cls === root.selectedKey) { index = i; break }
    var step = delta < 0 ? -1 : 1
    var next = index
    for (var n = 0; n < Math.abs(delta); n++) {
      var probe = next + step
      while (probe >= 0 && probe < root.rows.length && root.isHeader(root.rows[probe])) probe += step
      if (probe < 0 || probe >= root.rows.length) break
      next = probe
    }
    if (next < 0) return
    root.selectKey(root.rows[next].cls)
    resultList.positionViewAtIndex(next, ListView.Contain)
  }

  function setFilter(value) {
    root.filterText = String(value || "")
    root.rebuild()
    // Typing means the user is hunting for one app, so land on the first
    // result instead of leaving the cursor on whatever was selected before.
    if (root.filterText.length > 0) root.selectKey(root.firstAppKey())
  }

  // ------------------------------------------------------------- actions

  // An empty workspace is "Any": the app is not placed.
  function assignWorkspace(workspace) {
    var row = root.selectedRow
    if (!row) return
    var ws = String(workspace)
    if (ws.length === 0 && !row.rule) return
    var next = Rules.upsert(root.state, row.cls, ws,
                            row.rule ? row.rule["silent"] === true : false, row.name,
                            row.verified === true, row.command)
    root.apply(next, row.running && ws.length > 0 ? row.address : "", ws,
               row.cls + (ws.length > 0 ? " → workspace " + ws : " → any workspace"))
  }

  function toggleSilent() {
    var row = root.selectedRow
    if (!row) return
    var quiet = !(row.rule && row.rule["silent"] === true)
    var next = Rules.upsert(root.state, row.cls, row.rule ? row.rule["workspace"] : "", quiet, row.name,
                            row.verified === true, row.command)
    root.apply(next, "", "", row.cls + (quiet ? " → silent" : " → follow focus"))
  }

  function toggleStartupOnly() {
    var row = root.selectedRow
    if (!row || !row.rule || String(row.rule["workspace"]).length === 0) return
    var on = row.rule["startupOnly"] !== true
    root.apply(Rules.setStartupOnly(root.state, row.cls, on), "", "",
               row.cls + (on ? " → placed only at startup" : " → placed every time"))
  }

  function setStartupSeconds(seconds) {
    var row = root.selectedRow
    if (!row || !row.rule) return
    root.apply(Rules.setStartupOnly(root.state, row.cls, row.rule["startupOnly"] === true, seconds),
               "", "", row.cls + " → startup placement lasts " + seconds + " s")
  }

  // Works for an app with no rule yet: it launches at login without being
  // placed, and gets a rule only to remember that.
  function toggleAutostart() {
    var row = root.selectedRow
    if (!row) return
    // The row knows the desktop entry's command even when the rule predates
    // command storage, so pass it along instead of refusing the toggle.
    var command = String(row.command || "")
    if (command.length === 0) return
    var on = !Rules.isAutostart(root.state, row.cls)
    root.apply(Rules.setAutostart(root.state, row.cls, on, command, row.name), "", "",
               row.cls + (on ? " → launches at startup" : " → no longer launches at startup"))
  }

  function removeRule() {
    var row = root.selectedRow
    if (!row || !row.rule) return
    root.apply(Rules.remove(root.state, row.cls), "", "", "Removed rule for " + row.cls)
  }

  function assignMonitor(workspace, monitor) {
    var next = Rules.setWorkspaceMonitor(root.state, workspace, monitor)
    root.apply(next, "", "", String(monitor || "").length === 0
      ? "Workspace " + workspace + " → auto"
      : "Workspace " + workspace + " → pinned")
  }

  // Persistent workspaces exist even while empty, which is also what puts
  // them on Omarchy's bar — so this is both "always there" and "show it".
  function toggleWorkspacePersistent(workspace) {
    var now = Rules.workspacePersistent(root.state, workspace)
    root.apply(Rules.setWorkspacePersistent(root.state, workspace, !now), "", "",
               "Workspace " + workspace + (now ? " → on demand" : " → always present"))
  }

  // Removing a workspace takes its pinned apps' rules with it, so that is
  // confirmed first when there is anything to lose. Open windows are left
  // where they are: Hyprland keeps a workspace alive while it has windows.
  property string removeTarget: ""
  readonly property bool removeConfirmOpen: root.removeTarget.length > 0

  function removeWorkspace(workspace) {
    var ws = String(workspace)
    var pinned = Rules.rulesForWorkspace(root.state, ws).length
    if (pinned === 0 && Rules.workspaceMonitor(root.state, ws).length === 0) {
      root.apply(Rules.removeWorkspace(root.state, ws), "", "", "Workspace " + ws + " removed")
      return
    }
    root.removeTarget = ws
    content.forceActiveFocus()
  }

  readonly property string removeMessage: {
    if (root.removeTarget.length === 0) return ""
    var pinned = Rules.rulesForWorkspace(root.state, root.removeTarget).length
    var bits = []
    if (pinned > 0) bits.push(pinned === 1 ? "the app pinned to it loses its rule" : pinned + " pinned apps lose their rules")
    if (Rules.workspaceMonitor(root.state, root.removeTarget).length > 0) bits.push("its monitor pin is dropped")
    if (Rules.workspacePersistent(root.state, root.removeTarget)) bits.push("it is no longer always present")
    return "Remove workspace " + root.removeTarget + "? " + bits.join(", ").replace(/^./, function(c) { return c.toUpperCase() }) + "."
  }

  function confirmRemove() {
    var ws = root.removeTarget
    root.removeTarget = ""
    viewTabs.forceActiveFocus()
    if (ws.length > 0) root.apply(Rules.removeWorkspace(root.state, ws), "", "", "Workspace " + ws + " removed")
  }

  function cancelRemove() {
    root.removeTarget = ""
    viewTabs.forceActiveFocus()
  }

  function addWorkspace() {
    var next = root.nextFreeWorkspace
    if (next < 1) {
      root.status = "No free workspace below 10"
      root.statusError = true
      return
    }
    root.apply(Rules.setWorkspacePersistent(root.state, String(next), true), "", "",
               "Workspace " + next + " added")
  }

  // ------------------------------------------------------------- write

  // One direction only: error baseline -> JSON -> Lua -> reload -> re-check.
  //
  // The baseline matters: `hyprctl configerrors` reports errors from the WHOLE
  // config. Without comparing against the moment before the write, a single
  // unrelated error in another file would roll back every valid change.
  function apply(next, moveAddress, moveWorkspace, message) {
    if (root.applying) {
      root.status = "Busy — previous write still running"
      root.statusError = true
      return
    }
    root.rollbackLua = luaFile.text() || ""
    // Roll back BOTH files. Reverting only the Lua would leave rules.json
    // claiming a rule Hyprland has never seen.
    root.rollbackJson = rulesFile.text() || ""
    root.rollingBack = false
    root.applying = true
    root.stagedState = next
    root.pendingMoveAddress = String(moveAddress || "")
    root.pendingMoveWorkspace = String(moveWorkspace || "")
    root.status = message ? (message + " …") : "Saving …"
    root.statusError = false

    if (!baselineProc.running) baselineProc.running = true
  }

  // Class -> process names to wait for, for apps that start themselves.
  function guardMap() {
    var out = ({})
    for (var i = 0; i < root.allApps.length; i++) {
      var app = root.allApps[i]
      if (app.guards && app.guards.length > 0) out[app.cls] = app.guards
    }
    return out
  }

  function onBaselineChecked(errText) {
    root.errorBaseline = String(errText || "").trim()
    var next = root.stagedState || Rules.emptyState()
    root.stagedState = null

    root.state = next
    rulesFile.setText(Rules.toJson(next))
    luaFile.setText(Rules.toLua(next, root.guardMap()))
    root.rebuild()

    if (!reloadProc.running) reloadProc.running = true
  }

  // hyprctl returns before Hyprland finishes recomputing the config, so the
  // verification runs on a short delay or it reads the pre-reload state.
  function onReloadFinished() {
    verifyTimer.restart()
  }

  function onConfigChecked(errText) {
    var text = String(errText || "").trim()
    var regressed = text.length > 0 && text !== root.errorBaseline

    if (regressed && !root.rollingBack) {
      root.rollingBack = true
      root.status = "Config error — reverting: " + text.split("\n")[0]
      root.statusError = true
      luaFile.setText(root.rollbackLua)
      if (root.rollbackJson.length > 0) rulesFile.setText(root.rollbackJson)
      if (!reloadProc.running) reloadProc.running = true
      return
    }

    root.applying = false

    if (root.rollingBack) {
      root.rollingBack = false
      root.loadState()
      return
    }

    root.status = root.status.replace(" …", " ✓")
    root.statusError = false
    root.readMonitors()

    // The rule takes effect the next time the window opens; if it is already
    // open, move it now so the result is visible immediately.
    if (root.pendingMoveAddress.length > 0 && root.pendingMoveWorkspace.length > 0) {
      evalProc.command = ["hyprctl", "eval",
        Rules.moveWindowLua(root.pendingMoveAddress, root.pendingMoveWorkspace,
          Rules.workspaceMonitor(root.state, root.pendingMoveWorkspace))]
      root.pendingMoveAddress = ""
      root.pendingMoveWorkspace = ""
      if (!evalProc.running) evalProc.running = true
    }

    Qt.callLater(function() { root.refresh() })
  }

  function refresh() {
    try { Hyprland.refreshToplevels() } catch (e) {}
    if (!steamProbe.running) steamProbe.running = true
    if (!autostartProbe.running) autostartProbe.running = true
    if (!hiddenProbe.running) hiddenProbe.running = true
    root.rebuild()
  }

  // ------------------------------------------------------------- IO

  FileView {
    id: rulesFile
    path: root.rulesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadState()
    onFileChanged: reload()
    onLoadFailed: root.loadState()
  }

  FileView {
    path: root.stateHome + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  FileView {
    path: root.home + "/.config/hypr/hyprmoncfg-monitors.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.globalPlan = text().indexOf("o.workspaces.enabled = false") !== -1
    onLoadFailed: root.globalPlan = false
  }

  FileView {
    path: root.home + "/.config/hypr/monitors.lua"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.adoptOmarchyScales(text())
  }

  FileView {
    id: luaFile
    path: root.luaPath
    watchChanges: false
    printErrors: false
  }

  Process {
    id: baselineProc
    command: ["hyprctl", "configerrors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onBaselineChecked(text)
    }
  }

  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
    onExited: root.onReloadFinished()
  }

  Process {
    id: errorsProc
    command: ["hyprctl", "configerrors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onConfigChecked(text)
    }
  }

  Process {
    id: evalProc
    command: ["hyprctl", "eval", ""]
  }

  // Read once: the default browser decides the product prefix of every web
  // app's class, and changing it is rare enough that a shell restart may
  // pick it up.
  Process {
    id: browserProbe
    command: ["xdg-settings", "get", "default-web-browser"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.browserPrefix = Rules.browserPrefix(String(text || "").trim())
        root.rebuild()
      }
    }
  }

  Process {
    id: autostartProbe
    command: ["sh", "-c",
      "for d in /etc/xdg/autostart \"${XDG_CONFIG_HOME:-$HOME/.config}/autostart\"; do "
      + "for f in \"$d\"/*.desktop; do [ -e \"$f\" ] || continue; "
      + "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$(basename \"$f\")\" "
      + "\"$(sed -n 's/^Hidden=//p' \"$f\" | head -1)\" "
      + "\"$(sed -n 's/^OnlyShowIn=//p' \"$f\" | head -1)\" "
      + "\"$(sed -n 's/^NotShowIn=//p' \"$f\" | head -1)\" "
      + "\"$(sed -n 's/^Exec=//p' \"$f\" | head -1)\"; done; done"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.autostartEntries = Rules.parseAutostart(text, Quickshell.env("XDG_CURRENT_DESKTOP") || "Hyprland")
        root.rebuild()
      }
    }
  }

  Process {
    id: hiddenProbe
    command: ["sh", "-c",
      "for f in \"${XDG_DATA_HOME:-$HOME/.local/share}\"/applications/*.desktop; do "
      + "[ -e \"$f\" ] || continue; grep -qi '^Hidden=true' \"$f\" && basename \"$f\"; done; true"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.hiddenEntries = Rules.parseHiddenEntries(text)
        root.rebuild()
      }
    }
  }

  Process {
    id: steamProbe
    command: ["sh", "-c",
      "for p in /proc/[0-9]*; do " +
      "id=$(tr '\\0' '\\n' < \"$p/environ\" 2>/dev/null | sed -n 's/^SteamAppId=//p' | head -1); " +
      "[ -n \"$id\" ] && echo \"${p#/proc/} $id\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].trim().split(" ")
          if (parts.length === 2 && parts[0].length > 0 && parts[1].length > 0) map[parts[0]] = parts[1]
        }
        root.steamPids = map
        root.rebuild()
      }
    }
  }

  Timer {
    id: verifyTimer
    interval: 200
    repeat: false
    onTriggered: { if (!errorsProc.running) errorsProc.running = true }
  }

  Process {
    id: updateProbe
    command: ["sh", root.updateScript, "check", root.pluginDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.updateState = Rules.parseUpdateProbe(text)
        root.updateCheckedAt = Date.now()
        root.nowMs = root.updateCheckedAt
      }
    }
  }

  // Twenty seconds after the shell starts, then once a day. Not at the very
  // start: the shell is busy with login, and nothing is lost by waiting.
  Timer {
    interval: 20000
    running: true
    repeat: false
    onTriggered: if (Rules.updateCheckEnabled(root.state)) root.checkForUpdates()
  }

  Timer {
    interval: 86400000
    running: true
    repeat: true
    onTriggered: if (Rules.updateCheckEnabled(root.state)) root.checkForUpdates()
  }

  // Keeps "checked 23 minutes ago" honest while the panel stays open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // FileView does not create directories, and on a fresh install neither
  // ~/.local/state/omarchy/appspace/ nor the toggles directory may exist yet.
  // The Lua module is seeded with the same output an empty rule set
  // generates. A rules file left behind by the plugin's old name, appws, is
  // adopted so a rename does not lose anyone's rules.
  Process {
    id: bootstrapProc
    command: ["sh", "-c",
      "mkdir -p \"$1\" \"$(dirname \"$2\")\"; "
        + "[ -e \"$1/rules.json\" ] || { [ -e \"$4\" ] && mv \"$4\" \"$1/rules.json\"; }; "
        + "[ -e \"$2\" ] || printf '%s' \"$3\" > \"$2\"",
      "sh", root.stateHome + "/omarchy/appspace", root.luaPath,
      Rules.toLua(Rules.emptyState()), root.stateHome + "/omarchy/appws/rules.json"]
    running: true
  }

  IpcHandler {
    target: "dominikzajac.appspace"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function autostart(cls: string, state: string): string {
      var name = String(cls || "")
      if (!name.length) return "usage: autostart <class> <on|off>"
      if (root.applying) return "busy"
      var rule = Rules.findCI(root.state.rules, name)
      var row = root.rowForKey(rule ? rule["class"] : name)
      if (!rule && !row) return "no app or rule for " + name
      var target = rule ? rule["class"] : row.cls
      var on = String(state || "").toLowerCase() === "on"
      var command = row ? String(row.command || "") : (rule ? String(rule["command"] || "") : "")
      if (on && command.length === 0 && !Rules.canAutostart(root.state, target))
        return "no launch command known for " + name
      root.apply(Rules.setAutostart(root.state, target, on, command, row ? row.name : target), "", "",
                 target + (on ? " → launches at startup" : " → no longer launches at startup"))
      return "ok"
    }

    // startup <class> <on|off> <seconds>: place the app on its workspace only
    // for windows it opens within that many seconds of login. "-" keeps the
    // current number.
    function startup(cls: string, state: string, seconds: string): string {
      var name = String(cls || "")
      if (!name.length) return "usage: startup <class> <on|off> <seconds|->"
      if (root.applying) return "busy"
      var rule = Rules.findCI(root.state.rules, name)
      if (!rule) return "no rule for " + name
      if (String(rule["workspace"]).length === 0) return name + " has no workspace to apply at startup"
      var on = String(state || "").toLowerCase() === "on"
      var secs = parseInt(seconds, 10)
      root.apply(Rules.setStartupOnly(root.state, rule["class"], on, isNaN(secs) ? undefined : secs),
                 "", "", rule["class"] + (on ? " → placed only at startup" : " → placed every time"))
      return "ok"
    }

    function persist(workspace: string, state: string): string {
      var ws = String(workspace || "")
      if (!ws.length) return "usage: persist <workspace> <on|off>"
      if (root.applying) return "busy"
      var on = String(state || "").toLowerCase() === "on"
      root.apply(Rules.setWorkspacePersistent(root.state, ws, on), "", "",
                 "Workspace " + ws + (on ? " → always present" : " → on demand"))
      return "ok"
    }

    // Drops the workspace and the rules pinned to it, no questions asked:
    // a command line cannot answer the panel's confirmation.
    function forget(workspace: string): string {
      var ws = String(workspace || "")
      if (!ws.length) return "usage: forget <workspace>"
      if (root.applying) return "busy"
      if (!(ws in root.state.workspaces) && Rules.rulesForWorkspace(root.state, ws).length === 0)
        return "nothing to forget for workspace " + ws
      root.apply(Rules.removeWorkspace(root.state, ws), "", "", "Workspace " + ws + " removed")
      return "ok"
    }

    // Same as clicking the workspace's remove button: asks in the panel
    // when there is something to lose.
    function remove(workspace: string): string {
      var ws = String(workspace || "")
      if (!ws.length) return "usage: remove <workspace>"
      if (root.applying) return "busy"
      root.removeWorkspace(ws)
      return "ok"
    }

    // updates <on|off|check|update>: on and off turn the daily check on and
    // off (a manual check still works), check asks now, update opens
    // Omarchy's updater in a terminal.
    function updates(action: string): string {
      var what = String(action || "").toLowerCase()
      if (what === "check") { root.checkForUpdates(); return "ok" }
      if (what === "update") { root.runUpdate(); return "ok" }
      if (what !== "on" && what !== "off") return "usage: updates <on|off|check|update>"
      // A setting, not a Hyprland rule: written straight to rules.json with no
      // reload and no rollback dance, like the other bookkeeping.
      var next = Rules.setUpdateCheck(root.state, what === "on")
      root.state = next
      rulesFile.setText(Rules.toJson(next))
      return "ok"
    }

    // The workspace strip in the bar: this monitor's own workspaces, in place of
    // Omarchy's workspaces widget (turn that one off in the bar settings).
    function strip(state: string): string {
      var what = String(state || "").toLowerCase()
      if (what !== "on" && what !== "off") return "usage: strip <on|off>"
      root.setBarStrip(what === "on")
      return "ok"
    }

    function monitors(): string {
      var lines = []
      for (var i = 0; i < root.monitorList.length; i++) {
        var m = root.monitorNow(root.monitorList[i])
        lines.push(root.monitorList[i].name + " " + root.monitorList[i].description + " -> " + m.mode
          + " at " + m.x + "x" + m.y + " scale " + m.scale + " transform " + m.transform)
      }
      return lines.join("\n")
    }

    // monitor <description> <mode> <x> <y> <scale> [transform]
    function monitor(description: string, mode: string, x: string, y: string, scale: string, transform: string): string {
      if (root.applying) return "busy"
      root.applyMonitor(String(description), { mode: mode, x: x, y: y, scale: scale, transform: transform === "" ? 0 : transform })
      return "ok — keep or revert within 15 seconds"
    }

    function keep(): string { root.keepMonitors(); return "ok" }
    function revert(): string { root.revertMonitors(); return "ok" }

    function stripnumber(state: string): string {
      var what = String(state || "").toLowerCase()
      if (what !== "on" && what !== "off") return "usage: stripnumber <on|off>"
      root.setBarNumber(what === "on")
      return "ok"
    }

    function icon(state: string): string {
      var what = String(state || "").toLowerCase()
      if (what !== "on" && what !== "off") return "usage: icon <on|off>"
      root.setShowIcon(what === "on")
      return root.statusError ? root.status : "ok"
    }

    function shortcut(keys: string): string {
      root.applyShortcut(keys)
      return root.statusError ? root.status : "ok"
    }

    function advanced(state: string): string {
      root.advancedOpen = String(state || "").toLowerCase() === "on"
      return "ok"
    }

    function view(name: string): string {
      var value = String(name || "").toLowerCase()
      if (value !== "apps" && value !== "workspaces" && value !== "monitors" && value !== "settings") return "usage: view <apps|workspaces|monitors|settings>"
      root.view = value
      return "ok"
    }

    function select(cls: string): string {
      var name = String(cls || "")
      if (!name.length) return "usage: select <class>"
      if (!root.rowForKey(name)) return "no row for " + name
      root.selectKey(name)
      return "ok"
    }

    function list(): string {
      var out = []
      for (var i = 0; i < root.state.rules.length; i++) {
        var r = root.state.rules[i]
        var ws = String(r["workspace"])
        var bits = []
        if (r["silent"]) bits.push("silent")
        if (ws.length > 0 && r["startupOnly"]) bits.push("only at startup: first " + r["startupWindow"] + " s")
        if (r["autostart"]) bits.push("launches at login")
        out.push(r["class"] + " -> " + (ws.length > 0 ? ws : "any") + (bits.length ? " (" + bits.join(", ") + ")" : ""))
      }
      var names = Rules.sortedWorkspaceNames(root.state)
      for (var j = 0; j < names.length; j++) {
        var entry = root.state.workspaces[names[j]]
        var parts = []
        if (entry["monitor"].length > 0) parts.push(entry["monitor"])
        if (entry["persistent"]) parts.push("always present")
        out.push("workspace " + names[j] + " -> " + parts.join(", "))
      }
      return out.length ? out.join("\n") : "(no rules)"
    }

    // workspace "any" (or "none") means not placed.
    function set(cls: string, workspace: string, silent: string): string {
      var name = String(cls || "")
      var ws = String(workspace || "")
      if (!name.length || !ws.length) return "usage: set <class> <workspace|any> <normal|silent>"
      if (ws === "any" || ws === "none") ws = ""
      if (root.applying) return "busy"
      var quiet = String(silent || "").toLowerCase() === "silent"
      root.apply(Rules.upsert(root.state, name, ws, quiet, name), "", "",
                 name + (ws.length > 0 ? " → workspace " + ws : " → any workspace"))
      return "ok"
    }

    function unset(cls: string): string {
      var name = String(cls || "")
      if (!name.length) return "usage: unset <class>"
      if (root.applying) return "busy"
      if (!Rules.find(root.state.rules, name)) return "no rule for " + name
      root.apply(Rules.remove(root.state, name), "", "", "Removed rule for " + name)
      return "ok"
    }

    function pin(workspace: string, monitorDescription: string): string {
      var ws = String(workspace || "")
      if (!ws.length) return "usage: pin <workspace> [monitor-description]"
      if (root.applying) return "busy"
      var monitor = String(monitorDescription || "")
      if (monitor.length > 0 && monitor.indexOf("desc:") !== 0) monitor = "desc:" + monitor
      root.apply(Rules.setWorkspaceMonitor(root.state, ws, monitor), "", "",
                 "Workspace " + ws + (monitor.length ? " → pinned" : " → auto"))
      return "ok"
    }
  }

  // Windows are watched while the panel is closed too: a rule written from a
  // desktop entry is only confirmed, respelled or carried over to an alias
  // when its window is seen, and that must not wait for the next time the
  // panel happens to be open. The timer coalesces a burst of windows into one
  // refresh and lets a new window's class settle before it is read.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { windowSettle.restart() }
  }

  Timer {
    id: windowSettle
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    // A confirmation left open when the panel closes must not greet the
    // next open.
    root.removeTarget = ""
    if (!root.opened) return
    root.nowMs = Date.now()
    root.filterText = ""
    root.status = ""
    root.statusError = false
    root.refresh()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  onViewChanged: if (view === "monitors") root.readMonitors()

  Component.onCompleted: { root.loadState(); root.readMonitors(); root.refreshLayout() }

  // ------------------------------------------------------------- UI

  // The monitor this bar is on, to list only the workspaces that belong to it.
  readonly property var barMonitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    try { return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor } catch (e) { return null }
  }

  // Slots shown on this monitor's bar: the ones assigned to it, or, when none
  // is, its first five. With a global plan they are workspace numbers as usual.
  readonly property var stripSlots: {
    var m = root.barMonitor
    var desc = m ? "desc:" + String(m.description || "") : ""
    var owned = []
    for (var key in root.state.workspaces) {
      var n = parseInt(key, 10)
      if (n >= 1 && n <= 10 && root.state.workspaces[key]["monitor"] === desc) owned.push(n)
    }
    if (owned.length === 0 && root.perMonitor) owned = [1, 2, 3, 4, 5]
    owned.sort(function(a, b) { return a - b })
    return owned
  }

  // The workspace the bar's monitor shows carries its layout, as in Omarchy's own
  // widget: a square tiles, a circle scrolls, a triangle floats. It stands in for
  // the number, which is how the active slot is told from the others.
  property string activeMode: "dwindle"
  property bool modeStale: false
  property var modeCache: ({})
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function modeGlyph(mode) {
    if (mode === "scrolling") return "\u{F0765}"
    if (mode === "floating") return "\u{F0536}"
    return "\u{F14FB}"
  }

  function activeWorkspaceId() {
    var m = root.barMonitor
    return m && m.activeWorkspace ? m.activeWorkspace.id : -1
  }

  function showActiveMode() {
    var mode = root.modeCache[root.activeWorkspaceId()]
    if (mode !== undefined) root.activeMode = mode
    else root.readMode()
  }

  function readMode() {
    if (modeProc.running) { root.modeStale = true; return }
    var id = root.activeWorkspaceId()
    if (id === -1) return
    root.modeProcWorkspace = id
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(id)]
    modeProc.running = true
  }

  function refreshLayout() {
    root.modeCache = ({})
    root.modeGeneration++
    root.readMode()
  }

  // The layout commands act on the focused workspace, so a click on another
  // monitor's bar focuses that monitor first.
  function cycleLayout() {
    if (!root.bar) return
    var command = "omarchy-hyprland-workspace-layout-toggle"
    var m = root.barMonitor
    if (m && !m.focused)
      command = "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + m.name + "\" })") + " >/dev/null && " + command
    root.bar.run(command)
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        root.modeCache[root.modeProcWorkspace] = mode
        if (root.modeProcWorkspace === root.activeWorkspaceId()) root.activeMode = mode
      }
    }
    onExited: {
      if (!root.modeStale) return
      root.modeStale = false
      Qt.callLater(root.showActiveMode)
    }
  }

  Connections {
    target: root.barMonitor
    function onActiveWorkspaceChanged() { root.showActiveMode() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "configreloaded") root.refreshLayout()
    }
  }

  // Super + L changes the layout without a focus change and tells the workspaces
  // widget by this name, so a strip standing in for it listens for it too.
  ShellIpc {
    target: "omarchy.workspaces"

    // Panel is not a BarWidget, so it has no broadcast(): ask every live
    // instance (one per screen) directly.
    function refresh(): void {
      var items = root.bar && typeof root.bar.moduleWidgets === "function"
        ? root.bar.moduleWidgets(root.moduleName) : [root]
      for (var i = 0; i < items.length; i++)
        if (items[i] && typeof items[i].refreshLayout === "function") items[i].refreshLayout()
    }
  }

  function focusSlot(slot) {
    var m = root.barMonitor
    if (!m || !root.bar) return
    var expr = root.perMonitor
      ? "o.workspaces.focus(" + slot + ", \"" + m.name + "\")"
      : "hl.dsp.focus({ workspace = \"" + slot + "\" })"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(expr))
  }

  function stripId(slot) {
    var m = root.barMonitor
    return root.resolvedId(slot, m ? "desc:" + String(m.description || "") : "")
  }

  Grid {
    id: barRow
    columns: root.vertical ? 1 : 64
    spacing: 0

    Repeater {
      model: Rules.workspaceBarEnabled(root.state) && root.perMonitor ? root.stripSlots : []

      WidgetButton {
        required property int modelData

        readonly property int wsId: root.stripId(modelData)
        readonly property bool shown: root.barMonitor && root.barMonitor.activeWorkspace
          && root.barMonitor.activeWorkspace.id === wsId
        readonly property bool occupied: root.workspaceOccupied(wsId)

        bar: root.bar
        text: shown ? root.modeGlyph(root.activeMode) : (modelData === 10 ? "0" : String(modelData))
        opacity: shown || occupied ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? (Number(root.barSize) || 0) : Style.space(20)
        fixedHeight: Number(root.barSize) || 0
        onPressed: function() {
          if (shown) root.cycleLayout()
          else root.focusSlot(modelData)
        }

        // The slots are not numbered in order, so the active one keeps its number:
        // dark, centred in the layout shape.
        Text {
          textFormat: Text.PlainText
          visible: parent.shown && Rules.workspaceNumberEnabled(root.state)
          anchors.centerIn: parent
          text: parent.modelData === 10 ? "0" : String(parent.modelData)
          color: Color.background
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    BarIconButton {
      id: button
      visible: Rules.showIconEnabled(root.state)
      bar: root.bar
      text: "\u{F0A07}"
      tooltipText: "AppSpace"
      onPressed: root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // KeyboardPanel focuses focusTarget itself when it opens, overriding any
    // focus set elsewhere — so it has to name the control that should really
    // receive the first keystroke in each view.
    focusTarget: root.view === "apps" ? searchField : viewTabs
    contentWidth: panel.fittedContentWidth(Style.space(780))
    // The apps view wants a tall list; the workspaces view is a short table and
    // would otherwise sit above a slab of empty space.
    contentHeight: root.view === "apps"
      ? panel.fittedContentHeight(Style.space(620))
      : panel.fittedContentHeight(header.implicitHeight + Style.space(10)
          + (root.view === "monitors" ? monitorsView.implicitHeight
              : root.view === "settings" ? settingsView.implicitHeight : workspacesView.implicitHeight)
          + Style.space(8) + statusRow.height)

    // A plain Item rather than PanelKeyCatcher: that helper swallows Tab to
    // switch bar panels, which would make it impossible to reach the
    // workspace and monitor controls from the keyboard.
    Item {
      id: content
      anchors.fill: parent

      Keys.priority: Keys.AfterItem
      Keys.onPressed: function(event) {
        if (root.removeConfirmOpen) {
          if (removeConfirm.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ControlModifier)) {
          root.view = root.view === "apps" ? "workspaces" : "apps"
          event.accepted = true
        }
      }

      // ------------------------------------------------------ hero + tabs
      //
      // The same header the first-party panels use: a large glyph on the
      // left, the panel's name, and one dimmed uppercase line of status.
      Column {
        id: header
        readonly property var panel: root
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: root.panelTitle
          meta: root.panelDescription
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "\u{F0A07}"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          // The update status and its one button. A trailingControl's `root`
          // is the hero, not the panel, so it reaches the panel through
          // `header.panel`.
          trailingControl: Component {
            Column {
              spacing: Style.space(2)
              visible: header.panel.updateInfo.text.length > 0

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: header.panel.updateInfo.text
                color: header.panel.updateInfo.canUpdate ? Color.accent : Qt.darker(header.panel.foreground, 1.4)
                font.family: header.panel.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: header.panel.updateInfo.canUpdate
              }

              Button {
                anchors.right: parent.right
                visible: header.panel.updateInfo.canCheck
                text: header.panel.updateInfo.canUpdate ? "Update\u2026" : "Check now"
                tooltipText: header.panel.updateInfo.canUpdate
                  ? "Opens Omarchy's updater in a terminal. It shows what changes and asks first."
                  : "Ask the plugin's repository whether a newer version is published"
                bordered: true
                focusable: true
                foreground: header.panel.foreground
                accent: Color.accent
                fontFamily: header.panel.fontFamily
                onClicked: header.panel.updateInfo.canUpdate ? header.panel.runUpdate() : header.panel.checkForUpdates()
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        ButtonGroup {
          id: viewTabs
          options: [
            { value: "apps", label: "Apps" },
            { value: "workspaces", label: "Workspaces" },
            { value: "monitors", label: "Monitors" },
            { value: "settings", label: "Settings" }
          ]
          value: root.view
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) { root.view = value }

          // ButtonGroup sizes each chip to its label; two tabs read better
          // as equals. The chips are the Row's Button children (the
          // Repeater itself has no `text`), measured once they exist.
          function equalize() {
            var widest = 0
            for (var i = 0; i < children.length; i++) {
              var chip = children[i]
              if (chip && chip.text !== undefined) widest = Math.max(widest, chip.implicitWidth)
            }
            for (var j = 0; j < children.length; j++)
              if (children[j] && children[j].text !== undefined) children[j].width = widest
          }
          Component.onCompleted: Qt.callLater(equalize)
        }
      }

      // ------------------------------------------------------- apps view
      Item {
        id: appsView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: statusRow.top
        anchors.bottomMargin: Style.space(8)
        visible: root.view === "apps"

        TextField {
          id: searchField
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Search apps and windows…"
          text: root.filterText
          onTextChanged: if (text !== root.filterText) root.setFilter(text)

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
            else if (event.key === Qt.Key_Escape) {
              if (root.filterText.length > 0) searchField.text = ""
              else root.close()
              event.accepted = true
            }
          }
        }

        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: searchField.bottom
          anchors.topMargin: Style.space(10)
          anchors.bottom: parent.bottom

          Item {
            id: listPane
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.round(parent.width * 0.40)
            clip: true

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: root.rows.length === 0
              text: "Nothing matches"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            ListView {
              id: resultList
              anchors.fill: parent
              anchors.rightMargin: Style.space(10)
              model: root.rows
              clip: true
              spacing: Style.space(1)
              boundsBehavior: Flickable.StopAtBounds

              delegate: Rectangle {
                id: rowItem
                required property int index
                required property var modelData

                readonly property bool header: modelData.kind === "header"
                readonly property bool current: !header && modelData.cls === root.selectedKey

                width: ListView.view.width
                height: header ? Style.space(index === 0 ? 20 : 28) : Style.space(26)
                radius: Style.cornerRadius
                color: current ? Util.alpha(root.foreground, 0.10) : "transparent"

                PanelSectionHeader {
                  visible: rowItem.header
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(3)
                  text: rowItem.header ? (modelData.label + " · " + modelData.count) : ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Row {
                  visible: !rowItem.header
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(7)

                  // A dot instead of a "not running" caption: same information,
                  // one glance, no second line of text under every row.
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    text: rowItem.modelData.running ? "•" : ""
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Image {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: rowItem.modelData.icon.length > 0
                    width: visible ? Style.space(15) : 0
                    height: Style.space(15)
                    source: rowItem.modelData.icon
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(6) - parent.spacing * 3
                      - (rowItem.modelData.icon.length > 0 ? Style.space(15) : 0)
                      - badge.width
                    text: rowItem.modelData.name
                    color: root.foreground
                    opacity: rowItem.modelData.running ? 1 : 0.72
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: badge
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.ruleBadge(rowItem.modelData.rule).length > 0
                    text: root.ruleBadge(rowItem.modelData.rule)
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: !rowItem.header
                  hoverEnabled: !rowItem.header
                  cursorShape: rowItem.header ? Qt.ArrowCursor : Qt.PointingHandCursor
                  onClicked: root.selectKey(rowItem.modelData.cls)
                }
              }
            }
          }

          Rectangle {
            id: divider
            anchors.left: listPane.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.normalBorderWidth
            color: Util.alpha(root.foreground, 0.12)
          }

          // Scrolls if every control is showing and the pane is short.
          Flickable {
            id: detailFlick
            anchors.left: divider.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            visible: !!root.selectedRow
            contentWidth: width
            contentHeight: detailColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

          Column {
            id: detailColumn
            width: detailFlick.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: Math.max(appTitle.implicitHeight, removeButton.implicitHeight)

              Text {
                textFormat: Text.PlainText
                id: appTitle
                anchors.left: parent.left
                anchors.right: removeButton.visible ? removeButton.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedRow ? root.selectedRow.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                elide: Text.ElideRight
              }

              Button {
                id: removeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !!(root.selectedRow && root.selectedRow.rule)
                text: "Remove rule"
                tooltipText: "Forget everything set for this app"
                bordered: true
                focusable: true
                // Color.urgent is the palette's red, the same one ConfirmDialog
                // paints destructive choices with.
                foreground: Color.urgent
                accent: Color.urgent
                fontFamily: root.fontFamily
                onClicked: root.removeRule()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedRow ? ("class: " + root.selectedRow.cls) : ""
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool sure: root.selectedRow && root.selectedRow.verified
                width: chip.implicitWidth + Style.space(12)
                height: Style.space(17)
                radius: height / 2
                color: Util.alpha(sure ? Color.accent : root.foreground, 0.14)

                Text {
                  textFormat: Text.PlainText
                  id: chip
                  anchors.centerIn: parent
                  text: parent.sure ? "verified" : "guessed class"
                  color: parent.sure ? Color.accent : root.foreground
                  opacity: parent.sure ? 1 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.selectedRow && root.selectedRow.orphan === true
              text: "No window and no installed app uses this class, so this rule can never fire. "
                + "Launch the app once and assign it from its real entry."
              color: "#e0a33e"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.selectedRow && !root.selectedRow.verified && root.selectedRow.orphan !== true
              text: "Guessed from the .desktop file. Confirmed once the app runs."
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            PanelSectionHeader {
              text: "OPENS ON WORKSPACE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              width: parent.width
              options: root.workspaceOptions
              // Only a real rule highlights a workspace chip. Highlighting the
              // window's current workspace would read as "a rule exists" when
              // none does; with no placement the highlight is on "Any".
              value: root.selectedRow && root.selectedRow.rule
                ? String(root.selectedRow.rule["workspace"]) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(value) { root.assignWorkspace(value) }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              readonly property bool placed: !!(root.selectedRow && root.selectedRow.rule
                && String(root.selectedRow.rule["workspace"]).length > 0)
              visible: root.selectedRow && !placed
              text: "Not placed: it opens wherever it normally would."
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
              visible: !!root.selectedRow
            }

            Toggle {
              readonly property bool placed: !!(root.selectedRow && root.selectedRow.rule
                && String(root.selectedRow.rule["workspace"]).length > 0)
              width: parent.width
              visible: !!root.selectedRow
              label: "Silent"
              description: placed
                ? "Opens there without pulling focus"
                : "Opens without taking focus, wherever it opens"
              checked: root.selectedRow && root.selectedRow.rule
                ? root.selectedRow.rule["silent"] === true : false
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleSilent()
            }

            Toggle {
              readonly property bool launchable: root.selectedRow
                && String(root.selectedRow.command || "").length > 0
              // The app installs its own login entry (1Password does). A
              // second launch from here would only lose the race and close on
              // the app's single-instance lock, so the switch is left alone.
              readonly property bool startsItself: root.selectedRow
                && String(root.selectedRow.ownAutostart || "").length > 0

              width: parent.width
              visible: !!root.selectedRow
              label: "Launch at startup"
              description: startsItself
                ? (root.selectedRow.name + " already starts itself when you log in, from its own settings")
                : launchable
                  ? "Starts when you log in"
                  : "Unavailable: no desktop entry to launch this class from"
              checked: root.selectedRow && Rules.isAutostart(root.state, root.selectedRow.cls)
              // Without a command there is nothing to put in the launch line,
              // so the row stays visible but inert rather than silently no-op.
              enabled: launchable && !startsItself
              opacity: launchable && !startsItself ? 1 : 0.45
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleAutostart()
            }

            Toggle {
              readonly property bool placed: !!(root.selectedRow && root.selectedRow.rule
                && String(root.selectedRow.rule["workspace"]).length > 0)
              readonly property bool only: !!(root.selectedRow && root.selectedRow.rule
                && root.selectedRow.rule["startupOnly"] === true)
              width: parent.width
              visible: root.selectedRow && placed
              label: "Custom workspace only at startup"
              description: only
                ? "Works only at startup"
                : "Works every time you open the app"
              checked: only
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleStartupOnly()
            }

            // For the rare app where one window is not the whole startup (a
            // browser that reopens several), or the default time is off. The
            // numbers read as a sentence so nothing needs explaining.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.selectedRow && !!root.selectedRow.rule && root.selectedRow.rule["startupOnly"] === true

              Button {
                text: root.advancedOpen ? "Advanced  \u25BE" : "Advanced  \u25B8"
                bordered: false
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.advancedOpen = !root.advancedOpen
              }

              Row {
                visible: root.advancedOpen
                spacing: Style.space(7)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Place every window it opens within"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                NumberField {
                  anchors.verticalCenter: parent.verticalCenter
                  from: 5
                  to: 600
                  stepSize: 5
                  fieldWidth: Style.space(62)
                  value: root.selectedRow && root.selectedRow.rule ? root.selectedRow.rule["startupWindow"] : 20
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onModified: function(v) {
                    if (root.selectedRow && root.selectedRow.rule && v !== root.selectedRow.rule["startupWindow"])
                      root.setStartupSeconds(v)
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "s of login"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.advancedOpen
                width: parent.width
                text: "Raise it for a slow app: Steam can take 40 s or more to show its first window."
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

          }
          }
        }
      }

      // ------------------------------------------------- workspaces view
      //
      // A Column with a Repeater rather than an anchored ListView: the list is
      // at most ten rows, and an implicit height lets the popup shrink to fit
      // instead of leaving a slab of empty space under it.
      Column {
        id: workspacesView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        visible: root.view === "workspaces"
        spacing: Style.space(6)

        Row {
          id: wsHeader
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: Style.space(46)
            text: "WS"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: Style.space(190)
            text: "MONITOR"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: "PINNED APPS"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: root.workspaceRows

          Item {
            id: wsRow
            required property var modelData

            readonly property string wsName: String(modelData.id)
            readonly property string heading: modelData.heading
            readonly property real headingHeight: heading.length > 0 ? Style.space(22) : 0
            readonly property bool occupied: root.workspaceOccupied(
              root.resolvedId(modelData.id, Rules.workspaceMonitor(root.state, String(modelData.id))))
            readonly property bool persistent: Rules.workspacePersistent(root.state, wsName)
            readonly property var pinned: Rules.rulesForWorkspace(root.state, wsName)

            width: workspacesView.width
            height: Style.spacing.controlHeight + Style.space(6) + headingHeight

            Text {
              textFormat: Text.PlainText
              visible: wsRow.heading.length > 0
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.topMargin: Style.space(4)
              text: wsRow.heading.toUpperCase()
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.spacing.controlHeight + Style.space(6)
              spacing: Style.space(10)

              Row {
                width: Style.space(46)
                height: parent.height
                spacing: Style.space(5)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: wsRow.occupied ? "\u2022" : ""
                  width: Style.space(6)
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: wsRow.wsName
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }
              }

              Dropdown {
                width: Style.space(190)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: root.monitorOptions
                value: Rules.workspaceMonitor(root.state, wsRow.wsName)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.assignMonitor(wsRow.wsName, value) }
              }

              // Pinned apps, clickable: jumps to that app in the Apps view so
              // the rule can be changed where it was made.
              Row {
                height: parent.height
                width: parent.width - Style.space(46) - Style.space(190)
                  - trailing.width - parent.spacing * 3
                spacing: Style.space(5)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  visible: wsRow.pinned.length === 0
                  text: "\u2014"
                  color: root.foreground
                  opacity: 0.3
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: wsRow.pinned

                  Rectangle {
                    id: pinnedChip
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    width: pinnedLabel.implicitWidth + Style.space(12)
                    height: Style.space(18)
                    radius: height / 2
                    color: Util.alpha(root.foreground, 0.10)

                    Text {
                      textFormat: Text.PlainText
                      id: pinnedLabel
                      anchors.centerIn: parent
                      text: pinnedChip.modelData["class"] + (pinnedChip.modelData["startupOnly"] === true ? " · login" : "")
                      color: root.foreground
                      opacity: 0.8
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.setFilter("")
                        root.selectKey(pinnedChip.modelData["class"])
                        root.view = "apps"
                      }
                    }
                  }
                }
              }

              // Fixed-width slots so the buttons line up across rows whether
              // or not a row can be removed.
              Row {
                id: trailing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                // Sized by the wider label so "Always" and "On demand" are
                // the same button, not two widths.
                Button {
                  id: persistToggle
                  width: persistRef.implicitWidth
                  text: wsRow.persistent ? "Always" : "On demand"
                  tooltipText: wsRow.persistent
                    ? "Exists even when empty, so it always shows on the bar"
                    : "Appears only while something is open on it"
                  bordered: true
                  focusable: true
                  selected: wsRow.persistent
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.toggleWorkspacePersistent(wsRow.wsName)
                }

                // A workspace above the five the bar always shows can be
                // dropped again. The slot stays even when the button does
                // not, so the rows line up.
                Button {
                  readonly property bool removable: wsRow.modelData.id > 5
                  iconText: "\u{F0156}"
                  tooltipText: wsRow.pinned.length > 0
                    ? "Remove this workspace and the rules of the apps pinned to it"
                    : "Remove this workspace from the list"
                  // Same height as the text button beside it, and square.
                  height: persistRef.implicitHeight
                  width: height
                  bordered: true
                  focusable: removable
                  enabled: removable
                  opacity: removable ? 1 : 0
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (removable) root.removeWorkspace(wsRow.wsName)
                }
              }
            }
          }
        }

        // Invisible reference: the wider of the two labels sizes the slot.
        Button {
          id: persistRef
          visible: false
          text: "On demand"
          bordered: true
          fontFamily: root.fontFamily
        }

        Item { width: 1; height: Style.space(4) }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Button {
            text: root.nextFreeWorkspace > 0
              ? ("+ Add workspace " + root.nextFreeWorkspace)
              : "+ Add workspace"
            bordered: true
            focusable: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.addWorkspace()
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "1–5 are always listed. New ones are added as always-present."
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

      }

      // ------------------------------------------------- monitors view
      Column {
        id: monitorsView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        visible: root.view === "monitors"
        spacing: Style.space(10)

        // A change that can't be seen can't be confirmed, so it undoes itself.
        Row {
          visible: root.confirmLeft > 0
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: "Keep these display settings? Reverting in " + root.confirmLeft + " s"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Button {
            text: "Keep"
            bordered: true
            focusable: true
            selected: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.keepMonitors()
          }
          Button {
            text: "Revert"
            bordered: true
            focusable: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.revertMonitors()
          }
        }

        // The layout as it will be: each screen drawn at its position and size.
        Rectangle {
          id: layoutMap
          width: parent.width
          height: Style.space(230)
          radius: Style.space(6)
          color: Util.alpha(root.foreground, 0.05)
          clip: true

          readonly property real pad: Style.space(14)
          readonly property real k: Math.min((width - 2 * pad) / root.layoutBounds.w,
                                             (height - 2 * pad) / root.layoutBounds.h)
          readonly property real offX: (width - root.layoutBounds.w * k) / 2
          readonly property real offY: (height - root.layoutBounds.h * k) / 2

          Repeater {
            model: root.monitorList

            Rectangle {
              id: screenBox
              required property var modelData
              readonly property var now: root.monitorNow(modelData)
              readonly property var size: root.logicalSize(now.mode, now.scale, now.transform)

              // While dragging, the box follows the pointer; the layout
              // position it would snap to is in `target`.
              property bool dragging: false
              property real pointerDx: 0
              property real pointerDy: 0
              readonly property var target: dragging
                ? root.snapped(modelData.description, now.x + pointerDx, now.y + pointerDy, 6 / layoutMap.k)
                : null
              readonly property real shownX: dragging ? (target ? target.x : now.x + pointerDx) : now.x
              readonly property real shownY: dragging ? (target ? target.y : now.y + pointerDy) : now.y

              x: layoutMap.offX + (shownX - root.layoutBounds.x) * layoutMap.k
              y: layoutMap.offY + (shownY - root.layoutBounds.y) * layoutMap.k
              z: dragging ? 2 : 1
              width: size.w * layoutMap.k
              height: size.h * layoutMap.k
              radius: Style.space(3)
              color: Util.alpha(Color.accent, dragging ? 0.32 : 0.18)
              border.width: 1
              border.color: dragging && !target ? "#ff6b6b" : Color.accent

              MouseArea {
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                preventStealing: true
                property real startX: 0
                property real startY: 0

                onPressed: function(mouse) {
                  if (root.applying) return
                  var p = mapToItem(layoutMap, mouse.x, mouse.y)
                  startX = p.x; startY = p.y
                  screenBox.pointerDx = 0; screenBox.pointerDy = 0
                  screenBox.dragging = true
                }
                onPositionChanged: function(mouse) {
                  if (!screenBox.dragging) return
                  var p = mapToItem(layoutMap, mouse.x, mouse.y)
                  screenBox.pointerDx = (p.x - startX) / layoutMap.k
                  screenBox.pointerDy = (p.y - startY) / layoutMap.k
                }
                onReleased: function() {
                  if (!screenBox.dragging) return
                  var spot = screenBox.target
                  screenBox.dragging = false
                  if (!spot) {
                    root.status = "Screens can't overlap"
                    root.statusError = true
                    return
                  }
                  if (spot.x !== screenBox.now.x || spot.y !== screenBox.now.y)
                    root.applyMonitor(screenBox.modelData.description, { x: spot.x, y: spot.y })
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                width: parent.width - Style.space(6)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.shortName(modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Repeater {
          model: root.monitorList

          Item {
            id: monRow
            required property var modelData
            readonly property var now: root.monitorNow(modelData)
            readonly property string desc: modelData.description

            width: monitorsView.width
            height: Style.spacing.controlHeight + Style.space(6)

            Row {
              anchors.fill: parent
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                width: Style.space(120)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.shortName(monRow.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Dropdown {
                width: Style.space(190)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: monRow.modelData.modes
                value: monRow.now.mode
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.applyMonitor(monRow.desc, { mode: value }) }
              }

              Dropdown {
                width: Style.space(80)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: ["1", "1.25", "1.5", "1.6", "1.75", "2", "3"].map(function(v) { return { value: v, label: v + "×" } })
                value: String(monRow.now.scale)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.applyMonitor(monRow.desc, { scale: value }) }
              }

              Dropdown {
                width: Style.space(110)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: [{ value: "0", label: "Normal" }, { value: "1", label: "90°" },
                          { value: "2", label: "180°" }, { value: "3", label: "270°" }]
                value: String(monRow.now.transform)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) { root.applyMonitor(monRow.desc, { transform: value }) }
              }

              Dropdown {
                width: Style.space(190)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: {
                  var out = [{ value: "", label: "Position " + monRow.now.x + ", " + monRow.now.y }]
                  for (var i = 0; i < root.monitorList.length; i++) {
                    var other = root.monitorList[i]
                    if (other.description === monRow.desc) continue
                    var nm = root.shortName(other)
                    out.push({ value: "right:" + other.description, label: "Right of " + nm })
                    out.push({ value: "left:" + other.description, label: "Left of " + nm })
                    out.push({ value: "above:" + other.description, label: "Above " + nm })
                    out.push({ value: "below:" + other.description, label: "Below " + nm })
                  }
                  return out
                }
                value: ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                onChanged: function(value) {
                  if (value.length === 0) return
                  var spot = root.placement(monRow.desc, value)
                  if (spot) root.applyMonitor(monRow.desc, { x: spot.x, y: spot.y })
                }
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Drag a screen to move it; it always snaps flush against another. Saved per display, and a change reverts unless you keep it."
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ------------------------------------------------- settings view
      Column {
        id: settingsView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Style.space(14)
        visible: root.view === "settings"
        spacing: Style.space(14)

        Text {
          textFormat: Text.PlainText
          text: "IN THE BAR"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: Style.space(110)
            anchors.verticalCenter: parent.verticalCenter
            text: "Position"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Dropdown {
            width: Style.space(190)
            anchors.verticalCenter: parent.verticalCenter
            showLabel: false
            options: root.barSections
            value: root.barSection
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { root.moveToSection(value) }
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(110) - Style.space(190) - parent.spacing * 2
            elide: Text.ElideRight
            text: "The same sections Omarchy offers when it is installed."
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: Style.space(110)
            anchors.verticalCenter: parent.verticalCenter
            text: "Icon"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Button {
            text: Rules.showIconEnabled(root.state) ? "Show icon: On" : "Show icon: Off"
            tooltipText: "The AppSpace icon in the bar. Off needs a shortcut below to open the panel."
            bordered: true
            focusable: true
            selected: Rules.showIconEnabled(root.state)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setShowIcon(!Rules.showIconEnabled(root.state))
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: Style.space(110)
            anchors.verticalCenter: parent.verticalCenter
            text: "Workspaces"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Button {
            visible: root.perMonitor
            text: Rules.workspaceBarEnabled(root.state) ? "Bar workspaces: On" : "Bar workspaces: Off"
            tooltipText: "Show only each monitor's own workspaces in the bar, in place of Omarchy's workspaces widget"
            bordered: true
            focusable: true
            selected: Rules.workspaceBarEnabled(root.state)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setBarStrip(!Rules.workspaceBarEnabled(root.state))
          }

          Button {
            visible: root.perMonitor && Rules.workspaceBarEnabled(root.state)
            text: Rules.workspaceNumberEnabled(root.state) ? "Number: On" : "Number: Off"
            tooltipText: "Show the slot number inside the marker of the active workspace"
            bordered: true
            focusable: true
            selected: Rules.workspaceNumberEnabled(root.state)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setBarNumber(!Rules.workspaceNumberEnabled(root.state))
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.perMonitor
            anchors.verticalCenter: parent.verticalCenter
            text: "Needs Omarchy 4.5's workspaces per monitor."
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Text {
          textFormat: Text.PlainText
          text: "OPENING THIS PANEL"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: Style.space(110)
            anchors.verticalCenter: parent.verticalCenter
            text: "Shortcut"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          TextField {
            id: shortcutField
            width: Style.space(240)
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            placeholderText: "SUPER + ALT + A"
            text: Rules.shortcutOf(root.state)
            onAccepted: root.applyShortcut(text)
            onEditingFinished: root.applyShortcut(text)
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(110) - Style.space(240) - parent.spacing * 2
            elide: Text.ElideRight
            text: "Modifiers and a key. Enter saves; empty removes it."
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "From a terminal: omarchy-shell dominikzajac.appspace toggle"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ConfirmDialog {
        id: removeConfirm
        anchors.fill: parent
        opened: root.removeConfirmOpen
        z: 10
        message: root.removeMessage
        confirmText: "Remove"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelRemove()
        onConfirmed: root.confirmRemove()
      }

      // ----------------------------------------------------------- status
      Item {
        id: statusRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(16)

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          text: root.status
          color: root.statusError ? "#ff6b6b" : Color.accent
          opacity: root.status.length > 0 ? 1 : 0
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
