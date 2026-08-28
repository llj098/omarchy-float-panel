function stringValue(value) {
  return value === undefined || value === null ? "" : String(value)
}

function hasEmbeddedNul(value) {
  return stringValue(value).indexOf("\u0000") !== -1
}

function normalizeAppId(value) {
  var normalized = stringValue(value).trim().toLowerCase()
  if (normalized.slice(-8) === ".desktop")
    normalized = normalized.slice(0, -8)
  return normalized
}

function launchOrderFromTags(tags) {
  var values = tags || []
  var prefix = "float-panel-order-"
  var earliest = null
  for (var i = 0; i < values.length; i++) {
    var tag = stringValue(values[i])
    if (tag.slice(0, prefix.length) !== prefix) continue

    var order = Number(tag.slice(prefix.length))
    if (!isFinite(order) || order < 0) continue
    if (earliest === null || order < earliest) earliest = order
  }
  return earliest
}

function numericOrder(value) {
  if (value === undefined || value === null || value === "") return null
  var order = Number(value)
  return isFinite(order) && order >= 0 ? order : null
}

function groupToplevels(visibleToplevels, minimizedToplevels, describe) {
  var groups = []
  var byKey = {}

  function add(toplevel, minimized) {
    if (!toplevel) return

    var description = describe(toplevel) || {}
    if (description.ignored === true || hasEmbeddedNul(description.appId) || hasEmbeddedNul(description.key))
      return

    var key = normalizeAppId(description.key || description.appId)
    if (!key)
      key = "window:" + stringValue(description.address || description.title)
    if (!key || key === "window:") return

    var group = byKey[key]
    if (!group) {
      group = {
        key: key,
        appId: stringValue(description.appId),
        name: stringValue(description.name || description.appId || description.title || "Application"),
        iconSource: stringValue(description.iconSource),
        windows: [],
        visibleWindows: [],
        minimizedWindows: [],
        active: false,
        urgent: false,
        representative: null,
        order: numericOrder(description.order),
        appearanceOrder: groups.length
      }
      byKey[key] = group
      groups.push(group)
    }

    var item = {
      toplevel: toplevel,
      address: stringValue(description.address),
      title: stringValue(description.title),
      activated: description.activated === true,
      minimized: minimized === true
    }

    group.windows.push(item)
    if (item.minimized)
      group.minimizedWindows.push(item)
    else
      group.visibleWindows.push(item)

    group.active = group.active || item.activated
    group.urgent = group.urgent || description.urgent === true

    var itemOrder = numericOrder(description.order)
    if (itemOrder !== null && (group.order === null || itemOrder < group.order))
      group.order = itemOrder

    if (!group.representative || (item.activated && !item.minimized) ||
        (group.representative.minimized && !item.minimized))
      group.representative = item
  }

  var visible = visibleToplevels || []
  var minimized = minimizedToplevels || []
  for (var i = 0; i < visible.length; i++) add(visible[i], false)
  for (var j = 0; j < minimized.length; j++) add(minimized[j], true)

  groups.sort(function(a, b) {
    if (a.order === null && b.order === null) return a.appearanceOrder - b.appearanceOrder
    if (a.order === null) return 1
    if (b.order === null) return -1
    if (a.order !== b.order) return a.order - b.order
    return a.appearanceOrder - b.appearanceOrder
  })

  for (var k = 0; k < groups.length; k++) {
    var current = groups[k]
    current.allMinimized = current.visibleWindows.length === 0
    current.count = current.windows.length
  }

  return groups
}

function switcherMru(value) {
  var rank = Number(value)
  return isFinite(rank) && rank >= 0 ? rank : null
}

function groupSwitcherToplevels(visibleToplevels, minimizedToplevels, describe) {
  var groups = []
  var byKey = {}

  function add(toplevel, minimized) {
    if (!toplevel) return

    var description = describe(toplevel) || {}
    if (description.ignored === true || hasEmbeddedNul(description.appId) || hasEmbeddedNul(description.key))
      return

    var key = normalizeAppId(description.key || description.appId)
    if (!key)
      key = "window:" + stringValue(description.address || description.title)
    if (!key || key === "window:") return

    var mru = switcherMru(description.mru)
    var launchOrder = numericOrder(description.order)
    var item = {
      toplevel: toplevel,
      address: stringValue(description.address),
      title: stringValue(description.title),
      activated: description.activated === true,
      minimized: minimized === true,
      mru: mru,
      order: launchOrder
    }

    var group = byKey[key]
    if (!group) {
      group = {
        key: key,
        appId: stringValue(description.appId),
        name: stringValue(description.name || description.appId || description.title || "Application"),
        iconSource: stringValue(description.iconSource),
        windows: [],
        active: false,
        representative: null,
        mru: mru,
        order: launchOrder,
        appearanceOrder: groups.length
      }
      byKey[key] = group
      groups.push(group)
    }

    group.windows.push(item)
    group.active = group.active || item.activated
    if (mru !== null && (group.mru === null || mru < group.mru)) group.mru = mru
    if (launchOrder !== null && (group.order === null || launchOrder < group.order)) group.order = launchOrder

    var representative = group.representative
    var newer = !representative ||
      (item.mru !== null && (representative.mru === null || item.mru < representative.mru)) ||
      (item.mru === representative.mru && !item.minimized && representative.minimized)
    if (newer) group.representative = item
  }

  var visible = visibleToplevels || []
  var minimized = minimizedToplevels || []
  for (var i = 0; i < visible.length; i++) add(visible[i], false)
  for (var j = 0; j < minimized.length; j++) add(minimized[j], true)

  groups.sort(function(a, b) {
    if (a.mru !== null || b.mru !== null) {
      if (a.mru === null) return 1
      if (b.mru === null) return -1
      if (a.mru !== b.mru) return a.mru - b.mru
    }
    if (a.order !== null || b.order !== null) {
      if (a.order === null) return 1
      if (b.order === null) return -1
      if (a.order !== b.order) return a.order - b.order
    }
    return a.appearanceOrder - b.appearanceOrder
  })

  return groups
}

function actionForGroup(group) {
  if (!group || !group.representative) return ""
  if (group.active && !group.representative.minimized) return "hide"
  return group.representative.minimized ? "restore" : "focus"
}
