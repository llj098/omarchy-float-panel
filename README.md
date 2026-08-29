# Omarchy Float Panel

An Omarchy 4 bar widget that shows one icon per application on each monitor's active workspace. It also includes native Hyprland Lua bindings for per-workspace floating mode and keyboard-driven minimize/restore behavior.

## Behavior

- The TaskList is shown only when the active normal workspace is in Float mode and has visible or minimized applications.
- Each application is represented by one icon, even when it owns multiple windows.
- Icons stay sorted by application process launch time; focus, raise, minimize, restore, and Shell restarts do not reorder them.
- Left click behaves like a taskbar toggle for the representative window.
  - An inactive visible window is focused and raised to the top.
  - If the representative is active, that window is hidden in the workspace's minimized special workspace.
  - If all of the application's windows are minimized, one is restored, focused, and raised.
- `Super+M` minimizes the active window by moving it silently to a special workspace dedicated to its source workspace.
- `Super+Shift+T` toggles the focused regular workspace between all-floating and normal tiling behavior.
- `Super+Left/Right` keeps Omarchy's directional focus behavior in tiling mode and snaps the active window to the corresponding monitor half in floating mode.
- `Super+Up/Down` keeps directional focus in Tiling mode; in Float mode it geometry-maximizes/restores the active floating window, retaining the bar and client chrome while allowing multiple windows to remain full-sized peers without resize-on-switch.
- Omarchy's `Super` +/- resize family (base 100, `Alt` 25, `Ctrl` 300; add `Shift` for vertical) keeps its original relative tiling actions; in Float mode it resizes around the window center and stops at that window's monitor work-area boundary.
- `Super+F` keeps Omarchy's true synchronized fullscreen in Tiling mode; in Float mode it toggles compositor-only fullscreen, hiding the bar and margins without telling the client to hide browser tabs or other chrome.
- `Super+Tab`/`Super+Shift+Tab` keep Omarchy's next/previous-workspace behavior in both modes. App switching remains exclusively on `Alt+Tab`.
- `Alt+Tab` opens a centered, launcher-themed MRU application list for the current workspace (including its minimized apps). Repeated Tab/Shift+Tab changes only the highlight; releasing Alt restores/focuses the selected app.
- Floating mode is independent per workspace and persists across Hyprland config reloads and logins.
- No daemon, polling loop, fixed workspace ID, or hyprbars plugin is used.

Hyprland supports tiled and floating windows concurrently. The Lua integration keeps only a set of workspace names whose normal windows should be floating. It applies that mode to current windows and reacts to `window.open` and `window.move_to_workspace` for future/moved windows.

## Requirements

- Omarchy 4 / `quattro` shell plugin system
- Hyprland with Lua configuration (0.55 or newer)
- Quickshell 0.3.1 or a compatible build

This does not target the legacy Waybar-based Omarchy releases.

## Development install

From this checkout:

```bash
mkdir -p ~/.config/omarchy/plugins
test ! -e ~/.config/omarchy/plugins/fatlj.float-panel
ln -s "$PWD" ~/.config/omarchy/plugins/fatlj.float-panel
omarchy plugin validate ~/.config/omarchy/plugins/fatlj.float-panel
omarchy-shell shell rescanPlugins
sleep 2 # rescan is asynchronous
omarchy plugin enable fatlj.float-panel
omarchy bar move fatlj.float-panel --section left --after omarchy.workspaces
```

Third-party plugins execute unsandboxed inside `omarchy-shell`; review the checkout before enabling it.

Add the Hyprland integration near the end of `~/.config/hypr/hyprland.lua`, after `require("default.hypr.omarchy")` and the normal Omarchy/user modules:

```lua
dofile((os.getenv("HOME") or "") .. "/.config/omarchy/plugins/fatlj.float-panel/hypr/float-panel.lua")
```

Hyprland should reload the configuration automatically. After updating an already loaded plugin checkout, let the file watcher settle and then restart Omarchy Shell once: the watcher notices QML/JavaScript changes, but the running engine can retain an imported JavaScript module cache. Do not overlap the restart with an in-progress file copy/hot reload.

```bash
sleep 2
omarchy-restart-shell
```

## Workspace mode

Press `Super+Shift+T` on any regular workspace:

- Tiling → floating: all current windows float; windows opened or moved there also float.
- Floating → tiling: all current windows tile; windows subsequently moved there tile. Newly opened windows again follow normal Hyprland application rules.

In every mode, `Super+Tab` and `Super+Shift+Tab` cycle the existing regular workspaces on the focused window's monitor with boundary wrap; special workspaces are excluded and missing workspace IDs are not created.

The set of floating workspace names is stored at:

```text
~/.local/state/omarchy/float-panel-workspaces
```

Deleting that file resets the remembered modes at the next Hyprland config reload. Switching to tiling deliberately tiles all normal windows on that workspace; it does not preserve per-window exceptions from before the toggle.

