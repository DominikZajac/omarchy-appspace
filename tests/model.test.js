const test = require("node:test")
const assert = require("node:assert/strict")
const childProcess = require("node:child_process")
const fs = require("node:fs")
const path = require("node:path")
const Rules = require("../Rules.js")

test("a schema 1 file, which had no workspaces section, loads as an empty map", () => {
  const state = Rules.normalize({ version: 1, rules: [{ class: "vesktop", workspace: "3" }] })
  assert.equal(state.rules.length, 1)
  assert.deepEqual(state.workspaces, {})
})

test("a schema 2 file, which stored a bare monitor string, loads as a workspace entry", () => {
  const state = Rules.normalize({
    version: 2,
    rules: [],
    workspaces: { "3": "desc:LG Electronics MP59G" }
  })
  assert.deepEqual(state.workspaces["3"], { monitor: "desc:LG Electronics MP59G", persistent: false })
})

test("a workspace with neither a monitor nor persistence carries no rule and is dropped", () => {
  const state = Rules.normalize({
    version: 3,
    rules: [],
    workspaces: { "4": { monitor: "", persistent: false } }
  })
  assert.deepEqual(state.workspaces, {})

  const cleared = Rules.setWorkspacePersistent(
    Rules.setWorkspaceMonitor(Rules.emptyState(), "4", "desc:X"), "4", false)
  assert.equal(Rules.workspaceMonitor(cleared, "4"), "desc:X")
  assert.deepEqual(Rules.setWorkspaceMonitor(cleared, "4", "").workspaces, {})
})

test("setting a monitor keeps persistence and vice versa", () => {
  let state = Rules.setWorkspacePersistent(Rules.emptyState(), "6", true)
  state = Rules.setWorkspaceMonitor(state, "6", "desc:Samsung")
  assert.deepEqual(Rules.workspaceEntry(state, "6"), { monitor: "desc:Samsung", persistent: true })
})

// The bug this guards: brave-browser.desktop declares StartupWMClass
// "brave-browser" while the window class is "Brave-browser". Treating those as
// two apps produced two rows and a rule that never matched anything.
test("rules are replaced case-insensitively, and the newest spelling is stored", () => {
  let state = Rules.normalize({ rules: [{ class: "brave-browser", workspace: "1" }] })
  assert.ok(Rules.findCI(state.rules, "Brave-browser"))
  assert.equal(Rules.find(state.rules, "Brave-browser"), null)

  state = Rules.upsert(state, "Brave-browser", "2", false, "Brave-browser")
  assert.equal(state.rules.length, 1)
  assert.equal(state.rules[0]["class"], "Brave-browser")
  assert.equal(state.rules[0]["workspace"], "2")

  assert.equal(Rules.remove(state, "BRAVE-BROWSER").rules.length, 0)
})

test("class patterns are anchored and regex-escaped so one app cannot match another", () => {
  assert.equal(Rules.classPattern("foot"), "^foot$")
  assert.equal(Rules.classPattern("org.gnome.Files"), "^org\\.gnome\\.Files$")
})

test("Lua strings escape quotes and backslashes", () => {
  assert.equal(Rules.luaString('we"ird\\class'), '"we\\"ird\\\\class"')
})

test("generated Lua carries window rules, workspace rules and a guard", () => {
  let state = Rules.normalize({ rules: [{ class: "vesktop", workspace: "3", silent: true }] })
  state = Rules.setWorkspaceMonitor(state, "3", "desc:LG")
  state = Rules.setWorkspacePersistent(state, "6", true)
  const lua = Rules.toLua(state)

  assert.match(lua, /if type\(hl\) ~= "table" or type\(o\) ~= "table" then return end/)
  assert.match(lua, /hl\.workspace_rule\(\{ workspace = "3", monitor = "desc:LG" \}\)/)
  assert.match(lua, /hl\.workspace_rule\(\{ workspace = "6", persistent = true \}\)/)
  assert.match(lua, /o\.window\("\^vesktop\$", \{ workspace = "3 silent" \}\)/)
})

test("generated Lua is syntactically valid", (t) => {
  let luac
  try {
    luac = childProcess.execFileSync("sh", ["-c", "command -v luac"], { encoding: "utf8" }).trim()
  } catch (e) {
    return t.skip("luac not installed")
  }
  let state = Rules.normalize({ rules: [{ class: 'we"ird\\class', workspace: "9" }] })
  state = Rules.setWorkspaceMonitor(state, "9", 'desc:Odd "Monitor" \\ Name')
  const file = path.join(fs.mkdtempSync("/tmp/appws-"), "generated.lua")
  fs.writeFileSync(file, Rules.toLua(state))
  childProcess.execFileSync(luac, ["-p", file])
})

// Hyprland silently ignores unknown keys in this dispatcher and falls back to
// the ACTIVE window, so a wrong key would move whatever the user is looking at.
test("the move dispatcher names the window explicitly and does not follow it", () => {
  const lua = Rules.moveWindowLua("0xdeadbeef", "3")
  assert.match(lua, /window = "address:0xdeadbeef"/)
  assert.match(lua, /follow = false/)
})

