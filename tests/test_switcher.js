#!/usr/bin/env node

const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")
const { spawnSync } = require("node:child_process")

const model = vm.createContext({})
vm.runInContext(fs.readFileSync("TaskListModel.js", "utf8"), model)
// Exercise the actual QML root functions, not a second implementation. Socket
// callbacks are delivered manually; this is not a real compositor/QML test.
const qml = fs.readFileSync("AppSwitcher.qml", "utf8")
const functions = Array.from(qml.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm), match => match[0]).join("\n")
assert.ok(functions.includes("function completeBegin("))

const monitors = [
  { id: 0, focused: true, activeWorkspace: { id: 1, name: "1" } },
  { id: 7, focused: false, activeWorkspace: { id: 11, name: "11" } }
]
function client(address, workspaceId, mru, extra = {}) {
  return {
    address: "0x" + address, workspace: { id: workspaceId, name: String(workspaceId) },
    monitor: workspaceId === 1 ? 0 : 7, mapped: true, class: "same.app",
    title: "Synthetic test window", focusHistoryID: mru, ...extra
  }
}
const clients = [client("a", 1, 0), client("b", 11, 1)]

function harness() {
  const dispatches = []
  const screens = [{ monitorId: 0 }, { monitorId: 7 }]
  const context = {
    TaskListModel: model, console,
    shell: null, opened: false, snapshot: [], selectedIndex: -1,
    targetScreen: null, snapshotRequestPending: false,
    pendingClients: null, pendingMonitors: null, commitWhenReady: false,
    pendingDirection: 0, debugEnabled: false,
    layerState: "hidden", hideWhenMapped: false, pendingActivation: null,
    switcherNamespace: "fatlj-app-switcher", luaLogWirePrefix: "custom>>fatlj.float-panel:log:",
    clientsSocket: { connected: false }, monitorsSocket: { connected: false },
    luaLogSocket: { connected: true },
    Quickshell: { screens, iconPath: value => value },
    Hyprland: {
      monitorFor: screen => ({ id: screen.monitorId }),
      dispatch: command => dispatches.push(command)
    },
    DesktopEntries: { byId: () => null, heuristicLookup: () => null },
    Qt: { callLater: callback => callback() },
    ListView: { Contain: 0 }, list: { positionViewAtIndex: () => {} }
  }
  context.root = context
  vm.createContext(context)
  vm.runInContext(functions, context, { filename: "AppSwitcher.qml functions" })
  return { root: context, dispatches, screens }
}

function mapped(root) { root.acceptCompositorEvent("openlayer>>fatlj-app-switcher") }
function closed(root) { root.acceptCompositorEvent("closelayer>>fatlj-app-switcher") }

// Both response orders, and Alt release before either/between/after responses.
for (const order of ["clients-first", "monitors-first"]) {
  for (const releaseAt of [0, 1, 2]) {
    const { root, dispatches, screens } = harness()
    root.step(1)
    assert.equal(root.clientsSocket.connected, true)
    assert.equal(root.monitorsSocket.connected, true)
    const responses = order === "clients-first"
      ? [() => root.acceptClientsResponse(JSON.stringify(clients)), () => root.acceptMonitorsResponse(JSON.stringify(monitors))]
      : [() => root.acceptMonitorsResponse(JSON.stringify(monitors)), () => root.acceptClientsResponse(JSON.stringify(clients))]
    if (releaseAt === 0) assert.equal(root.commit(), "pending-commit")
    responses[0]()
    assert.equal(root.opened, false)
    assert.equal(root.snapshotRequestPending, true)
    assert.equal(dispatches.length, 0)
    if (releaseAt === 1) assert.equal(root.commit(), "pending-commit")
    responses[1]()
    if (releaseAt === 2) {
      assert.equal(root.opened, true)
      assert.equal(root.snapshot[root.selectedIndex].representative.address, "b")
      mapped(root)
      assert.equal(root.commit(), "pending-close")
      assert.equal(dispatches.length, 0, "focus must wait for the compositor's close event")
      closed(root)
    }
    assert.equal(root.targetScreen, screens[0], "the overlay stays on the initiating monitor")
    assert.equal(root.snapshotRequestPending, false)
    assert.equal(root.opened, false)
    assert.equal(dispatches.length, 1)
    assert.ok(dispatches[0].includes("hl.get_workspace(11)"), "remote windows must not inherit workspace 1")
    responses[0]()
    responses[1]()
    assert.equal(dispatches.length, 1, "late/duplicate responses must not commit twice")
  }
}

