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

  assert.deepEqual(Array.from(items, item => item.representative.address), ["active", "hidden", "new-visible", "old-visible"])
  assert.equal(items.length, 4, "every window must remain a separate Alt-Tab item")
  assert.equal(items[2].appId, items[3].appId, "same-app windows must keep their common application identity")
  assert.notEqual(items[2].key, items[3].key, "same-app windows must have distinct list identities")
  assert.equal(items[1].representative.minimized, true)
  assert.equal(items[2].title, "Newer window")
}

{
  const items = context.listSwitcherToplevels([top("visible")], [top("hidden")], descriptor({
    visible: { appId: "same.app", mru: 4 },
    hidden: { appId: "same.app", mru: 1 }
  }))
  assert.deepEqual(Array.from(items, item => item.representative.address), ["hidden", "visible"],
    "visible and minimized windows from one app must both remain selectable")
}

assert.equal(context.actionForGroup(null), "")
assert.equal(context.actionForGroup({ representative: { minimized: false }, active: true }), "hide")
assert.equal(context.actionForGroup({ representative: { minimized: false }, active: false }), "focus")
assert.equal(context.actionForGroup({ representative: { minimized: true }, active: false }), "restore")
assert.equal(context.normalizeAppId(" Org.Example.App.desktop "), "org.example.app")
assert.equal(context.launchOrderFromTags(["default-opacity*", "float-panel-order-42"]), 42)
assert.equal(context.launchOrderFromTags(["float-panel-order-invalid"]), null)
console.log("MODEL_TESTS_OK")
