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

  // The bar sizes each widget from its root implicitWidth/Height. Without
  // these the slot collapses to 0x0 and the icon never appears on the bar.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string panelTitle: "AppSpace"

  readonly property string panelDescription: "Manage where apps open: which workspace, and on which monitor"

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

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
      sortable.push({ x: Number(m.x) || 0, description: String(m.description || ""), name: String(m.name || "") })
    }
    sortable.sort(function(a, b) { return a.x - b.x })

    for (var j = 0; j < sortable.length; j++) {
      var mon = sortable[j]
      if (mon.description.length === 0) continue
      var position = sortable.length === 2 ? (j === 0 ? "left" : "right") : String(j + 1)
      var make = mon.description.split(" ")[0]
      out.push({
        value: "desc:" + mon.description,
        label: make + " · " + position,
        tooltip: mon.name + " — " + mon.description
      })
    }
    return out
  }

  readonly property var workspaceOptions: {
    var out = []
    for (var i = 1; i <= 9; i++) out.push({ value: String(i), label: String(i) })
    return out
  }

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
      var row = put({
        cls: guessed,
        name: String(entry.name || guessed),
        icon: root.iconSource(entry.icon),
        ownAutostart: own,
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
        if (!row.ownAutostart) row.ownAutostart = own
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

    var out = []
    for (var p = 0; p < apps.length; p++)
      if (Rules.matches(root.filterText, apps[p])) out.push(apps[p])

    root.rows = out
    if (!root.rowForKey(root.selectedKey)) root.selectKey(out.length > 0 ? out[0].cls : "")

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

  function rowForKey(key) {
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].cls === key) return root.rows[i]
    return null
  }

  readonly property var selectedRow: root.rowForKey(root.selectedKey)

  function selectKey(key) {
    root.selectedKey = String(key)
  }

  function moveSelection(delta) {
    if (root.rows.length === 0) return
    var index = 0
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].cls === root.selectedKey) { index = i; break }
    var next = index + delta
    if (next < 0) next = 0
    if (next > root.rows.length - 1) next = root.rows.length - 1
    root.selectKey(root.rows[next].cls)
    resultList.positionViewAtIndex(next, ListView.Contain)
  }

  function setFilter(value) {
    root.filterText = String(value || "")
    root.rebuild()
    // Typing means the user is hunting for one app, so land on the first
    // result instead of leaving the cursor on whatever was selected before.
    if (root.filterText.length > 0 && root.rows.length > 0) root.selectKey(root.rows[0].cls)
  }

  // ------------------------------------------------------------- actions

  function assignWorkspace(workspace) {
    var row = root.selectedRow
    if (!row) return
    var next = Rules.upsert(root.state, row.cls, String(workspace),
                            row.rule ? row.rule["silent"] === true : false, row.name,
                            row.verified === true, row.command)
    root.apply(next, row.running ? row.address : "", String(workspace),
               row.cls + " → workspace " + workspace)
  }

  function toggleSilent() {
    var row = root.selectedRow
    if (!row || !row.rule) return
    var quiet = !(row.rule["silent"] === true)
    var next = Rules.upsert(root.state, row.cls, row.rule["workspace"], quiet, row.name,
                            row.verified === true, row.command)
    root.apply(next, "", "", row.cls + (quiet ? " → silent" : " → follow focus"))
  }

  function toggleAutostart() {
    var row = root.selectedRow
    if (!row || !row.rule) return
    // The row knows the desktop entry's command even when the rule predates
    // command storage, so pass it along instead of refusing the toggle.
    var command = String(row.command || "")
    if (command.length === 0) return
    var on = !Rules.isAutostart(root.state, row.cls)
    root.apply(Rules.setAutostart(root.state, row.cls, on, command), "", "",
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

  // Class -> the app's own autostart entry, for the launch guard in the Lua.
  function ownAutostartMap() {
    var out = ({})
    for (var i = 0; i < root.rows.length; i++)
      if (root.rows[i].ownAutostart) out[root.rows[i].cls] = root.rows[i].ownAutostart
    return out
  }

  function onBaselineChecked(errText) {
    root.errorBaseline = String(errText || "").trim()
    var next = root.stagedState || Rules.emptyState()
    root.stagedState = null

    root.state = next
    rulesFile.setText(Rules.toJson(next))
    luaFile.setText(Rules.toLua(next, root.ownAutostartMap()))
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

    // The rule takes effect the next time the window opens; if it is already
    // open, move it now so the result is visible immediately.
    if (root.pendingMoveAddress.length > 0 && root.pendingMoveWorkspace.length > 0) {
      evalProc.command = ["hyprctl", "eval",
        Rules.moveWindowLua(root.pendingMoveAddress, root.pendingMoveWorkspace)]
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
      if (!rule) return "no rule for " + name
      var on = String(state || "").toLowerCase() === "on"
      var row = root.rowForKey(rule["class"])
      var command = row ? String(row.command || "") : ""
      if (on && command.length === 0 && !Rules.canAutostart(root.state, rule["class"]))
        return "no launch command known for " + name
      root.apply(Rules.setAutostart(root.state, rule["class"], on, command), "", "",
                 rule["class"] + (on ? " → launches at startup" : " → no longer launches at startup"))
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

    function view(name: string): string {
      var value = String(name || "").toLowerCase()
      if (value !== "apps" && value !== "workspaces") return "usage: view <apps|workspaces>"
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
        out.push(r["class"] + " -> " + r["workspace"] + (r["silent"] ? " (silent)" : ""))
      }
      var names = Rules.sortedWorkspaceNames(root.state)
      for (var j = 0; j < names.length; j++) {
        var entry = root.state.workspaces[names[j]]
        var bits = []
        if (entry["monitor"].length > 0) bits.push(entry["monitor"])
        if (entry["persistent"]) bits.push("always present")
        out.push("workspace " + names[j] + " -> " + bits.join(", "))
      }
      return out.length ? out.join("\n") : "(no rules)"
    }

    function set(cls: string, workspace: string, silent: string): string {
      var name = String(cls || "")
      var ws = String(workspace || "")
      if (!name.length || !ws.length) return "usage: set <class> <workspace> <normal|silent>"
      if (root.applying) return "busy"
      var quiet = String(silent || "").toLowerCase() === "silent"
      root.apply(Rules.upsert(root.state, name, ws, quiet, name), "", "",
                 name + " → workspace " + ws)
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
    root.filterText = ""
    root.status = ""
    root.statusError = false
    root.refresh()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  Component.onCompleted: root.loadState()

  // ------------------------------------------------------------- UI

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0A07}"
    tooltipText: "AppSpace"
    onPressed: root.toggle()
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
      ? panel.fittedContentHeight(Style.space(540))
      : panel.fittedContentHeight(header.implicitHeight + Style.space(10)
          + workspacesView.implicitHeight + Style.space(8) + statusRow.height)

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
              text: "\u{F0A07}"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        ButtonGroup {
          id: viewTabs
          options: [
            { value: "apps", label: "Apps" },
            { value: "workspaces", label: "Workspaces" }
          ]
          value: root.view
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) { root.view = value }
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

                readonly property bool current: modelData.cls === root.selectedKey

                width: ListView.view.width
                height: Style.space(26)
                radius: Style.cornerRadius
                color: current ? Util.alpha(root.foreground, 0.10) : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(7)

                  // A dot instead of a "not running" caption: same information,
                  // one glance, no second line of text under every row.
                  Text {
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
                    id: badge
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!rowItem.modelData.rule
                    text: visible ? ("→ " + rowItem.modelData.rule["workspace"]) : ""
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
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

          Column {
            anchors.left: divider.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(10)
            visible: !!root.selectedRow

            Text {
              width: parent.width
              text: root.selectedRow ? root.selectedRow.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
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
              width: parent.width
              visible: root.selectedRow && !root.selectedRow.verified && root.selectedRow.orphan !== true
              text: "Derived from the .desktop file and may be wrong. Confirmed once the app runs."
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            PanelSectionHeader {
              text: "ASSIGN TO WORKSPACE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              width: parent.width
              options: root.workspaceOptions
              // Only a real rule highlights a chip. Highlighting the window's
              // current workspace would read as "a rule exists" when none does.
              value: root.selectedRow && root.selectedRow.rule
                ? String(root.selectedRow.rule["workspace"]) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(value) { root.assignWorkspace(value) }
            }

            Text {
              width: parent.width
              visible: root.selectedRow && !root.selectedRow.rule
              text: "No rule yet — pick a workspace to create one."
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
              visible: root.selectedRow && !!root.selectedRow.rule
            }

            Toggle {
              width: parent.width
              visible: root.selectedRow && !!root.selectedRow.rule
              label: "Silent"
              description: "Opens there without pulling focus"
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
              visible: root.selectedRow && !!root.selectedRow.rule
              label: "Launch at startup"
              description: startsItself
                ? (root.selectedRow.name + " already starts itself when you log in, from its own settings")
                : launchable
                  ? "Opens on its workspace when you log in"
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

            Item {
              width: parent.width
              height: removeButton.implicitHeight
              visible: root.selectedRow && !!root.selectedRow.rule

              Button {
                id: removeButton
                anchors.right: parent.right
                text: "Remove rule"
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
            width: Style.space(46)
            text: "WS"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(190)
            text: "MONITOR"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "PINNED APPS"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: root.barWorkspaces

          Item {
            id: wsRow
            required property int modelData

            readonly property string wsName: String(modelData)
            readonly property bool occupied: root.workspaceOccupied(modelData)
            readonly property bool persistent: Rules.workspacePersistent(root.state, wsName)
            readonly property var pinned: Rules.rulesForWorkspace(root.state, wsName)

            width: workspacesView.width
            height: Style.spacing.controlHeight + Style.space(6)

            Row {
              anchors.fill: parent
              spacing: Style.space(10)

              Row {
                width: Style.space(46)
                height: parent.height
                spacing: Style.space(5)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: wsRow.occupied ? "\u2022" : ""
                  width: Style.space(6)
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
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
                      id: pinnedLabel
                      anchors.centerIn: parent
                      text: pinnedChip.modelData["class"]
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

                Item {
                  width: persistRef.implicitWidth
                  height: persistToggle.implicitHeight

                  Button {
                    id: persistToggle
                    anchors.right: parent.right
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
                }

                // A workspace above the five the bar always shows can be
                // dropped again while it is on demand. The slot stays even
                // when the button does not, so the rows line up.
                Button {
                  readonly property bool removable: wsRow.modelData > 5 && !wsRow.persistent
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
            anchors.verticalCenter: parent.verticalCenter
            text: "1–5 are always on Omarchy's bar. New ones are added as always-present."
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
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