{
  const { root, dispatches } = harness()
  root.step(-1)
  for (let i = 0; i < 6; i++) root.step(-1)
  root.acceptClientsResponse("[")
  root.acceptMonitorsResponse("{}")
  assert.equal(root.snapshotRequestPending, true, "partial responses must not complete the snapshot")
  root.acceptClientsResponse(JSON.stringify(clients))
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  assert.equal(root.selectedIndex, 1, "negative accumulated repeats must wrap to a valid index")
  assert.equal(dispatches.length, 0, "highlight changes must not activate windows")
  root.step(1)
  assert.equal(root.selectedIndex, 0)
  root.step(-1)
  assert.equal(root.selectedIndex, 1)
}

for (const cancel of [root => root.cancel(), root => root.resetRequest()]) {
  const { root, dispatches } = harness()
  root.step(1)
  root.commit()
  root.acceptClientsResponse(JSON.stringify(clients))
  cancel(root) // resetRequest is also the error handler for either socket
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  assert.equal(root.opened, false)
  assert.equal(root.clientsSocket.connected, false)
  assert.equal(root.monitorsSocket.connected, false)
  assert.equal(dispatches.length, 0)
  root.step(1)
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  root.acceptClientsResponse(JSON.stringify(clients))
  assert.equal(root.opened, true, "a failed/cancelled snapshot must allow a fresh request")
}

{
  const { root, screens } = harness()
  root.beginFromSnapshot([client("b", 11, 0)], monitors, 1)
  assert.equal(root.opened, true, "an empty focused monitor can switch to the only window on another monitor")
  assert.equal(root.selectedIndex, 0)
  assert.equal(root.targetScreen, screens[0])
  mapped(root)
  root.cancel()
  closed(root)
  root.beginFromSnapshot([clients[0]], monitors, 1)
  assert.equal(root.opened, false, "one already-active window is still a no-op")
  root.beginFromSnapshot([], monitors, 1)
  assert.equal(root.opened, false)
}

// Execute the real generated activation callback under a small Lua compositor
// mock to check routing and races without touching the running desktop.
function activate(command, setup = "", expected = "top:11,focus:11", assertEvents = "") {
  const program = `
local destination = { id = 11, name = "11", monitor = {} }
destination.monitor.active_workspace = destination
local minimized = { id = -91, name = "special:omarchy-minimized-11" }
local other = { id = 12, name = "12", monitor = {} }
local selected = { workspace = destination, fullscreen = 0, floating = true, address = "0xb" }
local exists, workspace_exists = true, true
local peers, actions, events = {}, {}, {}
local focused = nil
${setup}
hl = {
  get_window = function(selector) assert(selector == "address:0xb"); return exists and selected or nil end,
  get_workspace = function(id) assert(id == 11); return workspace_exists and destination or nil end,
  get_windows = function() return peers end,
  dsp = { window = {} },
}
hl.dsp.event = function(line) return function() table.insert(events, line) end end
hl.dsp.window.move = function(args)
  assert(args.workspace == "11" and args.follow == false and args.window == selected)
  return function() selected.workspace = destination; table.insert(actions, "move:11") end
end
hl.dsp.focus = function(args)
  assert(args.window == selected)
  return function() focused = args.window; table.insert(actions, "focus:" .. args.window.workspace.id) end
end
hl.dsp.window.alter_zorder = function(args)
  -- The real alter_zorder simulates pointer movement, which can refocus the
  -- initiating monitor even without any physical pointer movement.
  return function() focused = nil; table.insert(actions, args.mode .. ":" .. args.window.workspace.id) end
end
hl.dispatch = function(action) action() end
local callback = ${command}
callback()
assert(table.concat(actions, ",") == ${JSON.stringify(expected)}, table.concat(actions, ","))
if #actions > 0 then assert(focused == selected, "pointer refocus stole the final keyboard focus") end
${assertEvents}
`
  const result = spawnSync("lua", ["-"], { input: program, encoding: "utf8", timeout: 5000 })
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout)
}

