#!/usr/bin/env node

const assert = require("node:assert/strict")
const fs = require("node:fs")
const vm = require("node:vm")

const source = fs.readFileSync("TaskListModel.js", "utf8")
const context = { console }
vm.createContext(context)
vm.runInContext(source, context, { filename: "TaskListModel.js" })

function top(address) {
  return { address }
}

function descriptor(values) {
  return toplevel => ({ address: toplevel.address, ...values[toplevel.address] })
}

{
  const visible = [top("a"), top("b")]
  const minimized = [top("c")]
  const groups = context.groupToplevels(visible, minimized, descriptor({
    a: { appId: "Firefox", name: "Firefox", activated: false },
    b: { appId: "firefox.desktop", name: "Firefox", activated: true },
    c: { appId: "FIREFOX", name: "Firefox" }
  }))

  assert.equal(groups.length, 1)
  assert.equal(groups[0].key, "firefox")
  assert.equal(groups[0].count, 3)
  assert.equal(groups[0].visibleWindows.length, 2)
  assert.equal(groups[0].minimizedWindows.length, 1)
  assert.equal(groups[0].representative.address, "b")
  assert.equal(groups[0].active, true)
  assert.equal(groups[0].allMinimized, false)
}

{
  const visible = [top("late"), top("untagged")]
  const minimized = [top("early")]
  const groups = context.groupToplevels(visible, minimized, descriptor({
    late: { appId: "late.app", order: 200 },
    untagged: { appId: "untagged.app" },
    early: { appId: "early.app", order: 100 }
  }))

  assert.deepEqual(
    Array.from(groups, group => group.key),
    ["early.app", "late.app", "untagged.app"],
    "groups must follow process launch order instead of visible/minimized list order"
  )
}

{
  const visible = [top("visible")]
  const minimized = [top("hidden")]
  const groups = context.groupToplevels(visible, minimized, descriptor({
    visible: { appId: "org.gnu.Emacs", name: "Emacs" },
    hidden: { appId: "org.gnu.Emacs", name: "Emacs", activated: true }
  }))

  assert.equal(groups[0].representative.address, "visible", "a visible window must represent a mixed group")
}

{
  const groups = context.groupToplevels([], [top("hidden")], descriptor({
    hidden: { appId: "org.telegram.desktop", name: "Telegram", urgent: true }
  }))

  assert.equal(groups.length, 1)
  assert.equal(groups[0].representative.address, "hidden")
  assert.equal(groups[0].allMinimized, true)
  assert.equal(groups[0].urgent, true)
}

{
  const visible = [top("1"), top("2")]
  const groups = context.groupToplevels(visible, [], descriptor({
    1: { title: "Unknown one" },
    2: { title: "Unknown two" }
  }))

  assert.equal(groups.length, 2, "unknown windows must not collapse into one group")
  assert.deepEqual(Array.from(groups, group => group.key), ["window:1", "window:2"])
}

{
  const groups = context.groupToplevels([top("app"), top("popup")], [], descriptor({
    app: { appId: "org.example.App", name: "App" },
    popup: { ignored: true, appId: "org.fcitx.Fcitx5" }
  }))

  assert.equal(groups.length, 1, "unmanaged input-method and popup surfaces must be ignored")
  assert.equal(groups[0].key, "org.example.app")
}

{
  const groups = context.groupToplevels([top("app"), top("candidate")], [], descriptor({
    app: { appId: "wechat", name: "WeChat" },
    candidate: { appId: "fcitx\u0000fcit", key: "fcitx\u0000fcit", name: "Input Window" }
  }))

  assert.equal(groups.length, 1, "malformed X11 combo-surface identities must be ignored")
  assert.equal(groups[0].key, "wechat")
}

{
  const items = context.listSwitcherToplevels(
    [top("active"), top("old-visible"), top("new-visible")],
    [top("hidden")],
    descriptor({
      active: { appId: "active.app", name: "Active", title: "Active window", activated: true, mru: 0, order: 40 },
      "old-visible": { appId: "other.app", name: "Other", title: "Older window", mru: 5, order: 30 },
      "new-visible": { appId: "other.app", name: "Other", title: "Newer window", mru: 2, order: 30 },
      hidden: { appId: "hidden.app", name: "Hidden", title: "Minimized window", mru: 1, order: 20 }
    })
  )

  assert.deepEqual(Array.from(items, item => item.representative.address), ["active", "new-visible", "old-visible", "hidden"],
    "a recently minimized window must follow every visible window, regardless of focus history")
  assert.equal(items.length, 4, "every window must remain a separate Alt-Tab item")
  assert.equal(items[1].appId, items[2].appId, "same-app windows must keep their common application identity")
  assert.notEqual(items[1].key, items[2].key, "same-app windows must have distinct list identities")
  assert.equal(items[3].representative.minimized, true)
  assert.equal(items[1].title, "Newer window")
}

{
  const items = context.listSwitcherToplevels([top("visible")], [top("hidden")], descriptor({
    visible: { appId: "same.app", mru: 4 },
    hidden: { appId: "same.app", mru: 1 }
  }))
  assert.deepEqual(Array.from(items, item => item.representative.address), ["visible", "hidden"],
    "visible and minimized windows from one app must both remain selectable, with minimized last")
}

