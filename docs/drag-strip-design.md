# Lua-controlled floating-window drag strip

## Current refinement: fixed corner gaps (2026-09-08)

The user supersedes the old whole-top tradeoff: Lua chooses **height=10 and hit_inset=24 logical pixels per side**. Only the middle strip paints and moves; both upper gaps leave native border cursors/input available within the compositor's existing grab envelope. The fixed inset does **not** promise to match every theme's rounding. No effective-rounding export, rule matching or automatic corner calculation is used.

The approved additional mechanism is one scoped `CDecorationPositioner::getWindowDecorationBox(IHyprWindowDecoration*)` hook. On exact source `efb50993780079460b0cbed1363e2166a2de1d9f`, stock STICKY top assigns full width and ABSOLUTE replies are empty (`DecorationPositioner.cpp:196–205,246–251,405–415`); core uses that box both for input routing (`Window.cpp:450–468`) and native cursor suppression (`InputManager.cpp:2145–2239`). Narrowing only paint/manual hit cannot free corners. The hook returns the shared logical paint/hit rectangle only for owned decorations, delegating every other decoration to the original function. It never mutates cached positioning replies, layout extents or decoration flags. The existing exact build/running-commit guard and all-or-rollback registration cover this hook; unload removes it after owned decorations are detached.

The shared rectangle follows current main-surface geometry plus existing workspace/floating render offsets. Horizontal inset is applied before monitor translation/scaling for paint; manual hit and core box use global logical coordinates. Width clamps to zero when twice the inset reaches/exceeds window width. Zero-width rectangles neither paint nor claim a press (Hyprutils 0.14.1 box containment is half-open). Native border resize may still act in the empty center; that is not strip input. Style, eligibility, drag acceptance and all baseline `81df685` diagnostics/geometry policies remain Lua-owned and unchanged.

## Scope and status

Design approved in direction by the user: implement the decoration/input mechanism in C++, expose events and interfaces to Lua, and keep interaction and geometry policy in Lua. Implement and test in isolation; no physical-machine deployment, push, or main-branch merge is authorized by this task. Implementation baseline is `71b00da8818c48cf0ca5be82b84aa62fee8ef4e5` (tree equivalent to `761e140`). The original checkout contains five unrelated uncommitted experiments; do not import them.

This feature is an alternative to Super + left-button dragging, not its removal. It gives user interaction an explicit source and completion point. It does not solve every existing topology/anchor problem, application-initiated geometry ambiguity, or missing post-work-area notification. Existing persistence format, AppSwitcher/TaskList, standard keybindings, placement rules, and release/deployment system are out of scope.

## Implementation and bounded acceptance

Native bridge 0.6.0 implements the attached primitive in `native/src/drag_strip.cpp`; `float-panel.lua` loads and wires `drag-strip.lua` only when both new capabilities are available. Missing/older bridge retains existing behavior. No QML/JS or binding changes are required.

Only the inset middle top strip moves. Side/bottom and upper-corner native resizing, plus original Super controls, remain. In addition to the two raw `CDragStateController::dragBegin/dragEnd` hooks, the single owned-decoration box hook above aligns core input/cursor routing with paint. No InputManager hook is used.

Current acceptance is deliberately bounded: taller center hover and unchanged geometry/work area; center native move; both upper native corner cursors and diagonal resize within the existing grab envelope; middle/corner transitions; original Super move/resize; automated regressions; one 1.25-scale smoke; basic new-hook cleanup. The extended checklist later in this document remains a design reference, **not a claim of exhaustive desktop certification**. Optional lock/session, arbitrary grabs/input-capture integrations and elaborate scene/topology cases are not certified. The VM Shell lock/idle subsystem was not repaired.

The module exports `new(native, policy)` returning `enabled`, `reconcile`, `pointer`, `drag`, `active`, `forget`, `interrupt`, `shutdown`. Injected callbacks are `identity`, `address`, `eligible`, `style`, `snapshot`, `equal`, `destination_valid`, `accept`. Production identity prefers `window.stable_id`. `float-panel.lua` supplies actual workspace/window semantics, theme style, independent geometry snapshots, managed-tag removal, final anchor rebase and existing persistence exclusions. Active-window reflow and early workspace-transfer acceptance are guarded per window. Other windows still reflow. Paint is cached only after successful native updates; existing primitives receive style changes.

