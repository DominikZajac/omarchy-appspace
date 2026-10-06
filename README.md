# AppSpace

![AppSpace](preview.png)

An Omarchy bar widget that manages where apps open: which workspace, and on
which monitor — without hand-editing the Hyprland config.

Click the monitor icon on the bar. Pick an app on the left, click a workspace on the
right — that's the whole interaction. The rule is written, Hyprland is reloaded,
and if the app is already running its window moves there immediately.

## Two views

**Apps** — every running window and every installed application, searchable.
A dot marks what is currently running. Assign a workspace, toggle *Silent* and
*Launch at startup*, remove the rule.

**Workspaces** — one row per workspace: which monitor it lives on, which apps are
pinned to it, and whether it is always present. `+ Add workspace` creates the next
free one as always-present. Switch it to *On demand* and it stays listed, so you
can still pin apps or a monitor to it. Every workspace above 5 has a ×: removing
it drops its settings and the rules of the apps pinned to it, after a
confirmation when apps or a monitor are attached. Open windows stay where they are.

Switch with the tabs or `Ctrl+Tab`.

## How it works

`~/.local/state/omarchy/appspace/rules.json` is the single source of truth. From it
the plugin generates `~/.local/state/omarchy/toggles/hypr/appspace.lua`, which is
overwritten in full — never edit that file by hand. Omarchy loads every module in
that directory on each config reload, so nothing in `~/.config/hypr` changes. The
plugin never reads the Lua back.

Window classes come from `Hyprland.toplevels`, i.e. from live windows. That is
deliberate: a `.desktop` file is only a hint. For an app that is not running,
the class is derived from its desktop entry, in this order:

1. `StartupWMClass`, when it looks like a class. Arch's `chromium.desktop`
   declares the unfilled build template `@@startup_wm_class`; anything with
   template markers, whitespace or shell characters is ignored. Flatpak exports
   are skipped too: their declaration is copied from upstream while the
   sandboxed window carries the Flatpak app id.
2. Steam: `steam://rungameid/<id>` becomes `steam_app_<id>`.
3. Terminal launchers: the `--app-id=` on the command line (`TUI.tile`,
   `TUI.float`), or `org.omarchy.<name>` for `omarchy-launch-tui`.
4. Omarchy web apps: `omarchy-launch-webapp <url>` opens the URL in the default
   browser's `--app` mode, which names the window `<browser>-<host>_<path>-Default`,
   e.g. `brave-chatgpt.com__-Default`. The browser prefix follows the default
   browser the same way `omarchy-launch-webapp` picks it.
5. Otherwise the desktop entry id: `org.gnome.Nautilus.desktop` → `org.gnome.Nautilus`.

Rows are merged case-insensitively, and a live window's spelling always wins,
because that is the string Hyprland compares against. A rule written with a
desktop entry's spelling (`brave-browser`) is rewritten to the window's
(`Brave-browser`) the first time that window is seen, and the Lua regenerated.

Every derived class is labelled **guessed class** until a real window confirms
it. A declared `StartupWMClass` is a guess like any other: Obsidian declares
`md.Obsidian` and opens as `md.obsidian.Obsidian`, Pinta declares `Pinta` and
opens as `com.github.PintaProject.Pinta`. **verified** means a live window has
used the class. Confirmation is sticky: once a window has proved a class, the
rule stays verified after the app closes, and a rule whose class no window
ever used is called out as one that can never fire.

Windows are watched while the panel is closed too, so a rule is confirmed,
respelled or carried over to an alias as soon as its window appears, not the
next time the panel happens to be open.

Steam is a special case worth knowing about. It writes one `.desktop` per game
with no `StartupWMClass` and a launcher `Exec`, so the plugin reads the game id
out of `steam://rungameid/<id>` and guesses `steam_app_<id>` — right for Proton
and other XWayland games, wrong for native Wayland ones (Factorio actually opens
as `com.factorio.Factorio`). While a game runs, the plugin reads `SteamAppId`
from the process environment, learns which class the launcher entry really
opens, records that alias, and moves the rule over to the real class. The
launcher entry and the real window collapse into one row from then on.

## Which apps work

Tested on Omarchy 4 with Hyprland 0.56. "Out of the box" means a rule made
from the installed-apps row fires on the first launch.

