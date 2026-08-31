# Omarchy Float Panel

An Omarchy 4 bar widget that shows one icon per application on each monitor's active workspace. It also includes native Hyprland Lua bindings for per-workspace floating mode and keyboard-driven minimize/restore behavior.

## Behavior

- The TaskList is shown only when the active normal workspace is in Float mode and has visible or minimized applications.
- A second `Float Toggle` widget instance can stay beside Omarchy Indicators; left click switches that bar's current regular workspace between Float and Tiling, with a bright/dim state icon.
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
- `Alt+Tab` opens a centered, launcher-themed MRU window list on every regular workspace, in both Tiling and Float modes. Every window is a separate item even when several belong to the same application; minimized windows are included. Repeated Tab/Shift+Tab changes only the highlight; releasing Alt restores/focuses the selected window.
- Floating mode is independent per workspace and persists across Hyprland config reloads and logins.
- Float windows remember their last closed free, half-screen, or geometric-max placement per workspace and restore it when reopened.
- New parented windows without an application-specified position are initially centered over their concrete parent, then fitted to the monitor work area; explicit application placement is preserved.
- XWayland size constraints are normalized from each window's own hints, including after monitor scale reflow, without application-class rules.
- No daemon, polling loop, fixed workspace ID, or hyprbars plugin is used.

Hyprland supports tiled and floating windows concurrently. The Lua integration keeps only a set of workspace names whose normal windows should be floating. It applies that mode to current windows and reacts to `window.open` and `window.move_to_workspace` for future/moved windows.

## Requirements

