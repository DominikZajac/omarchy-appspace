// Runs the generated Lua against a mocked Hyprland, in both workspace modes.
const test = require("node:test")
const assert = require("node:assert/strict")
const childProcess = require("node:child_process")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const Rules = require("../Rules.js")

const haveLua = childProcess.spawnSync("lua", ["-v"]).status === 0
const LG = "LG Electronics MP59G 0x01010101"
const SAM = "Samsung Electric Company Odyssey G52A H4ZT300035"

function buildState() {
  let state = Rules.emptyState()
  state = Rules.setWorkspaceMonitor(state, "1", "desc:" + SAM)
  state = Rules.setWorkspaceMonitor(state, "3", "desc:" + LG)
  state = Rules.upsert(state, "vesktop", "3", true, "vesktop", true)
  state = Rules.upsert(state, "foot", "1", false, "foot", true)
  return Rules.setMonitor(state, "desc:" + LG, { mode: "1920x1080@74.97", x: 2102, y: 575, scale: 1 })
}

const HARNESS = `
local calls = { rules = {}, windows = {}, binds = {}, monitors = {} }
hl = {
  get_monitors = function() if NOMONITORS then return {} end return { { name = "DP-2", description = "${SAM}" }, { name = "DP-3", description = "${LG}" } } end,
  workspace_rule = function(r) calls.rules[#calls.rules + 1] = r end,
  monitor = function(m) calls.monitors[#calls.monitors + 1] = m end,
  on = function() end, dispatch = function() end, get_active_window = function() return nil end,
  dsp = { window = { move = function() end }, focus = function() end },
}
o = {
  window = function(pattern, opts) calls.windows[#calls.windows + 1] = { pattern = pattern, workspace = opts.workspace } end,
  exec_on_start = function() end,
  rebind = function(keys) calls.binds[#calls.binds + 1] = keys end,
  workspaces = PERMONITOR and { workspace_id = function(m, slot) return (m.name == "DP-3" and 10 or 0) + slot end, focus = function() return function() end end } or nil,
}
dofile(arg[1])
local out = {}
for _, r in ipairs(calls.rules) do out[#out + 1] = "rule " .. r.workspace .. " " .. tostring(r.monitor) .. " default=" .. tostring(r.default) end
for _, w in ipairs(calls.windows) do out[#out + 1] = "window " .. w.pattern .. " " .. tostring(w.workspace) end
out[#out + 1] = "binds " .. #calls.binds
out[#out + 1] = "monitors " .. #calls.monitors
print(table.concat(out, "\\n"))
`

function run(globalPlan, perMonitor, atLogin) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "appspace-lua-"))
  fs.mkdirSync(path.join(dir, ".config", "hypr"), { recursive: true })
  if (globalPlan) fs.writeFileSync(path.join(dir, ".config", "hypr", "hyprmoncfg-monitors.lua"), "o.workspaces.enabled = false\n")
  const generated = path.join(dir, "appspace.lua")
  fs.writeFileSync(generated, Rules.toLua(buildState()))
  const harness = path.join(dir, "harness.lua")
  if (atLogin) {
    // Hyprland has not set its monitors up yet; Omarchy's block file from an earlier session is all there is.
    fs.mkdirSync(path.join(dir, ".local", "state", "omarchy"), { recursive: true })
    fs.writeFileSync(path.join(dir, ".local", "state", "omarchy", "monitor-workspaces"),
      "0\tDP-2\t" + SAM + "\n1\tDP-3\t" + LG + "\n")
  }
  fs.writeFileSync(harness, "PERMONITOR = " + perMonitor + "\nNOMONITORS = " + !!atLogin + "\n" + HARNESS)
  const result = childProcess.spawnSync("lua", [harness, generated], { env: { HOME: dir, PATH: process.env.PATH }, encoding: "utf8" })
  fs.rmSync(dir, { recursive: true, force: true })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout
}

test("stock per-monitor Omarchy: slots become the owner's block ids, no monitor pins, keys follow", { skip: !haveLua }, () => {
  const out = run(false, true)
  // each monitor starts on the lowest slot it owns
  assert.match(out, /rule 1 desc:Samsung[^\n]* default=true/)
  assert.match(out, /rule 13 desc:LG[^\n]* default=true/)
  assert.match(out, /window \^vesktop\$ 13 silent/)
  assert.match(out, /window \^foot\$ 1/)
  assert.match(out, /binds 6/)
  assert.match(out, /monitors 1/)
})

test("a global plan (hyprmoncfg): plain ids, and the monitor pin goes to the workspace rule", { skip: !haveLua }, () => {
  const out = run(true, true)
  assert.match(out, /rule 3 desc:LG Electronics[^\n]* default=nil/)
  assert.match(out, /rule 1 desc:Samsung/)
  assert.match(out, /window \^vesktop\$ 3 silent/)
  assert.match(out, /binds 0/)
})

test("older Omarchy without per-monitor workspaces behaves like a global plan", { skip: !haveLua }, () => {
  const out = run(false, false)
  assert.match(out, /rule 3 desc:LG Electronics/)
  assert.match(out, /window \^vesktop\$ 3 silent/)
  assert.match(out, /binds 0/)
})

test("at login, before Hyprland knows its monitors, slots still resolve from Omarchy's block file", { skip: !haveLua }, () => {
  const out = run(false, true, true)
  assert.match(out, /rule 13 desc:LG[^\n]* default=true/)
  assert.match(out, /window \^vesktop\$ 13 silent/)
  assert.match(out, /window \^foot\$ 1/)
})