{
  const { root, dispatches } = harness()
  root.beginFromSnapshot(clients, monitors, 1)
  mapped(root)
  root.commit()
  closed(root)
  const command = dispatches[0]
  activate(command)
  activate(command, "selected.workspace = minimized", "move:11,top:11,focus:11")
  activate(command, "selected.workspace = other", "")
  activate(command, "exists = false", "")
  activate(command, "selected.workspace = nil", "")
  activate(command, "workspace_exists = false", "")
  activate(command, "destination.monitor.active_workspace = other", "")
  activate(command, "destination.monitor = nil", "")
  activate(command, 'destination.name = "renamed"', "")
  activate(command, `
selected.fullscreen = 2
peers = {
  { address = "0xc", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xb", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xd", workspace = other, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xe", workspace = destination, floating = true, pinned = true, fullscreen = 0, allowed_over_fullscreen = true },
}`, "bottom:11,top:11,focus:11")
  // Another window owns the covering fullscreen state: the activated floating window still
  // has to become the top-most window above it, and the fullscreen owner is not lowered.
  activate(command, `
peers = {
  { address = "0xc", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xf", workspace = destination, floating = false, fullscreen = 2, allowed_over_fullscreen = true },
}`, "bottom:11,top:11,focus:11")
  // Nothing is fullscreen, so peer z-order is left alone.
  activate(command, `
peers = {
  { address = "0xc", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
}`)
  // A tiled target can never be drawn above a covering fullscreen window, so peers are
  // not hidden for it.
  activate(command, `
selected.floating = false
peers = {
  { address = "0xc", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xf", workspace = destination, floating = false, fullscreen = 2, allowed_over_fullscreen = true },
}`)
  // Debug mode adds counters and one journal line without changing the dispatch order.
  {
    const { root, dispatches } = harness()
    root.debugEnabled = true
    root.beginFromSnapshot(clients, monitors, 1)
    mapped(root)
    root.commit()
    closed(root)
    activate(dispatches[0], `
selected.fullscreen = 2
peers = {
  { address = "0xc", workspace = destination, floating = true, fullscreen = 0, allowed_over_fullscreen = true },
  { address = "0xe", workspace = destination, floating = true, pinned = true, fullscreen = 0, allowed_over_fullscreen = true },
}`, "bottom:11,top:11,focus:11",
      'assert(#events == 1 and events[1]:find("lowered=1", 1, true) and events[1]:find("pinned_above=1", 1, true), table.concat(events, "|"))')
  }
}

{
  const { root, dispatches } = harness()
  const hidden = client("b", -91, 1, { workspace: { id: -91, name: "special:omarchy-minimized-11" } })
  root.beginFromSnapshot([clients[0], hidden], monitors, 1)
  assert.equal(root.snapshot[root.selectedIndex].representative.minimized, true)
  mapped(root)
  root.commit()
  closed(root)
  activate(dispatches[0], "selected.workspace = minimized", "move:11,top:11,focus:11")
  activate(dispatches[0], "", "top:11,focus:11") // already restored since the snapshot
}