{
  const describe = descriptor({
    recent: { mru: 2, order: 50 },
    older: { mru: 7, order: 10 },
    unranked: { mru: -1 },
    "hidden-recent": { mru: 0, order: 20 },
    "hidden-older": { mru: 1, order: 5 },
    "hidden-unranked": { mru: -1, order: 1 }
  })
  const visible = [top("unranked"), top("older"), top("recent")]
  const minimized = [top("hidden-unranked"), top("hidden-older"), top("hidden-recent")]
  const addresses = items => Array.from(items, item => item.representative.address)
  assert.deepEqual(addresses(context.listSwitcherToplevels(visible, minimized, describe)),
    ["recent", "older", "unranked", "hidden-recent", "hidden-older", "hidden-unranked"],
    "minimized-last takes precedence over MRU and launch order, including missing focus history")
  assert.deepEqual(addresses(context.listSwitcherToplevels([], minimized, describe)),
    ["hidden-recent", "hidden-older", "hidden-unranked"],
    "all-minimized windows remain selectable in MRU order")
  assert.deepEqual(addresses(context.listSwitcherToplevels(
    visible.concat(top("hidden-recent")), minimized.slice(0, 2), describe)),
    ["hidden-recent", "recent", "older", "unranked", "hidden-older", "hidden-unranked"],
    "a restored window must immediately rejoin visible MRU order without a stale demotion")
}

{
  const group = context.groupToplevels([top("b"), top("a")], [], descriptor({
    a: { appId: "same.app", order: 10, activated: true },
    b: { appId: "same.app", order: 20 }
  }))[0]
  const decision = context.actionForGroup(group)
  assert.equal(decision.action, "focus")
  assert.equal(decision.target.address, "b", "A must cycle directly to B")
}

{
  const group = context.groupToplevels([top("a"), top("b")], [], descriptor({
    a: { appId: "same.app", order: 10 },
    b: { appId: "same.app", order: 20, activated: true }
  }))[0]
  const decision = context.actionForGroup(group)
  assert.equal(decision.action, "hide-all", "the final window must advance to NONE")
  assert.deepEqual(Array.from(decision.targets, item => item.address), ["a", "b"])
}

{
  const group = context.groupToplevels([], [top("b"), top("a")], descriptor({
    a: { appId: "same.app", order: 10 },
    b: { appId: "same.app", order: 20 }
  }))[0]
  const decision = context.actionForGroup(group)
  assert.equal(decision.action, "restore")
  assert.equal(decision.target.address, "a", "NONE must restart the stable ring at A")
}

{
  const group = context.groupToplevels([top("b"), top("a")], [], descriptor({
    a: { appId: "same.app", order: 10 },
    b: { appId: "same.app", order: 20 }
  }))[0]
  const decision = context.actionForGroup(group)
  assert.equal(decision.action, "focus")
  assert.equal(decision.target.address, "a", "without a live snapshot, focus outside the group must enter the ring at A")
}

{
  const group = context.groupToplevels([top("old"), top("recent")], [], descriptor({
    old: { appId: "same.app", order: 10, activated: true },
    recent: { appId: "same.app", order: 20 }
  }))[0]
  const decision = context.actionForGroup(group, [
    { address: "0xold", focusHistoryID: 5 },
    { address: "0xrecent", focusHistoryID: 1 },
    { address: "0xother", focusHistoryID: 0 }
  ])
  assert.equal(decision.action, "focus")
  assert.equal(decision.target.address, "recent",
    "focus outside the group must enter at its live most-recent window, not stale activation or launch order")
  assert.equal(decision.cycleStart, "recent")

  const second = context.actionForGroup(group, [
    { address: "0xold", focusHistoryID: 2 },
    { address: "0xrecent", focusHistoryID: 0 }
  ], decision.cycleStart)
  assert.equal(second.action, "focus")
  assert.equal(second.target.address, "old", "the second click must visit the other window before NONE")

  const third = context.actionForGroup(group, [
    { address: "0xold", focusHistoryID: 0 },
    { address: "0xrecent", focusHistoryID: 1 }
  ], decision.cycleStart)
  assert.equal(third.action, "hide-all", "the MRU-rotated ring must reach NONE only after every window")
  assert.equal(third.cycleComplete, true)
}

{
  const group = context.groupToplevels([top("a"), top("b")], [], descriptor({
    a: { appId: "same.app", order: 10 },
    b: { appId: "same.app", order: 20 }
  }))[0]
  const decision = context.actionForGroup(group, [
    { address: "0xa", focusHistoryID: 0 },
    { address: "0xb", focusHistoryID: 2 }
  ])
  assert.equal(decision.action, "focus")
  assert.equal(decision.target.address, "b", "an active group must continue its stable A-to-B ring")
}

{
  const active = context.groupToplevels([top("only")], [], descriptor({
    only: { appId: "single.app", activated: true }
  }))[0]
  const hidden = context.groupToplevels([], [top("only")], descriptor({
    only: { appId: "single.app" }
  }))[0]
  assert.equal(context.actionForGroup(active).action, "hide-all")
  assert.equal(context.actionForGroup(hidden).action, "restore")
}