- Omarchy 4 / `quattro` shell plugin system
- Hyprland 0.56.2 with Lua configuration, development headers, and `pkg-config` metadata
- A C++23 compiler and the Lua development package matching Hyprland
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
make -C native
```

Third-party QML plugins execute unsandboxed inside `omarchy-shell`. The native metadata bridge is also loaded into the Hyprland compositor, so review the checkout before enabling it. Hyprland's C++ plugin ABI is not stable: rebuild `native/build/float-panel-native.so` against the installed Hyprland headers after every Hyprland upgrade. The bridge checks the exact build commit and refuses to load on a mismatch.

Add the Hyprland integration near the end of `~/.config/hypr/hyprland.lua`, after `require("default.hypr.omarchy")` and the normal Omarchy/user modules:

```lua
dofile((os.getenv("HOME") or "") .. "/.config/omarchy/plugins/fatlj.float-panel/hypr/float-panel.lua")
```

`float-panel.lua` loads the bridge with Hyprland's native `hl.plugin.load()` API when the built `.so` exists. Its sole binding, `hl.plugin.float_panel.window_semantics(address)`, is read-only and returns compositor facts: XWayland and parent/transient/override/type state, concrete parent address, and ICCCM `program_position`/`user_position`. Lua owns all placement and persistence policy: it centers an unpositioned child over a resolvable parent and then runs the normal work-area fit. Explicitly positioned or parentless windows keep application placement. Missing or failing native reads degrade safely; persistence fails closed when semantics are unavailable.

Hyprland should reload the configuration automatically. After updating an already loaded plugin checkout, let the file watcher settle and then restart Omarchy Shell once: the watcher notices QML/JavaScript changes, but the running engine can retain an imported JavaScript module cache. Do not overlap the restart with an in-progress file copy/hot reload.

```bash
sleep 2
omarchy-restart-shell
```

## Workspace mode

Press `Super+Shift+T` on any regular workspace, or left-click a `Float Toggle` bar-widget instance on that monitor:

- Tiling → floating: all current windows float; windows opened or moved there also float.
- Floating → tiling: all current windows tile; windows subsequently moved there tile. Newly opened windows again follow normal Hyprland application rules.

In every mode, `Super+Tab` and `Super+Shift+Tab` cycle the existing regular workspaces on the focused window's monitor with boundary wrap; special workspaces are excluded and missing workspace IDs are not created.

The plugin supports multiple bar-widget instances. Existing/default instances use `Task List`; configure an additional instance as `Float Toggle` and place it beside `omarchy.indicators`. It remains visible and clickable in both modes and calls the same in-process Lua mode function as the keyboard binding. Omarchy's first-party Indicators loader has no third-party indicator registration point, so no system plugin files are modified.

The set of floating workspace names is stored at:

```text
~/.local/state/omarchy/float-panel-workspaces
```

Deleting that file resets the remembered modes at the next Hyprland config reload. Switching to tiling deliberately tiles all normal windows on that workspace; it does not preserve per-window exceptions from before the toggle.

Float-window placement is stored atomically at:

```text
~/.local/state/omarchy/float-panel-geometries
```

Before assigning a geometry slot, the native bridge reads compositor-owned window relationships and reports a concrete parent by address without exposing titles. Independent Wayland toplevels and X11 `NORMAL`/parentless `DIALOG` windows are eligible; parented/transient windows, override-redirect windows, and X11 utility, tooltip, menu, notification, splash, toolbar, dock, desktop, combo, and drag-and-drop types never claim, save, or restore geometry. New eligible records are written only after initial parent/application placement and the full work-area fit; existing eligible records restore normally. This is based on standard window semantics rather than application class or title.

For eligible windows, the application key is the workspace plus Hyprland's immutable `initial_class`; an application-provided `xdg_tag` further separates stable window roles. Identical windows without a role use numbered slots, so closing and reopening one while its peers remain open restores its own slot. If all indistinguishable instances close, their next launch order deterministically consumes the saved slots because neither Hyprland nor the application provides a cross-process window ID. Free windows reopen at their saved logical size, shrinking when necessary to fit a smaller work area while retaining relative position; left/right/max placements are recomputed from the current monitor work area. `window.close` records the final user/plugin placement, and `hyprland.shutdown` records windows still open, but neither replaces that placement with a temporary topology-reflow box. Tiling workspaces are not restored or allowed to overwrite Float geometry. Compositor-only fullscreen persists its underlying placement rather than reopening fullscreen. Delete this file and reload Hyprland to reset remembered placements.

In a floating workspace, `Super+Left` and `Super+Right` snap the active window to the left or right half of the current monitor and record that placement intent in a live-window tag. Geometry is calculated from the monitor's scale, reserved bar area, live `gaps_out`/`gaps_in`, and border size, so managed halves recompute exactly across reload, monitor migration, and monitor layout/scale changes instead of remaining defensively shrunk after returning to a larger work area. On module startup, existing exact plugin-style halves are adopted; only anchored full-height matches within a 2-pixel client size-increment delta qualify. Before later reflow, cached observed geometry is checked (including Hyprland's monitor-origin translation); a mouse-edited mismatch clears side intent and falls back to free-window behavior. Keyboard resize also clears side intent. `Super+Up` saves the exact floating box and source workspace in a live-window tag, then resizes and moves that still-floating window to its monitor's usable work area. If Up started from a managed half, Down restores the corresponding half on the current monitor; Up from a free window retains exact free restore semantics. Multiple tagged windows can therefore stay at the same full size; AppSwitcher and TaskList select one with their existing exact-address focus/raise path and do not resize the others. `Super+Down` restores/clamps only the selected window's saved box and clears its tag. Config reloads preserve tags and exact max geometry; monitor migration refills tagged windows against the destination work area. Moving a tagged window to another regular workspace or switching its source workspace to Tiling clears the metadata. Clients intentionally continue reporting `fullscreen = 0` and `fullscreenClient = 0`; they do not receive the maximized protocol state.

Ordinary free floats keep an immutable live reflow anchor containing their pre-reflow box, source floating work area/monitor, normalized size and free-space position, and the last box applied by this module. Every `workspace.move_to_monitor`, `monitor.layout_changed`, and mapped-layer work-area reflow derives size and position from that source—not from an intermediate fitted box—so both dimensions grow or shrink proportionally, right/center/bottom alignment survives, and returning to the same work area restores the source box. The existing final clamp still keeps every result wholly inside the current floating bounds. The source workspace's minimized special windows use the same anchor, including across shutdown capture. Explicit plugin geometry actions (keyboard resize, snap, maximize/restore, workspace-mode changes, open/restore) reset or rebase it. A native/user geometry mismatch is rebased at the next same-bounds reflow, and a size mismatch is rebased before a topology reflow. Hyprland Lua exposes no reliable native move/resize completion event here, so a position-only mouse move immediately followed by a simultaneous topology change cannot be distinguished from compositor origin translation; no polling, delay, or mouse hook is added to guess.

The integration sets `general.float_gaps = -1`, which inherits `gaps_out`; centered keyboard resizing uses that gap, border, reserved area, scale, and transform to clamp against the active window's own monitor. `Super+F` toggles split fullscreen state (`internal = 2`, `client = 0`) to fill the display while retaining client chrome. In a tiling workspace these keys retain Omarchy's original relative-resize, directional-focus, or synchronized-fullscreen behavior. Hyprland's native `monitor.layout_changed` event checks every plugin Float workspace after scale, mode/resolution, transform, or logical-position changes; tagged side/max peers retain their managed intent while free windows use their proportional anchor. The same pass includes matching minimized special workspaces. After a newly mapped layer has established its exclusive reservation, Hyprland's post-arrange `layer.opened` event refits only Float workspaces on that exact monitor. Dynamic exclusive-zone mutations without a layer remap, and standalone gap changes, are not claimed by these event routes.

For native edge/corner resizing without holding `Super`, enable Hyprland's supported border-resize path. The default 15-pixel extended grab area and resize cursor then apply; `Super+Right-drag` remains available.

```lua
hl.config({ general = { resize_on_border = true } })
```

Application minimum-size hints are ignored globally through one match-free Hyprland window rule with `min_size = { 1, 1 }`; no application name, class, or title is special-cased. Application maximum-size hints retain Hyprland's native behavior.

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

TaskList clicks follow a deterministic per-application state ring. One window toggles `A → minimized → A`; multiple windows cycle in stable launch/address order and then minimize the whole group, for example `A → B → minimized → A`. Entering a group while another app is active starts at its first visible window. A minimized next window is restored before focus/raise, and the final-to-minimized transition moves every visible member to the workspace's dedicated minimized special workspace in one Hyprland callback. Alt-Tab is deliberately different: it does not group by application, and labels each independently selectable window with its application name and window title.

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

Lua bind/context and monitor-reflow records are written to `/tmp/float-panel-debug.log`, rotated at 5 MiB to one `.1` file. Each topology reflow emits privacy-safe per-window `before`, `decision`, and `after` records with the trigger, source/target bounds, anchor and normalized ratios, requested resize/move, and actual geometry. TaskList and AppSwitcher records use the `fatlj.float-panel` prefix in the Omarchy Shell log. Reflow records contain addresses and workspace/monitor identifiers, never window titles, class names, or typed/content text. Remove the marker and reload both components to disable logging.

## Validation

```bash
./scripts/validate.sh
```

The validation suite checks the manifest, QML/JavaScript/Lua syntax, grouping behavior, active-window workspace routing, fractional-scale geometry, pinned-window fitting, workspace-mode events, minimize routing, and the absence of fixed workspace/hyprbars dependencies.

A real Omarchy/Hyprland session is still required for final visual and interaction testing.
