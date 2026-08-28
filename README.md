# Omarchy Float Panel

An Omarchy 4 bar widget that shows one icon per application on each monitor's active workspace. It also includes native Hyprland Lua bindings for per-workspace floating mode and keyboard-driven minimize/restore behavior.

## Behavior

- The TaskList is shown on every normal workspace that has visible or minimized applications.
- Each application is represented by one icon, even when it owns multiple windows.
- Left click behaves like a taskbar toggle for the representative window.
  - An inactive visible window is focused and raised to the top.
  - If the representative is active, that window is hidden in the workspace's minimized special workspace.
  - If all of the application's windows are minimized, one is restored, focused, and raised.
- `Super+M` minimizes the active window by moving it silently to a special workspace dedicated to its source workspace.
- `Super+Shift+T` toggles the focused regular workspace between all-floating and normal tiling behavior.
- `Super+Left/Right` keeps Omarchy's directional focus behavior in tiling mode and snaps the active window to the corresponding monitor half in floating mode.
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

The set of floating workspace names is stored at:

```text
~/.local/state/omarchy/float-panel-workspaces
```

Deleting that file resets the remembered modes at the next Hyprland config reload. Switching to tiling deliberately tiles all normal windows on that workspace; it does not preserve per-window exceptions from before the toggle.

In a floating workspace, `Super+Left` and `Super+Right` snap the active window to the left or right half of the current monitor. Geometry is calculated from the monitor's scale, reserved bar area, live `gaps_out`/`gaps_in`, and border size, so snapped windows retain the same outer and middle margins as tiling and work with the bar on any edge. In a tiling workspace the same keys continue to focus the neighboring window.

## Minimize and restore

For a source workspace with internal ID `N`, `Super+M` moves the active window to:

```text
special:omarchy-minimized-N
```

The TaskList combines the active workspace with that matching special workspace. Because the source workspace is encoded in the special workspace name, no per-window origin database is needed.

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

The model admits only toplevels backed by a mapped Hyprland IPC client. Input-method candidates, tooltips, and other protocol-only transient surfaces are ignored structurally rather than through application-name blacklists.

Hyprland's focus dispatcher normally warps the pointer. To keep the pointer stationary and make focus click-driven, add native overrides to the user config:

```lua
hl.config({ input = { follow_mouse = 0 } })
hl.config({ cursor = { no_warps = true } })
```

## Validation

```bash
./scripts/validate.sh
```

The validation suite checks the manifest, QML/JavaScript/Lua syntax, grouping behavior, workspace-mode events, minimize routing, and the absence of fixed workspace/hyprbars dependencies.

A real Omarchy/Hyprland session is still required for final visual and interaction testing.
