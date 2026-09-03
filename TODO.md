# TODO

## Preserve free-window anchors through staged monitor reconfiguration

**Status:** Known bug, blocked by the target Hyprland `0.56.2-1` Lua API. Do not fix this by inferring the source of a geometry change from its final coordinates. The project will not add a native function hook for this case.

### Problem

During monitor disconnect, reconnect, or another staged layout change, a monitor can keep the same name while its logical origin changes. Hyprland's `CMonitor::moveTo()` translates mapped floating windows by that origin delta before emitting `monitor.layout_changed`. Workspace migration similarly translates its floating windows before emitting `workspace.move_to_monitor`.

Float Panel therefore observes only the resulting geometry. Its current reflow logic assumes that a same-name monitor did not translate the window. It can consequently mistake Hyprland's automatic translation for a real user or application move, replace the immutable pre-reflow anchor with a temporary destination-monitor state, and lose the original geometry. When the original work area returns, an ordinary free-floating window can then be restored from the wrong proportions—for example, the observed Alacritty case returned as `1340×1300` instead of its original `853×945`.

Managed left/right and geometric-max placements are recomputed from their explicit intent and are not the affected free-window case.

### Verified blocker

Hyprland `0.56.2` exposes neither a pre-translation monitor/workspace event nor a window move/resize event carrying the change source to Lua. Both available reflow events are post-change. Upstream still tracks the missing Lua move/resize notification as [Hyprland discussion #15519](https://github.com/hyprwm/Hyprland/discussions/15519); the automatic monitor-origin translation was introduced deliberately by [Hyprland PR #14928](https://github.com/hyprwm/Hyprland/pull/14928).

Once the post-change geometry is observed, a compositor translation and a user/application change can produce the same state. Coordinate comparison therefore cannot distinguish them reliably. A correct implementation requires an upstream source-tagged/pre-change event, a Hyprland source change, or native hooks around the exact compositor adjustment paths. Those options are currently unavailable or deliberately out of scope; polling, delays, input interception, and application-specific exceptions remain prohibited.

### Acceptance condition for a future fix

A future implementation must receive an explicit compositor-origin fact before geometry is changed, preserve the old anchor throughout every intermediate layout stage, still invalidate it after a genuine user/application edit, and restore the exact original geometry when the original work area returns. The regression test must include a same-name monitor whose logical origin changes while Hyprland translates the floating window.

## Keep floating windows inside the workspace work area

**Status:** Blocked by the target Hyprland `0.56.2-1` API. Do not emulate this with polling or global mouse-release interception.

### Problem

A floating window can currently be moved or interactively resized beyond the usable area of its workspace monitor. Its final outer geometry should remain fully inside the monitor work area while preserving the configured edge gap. The boundary must account for reserved layer-shell areas such as the Omarchy bar, fractional monitor scale, window borders/extents, and movement or resizing from every edge and corner.

The constraint must apply to both `Super`-drag operations and Hyprland's native `resize_on_border` path. It must not use a daemon, geometry polling, simulated pointer input, or a global mouse-button hook.

### Verified blocker

The target Hyprland build does not provide `misc:float_force_onscreen` or `misc:new_float_force_onscreen`. Its Lua event API also has no continuous or drag-end window geometry event. Native border resizing is handled directly inside Hyprland's drag controller, so the plugin cannot reliably clamp the resulting geometry from Lua without one of the prohibited workarounds.

Current Hyprland upstream has native force-onscreen support. Prefer upgrading to a stable packaged release containing that implementation rather than carrying a compositor patch.

### Intended native implementation

Once the target Hyprland package supports it:

1. Enable full floating-window clamping with `misc:float_force_onscreen = 2` and use `misc:new_float_force_onscreen = 2` for initial placement.
2. Set `general:float_gaps` to the desired floating edge margin (initially the current `gaps_out`, `10`).
3. Confirm that the implementation uses the current workspace monitor's logical work area after reserved areas, rather than the full monitor box.
4. Confirm behavior for windows whose requested minimum or current size exceeds the available work area; add a native work-area-aware maximum-size constraint if force-onscreen alone cannot keep all outer extents visible.
5. Version-gate the configuration so older Hyprland releases do not produce config errors.

### Acceptance checks

- Move a floating window beyond the left, right, top, and bottom edges and release it; the final outer geometry is clamped inside the work area with the configured gap.
- Resize from all four edges and all four corners; the final geometry remains inside the same bounds.
- Repeat with `Super` mouse dragging and native border resizing.
- Verify the bottom Omarchy bar remains unobscured and its reserved area is respected.
- Verify both target monitors independently at their configured fractional scales.
- Verify Wayland and WeChat XWayland windows.
- Verify moving, minimizing/restoring, snapping, and changing Float/Tiling mode do not bypass the constraint.