| Kind | Examples | Out of the box? |
|---|---|---|
| Native app with a correct `StartupWMClass` | Alacritty, foot, Spotify, Signal, 1Password | yes |
| No `StartupWMClass`, the desktop id is the class | Nautilus, Evince, mpv, Chromium | yes |
| `StartupWMClass` with the wrong case | Brave (`brave-browser` → `Brave-browser`), Typora | first launch misses; the rule is respelled when the window appears and fires from then on |
| Flatpak | Discord | yes, by Flatpak app id |
| Omarchy TUI launchers (`xdg-terminal-exec --app-id=…`, `omarchy-launch-tui`) | Docker (lazydocker), Disk Usage | yes; note that every `TUI.tile` launcher shares one class and moves as a group |
| `Terminal=true` entries that open in the default terminal | btop, nvim | not listed: the window carries the terminal's class |
| Omarchy web apps | ChatGPT, GitHub, Basecamp | yes while the default browser runs on Wayland. With `--ozone-platform=x11` in the browser's flags file every web app is `Brave-browser`, indistinguishable from the browser |
| Steam, Proton / XWayland | Balatro, Dark Souls | yes, as `steam_app_<id>` |
| Steam, native Linux | Factorio | first launch misses; the real class is learned while the game runs and the rule moves to it |
| Wrong `StartupWMClass` | Obsidian, Pinta | launch it once, then assign from the running row; the stale guessed row keeps its rule until you remove it |
| No desktop entry at all | | from the running window only |

Monitors are matched by `desc:` (make, model and serial), not by connector, so
moving a cable to another port keeps the layout.

*Launch at startup* rides on the rule, so an app is only launched into a
workspace you have already chosen for it. The generated Lua hooks Hyprland's
`hyprland.start` event through `o.exec_on_start`; a config reload does not
re-fire it, so reloading never relaunches your apps. The launch target is the
Desktop Entry ID rather than a resolved command line, because `uwsm-app`
resolves entries itself and gets the `.desktop` field codes right. An app with
no desktop entry has nothing to launch, so the toggle stays inert for it.

Some apps start themselves at login through an XDG autostart entry (1Password
writes one when its "start at login" setting is on). Launching such an app a
second time only loses a race and closes on its single-instance lock, so the
plugin scans `/etc/xdg/autostart` and `~/.config/autostart`: for an app that
starts itself the toggle says so and stays off, and every generated launch line
waits two seconds for the autostart pass and checks the app's
`app-<name>@autostart.service` unit before launching. The order is then
deterministic: the app's own entry wins, AppSpace fills in only when it is absent.

## Which apps work

Tested on Omarchy 4 with Hyprland 0.56. "Out of the box" means a rule made
from the installed-apps row fires on the first launch.

| Kind | Examples | Out of the box? |
|---|---|---|
| Native app with a correct `StartupWMClass` | Alacritty, foot, Spotify, Signal, 1Password | yes |
| No `StartupWMClass`, the desktop id is the class | Nautilus, Evince, mpv, Chromium | yes |
| `StartupWMClass` with the wrong case | Brave (`brave-browser` → `Brave-browser`), Typora | first launch misses; the rule is respelled when the window appears and fires from then on |
| Flatpak | Discord | yes, by Flatpak app id |
| Omarchy TUI launchers (`xdg-terminal-exec --app-id=…`, `omarchy-launch-tui`) | Docker (lazydocker), Disk Usage | yes; note that every `TUI.tile` launcher shares one class and moves as a group |
| `Terminal=true` entries that open in the default terminal | btop, nvim | not listed: the window carries the terminal's class |
| Omarchy web apps | ChatGPT, GitHub, Basecamp | yes while the default browser runs on Wayland. With `--ozone-platform=x11` in the browser's flags file every web app is `Brave-browser`, indistinguishable from the browser |
| Steam, Proton / XWayland | Balatro, Dark Souls | yes, as `steam_app_<id>` |
| Steam, native Linux | Factorio | first launch misses; the real class is learned while the game runs and the rule moves to it |
| Wrong `StartupWMClass` | Obsidian, Pinta | launch it once, then assign from the running row; the stale guessed row keeps its rule until you remove it |
| No desktop entry at all | | from the running window only |

Monitors are matched by `desc:` (make, model and serial), not by connector, so
moving a cable to another port keeps the layout.

*Launch at startup* rides on the rule, so an app is only launched into a
workspace you have already chosen for it. The generated Lua registers it through
`o.launch_on_start`, which hooks Hyprland's `hyprland.start` event — a config
reload does not re-fire it, so reloading never relaunches your apps. The launch
target is the Desktop Entry ID rather than a resolved command line, because
`uwsm-app` resolves entries itself and gets the `.desktop` field codes right. An
app with no desktop entry has nothing to launch, so the toggle stays inert for
it.