### Exact-version mechanism decisions

Source/header checks and the disposable guest use Hyprland `efb50993780079460b0cbed1363e2166a2de1d9f` / 0.56.2 and Lua 5.5.1:

- `input.mouse.button` is pre-bookkeeping. An accepted strip press and its paired release are **both** consumed there, never mixing a core-recorded press with a cancelled release. Unclaimed buttons, modifiers, existing held buttons and foreign native operations are not claimed. A release tombstone survives decoration removal/config reload. Native owns no synthetic input or per-motion geometry loop.
- Starts use `CLayoutManager::beginDragTarget(exactTarget, MBIND_MOVE, std::nullopt, true)`. Completion is emitted after the original `dragEnd` returns, including its final `setTargetGeom`. Null targets, rejected starts and synchronous removal are guarded.
- A real test found that an external floating-mode dispatcher ends core dragging **before** emitting `window.floating`. Merely accepting every raw end saved an aborted intermediate edit. The observer now tracks the initiating physical button: a core end before that button's release is `abort`, not `end`. This also conservatively aborts modifier-first/other-key termination; native Super behavior remains, but those orders are not certified as explicit persistence acceptance. No geometry or eligibility decision is made in C++.
- Stock sticky top positioning has `reserved=false` and `DECORATION_NON_SOLID`; the scoped box hook narrows only input/cursor routing, not layout reservation. The ten-pixel inset paint is a standard `CRectPassElement`, transformed with window/workspace motion and render-monitor scale. Hover routing is a coalesced idle callback scheduled by actual input/scene/geometry changes, never a timer or continuous scan. Cursor uses the lowest-priority override slot and restores it symmetrically; coexistence with another plugin using that same slot is not certified.
- The SDK's `removeWindowDecoration` leaves removal queued for hidden/unmapped windows and retains registration pointers. Teardown drains only this primitive's vector/pending/registration entries while its vtable remains loaded. No extra ABI hook is needed.
- `float_panel.window_changed` forwards raw `window.floating`, `window.updateRules`, and `window.openLate` facts. `window.open` is too early to assume final visibility. Lua alone reconciles eligibility.

Selected interruption policy invalidates pending acceptance before finishing bridge-owned input. Close/mode loss removes the primitive; topology callbacks interrupt then retain the existing reflow rules. Native loss facts invalidate Lua pending edits. No-op and aborted interactions do not invoke explicit drag acceptance. Existing startup/reload rebasing and general geometry-difference heuristics remain unchanged; this is not an interruption rollback or topology/anchor overhaul.

## User-visible behavior

- Lua enables a strip on mapped, visible floating windows in a regular plugin-enabled Float workspace. Native fullscreen, minimized/special workspace, and auxiliary no-border/menu/tooltip windows do not receive it. Use existing compositor semantics and project Lua helpers, never application class/title lists. Parent/transient relationship alone is not a reason to disable dragging an ordinary dialog.
- The strip is attached to the window, not an independent always-on-top surface. It follows actual rendered window motion, stacking, workspace animation, and per-monitor scale.
- Its input region remains available while its paint is hidden. Pointer entry shows a slightly thicker top-edge strip and a grab cursor. Pointer leave hides it unless an owned drag is active. No additional focus changes on mere hover beyond Hyprland's existing follow-mouse behavior.
- Lua style: 10 logical-pixel height and 24 logical-pixel horizontal inset per side, extending outward from and overlapping the existing top border, no client-content intrusion, no work-area or client-size reservation. Both paint and input are shortened, leaving upper corners to native resizing within the existing grab envelope. Side/bottom resizing is untouched. Start with simple solid paint, no blur, title text, buttons, or animation framework. Reuse current configured border/theme color where the public value can be read reliably; report a limitation rather than introduce a theme daemon or dependency.
- Left-button press claims this interaction and starts the exact window's native move operation. Hyprland retains its own drag threshold, motion, snapping and monitor transfer behavior. Do not implement per-motion window positioning in the plugin. No synthetic modifier/button injection.
- A click with no actual geometry change must not remove managed tags, rebase, or write persistence. Moving/resize completion automatically accepts final geometry in Lua; no explicit save shortcut.
- Initially a half-screen or geometry-maximized floating window keeps its current size while moving. Only a real completed edit releases the old managed intent. Do not add a new restore-under-pointer geometry algorithm in this feature. Leave such a UX change for a separately reviewed Lua policy.

