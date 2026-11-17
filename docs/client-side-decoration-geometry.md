# Client-side decoration margins

A Wayland client that draws its own window frame — Chromium and Electron windows,
GTK, rounded-corner clients — declares a window geometry that is smaller than the
surface it commits. The margin between them is the frame itself: the drop shadow,
the clear band a resize grip needs, the rounded corner. Everything the app draws
*inside* the geometry is the window; the ring is what surrounds it.

The protocol describes what a compositor does with that ring:

- the geometry rect is the window, and the compositor places the window by it;
- `xdg_toplevel.configure` carries the **content** size, so the client lays itself
  out for the box and then adds its frame around that box;
- the surface is therefore placed at `box − geometry origin`, with the ring
  reaching outside the box into the gap (Mutter: `buffer_rect = frame_rect −
  frame_extents`; Sway stopped clipping to the geometry in 2024 for exactly this
  reason, sway PR #8033);
- pointer coordinates are measured from the same origin the surface is placed at,
  so a click lands on the pixel it was aimed at.

## What Hyprland does instead

Hyprland has no concept of client decoration margins. `sendWindowSize` reports the
window box as the content size, and `IHyprRenderer::renderWindow` places the surface
at the box origin with the box as its destination box, while the popup pass alone
subtracts the geometry origin (`renderdata.pos -= geom.pos()`). The result for a
ring client: its frame is drawn *inside* the window, the content is inset by the
margin, a transparent band appears between the window border and the content, and
the app's own window controls sit away from where they are drawn. Upstream tracks
the same two defects (surface placement ignoring the geometry origin, and the origin
being added to the size limits) in Hyprland discussion #15870.

## What this plugin does about it

The bridge translates between Hyprland's box and the client's geometry, with no
application knowledge and no configuration:

| Hook | Purpose |
| --- | --- |
| `CXDGToplevelResource::setSize` | the configure carries the box, which is the content size |
| `CSurfacePassElement::CSurfacePassElement` | the surface is placed at `box − ring` and covers `box + ring`; popups keep Hyprland's own placement |
| `Desktop::CViewHitTester::windowSurfaceAt` | pointer coordinates are shifted by the same ring |
| `CXDGToplevelResource::layoutMinSize` / `layoutMaxSize` | the client's declared limits are content sizes, not content plus frame |

The ring is read from the client's own commit (`geometry` versus surface size) and
only when it is symmetric — the same margin on all four sides, which is what a frame
looks like. A surface that is merely a different size than its geometry (a client
that has not yet committed a frame for its new box, or one mid-resize) is left alone;
placing by a ring that does not exist yet would shift the window.

Because the margin is part of the surface the client already committed, this needs
no state, no per-window bookkeeping and no policy in Lua: the box stays the content
rect everywhere else in the plugin (persistence, maximize, minimize, snapping), and
Lua keeps every decision.

## Verification

Private headless Hyprland, real pointer events, screenshots plus `hyprctl` facts:

- a Chromium window at a 1030×960 box reports `geometry 1030×960`, `surface
  1050×980`, and the content starts exactly at the box edge (border outside it, ring
  over the gap);
- a click 200px right of the box edge reaches the page as `clientX = 200`, not 190;
- Obsidian's own window controls work through real clicks: maximize covers the work
  area (`[10,10] 1580×980`), restore returns to the exact previous box, minimize
  parks the window in the per-workspace store twice in a row, close closes;
- `layoutMinSize`/`layoutMaxSize` return the client's own numbers, so a client that
  pins its size is not clamped to a box larger than the size it pinned.

## Known limits

- XWayland windows keep Hyprland's behaviour: they declare frame extents, not a
  window geometry, and are not touched.
- A workspace slide clips the ring to the window bounding box for the duration of
  the animation.
- Damage on window movement comes from Hyprland's own window box. With the
  compositor shadow enabled (the default) that box already covers the ring; with
  shadows disabled, a moving ring client can leave up to one frame margin of stale
  pixels behind it. The ring is transparent for Chromium and a shadow for GTK, so
  this is invisible in practice; it is recorded here rather than patched with a
  further hook on `damageWindow`.
