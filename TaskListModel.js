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
      minimized: minimized === true,
      order: numericOrder(description.order)
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
    current.windows.sort(function(a, b) {
      if (a.order === null && b.order === null) return a.address < b.address ? -1 : (a.address > b.address ? 1 : 0)
      if (a.order === null) return 1
      if (b.order === null) return -1
      if (a.order !== b.order) return a.order - b.order
      return a.address < b.address ? -1 : (a.address > b.address ? 1 : 0)
    })
    current.allMinimized = current.visibleWindows.length === 0
    current.count = current.windows.length
  }

  return groups
}

function switcherMru(value) {
  var rank = Number(value)
  return isFinite(rank) && rank >= 0 ? rank : null
}

function listSwitcherToplevels(visibleToplevels, minimizedToplevels, describe) {
  var items = []

  function add(toplevel, minimized) {
    if (!toplevel) return

    var description = describe(toplevel) || {}
    if (description.ignored === true || hasEmbeddedNul(description.appId) || hasEmbeddedNul(description.key))
      return

    var address = stringValue(description.address)
    if (!address) return

    var mru = switcherMru(description.mru)
    var launchOrder = numericOrder(description.order)
    var window = {
      toplevel: toplevel,
      address: address,
      title: stringValue(description.title),
      activated: description.activated === true,
      minimized: minimized === true,
      mru: mru,
      order: launchOrder
    }
    items.push({
      key: "window:" + address,
      appId: stringValue(description.appId),
      name: stringValue(description.name || description.appId || description.title || "Application"),
      title: window.title,
      iconSource: stringValue(description.iconSource),
      windows: [window],
      active: window.activated,
      representative: window,
      mru: mru,
      order: launchOrder,
      appearanceOrder: items.length
    })
  }

  var visible = visibleToplevels || []
  var minimized = minimizedToplevels || []
  for (var i = 0; i < visible.length; i++) add(visible[i], false)
  for (var j = 0; j < minimized.length; j++) add(minimized[j], true)

  items.sort(function(a, b) {
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

  return items
}

function actionForGroup(group, liveClients, cycleStartAddress) {
  if (!group || !group.windows || group.windows.length === 0) return null

  var windows = group.windows
  if (group.allMinimized)
    return { action: "restore", target: windows[0], cycleStart: windows[0].address }

  var liveByAddress = {}
  var clients = liveClients || []
  for (var i = 0; i < clients.length; i++) {
    var client = clients[i] || {}
    var address = stringValue(client.address).replace(/^0x/, "").toLowerCase()
    if (address) liveByAddress[address] = client
  }

  function liveClient(item) {
    return liveByAddress[stringValue(item.address).replace(/^0x/, "").toLowerCase()] || null
  }

  var cycleStart = stringValue(cycleStartAddress)
  var cycleStartIndex = -1
  for (var j = 0; j < windows.length; j++) {
    if (stringValue(windows[j].address) === cycleStart) {
      cycleStartIndex = j
      break
    }
  }
  var ring = cycleStartIndex > 0
    ? windows.slice(cycleStartIndex).concat(windows.slice(0, cycleStartIndex))
    : windows

  var activeIndex = -1
  for (var k = 0; k < ring.length; k++) {
    var live = liveClient(ring[k])
    var activated = clients.length > 0 ? (live && Number(live.focusHistoryID) === 0) : ring[k].activated
    if (activated && !ring[k].minimized) {
      activeIndex = k
      break
    }
  }

  if (activeIndex >= 0) {
    if (activeIndex === ring.length - 1)
      return { action: "hide-all", targets: windows.slice(), cycleComplete: true }

    var next = ring[activeIndex + 1]
    return { action: next.minimized ? "restore" : "focus", target: next }
  }

  var mostRecent = null
  var mostRecentRank = null
  for (var n = 0; n < windows.length; n++) {
    if (windows[n].minimized) continue
    var candidate = liveClient(windows[n])
    var rank = candidate ? switcherMru(candidate.focusHistoryID) : null
    if (rank !== null && (mostRecentRank === null || rank < mostRecentRank)) {
      mostRecent = windows[n]
      mostRecentRank = rank
    }
  }
  if (mostRecent)
    return { action: "focus", target: mostRecent, cycleStart: mostRecent.address }

  for (var p = 0; p < windows.length; p++) {
    if (!windows[p].minimized)
      return { action: "focus", target: windows[p], cycleStart: windows[p].address }
  }

  return { action: "restore", target: windows[0], cycleStart: windows[0].address }
}
