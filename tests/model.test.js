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

// Switching a freshly added workspace to "on demand" used to drop its entry,
// and with it the row: a workspace above 5 with nothing on it had no reason
// to be listed. It now stays until removed on purpose.
test("a workspace with neither a monitor nor persistence stays listed but generates no rule", () => {
  const state = Rules.normalize({
    version: 3,
    rules: [],
    workspaces: { "6": { monitor: "", persistent: false } }
  })
  assert.deepEqual(state.workspaces, { "6": { monitor: "", persistent: false } })
  assert.ok(Rules.workspaceIsEmpty(state.workspaces["6"]))
  assert.match(Rules.toLua(state), /-- Workspace rules[^\n]*\n-- \(none\)/)

  let cleared = Rules.setWorkspacePersistent(Rules.setWorkspaceMonitor(Rules.emptyState(), "6", "desc:X"), "6", false)
  assert.equal(Rules.workspaceMonitor(cleared, "6"), "desc:X")
  cleared = Rules.setWorkspaceMonitor(cleared, "6", "")
  assert.deepEqual(Rules.sortedWorkspaceNames(cleared), ["6"], "still listed")
  assert.deepEqual(Rules.removeWorkspace(cleared, "6").workspaces, {})
})

test("removing a workspace also drops the rules pinned to it, and nothing else", () => {
  let state = Rules.upsert(Rules.upsert(Rules.emptyState(), "vesktop", "6", false, "Vesktop"), "foot", "2", false, "Foot")
  state = Rules.setWorkspaceMonitor(state, "6", "desc:LG")
  const next = Rules.removeWorkspace(state, "6")
  assert.deepEqual(next.workspaces, {})
  assert.deepEqual(next.rules.map(r => r["class"]), ["foot"])
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
  const file = path.join(fs.mkdtempSync("/tmp/appspace-"), "generated.lua")
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
  assert.match(lua, /if type\(o\.exec_on_start\) == "function" then/)
  assert.match(lua, /o\.exec_on_start\("uwsm-app -- foot\.desktop"\)/, "an app that does not start itself is launched directly")
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

// Flatpak exports copy StartupWMClass from upstream, but the sandboxed window
// carries the Flatpak app id, which is the desktop id.
test("a flatpak entry uses its app id even when it declares another class", () => {
  const exec = "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=com.discordapp.Discord com.discordapp.Discord"
  assert.equal(Rules.isFlatpakExec(exec), true)
  assert.equal(Rules.isFlatpakExec("/usr/bin/discord"), false)
  assert.equal(Rules.classFromEntry("discord", exec, "com.discordapp.Discord.desktop"), "com.discordapp.Discord")
})

// Omarchy's TUI launchers name the terminal window on the command line.
test("a terminal launcher's app id is the class", () => {
  assert.equal(Rules.terminalAppId("xdg-terminal-exec --app-id=TUI.tile -e lazydocker"), "TUI.tile")
  assert.equal(Rules.terminalAppId("xdg-terminal-exec --app-id TUI.float -e bash -c \"dua i /\""), "TUI.float")
  assert.equal(Rules.terminalAppId("omarchy-launch-tui btop"), "org.omarchy.btop")
  assert.equal(Rules.terminalAppId("omarchy-launch-tui --app-id=mon -e btop"), "mon")
  assert.equal(Rules.terminalAppId("btop"), "")
  assert.equal(Rules.classFromEntry("", "xdg-terminal-exec --app-id=TUI.tile -e lazydocker", "Docker.desktop"), "TUI.tile")
})

// Chromium names an --app window after the URL: host, "_", path with "/"
// turned into "_", wrapped in the product name and the profile.
test("a web app's class is derived from its URL and the default browser", () => {
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://chatgpt.com/", "chrome"), "chrome-chatgpt.com__-Default")
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://github.com/", "brave"), "brave-github.com__-Default")
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://launchpad.37signals.com", "chrome"), "chrome-launchpad.37signals.com__-Default")
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://messages.google.com/web/conversations", "chrome"),
    "chrome-messages.google.com__web_conversations-Default")
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://x.com/?lang=en", "chrome"), "chrome-x.com__-Default")
  assert.equal(Rules.webappClass("omarchy-launch-webapp https://chatgpt.com/", ""), "", "no prefix known yet")
  assert.equal(Rules.webappClass("brave https://chatgpt.com/", "brave"), "", "a plain browser launch is not a web app")
  assert.equal(Rules.classFromEntry("", "omarchy-launch-webapp https://chatgpt.com/", "ChatGPT.desktop", "chrome"), "chrome-chatgpt.com__-Default")
  assert.equal(Rules.classFromEntry("", "omarchy-launch-webapp https://chatgpt.com/", "ChatGPT.desktop", ""), "ChatGPT")
})

test("the browser prefix follows omarchy-launch-webapp's choice of browser", () => {
  assert.equal(Rules.browserPrefix("chromium.desktop"), "chrome")
  assert.equal(Rules.browserPrefix("google-chrome.desktop"), "chrome")
  assert.equal(Rules.browserPrefix("brave-browser.desktop"), "brave")
  assert.equal(Rules.browserPrefix("microsoft-edge.desktop"), "msedge")
  assert.equal(Rules.browserPrefix("firefox.desktop"), "chrome", "non-Chromium defaults fall back to chromium")
  assert.equal(Rules.browserPrefix(""), "chrome")
})

// brave-browser.desktop declares "brave-browser"; the window is "Brave-browser".
// Confirming the rule without fixing its spelling left "^brave-browser$" in
// the Lua, which never matched.
test("a live window with different casing respells the rule and keeps its settings", () => {
  let state = Rules.setAutostart(
    Rules.upsert(Rules.emptyState(), "brave-browser", "4", true, "Brave"), "brave-browser", true, "brave-browser.desktop")
  const next = Rules.respell(state, "Brave-browser")
  assert.equal(next.rules.length, 1)
  const rule = next.rules[0]
  assert.equal(rule["class"], "Brave-browser")
  assert.equal(rule["workspace"], "4")
  assert.equal(rule["silent"], true)
  assert.equal(rule["label"], "Brave")
  assert.equal(rule["verified"], true)
  assert.equal(rule["autostart"], true)
  assert.equal(rule["command"], "brave-browser.desktop")
  assert.match(Rules.toLua(next), /o\.window\("\^Brave-browser\$"/)

  assert.equal(Rules.respell(next, "Brave-browser"), null, "no rewrite once the spelling agrees")
  assert.equal(Rules.respell(next, "never-seen"), null)
})

// Factorio's launcher entry guesses steam_app_427520; the window is
// com.factorio.Factorio. Learning the alias folded the rows but left the rule
// on the guess, so the real window had no rule and the guess lingered as an
// orphan.
test("a learned alias carries the rule over to the real class", () => {
  let state = Rules.setAutostart(
    Rules.upsert(Rules.emptyState(), "steam_app_427520", "9", true, "Factorio"),
    "steam_app_427520", true, "Factorio.desktop")
  const next = Rules.migrateRule(state, "steam_app_427520", "com.factorio.Factorio")
  assert.deepEqual(next.rules.map(r => r["class"]), ["com.factorio.Factorio"])
  const rule = next.rules[0]
  assert.equal(rule["workspace"], "9")
  assert.equal(rule["silent"], true)
  assert.equal(rule["label"], "Factorio")
  assert.equal(rule["verified"], true)
  assert.equal(rule["autostart"], true)
  assert.equal(rule["command"], "Factorio.desktop")

  assert.equal(Rules.migrateRule(next, "steam_app_427520", "com.factorio.Factorio"), null, "nothing left to move")
  assert.equal(Rules.migrateRule(state, "steam_app_1", "x"), null, "no rule for the guess")
  const both = Rules.upsert(state, "com.factorio.Factorio", "2", false, "Factorio")
  assert.equal(Rules.migrateRule(both, "steam_app_427520", "com.factorio.Factorio"), null,
    "a rule on the real class is never overwritten")
})

// 1Password installs ~/.config/autostart/1password.desktop for itself. At
// login that entry and our launch line raced within the same second, and
// whichever lost closed on the single-instance lock.
test("only a binary that identifies the app is used to tell whether it is running", () => {
  assert.equal(Rules.guardBinary("/opt/1Password/1password %U"), "1password")
  assert.equal(Rules.guardBinary("\"/opt/My App/app\" %F"), "app")
  assert.equal(Rules.guardBinary("spotify --uri=%u"), "spotify")
  assert.equal(Rules.guardBinary("/usr/lib/some-very-long-binary-name"), "some-very-long-", "cut to the 15 characters the kernel keeps")
  assert.equal(Rules.guardBinary("steam steam://rungameid/427520"), "", "a Steam game is not the Steam client")
  assert.equal(Rules.guardBinary("/usr/bin/flatpak run com.discordapp.Discord"), "")
  assert.equal(Rules.guardBinary("omarchy-launch-webapp https://chatgpt.com/"), "")
  assert.equal(Rules.guardBinary("xdg-terminal-exec --app-id=TUI.tile -e lazydocker"), "")
  assert.equal(Rules.guardBinary(""), "")
})

test("the launch line launches plainly unless the app starts itself", () => {
  assert.equal(Rules.launchCommand("foot.desktop", []), "uwsm-app -- foot.desktop")
  assert.equal(Rules.launchCommand("foot.desktop"), "uwsm-app -- foot.desktop")
  assert.equal(Rules.launchCommand("1password.desktop", ["1password"]),
    "sleep 2; pgrep -x -- 1password >/dev/null || uwsm-app -- 1password.desktop")
  assert.equal(Rules.launchCommand("spotify.desktop", ["spotify", "spotify-client", "spotify"]),
    "sleep 2; pgrep -x -- spotify >/dev/null || pgrep -x -- spotify-client >/dev/null || uwsm-app -- spotify.desktop",
    "duplicates are dropped")
})

test("launch targets and process names are shell-quoted", () => {
  // Steam writes "Slay the Spire 2.desktop"; a bare target would be split by the shell.
  assert.equal(Rules.launchCommand("Slay the Spire 2.desktop", []), "uwsm-app -- 'Slay the Spire 2.desktop'")
  assert.equal(Rules.launchCommand("x;rm -rf ~.desktop", ["a;b"]),
    "sleep 2; pgrep -x -- 'a;b' >/dev/null || uwsm-app -- 'x;rm -rf ~.desktop'")
})

test("the generated Lua guards only the apps it was told start themselves", () => {
  let state = Rules.setAutostart(
    Rules.upsert(Rules.upsert(Rules.emptyState(), "spotify", "4", false, "Spotify"), "foot", "1", false, "Foot"),
    "spotify", true, "spotify.desktop")
  state = Rules.setAutostart(state, "foot", true, "foot.desktop")
  const lua = Rules.toLua(state, { "spotify": ["spotify"] })
  assert.match(lua, /o\.exec_on_start\("sleep 2; pgrep -x -- spotify >\/dev\/null \|\| uwsm-app -- spotify\.desktop"\)/)
  assert.match(lua, /o\.exec_on_start\("uwsm-app -- foot\.desktop"\)/)
})

test("autostart entries are parsed, user overrides system, hidden and foreign-desktop ones drop out", () => {
  const text = [
    "1password.desktop\t\t\t\t/opt/1Password/1password --silent",
    "gnome-thing.desktop\t\tGNOME;\t\tgnome-thing",
    "not-here.desktop\t\t\tHyprland;\tnot-here",
    "old.desktop\tfalse\t\t\told",
    "old.desktop\ttrue\t\t\told",
    "quoted.desktop\t\t\t\t\"/opt/My App/app\" --flag"
  ].join("\n")
  const entries = Rules.parseAutostart(text, "Hyprland")
  assert.deepEqual(entries.map(e => e.basename).sort(), ["1password.desktop", "quoted.desktop"])

  assert.equal(Rules.ownAutostartFor(entries, "1password.desktop", "/opt/1Password/1password %U"), "1password.desktop", "by name")
  assert.equal(Rules.ownAutostartFor(entries, "com.onepassword.OnePassword.desktop", "/opt/1Password/1password %U"), "1password.desktop", "by binary")
  assert.equal(Rules.ownAutostartFor(entries, "myapp.desktop", "\"/opt/My App/app\" %F"), "quoted.desktop", "quoted binary")
  assert.equal(Rules.ownAutostartFor(entries, "foot.desktop", "foot"), "")
  const withSteam = entries.concat([{ basename: "steam.desktop", exec: "/usr/bin/steam -silent", hidden: false }])
  assert.equal(Rules.ownAutostartFor(withSteam, "Factorio.desktop", "steam steam://rungameid/427520"), "",
    "a Steam game does not start itself just because the Steam client does")
  assert.equal(Rules.ownAutostartFor(withSteam, "steam.desktop", "/usr/bin/steam %U"), "steam.desktop")
  assert.deepEqual(Rules.guardBinaries(entries, "1password.desktop", "/opt/1Password/1password %U"), ["1password"])
  assert.deepEqual(Rules.guardBinaries(
    [{ basename: "sp.desktop", exec: "spotify-launcher --minimized" }], "sp.desktop", "spotify %U"),
    ["spotify", "spotify-launche"], "the autostart binary is cut the same way")
  assert.equal(Rules.ownAutostartFor([], "foot.desktop", "foot"), "")
})

// "AU · 1" told nobody which screen that was.
test("monitors are named by connector and vendor, with a position only when there are several", () => {
  assert.equal(Rules.connectorLabel("eDP-1"), "Laptop screen")
  assert.equal(Rules.connectorLabel("DP-2"), "DisplayPort 2")
  assert.equal(Rules.connectorLabel("HDMI-A-1"), "HDMI 1")
  assert.equal(Rules.connectorLabel("DVI-D-1"), "DVI 1")
  assert.equal(Rules.connectorLabel("Virtual-1"), "Virtual-1")

  assert.equal(Rules.monitorVendor("AU Optronics 0x82ED"), "AU Optronics")
  assert.equal(Rules.monitorVendor("LG Electronics MP59G 0x01010101"), "LG Electronics")
  assert.equal(Rules.monitorVendor("Dell Inc. U2720Q 7XKFD93"), "Dell Inc.")
  assert.equal(Rules.monitorVendor("Samsung Electric Company Odyssey G9 H1AK500000"), "Samsung Electric")
  assert.equal(Rules.monitorVendor(""), "")

  const laptop = { name: "eDP-1", description: "AU Optronics 0x82ED", x: 0, y: 0 }
  assert.equal(Rules.monitorLabel([laptop], 0), "Laptop screen")

  const two = [laptop, { name: "DP-2", description: "LG Electronics MP59G 0x01010101", x: 1920, y: 0 }]
  assert.equal(Rules.monitorLabel(two, 0), "Laptop screen · left")
  assert.equal(Rules.monitorLabel(two, 1), "LG Electronics (DisplayPort 2) · right")

  const three = two.concat([{ name: "HDMI-A-1", description: "Dell Inc. U2720Q X", x: 4480, y: 0 }])
  assert.equal(Rules.monitorLabel(three, 1), "LG Electronics (DisplayPort 2) · middle")
  assert.equal(Rules.monitorLabel(three, 2), "Dell Inc. (HDMI 1) · right")

  const stacked = [{ name: "DP-1", description: "LG Electronics A 1", x: 0, y: 0 }, { name: "DP-2", description: "LG Electronics B 2", x: 0, y: 1440 }]
  assert.equal(Rules.monitorLabel(stacked, 0), "LG Electronics (DisplayPort 1) · top")
  assert.equal(Rules.monitorLabel(stacked, 1), "LG Electronics (DisplayPort 2) · bottom")
})

// Reported during marketplace review: a window class or app name with a
// newline ended the "-- label" comment and ran the rest as Lua on reload.
test("labels cannot break out of the Lua comment they are written into", () => {
  assert.equal(Rules.luaComment("Foot"), "Foot")
  assert.equal(Rules.luaComment("evil\nhl.exec_cmd('rm -rf ~')"), "evil hl.exec_cmd('rm -rf ~')")
  assert.equal(Rules.luaComment("a\r\n\tb\u2028c"), "a b c")
  assert.equal(Rules.luaComment("x".repeat(100)).length, 80)

  let state = Rules.upsert(Rules.emptyState(), "evil\nhl.exec_cmd('touch /tmp/pwned')", "3", false,
    "label\nhl.exec_cmd('touch /tmp/pwned')")
  state = Rules.setAutostart(state, "evil\nhl.exec_cmd('touch /tmp/pwned')", true, "evil\n.desktop")
  const lua = Rules.toLua(state)
  const code = lua.split("\n").filter(l => !/^\s*--/.test(l) && l.trim().length > 0)
  assert.ok(code.every(l => !/touch \/tmp\/pwned/.test(l) || /^\s*o\.(window|exec_on_start)\(/.test(l)),
    "the payload only ever appears inside a quoted string on a rule line")
  assert.ok(!/\nhl\.exec_cmd/.test(lua), "no line starts with injected code")
  assert.match(lua, /o\.window\("\^evil\\nhl/, "the class is escaped inside the pattern string")
})

// ------------------------------------------------------------------ launch without a workspace, and startup-only placement

test("an app can launch at login with no workspace, and the rule goes when nothing is left on it", () => {
  let state = Rules.setAutostart(Rules.emptyState(), "spotify", true, "spotify.desktop", "Spotify")
  assert.equal(state.rules.length, 1)
  assert.equal(state.rules[0]["workspace"], "")
  assert.equal(state.rules[0]["autostart"], true)
  assert.equal(state.rules[0]["label"], "Spotify")
  assert.equal(Rules.isAutostart(state, "spotify"), true)

  // No window rule is generated for an app that is not placed, but it launches.
  const lua = Rules.toLua(state)
  assert.ok(!/o\.window\(/.test(lua))
  assert.match(lua, /o\.exec_on_start\("uwsm-app -- spotify\.desktop"\)/)

  assert.deepEqual(Rules.setAutostart(state, "spotify", false).rules, [], "off with no workspace leaves nothing")

  // Placing it later keeps the launch setting, and un-placing keeps it too.
  state = Rules.upsert(state, "spotify", "4", false, "Spotify")
  assert.equal(state.rules[0]["workspace"], "4")
  assert.equal(state.rules[0]["autostart"], true)
  state = Rules.upsert(state, "spotify", "", false, "Spotify")
  assert.equal(state.rules.length, 1, "still launches, so the rule stays")
  assert.equal(state.rules[0]["workspace"], "")
  state = Rules.setAutostart(state, "spotify", false)
  assert.deepEqual(state.rules, [])
})

test("choosing Any for an app that does not launch removes its rule", () => {
  let state = Rules.upsert(Rules.emptyState(), "foot", "2", false, "Foot")
  assert.equal(state.rules.length, 1)
  state = Rules.upsert(state, "foot", "", false, "Foot")
  assert.deepEqual(state.rules, [])
})

test("startup-only needs a workspace and carries its time window", () => {
  let state = Rules.upsert(Rules.emptyState(), "brave", "3", true, "Brave")
  assert.equal(state.rules[0]["startupOnly"], false)
  assert.equal(state.rules[0]["startupWindow"], Rules.DEFAULT_STARTUP_WINDOW)
  assert.equal(Rules.DEFAULT_STARTUP_WINDOW, 20)
  assert.equal(state.rules[0]["startupCount"], undefined, "there is no window count")

  state = Rules.setStartupOnly(state, "brave", true, 45)
  assert.deepEqual([state.rules[0]["startupOnly"], state.rules[0]["startupWindow"]], [true, 45])
  state = Rules.setStartupOnly(state, "brave", true)
  assert.equal(state.rules[0]["startupWindow"], 45, "leaving the seconds out keeps them")

  // Moving the workspace keeps the setting; removing the workspace switches it off.
  state = Rules.upsert(state, "brave", "5", true, "Brave")
  assert.equal(state.rules[0]["startupOnly"], true)
  state = Rules.setAutostart(state, "brave", true, "brave.desktop")
  state = Rules.upsert(state, "brave", "", true, "Brave")
  assert.equal(state.rules[0]["startupOnly"], false)
  assert.equal(state.rules[0]["autostart"], true)

  // With nothing to apply, the switch is a no-op rather than an error.
  assert.equal(Rules.setStartupOnly(state, "brave", true), state)

  // Out-of-range values are clamped, junk falls back to the default.
  let clamped = Rules.upsert(Rules.emptyState(), "x", "1", false, "x")
  clamped = Rules.setStartupOnly(clamped, "x", true, -5)
  assert.equal(clamped.rules[0]["startupWindow"], 1)
  clamped = Rules.setStartupOnly(clamped, "x", true, "abc")
  assert.equal(clamped.rules[0]["startupWindow"], Rules.DEFAULT_STARTUP_WINDOW)
})

test("every rule field survives every transformation", () => {
  let state = Rules.upsert(Rules.emptyState(), "brave", "3", true, "Brave", false, "brave.desktop")
  state = Rules.setAutostart(state, "brave", true)
  state = Rules.setStartupOnly(state, "brave", true, 30)
  const expected = { class: "brave", workspace: "3", silent: true, label: "Brave", autostart: true,
    command: "brave.desktop", startupOnly: true, startupWindow: 30 }
  const pick = r => Object.fromEntries(Object.keys(expected).map(k => [k, r[k]]))

  assert.deepEqual(pick(Rules.markVerified(state, "brave").rules[0]), expected)
  assert.deepEqual(pick(Rules.upsert(state, "brave", "3", true, "Brave").rules[0]), expected)
  assert.deepEqual(pick(Rules.migrateRule(state, "brave", "Brave-browser").rules[0]), { ...expected, class: "Brave-browser" })
  assert.deepEqual(pick(Rules.respell(state, "BRAVE").rules[0]), { ...expected, class: "BRAVE" })
  assert.deepEqual(pick(Rules.normalize(JSON.parse(Rules.toJson(state))).rules[0]), expected)
})

test("a rule file from before this version loads with startup-only off", () => {
  const state = Rules.normalize({ version: 5, rules: [{ class: "foot", workspace: "2", silent: true, autostart: true, command: "foot.desktop" }] })
  const rule = state.rules[0]
  assert.equal(rule["startupOnly"], false)
  assert.equal(rule["startupWindow"], 20)
  assert.equal(rule["autostart"], true)
  // A rule with no workspace and no launch is meaningless and is not kept.
  assert.deepEqual(Rules.normalize({ rules: [{ class: "x", workspace: "" }] }).rules, [])
})

test("removing a workspace unplaces an app that launches at login instead of forgetting it", () => {
  let state = Rules.setAutostart(Rules.upsert(Rules.emptyState(), "brave", "6", false, "Brave"), "brave", true, "brave.desktop")
  state = Rules.upsert(state, "foot", "6", false, "Foot")
  const next = Rules.removeWorkspace(state, "6")
  assert.deepEqual(next.rules.map(r => [r["class"], r["workspace"], r["autostart"]]), [["brave", "", true]])
})

test("generated Lua has a permanent rule or a startup placement, never both", () => {
  let state = Rules.upsert(Rules.emptyState(), "foot", "2", false, "Foot")
  state = Rules.upsert(state, "evil\nhl.exec_cmd('x')", "3", true, "label\nhl.exec_cmd('x')")
  state = Rules.setStartupOnly(state, "evil\nhl.exec_cmd('x')", true, 30)
  const lua = Rules.toLua(state)
  assert.match(lua, /o\.window\("\^foot\$", \{ workspace = "2" \}\)/)
  const evilRules = lua.split("\n").filter(l => /o\.window\("\^evil/.test(l))
  assert.equal(evilRules.length, 0, "a startup-only app has no permanent rule")
  assert.match(lua, /\{ class = "evil\\nhl\.exec_cmd\('x'\)", workspace = "3", follow = false, within = 30 \},/)
  assert.ok(!/\nhl\.exec_cmd/.test(lua), "no injected line")
  assert.ok(!/placements/.test(Rules.toLua(Rules.upsert(Rules.emptyState(), "foot", "2", false, "Foot"))),
    "no handler when nothing is startup-only")
})

// The startup handler is run for real against a fake /proc and a fake Hyprland,
// since a string match cannot tell whether the time arithmetic is right.
test("startup placement moves every window of the app opened within its seconds, and none after", (t) => {
  let lua
  try {
    lua = childProcess.execFileSync("sh", ["-c", "command -v lua5.4 || command -v lua"], { encoding: "utf8" }).trim()
  } catch (e) {
    return t.skip("lua not installed")
  }
  let state = Rules.upsert(Rules.emptyState(), "Brave-browser", "3", true, "Brave")
  state = Rules.setStartupOnly(state, "Brave-browser", true, 20)
  state = Rules.upsert(state, "mpv", "4", false, "mpv")
  state = Rules.setStartupOnly(state, "mpv", true, 5)
  const dir = fs.mkdtempSync("/tmp/appspace-lua-")
  fs.writeFileSync(path.join(dir, "generated.lua"), Rules.toLua(state))
  fs.writeFileSync(path.join(dir, "harness.lua"), `
    local handlers, moves = {}, {}
    hl = {
      on = function(event, fn) handlers[event] = fn end,
      dispatch = function(d) moves[#moves + 1] = d end,
      window_rule = function() end, workspace_rule = function() end,
      dsp = { window = { move = function(t) return t end } },
    }
    o = { window = function() end, exec_on_start = function() end }

    local uptime, started = 1000.0, 99000  -- compositor started 10 s ago
    local real_open = io.open
    io.open = function(name, mode)
      local content
      if name == "/proc/uptime" then content = string.format("%.2f 0.00\\n", uptime)
      elseif name == "/proc/self/stat" then
        -- the command name has spaces and a bracket, to prove parsing counts from the last ")"
        content = "123 (Hypr (x) land) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 " .. started .. " 22 23\\n"
      end
      if not content then return real_open(name, mode) end
      return { read = function() return content:gsub("\\n$", "") end, close = function() end }
    end

    dofile("${path.join(dir, "generated.lua")}")
    local function open(class, address)
      handlers["window.open"]({ class = class, address = address })
    end
    local function result() local s = {} for _, m in ipairs(moves) do s[#s + 1] = m.window .. "->" .. m.workspace .. ":" .. tostring(m.follow) end return table.concat(s, ",") end

    open("Brave-browser", "0x1")   -- placed
    open("firefox", "0x2")         -- not a startup app
    open("Brave-browser", "0x3")   -- placed too: there is no window count
    open("BRAVE-BROWSER", "0x4")   -- case does not matter
    open("mpv", "0x5")             -- mpv's window is 5 s and 10 s have passed: not placed
    print(result())

    uptime = 1000.0 + 15           -- 25 s since start: past Brave's 20 s window
    moves = {}
    open("Brave-browser", "0x7")
    print("late:" .. result())

    -- A config reload re-runs this file. Nothing carries over that could re-arm it.
    dofile("${path.join(dir, "generated.lua")}")
    open("Brave-browser", "0x8")
    print("after reload:" .. result())
  `)
  const out = childProcess.execFileSync(lua, [path.join(dir, "harness.lua")], { encoding: "utf8" }).trim().split("\n")
  assert.equal(out[0], "address:0x1->3:false,address:0x3->3:false,address:0x4->3:false")
  assert.equal(out[1], "late:", "nothing is placed after the window has passed")
  assert.equal(out[2], "after reload:", "a reload does not give the app more time")
})

test("startup placement matches the class without regard to case", (t) => {
  let lua
  try { lua = childProcess.execFileSync("sh", ["-c", "command -v lua5.4 || command -v lua"], { encoding: "utf8" }).trim() }
  catch (e) { return t.skip("lua not installed") }
  let state = Rules.upsert(Rules.emptyState(), "brave-browser", "3", false, "Brave")
  state = Rules.setStartupOnly(state, "brave-browser", true, 20)
  const dir = fs.mkdtempSync("/tmp/appspace-lua-")
  fs.writeFileSync(path.join(dir, "g.lua"), Rules.toLua(state))
  fs.writeFileSync(path.join(dir, "h.lua"), `
    local handler, moves = nil, 0
    hl = { on = function(_, fn) handler = fn end, dispatch = function() moves = moves + 1 end,
           window_rule = function() end, workspace_rule = function() end,
           dsp = { window = { move = function(t) return t end } } }
    o = { window = function() end, exec_on_start = function() end }
    local real = io.open
    io.open = function(n, m)
      local c = (n == "/proc/uptime") and "100.00 0\\n" or (n == "/proc/self/stat") and "1 (h) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 9500 22\\n" or nil
      if not c then return real(n, m) end
      return { read = function() return (c:gsub("\\n$", "")) end, close = function() end }
    end
    dofile("${path.join(dir, "g.lua")}")
    handler({ class = "Brave-browser", address = "0x1" })
    handler({ class = nil, address = "0x2" })
    print(moves)
  `)
  assert.equal(childProcess.execFileSync(lua, [path.join(dir, "h.lua")], { encoding: "utf8" }).trim(), "1")
})

test("an unplaced app can still open silently, and that rule disappears when switched off", () => {
  let state = Rules.upsert(Rules.emptyState(), "spotify", "", true, "Spotify")
  assert.equal(state.rules.length, 1, "silent alone is worth keeping")
  const lua = Rules.toLua(state)
  assert.match(lua, /o\.window\("\^spotify\$", \{ no_initial_focus = true \}\)  -- Spotify/)
  assert.ok(!/workspace = /.test(lua.split("\n").filter(l => /o\.window/.test(l)).join("\n")), "no workspace in it")

  // Placing it turns the same setting into the ordinary "silent" workspace rule.
  const placed = Rules.upsert(state, "spotify", "4", true, "Spotify")
  assert.match(Rules.toLua(placed), /workspace = "4 silent"/)
  assert.ok(!/no_initial_focus/.test(Rules.toLua(placed)))

  assert.deepEqual(Rules.upsert(state, "spotify", "", false, "Spotify").rules, [])
  const launches = Rules.setAutostart(state, "spotify", true, "spotify.desktop")
  assert.equal(Rules.upsert(launches, "spotify", "", false, "Spotify").rules.length, 1, "still launches")
})

// ~/.local/share/applications/bssh.desktop held only "Hidden=true": launching it
// failed with "Key 'Type' is missing" at every login.
test("apps hidden by a user stub are recognised by desktop id", () => {
  const hidden = Rules.parseHiddenEntries("bssh.desktop\n\nbvnc.desktop\n  avahi-discover.desktop  \n")
  assert.equal(hidden["bssh"], true)
  assert.equal(hidden["bvnc"], true)
  assert.equal(hidden["avahi-discover"], true)
  assert.equal(hidden["foot"], undefined)
  assert.deepEqual(Rules.parseHiddenEntries(""), {})
})

// ------------------------------------------------------------------ update check

test("update-check settings default on, round-trip and can be switched off", () => {
  assert.equal(Rules.updateCheckEnabled(Rules.emptyState()), true)
  assert.equal(Rules.updateCheckEnabled(null), true)
  const off = Rules.setUpdateCheck(Rules.emptyState(), false)
  assert.equal(Rules.updateCheckEnabled(off), false)
  assert.equal(Rules.updateCheckEnabled(Rules.normalize(JSON.parse(Rules.toJson(off)))), false)
  assert.equal(Rules.updateCheckEnabled(Rules.normalize({ rules: [] })), true, "an old file has no setting")
  assert.equal(Rules.updateCheckEnabled(Rules.setUpdateCheck(off, true)), true)
  // Unrelated edits must not lose the setting.
  const edited = Rules.upsert(off, "foot", "2", false, "Foot")
  assert.equal(Rules.updateCheckEnabled(edited), false)
  assert.equal(Rules.updateCheckEnabled(Rules.removeWorkspace(edited, "2")), false)
})

test("the probe's answer is one of four words and anything else is unknown", () => {
  assert.equal(Rules.parseUpdateProbe("current\n"), "current")
  assert.equal(Rules.parseUpdateProbe("  available "), "available")
  assert.equal(Rules.parseUpdateProbe("unmanaged"), "unmanaged")
  assert.equal(Rules.parseUpdateProbe("unknown"), "unknown")
  assert.equal(Rules.parseUpdateProbe(""), "unknown")
  assert.equal(Rules.parseUpdateProbe("sh: git: not found"), "unknown")
  assert.equal(Rules.parseUpdateProbe("rm -rf ~"), "unknown")
})

test("times read as a person would say them", () => {
  const min = 60000
  assert.equal(Rules.relativeTime(0, 5000), "just now")
  assert.equal(Rules.relativeTime(0, 44000), "just now")
  assert.equal(Rules.relativeTime(0, 60 * 1000), "1 minute ago")
  assert.equal(Rules.relativeTime(0, 23 * min), "23 minutes ago")
  assert.equal(Rules.relativeTime(0, 59 * min), "59 minutes ago")
  assert.equal(Rules.relativeTime(0, 60 * min), "1 hour ago")
  assert.equal(Rules.relativeTime(0, 5 * 60 * min), "5 hours ago")
  assert.equal(Rules.relativeTime(0, 24 * 60 * min), "1 day ago")
  assert.equal(Rules.relativeTime(0, 3 * 24 * 60 * min), "3 days ago")
  assert.equal(Rules.relativeTime(10000, 0), "just now", "a clock that went backwards does not print nonsense")
})

test("the panel's status line says what happened and what can be done", () => {
  const now = 100 * 60000
  const at = now - 23 * 60000
  assert.deepEqual(Rules.updateSummary({ state: "current", checkedAt: at }, now, true),
    { text: "No updates · checked 23 minutes ago", canCheck: true, canUpdate: false })
  assert.deepEqual(Rules.updateSummary({ state: "available", checkedAt: at }, now, true),
    { text: "Update available · checked 23 minutes ago", canCheck: true, canUpdate: true })
  assert.deepEqual(Rules.updateSummary({ state: "unknown", checkedAt: at }, now, true),
    { text: "Couldn’t check · tried 23 minutes ago", canCheck: true, canUpdate: false })
  assert.deepEqual(Rules.updateSummary({ state: "checking", checkedAt: at }, now, true),
    { text: "Checking for updates…", canCheck: false, canUpdate: false })
  assert.equal(Rules.updateSummary({ state: "unmanaged", checkedAt: 0 }, now, true).text, "", "nothing to show for a non-git install")
  assert.equal(Rules.updateSummary({ state: "pending", checkedAt: 0 }, now, true).text, "Not checked yet")
  assert.equal(Rules.updateSummary({ state: "pending", checkedAt: 0 }, now, false).text, "Update checks are off")
  assert.equal(Rules.updateSummary(null, now, true).canCheck, true)
})

// The check script is run for real against throwaway repositories, so each
// verdict comes from git rather than from a string match.
test("update-check.sh answers current, available, unmanaged and unknown from real repositories", (t) => {
  try { childProcess.execFileSync("git", ["--version"], { stdio: "ignore" }) } catch (e) { return t.skip("git not installed") }
  const script = path.join(__dirname, "..", "update-check.sh")
  const root = fs.mkdtempSync("/tmp/appspace-update-")
  const git = (cwd, ...args) => childProcess.execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ...args],
    { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()
  const check = (dir) => childProcess.execFileSync("sh", [script, "check", dir], { encoding: "utf8" }).trim()
  const commit = (dir, name) => { fs.writeFileSync(path.join(dir, name), name); git(dir, "add", "."); git(dir, "commit", "-q", "-m", name) }

  const origin = path.join(root, "origin"); fs.mkdirSync(origin)
  git(origin, "init", "-q", "-b", "main"); commit(origin, "one")
  const plugin = path.join(root, "plugin")
  git(root, "clone", "-q", origin, plugin)

  assert.equal(check(plugin), "current", "same commit")

  commit(origin, "two")
  assert.equal(check(plugin), "available", "origin has a commit the checkout lacks")

  git(plugin, "pull", "-q", "--ff-only")
  assert.equal(check(plugin), "current", "after updating")

  commit(plugin, "local-only")
  assert.equal(check(plugin), "current", "a checkout ahead of origin is not nagged")

  // Diverged: origin has something this checkout does not contain.
  commit(origin, "three")
  assert.equal(check(plugin), "available")

  assert.equal(check(root), "unmanaged", "not a git checkout")

  git(plugin, "remote", "set-url", "origin", path.join(root, "does-not-exist"))
  assert.equal(check(plugin), "unknown", "remote unreachable")

  // The check writes nothing: no new refs or objects came from asking.
  git(plugin, "remote", "set-url", "origin", origin)
  const before = git(plugin, "count-objects", "-v") + git(plugin, "for-each-ref")
  check(plugin)
  assert.equal(git(plugin, "count-objects", "-v") + git(plugin, "for-each-ref"), before)
})

// A window's class (its app_id) is chosen by the client, and the panel lists it.
// Qt's default text format auto-detects markup, so a class like
// <img src="http://..."> made the shell fetch that URL. Every Text element in the
// panel therefore pins plain text; Omarchy's own components already do.
test("every Text element in the panel renders plain text", () => {
  const qml = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")
  const offenders = []
  for (const m of qml.matchAll(/(?<![A-Za-z0-9_.])Text\s*\{/g)) {
    let depth = 1, i = m.index + m[0].length
    while (depth > 0 && i < qml.length) { depth += (qml[i] === "{") - (qml[i] === "}"); i++ }
    const block = qml.slice(m.index, i)
    if (!/textFormat:\s*Text\.PlainText/.test(block)) {
      offenders.push("line " + (qml.slice(0, m.index).split("\n").length))
    }
  }
  assert.deepEqual(offenders, [], "Text without textFormat: Text.PlainText")
})