## Why native is necessary and its limits

Verified against Hyprland `efb50993780079460b0cbed1363e2166a2de1d9f` (0.56.2):

- `HyprlandAPI::addWindowDecoration` and `IHyprWindowDecoration` are C++ interfaces; no equivalent Lua decoration renderer/input region exists.
- `SDecorationPositioningInfo::reserved=false` avoids geometry reservation. Hit/input extents and paint bounds must not be confused with client/work-area geometry.
- `CWindow::checkInputOnDecos` supports button/axis and decoration drag/drop notifications, not pointer enter/leave.
- Official matching hyprbars (`7644cecdb947060682891a0db2a0cdc5c0b9e704`) uses compositor mouse move/button subscriptions and native dragging. It is a source reference, not a new dependency or code to copy wholesale.
- A single compositor pointer-motion subscription is allowed for this feature's decoration hit routing. This is the explicitly discussed exception to the previous blanket restriction. It must not consume ordinary motion, record trajectories, or forward every desktop coordinate to Lua. Pointer observations are event-driven, not timers or a polling loop.
- `CDragStateController::dragBegin/dragEnd` have no general EventBus equivalents. The existing decoration `INPUT_TYPE_DRAG_END` is a drop-target callback, NOT a general notification that a user's window move ended. If hooks are used to expose the lifecycle, keep them exact-version-checked, application-independent and observational.
- Public Lua mouse dispatcher actions depend on current keybind press state (`Config::Actions::state()->m_passPressed`). Calling one blindly from a decoration callback is not a reliable substitute for an explicit native start/finish mechanism.

Native may own render resources, weak window references, hit/capture routing, event registration and raw interaction sequence identifiers. These are mechanism lifetimes, not placement state. Native must not decide Float eligibility, keep `prev`, clear managed tags, fit/reflow a window, persist geometry, classify applications, or infer whether a geometry change was an intentional edit.

## Implemented API contract v1

All functions use the existing `hl.plugin.float_panel` namespace. The six primitive operations below return a boolean. `capabilities()` and `window_semantics()` return tables. There is no generic widget toolkit.

| Function | Contract |
| --- | --- |
| `capabilities()` | Booleans `maximize_request_event`, `decoration_input_v1`, `drag_lifecycle_v1`; new capabilities are true only after complete registration. Missing capability disables the feature cleanly. |
| `decoration_set(address, options)` | Create/update one attached primitive. Options: `visible` boolean, `height` logical pixels (1–64), `color` ARGB integer (0–0xffffffff), `cursor` name string. `hit_inset` is a finite nonnegative logical-pixel distance per side, default 0; it shortens both paint and input. Negative/NaN/infinite values fail without changing the primitive. Width clamps to zero at inset >= half window width, with no strip paint/input. `height` defaults to 6 when omitted; production Lua explicitly sends 10/24. Hiding paint does not remove input. |
| `decoration_remove(address)` | Idempotent teardown, including pointer ownership and cursor cleanup belonging to this decoration only. |
| `decoration_capture(address, button)` | Claim a currently delivered decoration press; pair its later release even if pointer leaves or the window moves. Reject invalid/reentrant/foreign claims. Returns boolean, no token. |
| `decoration_release(address)` | Release only this decoration's capture. Safe if already released. Do not finish another window's native operation. |
| `drag_begin(address, mode)` | Start native interaction for this exact window, not whichever window is focused. Use the existing layout controller. Reject unsafe/invalid calls and an already-owned foreign drag. Only `mode="move"` is accepted; no custom geometry implementation. |
| `drag_finish(address)` | Finish only an operation started/owned by this bridge for the matching target. Safe no-op when none. Native completion is delivered after Hyprland's final synchronous geometry/layout work, not before it. |