// The switcher follows every monitor's actual active workspace, not its
// display label, monitor ID arithmetic, or the focused window's workspace.
{
  const monitors = [
    { id: 0, activeWorkspace: { id: 1, name: "1" } },
    { id: 7, activeWorkspace: { id: 11, name: "11" } }
  ]
  function client(address, id, name, mru, extra = {}) {
    return { address, workspace: { id, name }, mapped: true, class: "same.app", focusHistoryID: mru, ...extra }
  }
  const clients = [
    client("left", 1, "1", 0),
    client("right", 11, "11", 2),
    client("left-hidden", -91, "special:omarchy-minimized-1", 3),
    client("right-hidden", -92, "special:omarchy-minimized-11", 1),
    client("other-left", 2, "2", 4),
    client("other-right", 12, "12", 5),
    client("other-hidden", -93, "special:omarchy-minimized-12", 6),
    client("scratchpad", -94, "special:scratchpad", 7),
    client("unmapped", 11, "11", 8, { mapped: false }),
    client("no-mapping", 11, "11", 9, { mapped: undefined }),
    client("malformed", 11, "11", 10, { class: "bad\u0000app" }),
    client("renamed", 11, "stale-name", 11),
    client("right", 11, "11", 2), // duplicate entries must not create duplicate rows
    null
  ]
  const describe = value => ({
    address: value.address, appId: value.class, mru: value.focusHistoryID,
    activated: value.focusHistoryID === 0
  })
  const rows = outputs => context.listSwitcherClients(clients, outputs, describe)
  const addresses = items => Array.from(items, item => item.representative.address)
  const items = rows(monitors)
  assert.deepEqual(addresses(items), ["left", "right", "right-hidden", "left-hidden"])
  assert.equal(items.length, 4, "same-app windows on both monitors remain individual items")
  assert.deepEqual(JSON.parse(JSON.stringify(items[2].representative.route)), {
    workspaceId: 11, workspaceName: "11", minimizedWorkspaceName: "special:omarchy-minimized-11"
  }, "a minimized window must retain its own workspace as the restore destination")
  assert.equal(items[2].representative.minimized, true)
  assert.equal(items[1].representative.minimized, false)
  assert.equal(items[3].representative.route.workspaceId, 1)

  const otherSlot = [monitors[0], { id: 7, activeWorkspace: { id: 12, name: "12" } }]
  assert.deepEqual(addresses(rows(otherSlot)), ["left", "other-right", "left-hidden", "other-hidden"],
    "different local workspace numbers still join the all-visible-workspaces scope")
  assert.deepEqual(addresses(rows([monitors[0]])), ["left", "left-hidden"],
    "unplugged monitors and non-visible workspaces must not leak into the next snapshot")
  assert.deepEqual(addresses(rows([monitors[0], { ...monitors[1], disabled: true }])), ["left", "left-hidden"])
  assert.deepEqual(addresses(rows([monitors[0], { ...monitors[1], mirrorOf: "eDP-1" }])), ["left", "left-hidden"])
  assert.deepEqual(addresses(rows([...monitors, monitors[0]])), addresses(items), "duplicate monitor scope is harmless")
  assert.equal(rows([null, { activeWorkspace: { id: -1, name: "special:x" } },
    { activeWorkspace: { id: 1.5, name: "invalid" } }, {}]).length, 0)

  const named = context.listSwitcherClients([client("named", 37, "work", 1)], [
    { id: 42, activeWorkspace: { id: 37, name: "work" } }
  ], describe)
  assert.equal(named[0].representative.route.workspaceId, 37)
  assert.equal(named[0].representative.route.workspaceName, "work")
  assert.equal(named[0].representative.route.minimizedWorkspaceName, "special:omarchy-minimized-37")
}

assert.equal(context.actionForGroup(null), null)
assert.equal(context.normalizeAppId(" Org.Example.App.desktop "), "org.example.app")
assert.equal(context.launchOrderFromTags(["default-opacity*", "float-panel-order-42"]), 42)
assert.equal(context.launchOrderFromTags(["float-panel-order-invalid"]), null)


// Default Float, legacy migration, explicit Tiling, CRLF and hostile map keys.
for (const state of ["", "1\n11\n", "# float-panel-workspaces-v2\n"]) {
  const modes = context.parseWorkspaceModes(state);
  for (const name of ["1", "11", "21", "dev", "constructor", "__proto__"])
    assert.equal(context.workspaceFloatEnabled(modes, name), true);
}
const explicitModes = context.parseWorkspaceModes("# float-panel-workspaces-v2\r\ntile\t11\r\ntile\t__proto__\r\n");
assert.equal(context.workspaceFloatEnabled(explicitModes, "11"), false);
assert.equal(context.workspaceFloatEnabled(explicitModes, "__proto__"), false);
assert.equal(context.workspaceFloatEnabled(explicitModes, "21"), true);
assert.equal(context.workspaceFloatEnabled(explicitModes, ""), false);

console.log("MODEL_TESTS_OK")
