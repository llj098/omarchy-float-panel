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
| `CSurfacePassElement::CSurfacePassElement` | the surface is placed at `box − ring`, covers `box + ring`, and is clipped to the box; popups keep Hyprland's own placement |
| `Desktop::CViewHitTester::windowSurfaceAt` | pointer coordinates are shifted by the same ring |
| `Render::IHyprRenderer::damageSurface` | a client's own repaint is damaged from the same origin the surface is drawn at |
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

## The frame is not drawn outside the window

The ring is the client's own decoration, and this compositor draws the window frame
itself (border, gaps, shadow when enabled). Showing the client's frame as well puts
a second frame around every such window: a Chromium or Electron window paints a
faint dark band across the whole ring, which is invisible over a dark wallpaper and
clearly visible over a light one, and a GTK round-corner client paints a real drop
shadow there.

So the surface pass clips the surface to the window box: `clipBox` is the renderer's
scissor, in output-local scaled pixels, and it is set to the box the surface was
placed against. The client keeps drawing its frame — that is its business and its
resize band sits inside the geometry anyway — but what lands outside the window box
is not composited. Input is untouched: pointer coordinates are still shifted by the
same ring, and the client's resize band is inside the geometry, so edge resizing
keeps working.

This is not app-specific: it holds for any client that commits a window geometry
smaller than its surface. There is no configuration value and no application
knowledge involved.

## A client's repaint is moved with it

The compositor treats a window's position as the origin of its surface: when a
client commits, the part of the surface it repainted is moved to the output from
that position (`CWindow::commitWindow`: `damageSurface(surface,
m_realPosition->goal())`). Placing the surface one frame margin before that
position therefore separates two things that have to agree — where a client's
pixels are drawn and which pixels are considered changed — and every partial
update lands one frame margin away from the pixels it describes. The client's own
repaint is then drawn outside the damaged area, and the area that was damaged
keeps the previous frame until something repaints the whole window. Inside a text
line that reads as a selection highlight or freshly typed text that is only
partly revealed and heals as soon as the window is fully repainted.

So the damage origin is shifted by the same ring the placement uses, which puts
the two back on one origin. Measured in the private headless lab on a 900×560
Chromium box at (200,160) with a 10-pixel ring, same text selection, client damage
rect untouched between the two runs:

| | damage extents logged by `debug:log_damage` |
| --- | --- |
| placement only | `xy: 210, 179 wh: 860, 541` |
| placement and damage | `xy: 200, 169 wh: 860, 541` |

The surface is drawn at (190,150), so the client's own damage rect (10,19 in
surface coordinates) lands on (200,169) in both runs. The first row points at
(210,179) instead — one frame margin down and to the right of the pixels the
client actually painted — and the second row names that rect exactly.

The negotiation cannot be used instead. Hyprland implements `zxdg_decoration` and
answers `MODE_SERVER_SIDE` to every request (`src/protocols/XDGDecoration.cpp`:
the request is ignored and the server-side mode is sent back), but Chromium never
reads that answer: `WaylandToplevelWindow::OnDecorationModeChanged` is only called
from its own preference changes, so the client keeps its frame no matter what the
compositor says. The app-side lever that does exist is Chromium's *Use system title
bar and borders* preference (`browser.custom_chrome_frame = false`), and it removes
the frame and the ring with it — measured: `geometry == surface`, no margins. The
cost is that Chromium then stops drawing its own window controls, and this
compositor draws no titlebar to replace them, so the window loses its minimise,
maximise and close buttons. Clipping keeps the client's controls and removes only
the pixels outside the window.

Popups are left to Hyprland on purpose. Its popup pass already draws the window
surface at `box − geometry origin` before placing the popups, so a popup is drawn
relative to the same origin this plugin now uses for the main surface; shifting the
pointer coordinate with the same margin makes popup input agree with where the
popup is drawn. Upstream's own popup hit test works from the unshifted box, so
before this change a menu on a ring client was hit-tested one frame margin away
from where it was drawn.

## Verification

Private headless Hyprland, real pointer events, screenshots plus `hyprctl` facts:

- a Chromium window at a 1030×960 box reports `geometry 1030×960`, `surface
  1050×980`, and the content starts exactly at the box edge (border outside it, ring
  over the gap);
- a click 200px right of the box edge reaches the page as `clientX = 200`, not 190;
- on a light grey backdrop at scale 1.6, an unmaximized Chromium window darkens the
  pixels outside its border by a flat 5/255 across the whole ring; with the clip the
  same pixels differ from the backdrop by 0 (screenshots of the window in place and
  of the same area with the window moved away, compared pixel by pixel);
- a window that moves away repaints its old ring area completely, and the window at
  its new position is clipped the same way;
- pointer coordinates stay exact: a click 100 logical pixels right of and 99 below
  the page origin arrives as `clientX = 100, clientY = 99`, and one 400/305 away as
  `clientX = 400, clientY = 305`;
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
- Damage the compositor raises on its own (a move, a resize, a decoration or a
  titlebar) still comes from the window box, which is exactly the area the clipped
  surface covers, so a ring client that moves repaints the ring it just vacated
  (measured, no stale pixels).
- A window that the plugin decorates with its own titlebar keeps that decoration
  inside the window box, so a ring client's top margin overlaps the bottom of the
  titlebar by one frame margin. The client's ring cannot be dropped there without
  moving its content; every client on this desktop that draws a ring is excluded
  from the plugin titlebar, so this is a theoretical case.
- A single-window screen capture uses the window box, so it cuts the ring that the
  surface draws outside it. Monitor captures are unaffected.
- On a fractional monitor scale a client cannot express its frame margin exactly:
  a 1426-logical-wide Chromium window is 2281.6 physical pixels, so the client
  rounds its surface, its geometry and its margin independently. Hyprland stores
  the window-geometry origin as an integer, so what it reports can be 1-2 logical
  pixels short of the margin the client actually drew. The surface is then placed
  that much too far towards the box: a hairline of the ring shows inside the border
  (the band the client drew there is faint, but it is inside the window, so the clip
  does not remove it) and pointer coordinates carry the matching sub-2px error.
  Measured at scale 1.6: Obsidian (ring exactly 10) is pixel-exact, a Chromium
  window at 1426x778 shows 1.9 logical pixels on all four sides, and the same
  Chromium client at a size whose 1.6 multiple is whole (800x500) is exact again.
  The exact origin is not recoverable from the compositor side; closing the last 2px
  needs Hyprland itself to carry a fractional window geometry.