All address-based calls validate live ownership on every access. Lua interaction maps use stable window identity where available, not address alone; native keeps weak references and operation IDs so address reuse cannot inherit an interaction. Bad inputs return failure without compositor crashes. Header/library and running Hyprland commit mismatch remains a load refusal.

Events use the existing native custom EventBus -> `hl.on` mechanism, not journald IPC and not a new socket. The event payload must fit the existing primitive/window custom-event types:

- `float_panel.decoration_pointer(window, phase, button)`: `enter`, `leave`, `press`, `release`, `lost`. Zero button for non-button phases. Emit transitions, not continuous hover/motion noise. During capture, route the matching button's release to its owner independently of cursor position.
- `float_panel.window_changed(window)`: raw floating, rule-update or final-open fact; no native eligibility filtering.
- `float_panel.drag(window, phase, mode, sequence)`: `begin` before native work; `end` after its final work and observed initiating-button release; `abort` on interruption; `rejected` on failed start. Mode is `move` or `resize`; sequence is a monotonic decimal string. Mode identifies the native move/resize mode; sequence is an opaque per-operation ID. A before-start attempt is not proof it succeeded. Every announced attempt must terminate exactly once, including rejection or nested native cleanup. Do not label an ambiguous core end as a successful user edit; Lua still checks state and final geometry.

Lifecycle notification must also observe original Super dragging and native border/Super-right resizing if this capability is advertised as general. Do not claim general coverage while only instrumenting the new strip's start/finish wrappers. Lua ignores ineligible windows; C++ does not filter by workspace mode.

Registration and reload: extend the existing maximize-event reannouncement pattern for all added events. No duplicate handlers, old Lua-state references, stale decoration/capture state, or callbacks into an unloaded plugin. Remove owned decorations while implementation code is still valid. Partial initialization must roll back every already-registered resource. A hook-registration failure must disable the new capability or fail loading clearly, never advertise it as working.

## Input, rendering, and safety invariants

1. Hit testing follows compositor stacking and visibility: the actual exposed window only, with popups, top/overlay surfaces, session lock, seat grabs/input capture and existing native interactions respected. An inactive window's strip cannot steal input through a covering window. Core `windowAt` alone is not enough to exclude top-layer surfaces.
2. Use decoration input routing where it is sufficient. If paired button capture needs the global button subscription, limit consumption to the accepted press and its paired release. Ordinary content clicks, right clicks, modifier bindings, scrolls and unrelated button releases must retain normal behavior.
3. `input.mouse.button` emits BEFORE Hyprland's held-button bookkeeping; cancelling it prematurely can strand internal button state. Trace the complete path before selecting a capture strategy. Do not copy hyprbars' focus-gated release behavior as a guarantee against stuck drags. Test both release over the strip and release outside it.
4. Paint, manual hit and core decoration box share the same inset rectangle. Only owned decoration boxes are adapted; no global grab-area changes, mouse-dependent flags, negative extents or cached positioning mutations.
5. Cursor override ownership is narrow and symmetric. Hover must not overwrite drag, resize, lock or other higher-priority cursor state. Teardown restores the underlying cursor rather than hard-coding `left_ptr`.
6. Core native drag retains pointer delivery while captured; no custom per-motion move/resize loop. Do not call `dragEnd` when its target is null; 0.56.2 code assumes an extant target in parts of that method.
7. Callbacks may cause Lua to remove a decoration or close its window synchronously. Avoid accessing freed `this`, vector iterators, callbacks or window pointers after emitting to Lua. Prevent reentrant start/finish and duplicate terminal notifications.
8. Hover must be invalidated if its window disappears, is covered, changes workspace/mode/fullscreen state, or its decoration moves away under a stationary pointer. Use actual input/scene/lifecycle updates rather than a continuous timer. Avoid rendering reentrancy when delivering Lua callbacks.
9. Logical sizing and paint/hit transforms follow the rendered window and the monitor receiving that render pass. No fixed physical DPI, per-monitor special-case scripts, or exclusive-zone changes. Ineligible surfaces cannot acquire paint or input by C++ guessing a classification.
10. Close/unmap, destroy, lock, mode disable, config reload, plugin unload and ownership loss all release only owned resources. Aborted interactions must not accept a new anchor. Existing general anchor close/remap bugs are not to be silently declared fixed.