test("a desktop id falls back to a class only after stripping path and suffix", () => {
  assert.equal(Rules.classFromDesktopId("steam.desktop"), "steam")
  assert.equal(Rules.classFromDesktopId("/usr/share/applications/org.x.y.desktop"), "org.x.y")
  assert.equal(Rules.classFromDesktopId(""), "")
})

test("a workspace can be read back from the rule side", () => {
  let state = Rules.normalize({
    rules: [
      { class: "vesktop", workspace: "3" },
      { class: "spotify", workspace: "3" },
      { class: "foot", workspace: "5" }
    ]
  })
  assert.deepEqual(Rules.rulesForWorkspace(state, "3").map(r => r["class"]), ["spotify", "vesktop"])
  assert.deepEqual(Rules.rulesForWorkspace(state, "9"), [])
})

test("the round trip through JSON preserves both rule kinds", () => {
  let state = Rules.setWorkspacePersistent(
    Rules.upsert(Rules.emptyState(), "vesktop", "3", true, "vesktop"), "3", true)
  const reloaded = Rules.normalize(JSON.parse(Rules.toJson(state)))
  assert.deepEqual(reloaded, state)
})

test("the panel does not reference model internals the model no longer exports", () => {
  const qml = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  // Call sites only — the `import "Rules.js" as Rules` line is not one.
  const used = new Set([...qml.matchAll(/\bRules\.(\w+)\s*\(/g)].map(m => m[1]))
  for (const name of used) assert.ok(name in Rules, `Panel.qml calls Rules.${name}, which is not exported`)
})

// Steam ships one .desktop per game with no StartupWMClass and a launcher Exec,
// so the filename fallback would produce "Factorio" for a window that is really
// "steam_app_427520" — a rule that silently never matches.
test("a Steam game resolves to its steam_app class rather than its display name", () => {
  assert.equal(
    Rules.classFromEntry("", "steam steam://rungameid/427520", "Factorio.desktop"),
    "steam_app_427520")
  assert.equal(
    Rules.classFromEntry("", "steam steam://rungameid/2868840", "Slay the Spire 2.desktop"),
    "steam_app_2868840")
})

test("a declared StartupWMClass still wins over every fallback", () => {
  assert.equal(Rules.classFromEntry("vesktop", "steam steam://rungameid/1", "x.desktop"), "vesktop")
})

test("a normal launcher entry keeps falling back to its desktop id", () => {
  assert.equal(Rules.classFromEntry("", "/usr/bin/foot", "foot.desktop"), "foot")
})

// Verification used to be computed live, so closing an app demoted its rule
// back to "guessed" and wrongly flagged it as one that can never fire.
test("verification is sticky and survives editing the rule", () => {
  let state = Rules.normalize({ version: 3, rules: [{ class: "com.factorio.Factorio", workspace: "1" }] })
  assert.equal(Rules.isVerified(state, "com.factorio.Factorio"), false)

  state = Rules.markVerified(state, "com.factorio.Factorio")
  assert.equal(Rules.isVerified(state, "com.factorio.Factorio"), true)

  state = Rules.upsert(state, "com.factorio.Factorio", "2", true, "Factorio")
  assert.equal(Rules.isVerified(state, "com.factorio.Factorio"), true)

  assert.equal(Rules.markVerified(state, "com.factorio.Factorio"), null, "no rewrite when nothing changes")
  assert.equal(Rules.markVerified(state, "never-seen"), null)
})

test("assigning a rule from a live window records the confirmation immediately", () => {
  const state = Rules.upsert(Rules.emptyState(), "vesktop", "3", false, "vesktop", true)
  assert.equal(Rules.isVerified(state, "vesktop"), true)
})

// Factorio launches from steam://rungameid/427520 but opens a window classed
// com.factorio.Factorio, which showed the one game as two separate rows.
test("an alias folds a guessed class onto the class a real window used", () => {
  let state = Rules.emptyState()
  assert.equal(Rules.resolveAlias(state, "steam_app_427520"), "steam_app_427520")

  state = Rules.putAlias(state, "steam_app_427520", "com.factorio.Factorio")
  assert.equal(Rules.resolveAlias(state, "steam_app_427520"), "com.factorio.Factorio")

  assert.equal(Rules.putAlias(state, "steam_app_427520", "com.factorio.Factorio"), null, "no rewrite when unchanged")
  assert.equal(Rules.putAlias(state, "foot", "foot"), null, "an alias to itself is not an alias")
  assert.equal(Rules.putAlias(state, "", "x"), null)
})

test("aliases and confirmations survive a JSON round trip", () => {
  let state = Rules.putAlias(
    Rules.markVerified(Rules.upsert(Rules.emptyState(), "vesktop", "3", false, "vesktop"), "vesktop"),
    "steam_app_1", "real.Class")
  assert.deepEqual(Rules.normalize(JSON.parse(Rules.toJson(state))), state)
})

test("a schema 3 file loads with no aliases and nothing confirmed", () => {
  const state = Rules.normalize({ version: 3, rules: [{ class: "foot", workspace: "1" }], workspaces: {} })
  assert.deepEqual(state.aliases, {})
  assert.equal(state.rules[0]["verified"], false)
})

test("a schema 4 file loads with autostart off and no command", () => {
  const state = Rules.normalize({ version: 4, rules: [{ class: "foot", workspace: "1" }] })
  assert.equal(state.rules[0]["autostart"], false)
  assert.equal(state.rules[0]["command"], "")
})

// uwsm-app resolves a Desktop Entry ID itself, which handles field codes the way
// the spec says. Spotify's `Exec=spotify --uri=%u` otherwise resolves to an
// argv carrying a stray empty `--uri=`.
test("the launch target is the desktop entry, with argv only as a fallback", () => {
  assert.equal(Rules.launchTarget("spotify", []), "spotify.desktop")
  assert.equal(Rules.launchTarget("spotify.desktop", []), "spotify.desktop")
  assert.equal(Rules.launchTarget("", ["spotify", "--uri="]), "spotify --uri=")
  assert.equal(Rules.launchTarget("", []), "")
})

test("argv is quoted only where a shell would mangle it", () => {
  assert.equal(Rules.shellCommand(["spotify"]), "spotify")
  assert.equal(Rules.shellCommand(["/opt/My App/run", "--flag", "a b"]), "'/opt/My App/run' --flag 'a b'")
  assert.equal(Rules.shellCommand(["it's"]), "'it'\\''s'")
  assert.equal(Rules.shellCommand("already a string"), "already a string")
})

test("autostart needs a command, is remembered, and survives editing the rule", () => {
  let state = Rules.upsert(Rules.emptyState(), "spotify", "4", true, "spotify", true)
  assert.equal(Rules.canAutostart(state, "spotify"), false, "no command yet")

  state = Rules.setAutostart(state, "spotify", true, "spotify.desktop")
  assert.equal(Rules.isAutostart(state, "spotify"), true)
  assert.equal(Rules.canAutostart(state, "spotify"), true)

  state = Rules.upsert(state, "spotify", "5", false, "spotify")
  assert.equal(Rules.isAutostart(state, "spotify"), true, "moving the app must not unset autostart")
  assert.equal(state.rules[0]["command"], "spotify.desktop", "the command is kept")

  state = Rules.setAutostart(state, "spotify", false)
  assert.equal(Rules.isAutostart(state, "spotify"), false)
  assert.equal(Rules.canAutostart(state, "spotify"), true, "turning it off keeps the command")
})

test("the launch block is guarded and skips rules with nothing to launch", () => {
  let state = Rules.upsert(Rules.emptyState(), "foot", "1", false, "foot")
  state = Rules.setAutostart(state, "foot", true)
  assert.ok(!/launch_on_start/.test(Rules.toLua(state)), "no command means no launch line")

  state = Rules.setAutostart(state, "foot", true, "foot.desktop")
  const lua = Rules.toLua(state)
  assert.match(lua, /if type\(o\.launch_on_start\) == "function" then/)
  assert.match(lua, /o\.launch_on_start\("foot\.desktop"\)/)
})

// Regression: markVerified rebuilt the rule from a subset of its fields, so
// confirming a class silently dropped autostart and the command with it.
test("confirming a class keeps every other setting on the rule", () => {
  let state = Rules.setAutostart(
    Rules.upsert(Rules.emptyState(), "spotify", "4", true, "spotify"), "spotify", true, "spotify.desktop")
  state = Rules.markVerified(state, "spotify")

  const rule = Rules.find(state.rules, "spotify")
  assert.equal(rule["verified"], true)
  assert.equal(rule["autostart"], true)
  assert.equal(rule["command"], "spotify.desktop")
  assert.equal(rule["silent"], true)
  assert.equal(rule["workspace"], "4")
})

// Arch's chromium.desktop declares StartupWMClass=@@startup_wm_class, an
// unfilled build placeholder. Trusting it wrote a verified rule for a class
// that no window carries, while the real window is plainly "chromium".
test("a placeholder StartupWMClass is ignored in favour of the desktop id", () => {
  assert.equal(Rules.declaredClass("@@startup_wm_class"), "")
  assert.equal(Rules.declaredClass("  "), "")
  assert.equal(Rules.declaredClass("has space"), "")
  assert.equal(Rules.declaredClass("Brave-browser"), "Brave-browser")
  assert.equal(Rules.declaredClass("org.gnome.Nautilus"), "org.gnome.Nautilus")
  assert.equal(Rules.declaredClass("steam_app_427520"), "steam_app_427520")
  assert.equal(
    Rules.classFromEntry("@@startup_wm_class", "/usr/bin/chromium %U", "chromium.desktop"),
    "chromium")
})

test("a rule stored for a placeholder class is dropped on load", () => {
  const state = Rules.normalize({
    version: 5,
    rules: [
      { class: "@@startup_wm_class", workspace: "6", verified: true },
      { class: "chromium", workspace: "6" }
    ]
  })
  assert.deepEqual(state.rules.map(r => r["class"]), ["chromium"])
})