// Super+M leaves recent focus history on the minimized window. The next
// Alt+Tab must prefer another visible window, including on a different monitor.
{
  const { root, dispatches } = harness()
  const hidden = client("c", -91, 1, { workspace: { id: -91, name: "special:omarchy-minimized-11" } })
  const afterMinimize = [clients[0], hidden, client("b", 11, 2)]
  root.step(1)
  root.commit() // Also cover a quick Alt release before the snapshots arrive.
  root.acceptClientsResponse(JSON.stringify(afterMinimize))
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  assert.equal(dispatches.length, 1)
  activate(dispatches[0]) // Must select visible b, not recently minimized c.

  root.beginFromSnapshot(afterMinimize, monitors, 1)
  assert.deepEqual(Array.from(root.snapshot, item => item.representative.address), ["a", "b", "c"])
  assert.equal(root.snapshot[root.selectedIndex].representative.address, "b")
  root.step(1)
  assert.equal(root.snapshot[root.selectedIndex].representative.address, "c",
    "minimized windows remain reachable at the end of forward cycling")
  root.step(1)
  assert.equal(root.snapshot[root.selectedIndex].representative.address, "a")
  root.step(-1)
  assert.equal(root.snapshot[root.selectedIndex].representative.address, "c",
    "reverse cycling wraps to the minimized tail")
  assert.equal(dispatches.length, 1, "cycling only changes the highlight")
  mapped(root)
  root.cancel()
  closed(root)

  root.beginFromSnapshot([client("a", 1, 1), client("b", 11, 2), client("c", 11, 0)], monitors, 1)
  assert.deepEqual(Array.from(root.snapshot, item => item.representative.address), ["c", "a", "b"],
    "after restore, the next snapshot must use normal visible-window MRU order")
}

// A map request can still be in flight when Alt is released. Keep the layer
// alive until its map is acknowledged, then hide; never dispatch before close.
{
  const { root, dispatches } = harness()
  root.beginFromSnapshot(clients, monitors, 1)
  assert.equal(root.layerState, "mapping")
  assert.equal(root.commit(), "pending-close")
  assert.equal(root.opened, true)
  assert.equal(dispatches.length, 0)
  root.acceptCompositorEvent("closelayer>>unrelated-panel")
  assert.equal(dispatches.length, 0)
  root.step(1)
  assert.equal(root.snapshotRequestPending, false, "a pending close must not overlap a new presentation")
  mapped(root)
  assert.equal(root.layerState, "closing")
  assert.equal(root.opened, false)
  assert.equal(dispatches.length, 0)
  closed(root)
  assert.equal(root.layerState, "hidden")
  assert.equal(dispatches.length, 1)
  closed(root)
  assert.equal(dispatches.length, 1, "duplicate close events cannot activate twice")
  activate(dispatches[0])
}

for (const abort of [root => root.cancel(), root => root.abortPresentation()]) {
  const { root, dispatches } = harness()
  root.beginFromSnapshot(clients, monitors, 1)
  root.commit()
  abort(root)
  mapped(root)
  closed(root)
  assert.equal(dispatches.length, 0, "cancel or event-socket loss must discard the pending focus handoff")
  assert.equal(root.layerState, "hidden")
}

// An unexpected compositor close (e.g. monitor removal) never commits a selection.
{
  const { root, dispatches } = harness()
  root.beginFromSnapshot(clients, monitors, 1)
  mapped(root)
  closed(root)
  assert.equal(dispatches.length, 0)
  assert.equal(root.opened, false)
}

// Request responses can arrive before the event socket finishes reconnecting.
{
  const { root, dispatches } = harness()
  root.step(1)
  root.luaLogSocket.connected = false
  root.acceptClientsResponse(JSON.stringify(clients))
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  assert.equal(root.snapshotRequestPending, true)
  assert.equal(root.opened, false)
  root.luaLogSocket.connected = true
  root.completeBegin() // onRestored
  assert.equal(root.opened, true)
  mapped(root)
  root.commit()
  closed(root)
  assert.equal(dispatches.length, 1)
}

// A lost stream cancels the old intent. Recovery cannot replay an old selection.
{
  const { root, dispatches } = harness()
  root.step(1)
  root.luaLogSocket.connected = false
  root.acceptClientsResponse(JSON.stringify(clients))
  root.acceptMonitorsResponse(JSON.stringify(monitors))
  root.commit()
  root.abortPresentation() // onInterrupted
  root.luaLogSocket.connected = true
  root.completeBegin() // onRestored
  assert.equal(root.opened, false)
  assert.equal(dispatches.length, 0)
  assert.equal(JSON.parse(root.status()).eventConnected, true)
}

console.log("SWITCHER_TESTS_OK")