## Lua integration

Prefer a small isolated Lua interaction module with injected project callbacks, or a similarly narrow block if that is simpler and scanner-safe. Avoid a broad refactor of the 1,700-line policy file. Preserve the Omarchy keybinding scanner behavior (`safe_ipairs` for fake `hl` proxies); module loading must work from the installed plugin location and in tests.

Lua owns states equivalent to `idle -> hovered -> pressed/dragging -> idle/hovered`; state is keyed by stable identity and native operation sequence. It determines eligibility, style, left-button action, whether to capture and start, and cleanup. Native keeps only the mechanisms required to deliver facts.

- Startup/remap/mode/fullscreen/workspace changes reconcile decorations through existing reliable Lua events and owned mode functions. `window.floating` is not currently a public Lua event; do not invent it. If external floating changes cannot be observed through existing public rule/config events, expose that existing raw EventBus fact minimally or document the narrowly bounded limitation. No eligibility logic in native.
- On native begin, eligible windows snapshot current geometry, workspace/monitor, existing managed intent and anchor. Do not clear tags, resize, or rebase merely on button press or on a rejected/no-op attempt.
- During a native interaction, prevent the existing plugin reflow handler from fighting the actively dragged window or rebasing its intermediate geometry. This is a per-window ownership guard, not a global topology debounce. Other windows continue to process real work-area changes immediately.
- On a normal post-native end, compare the final geometry against the operation's before geometry in Lua. If unchanged, do nothing to tags/anchor/persistence. If actually changed and still eligible with a valid destination monitor/work area, clear superseded managed tags, establish `prev` using the final destination geometry and existing bounds helpers, then persist through the existing eligibility policy. Do not bypass application-specified-placement persistence rules.
- A drag moving the window to another workspace must not rebase in the early `window.move_to_workspace` callback. The general drag completion is the later acceptance point for this owned operation. Outside this operation, retain and document the existing unsupported external-single-window-move boundary.
- Interruption by topology, lock, destruction or mode loss must not be mistaken for user completion. When the available facts do not establish a safe completion, invalidate the Lua pending edit before finishing owned input and avoid a new `prev`. Document the selected interruption rule; do not guess geometry sources.
- Do NOT globally remove the old geometry-difference rebase heuristic in this feature unless all affected paths are explicitly redesigned and tested with review. Keep existing unrelated behavior, and state clearly that this feature does not cure all WeChat/topology anchor defects. The new explicit drag path must not rely on that heuristic for its own correct acceptance.

Runtime diagnostics, if added, follow the existing privacy-safe Lua custom IPC -> AppSwitcher QML `console.info()` -> journal path and marker. At most useful begin/end/abort summaries, no per-motion logs, titles, input content, private plugin log files, subprocess logging or native logger additions. Test harness artifacts are distinct from installed runtime logging.

## Validation and acceptance

### Local automated tests

The original expanded checklist below is retained as design context. The final user-scoped delivery uses the bounded acceptance listed above; unexecuted optional cases must be reported, not silently marked passed.

Run the existing static validator, JS model tests, Lua syntax, Lua policy tests and scanner test; run the full validation script where tool/import dependencies exist. Extend stubs to model real event ordering, not a fictional immediate final geometry. Existing tests must remain meaningful and passing.

New tests must cover:

- Capabilities absent/older native: clean fallback and Super bindings unchanged.
- Lua policy controls eligibility, appearance and action; native contains no class/title, Float/workspace, placement, persistence or `prev` decisions.
- Enter/leave changes paint only; repeated transitions/no-op updates do not change client geometry, reserve work area or log continuously.
- Left press plus paired release, release outside, no-op click, rejected drag, duplicate end, stale sequence and reused address.
- Real move changes `prev` once after the native final step; final step occurring after early workspace callback is modeled explicitly. Subsequent work-area mapping starts from the new `prev`.
- Native resize and fallback Super move feed the same completion policy when advertised as supported.
- A work-area event during drag does not trigger geometry fight/intermediate rebase; other windows still reflow. Test cancellation, and do not pretend all topology provenance is solved.
- Managed tags retained on click/no-op and removed on a real completed edit; persistence eligibility remains unchanged.
- Unmap/destroy/reload/mode-disable/lock during interaction cleans capture and cursor without saving an aborted edit or mutating a reused window.

### Native compilation and real compositor test

The local host has no `hyprland.pc`. Use a NEW disposable overlay of the authorized immutable base; the implementer is authorized to boot and stop its own test VM only. Never connect to or modify the physical machines (88,149,etc.) or existing unrelated VMs.

- Base: `/home/ljx/data/omarchy-vm/omarchy-iso/test-runs/omarchy-4.0.1/base.qcow2`.
- Required base SHA-256 before AND after: `45266ff4c3828676563d49ede47701ea52d9ced2ffbe59019c0846d117278af9`.
- SSH key alongside base: `id_ed25519`; guest user **`omarchy`**, NOT `lj`. The original successful fixture sessions and a fresh-overlay authentication check both verify this account.
- Create a new run directory under that base's `runs/`, a fresh backing overlay, and independent writable OVMF vars copied from `/usr/share/edk2/x64/OVMF_VARS.4m.fd` (verify actual installed path). QEMU code firmware must be read-only.
- Allocate unused localhost SSH/VNC ports and unique QMP socket/PID file; 2233/5905 were free when this design was written, but recheck. Existing QEMU processes on SSH 2228/3232 are NOT ours and must remain untouched.
- Useful old harness reference: `runs/20260904-201357-logged-resize-topology-history-repro/reproduce-logged-history.sh`. It is not a valid new-feature test; numeric `workspace=2` calls there did not reliably target the workspace. Use the source-verified string form `workspace="2"` and verify actual placement.
- Build the exact implementation snapshot against guest Hyprland headers; verify loaded plugin version/capabilities and no config errors. Baseline base may need isolated plugin installation/loading; do not upgrade Hyprland or patch its source.
- QMP USB-tablet/button injection is permitted ONLY as a VM test harness; no installed runtime input simulation. Demonstrate actual hover pixels/cursor state and actual native drag, not merely mocked event emission or dispatcher moves.
- The original expanded target included hover, unmodified drag, no-op, outside release, content, covered-window/top-popup input, original Super move/resize, two scales, and reload/destroy cleanup. Current required acceptance is the bounded set above; the fixed inset leaves both upper corners outside the move strip. Preserve structured geometry/capability/config-error evidence and privacy-safe screenshots of controlled empty probe windows.
- Synthetic HEADLESS monitor tests demonstrate only that synthetic path. They are not proof of physical monitor hotplug behavior. Do not add an unrelated external single-window workspace move and call it a topology reproduction.
- Stop only the test VM that this run started, confirm base hash unchanged, and report runtime failures/blockers honestly. Passing Lua mocks or a successful compile alone is not full GUI validation.

## Delivery

Keep commits on the isolated feature branch. Include exact API/event documentation, source, focused tests and a concise result with measured added C++/Lua/test lines, commands, environment versions, evidence paths, and remaining limitations. Do not sacrifice cleanup or split policy incorrectly to meet an estimated line budget (previous estimate: 300–500 new C++, 150–250 Lua, 200–400 tests). If scope/size materially grows, explain the reason rather than claiming the estimate was exact. No `.so`, disk image, runtime evidence archive or result handoff in Git. No main merge/push/deploy. Main assistant reviews before any next action.
