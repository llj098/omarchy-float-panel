#!/usr/bin/env bash
# Zero-impact verification against the live session.
#
# Nothing is moved, minimized, focused or drawn: the running compositor is only
# asked for j/monitors and j/clients, and the real plugin sources are evaluated
# offscreen in node against those snapshots (plus synthetic minimized stores, so the
# scenarios do not have to exist on the real desktop). Use this first; it cannot
# disturb whoever is working on the machine.
#
# Results are printed and also collected into .debug/bg/summary-model.txt
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=$REPO/.debug/bg
mkdir -p "$OUT_DIR"
SUMMARY=$OUT_DIR/summary-model.txt
: > "$SUMMARY"

: "${HYPRLAND_INSTANCE_SIGNATURE:?run this inside the session}"
: "${XDG_RUNTIME_DIR:?run this inside the session}"

CLIENTS=$OUT_DIR/live-clients.json
MONITORS=$OUT_DIR/live-monitors.json
hyprctl clients -j > "$CLIENTS" 2>/dev/null || { echo "FAIL: cannot read clients" | tee -a "$SUMMARY"; exit 1; }
hyprctl monitors -j > "$MONITORS" 2>/dev/null || { echo "FAIL: cannot read monitors" | tee -a "$SUMMARY"; exit 1; }

{
  echo "windows on displayed workspaces: $(python3 -c "
import json,sys
c=json.load(open('$CLIENTS'))
print(sum(1 for w in c if w.get('mapped') and not str(w['workspace']['name']).startswith('special:')))")"
  echo "minimized (plugin store):        $(python3 -c "
import json
c=json.load(open('$CLIENTS'))
print(sum(1 for w in c if str(w['workspace']['name']).startswith('special:omarchy-minimized-')))")"
  echo "minimized (shared store):        $(python3 -c "
import json
c=json.load(open('$CLIENTS'))
print(sum(1 for w in c if w['workspace']['name'] == 'special:minimized'))")"
  echo "SUPER+M bindings:                $(hyprctl binds -j | python3 -c "
import json,sys
print([b['description'] for b in json.load(sys.stdin) if b.get('key') == 'M' and b.get('modmask') == 64])")"
  echo "switcher global shortcuts:       $(hyprctl globalshortcuts | grep -c 'fatlj.float-panel:')"
} | tee -a "$SUMMARY"

# The real switcher functions, evaluated against the live snapshot plus the two
# minimized stores Omarchy can produce.
REPO="$REPO" CLIENTS="$CLIENTS" MONITORS="$MONITORS" node <<'NODE' 2>&1 | tee -a "$SUMMARY"
const fs = require("node:fs"), vm = require("node:vm")
const repo = process.env.REPO
const model = vm.createContext({})
vm.runInContext(fs.readFileSync(repo + "/TaskListModel.js", "utf8"), model)
const qml = fs.readFileSync(repo + "/AppSwitcher.qml", "utf8")
const functions = Array.from(qml.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm), m => m[0]).join("\n")
const clients = JSON.parse(fs.readFileSync(process.env.CLIENTS, "utf8"))
const monitors = JSON.parse(fs.readFileSync(process.env.MONITORS, "utf8"))
const describe = c => ({ address: c.address, appId: c.class, mru: c.focusHistoryID,
                         activated: c.focusHistoryID === 0, title: c.title })

function run(snapshot, monitorsSnapshot, direction) {
  const dispatches = []
  const screens = monitorsSnapshot.map(m => ({ monitorId: m.id }))
  const ctx = {
    TaskListModel: model, console: { info() {}, log() {} },
    shell: null, opened: false, snapshot: [], selectedIndex: -1, targetScreen: null,
    snapshotRequestPending: false, pendingClients: null, pendingMonitors: null,
    commitWhenReady: false, pendingDirection: 0, debugEnabled: false,
    layerState: "hidden", hideWhenMapped: false, pendingActivation: null,
    switcherNamespace: "fatlj-app-switcher", luaLogWirePrefix: "custom>>fatlj.float-panel:log:",
    clientsSocket: { connected: false }, monitorsSocket: { connected: false },
    luaLogSocket: { connected: true },
    Quickshell: { screens, iconPath: v => v },
    Hyprland: { monitorFor: s => ({ id: s.monitorId }), dispatch: c => dispatches.push(c) },
    DesktopEntries: { byId: () => null, heuristicLookup: () => null },
    Qt: { callLater: cb => cb() }, ListView: { Contain: 0 }, list: { positionViewAtIndex() {} }
  }
  ctx.root = ctx
  vm.createContext(ctx)
  vm.runInContext(functions, ctx, { filename: "switcher" })
  ctx.step(direction)
  ctx.acceptClientsResponse(JSON.stringify(snapshot))
  ctx.acceptMonitorsResponse(JSON.stringify(monitorsSnapshot))
  return { opened: ctx.opened, items: ctx.snapshot, dispatches, ctx }
}

const active = monitors.find(m => m.focused && m.activeWorkspace) || monitors[0]
const ws = active.activeWorkspace
const dockWindow = (suffix, tags) => ({
  address: "0xfp" + suffix, workspace: { id: -90, name: "special:minimized" }, mapped: true,
  class: "org.example.verify", title: "synthetic window " + suffix,
  focusHistoryID: 90 + Number(suffix), tags
})
const scenarios = [
  ["live session", clients],
  ["live + dock-minimized tagged from the displayed workspace",
    clients.concat([dockWindow(1, ["omarchy-minimized-from-" + ws.id])])],
  ["live + dock-minimized untagged (follows the focused workspace)",
    clients.concat([dockWindow(2, [])])],
  ["live + dock-minimized from a hidden workspace (must stay out of scope)",
    clients.concat([dockWindow(3, ["omarchy-minimized-from-999"])])]
]
for (const [label, snapshot] of scenarios) {
  const result = run(snapshot, monitors, 1)
  const names = result.items.map(i => `${i.name}${i.representative.minimized ? " (min)" : ""}`)
  const dockRow = result.items.find(i => i.appId === "org.example.verify")
  console.log(`${label}: overlay=${result.opened ? "opens" : "stays closed"} candidates=${result.items.length} ${JSON.stringify(names)}` +
    (dockRow ? ` dock-route={destination:${dockRow.representative.route.workspaceId},store:${dockRow.representative.route.minimizedWorkspaceName}}` : ""))
  if (result.opened && result.dispatches.length === 0) {
    // The activation route is read before the commit clears the snapshot, then the
    // real dispatcher generates the snippet. Nothing is executed against the session.
    const row = result.items[result.ctx.selectedIndex]
    const route = (row && row.representative.route) || {}
    result.ctx.acceptCompositorEvent("openlayer>>fatlj-app-switcher")
    result.ctx.commit()
    result.ctx.acceptCompositorEvent("closelayer>>fatlj-app-switcher")
    const snippet = result.dispatches[0] || ""
    console.log(`   activation route: destination=${route.workspaceId} store=${route.minimizedWorkspaceName}` +
      ` dispatches=${result.dispatches.length} move-from-store=${snippet.includes('hl.dsp.window.move')}`)
  }
}
NODE