## Install

```sh
omarchy plugin add https://github.com/DominikZajac/omarchy-appspace.git --enable
```

That is all. Enabling puts the monitor icon in the bar's right section; move it
with `omarchy bar move dominikzajac.appspace --section center` if you prefer it
elsewhere.

Upgrading from 0.3.0: the generated module moved out of `~/.config/hypr`. Delete
the `require("hypr.appspace")` line from `~/.config/hypr/hyprland.lua` and remove
`~/.config/hypr/appspace.lua`.

### Uninstall

```sh
omarchy plugin remove dominikzajac.appspace
rm ~/.local/state/omarchy/toggles/hypr/appspace.lua
hyprctl reload
```

The rules file, `~/.local/state/omarchy/appspace/rules.json`, is left in place;
remove it too if you want nothing behind.

### Dependencies

Nothing beyond a stock Omarchy 4 install: `hyprctl` (reload, config check, moving
windows), `uwsm-app` (launch at startup, via Omarchy's `o.launch_on_start`),
`xdg-settings` (which browser web apps open in), and `sh`. The plugin reads
`/proc/*/environ` of your own processes to learn a running Steam game's app id.

After editing plugin code, run `omarchy restart shell`. Saving a file only
refreshes the plugin registry — a mounted widget keeps running the old code.

## Keyboard

| Key | |
|---|---|
| type | filter the app list |
| `↑` `↓` | move through the list |
| `Tab` / `Shift+Tab` | walk the controls: tabs, workspace chips, monitor dropdowns, buttons |
| `←` `→` | move inside a chip group |
| `Enter` / `Space` | activate the focused control |
| `Ctrl+Tab` | switch between Apps and Workspaces |
| `Esc` | clear the filter, then close |

## From the CLI

```sh
omarchy-shell dominikzajac.appspace list
omarchy-shell dominikzajac.appspace set vesktop 3 normal     # third argument: normal | silent
omarchy-shell dominikzajac.appspace unset spotify
omarchy-shell dominikzajac.appspace pin 3 "LG Electronics MP59G 0x01010101"
omarchy-shell dominikzajac.appspace pin 3 ""                 # back to auto
omarchy-shell dominikzajac.appspace persist 6 on             # always-present workspace
omarchy-shell dominikzajac.appspace forget 6                 # drop workspace 6 and its pinned apps' rules
omarchy-shell dominikzajac.appspace autostart spotify on    # launch at login
omarchy-shell dominikzajac.appspace view workspaces
omarchy-shell dominikzajac.appspace select vesktop
```

IPC arguments are positional and all of them are required.

## Write safety

Before writing, the plugin records `hyprctl configerrors` as a baseline. After
writing and reloading it checks again, and reverts **both** files if a new error
appeared.

The baseline comparison matters: `configerrors` reports errors from the entire
config, so without it one unrelated broken file would roll back every valid
change. Reverting both files matters too — restoring only the Lua would leave
`rules.json` claiming a rule Hyprland has never seen.

## Limitations

- A rule applies every time a window opens, not only the first time.
- Matching is by window class only. Apps that open several windows under one class
  (Steam: library, friends list, update popups) are moved as a group. Narrowing by
  window title still needs a hand-written rule.
- Native Steam games get their real class only once they run: assign the
  launcher entry, start the game once, and the rule follows.
- A TUI that opens in the default terminal (`Terminal=true` with no
  `--app-id`) has the terminal's class and is not listed.
- Web apps can only be told apart from the browser when the browser runs on
  Wayland.
- The workspace list mirrors Omarchy's bar: 1–5 always, plus any live workspace up
  to 10, plus anything this plugin has a rule for.
- `Silent` only governs where a *new* window is placed. Omarchy ships
  `focus_on_activate = true`, so an already-open window that gets activated (a link
  clicked in another app) can still pull you to its workspace.

## Files

| | |
|---|---|
| `manifest.json` | plugin manifest |
| `Panel.qml` | bar widget, both views, write pipeline |
| `Rules.js` | model, JSON ↔ Lua serialization — no QML, no filesystem |
| `~/.local/state/omarchy/appspace/rules.json` | source of truth (schema 5) |
| `~/.local/state/omarchy/toggles/hypr/appspace.lua` | generated, overwritten in full, auto-loaded by Omarchy |