In a floating workspace, `Super+Left` and `Super+Right` snap the active window to the left or right half of the current monitor and record that placement intent in a live-window tag. Geometry is calculated from the monitor's scale, reserved bar area, live `gaps_out`/`gaps_in`, and border size, so managed halves recompute exactly across reload, monitor migration, and monitor layout/scale changes instead of remaining defensively shrunk after returning to a larger work area. On module startup, existing exact plugin-style halves are adopted; only anchored full-height matches within a 2-pixel client size-increment delta qualify. Before later reflow, cached observed geometry is checked (including Hyprland's monitor-origin translation); a mouse-edited mismatch clears side intent and falls back to free-window fit-only behavior. Keyboard resize also clears side intent. `Super+Up` saves the exact floating box and source workspace in a live-window tag, then resizes and moves that still-floating window to its monitor's usable work area. If Up started from a managed half, Down restores the corresponding half on the current monitor; Up from a free window retains exact free restore semantics. Multiple tagged windows can therefore stay at the same full size; AppSwitcher and TaskList select one with their existing exact-address focus/raise path and do not resize the others. `Super+Down` restores/clamps only the selected window's saved box and clears its tag. Config reloads preserve tags and exact max geometry; monitor migration refills tagged windows against the destination work area, while ordinary floats retain fit-only behavior. Moving a tagged window to another regular workspace or switching its source workspace to Tiling clears the metadata. Clients intentionally continue reporting `fullscreen = 0` and `fullscreenClient = 0`; they do not receive the maximized protocol state. The integration sets `general.float_gaps = -1`, which inherits `gaps_out`; centered keyboard resizing uses that gap, border, reserved area, scale, and transform to clamp against the active window's own monitor. `Super+F` toggles split fullscreen state (`internal = 2`, `client = 0`) to fill the display while retaining client chrome. In a tiling workspace these keys retain Omarchy's original relative-resize, directional-focus, or synchronized-fullscreen behavior. Hyprland's native `monitor.layout_changed` event defensively checks every plugin Float workspace after scale, mode/resolution, transform, or logical-position changes: oversized ordinary floats shrink, off-screen coordinates clamp, already-fitting geometry stays unchanged, and tagged geometric-max peers refill current bounds. Tiling and special/minimized workspaces are ignored. After a newly mapped layer has established its exclusive reservation, Hyprland's post-arrange `layer.opened` event refits only Float workspaces on that exact monitor. Dynamic exclusive-zone mutations without a layer remap, and standalone gap changes, are not claimed by these event routes.

For native edge/corner resizing without holding `Super`, enable Hyprland's supported border-resize path. The default 15-pixel extended grab area and resize cursor then apply; `Super+Right-drag` remains available.

```lua
hl.config({ general = { resize_on_border = true } })
```

The Lua integration also registers a native, XWayland-only `min_size = { 1, 1 }` rule for class `wechat`. WeChat advertises a `1165×1040` X11 minimum that blocks interactive edge resizing on the fractional-scale target, while direct compositor tests show that the client accepts and correctly renders smaller configure sizes. The rule overrides only Hyprland's interactive minimum; it does not force a startup size.

## Minimize and restore

For a source workspace with internal ID `N`, `Super+M` moves the active window to:

```text
special:omarchy-minimized-N
```

The TaskList combines the active workspace with that matching special workspace. It watches the existing Float workspace state file, so switching workspaces or toggling Float/Tiling updates its visibility without restarting the Shell. Because the source workspace is encoded in the special workspace name, no per-window origin database is needed.

Before disabling/removing the plugin, restore minimized windows through their TaskList icons. For manual recovery, reveal a workspace's hidden windows with:

```bash
hyprctl dispatch 'hl.dsp.workspace.toggle_special("omarchy-minimized-1")'
```

Replace `1` with the source workspace ID, then move the windows back normally.

## Application grouping and task actions

The widget reads Quickshell's reactive `HyprlandWorkspace.toplevels` models. Application identity is resolved in this order:

1. Wayland toplevel `appId`;
2. Hyprland client class from the last IPC object;
3. exact window address as a non-grouping fallback.

Desktop icons use an exact desktop-entry lookup, then `DesktopEntries.heuristicLookup()`, then the generic executable icon. Heuristic desktop-entry matching can be imperfect for unusual XWayland, Electron, PWA, and terminal-hosted applications.

When an app has multiple windows, the representative prefers an active visible window, then any visible window, then a minimized window. Clicking an active group hides only its active representative, not every window owned by the app. Clicking never cycles windows.

The Lua integration tags each managed window with its process start ticks from `/proc/PID/stat`. Task groups sort by the earliest such value among their windows, while untagged windows remain in first-observed order at the end. The tags remain attached when Hyprland changes workspace or Z-order and are reconstructed on config reload, so the TaskList does not need a separate ordering database.

The model admits only toplevels whose Hyprland IPC object explicitly reports `mapped === true`; an associated toplevel with an absent or not-yet-populated IPC mapping is not enough. This excludes the observed Fcitx X11 combo/input surface, which reaches Quickshell with an address and title but empty IPC identity/mapping fields. Malformed identities containing embedded NUL bytes are rejected as a secondary guard. Neither filter matches a window title or executable name.

Hyprland's focus dispatcher normally warps the pointer. To keep the pointer stationary and make focus click-driven, add native overrides to the user config:

```lua
hl.config({ input = { follow_mouse = 0 } })
hl.config({ cursor = { no_warps = true } })
```

## Debug logging

Create the marker below and reload Hyprland plus Omarchy Shell to enable explicit plugin traces:

```bash
touch ~/.local/state/omarchy/float-panel-debug
```

Lua bind/context and monitor-reflow records are written to `/tmp/float-panel-debug.log`, rotated at 5 MiB to one `.1` file. TaskList and AppSwitcher records use the `fatlj.float-panel` prefix in the Omarchy Shell log. Records contain addresses and workspace/monitor identifiers, not window titles or typed text. Remove the marker and reload both components to disable logging.

## Validation

```bash
./scripts/validate.sh
```

The validation suite checks the manifest, QML/JavaScript/Lua syntax, grouping behavior, active-window workspace routing, fractional-scale geometry, pinned-window fitting, workspace-mode events, minimize routing, and the absence of fixed workspace/hyprbars dependencies.

A real Omarchy/Hyprland session is still required for final visual and interaction testing.
