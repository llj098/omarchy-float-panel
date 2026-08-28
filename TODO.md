# TODO

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
