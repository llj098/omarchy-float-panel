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
      route: description.route || null,
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
    // Minimizing preserves recent focus history; keep hidden windows at the
    // tail instead of making the next Alt-Tab immediately restore them.
    if (a.representative.minimized !== b.representative.minimized)
      return a.representative.minimized ? 1 : -1
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

// Omarchy 4.5 minimizes through a single shared special workspace and tags each
// window with the regular workspace it came from. Windows minimized that way are
// absent from the source workspace's own minimized special workspace, so a scope
// that only reads the plugin's store would silently drop them.
var minimizedFromTagPrefix = "omarchy-minimized-from-"
// The shared store itself is Omarchy's contract, not this plugin's own convention.
var sharedMinimizedName = "special:minimized"

function minimizedSourceWorkspaceId(tags) {
  var values = Array.isArray(tags) ? tags : []
  var source = null
  for (var i = 0; i < values.length; i++) {
    var tag = stringValue(values[i])
    if (tag.slice(0, minimizedFromTagPrefix.length) !== minimizedFromTagPrefix) continue
    // Omarchy only ever writes a plain workspace id here ("[1-9][0-9]*"); anything
    // else belongs to something else and must not be read as a destination.
    var digits = tag.slice(minimizedFromTagPrefix.length)
    if (!/^[1-9][0-9]*$/.test(digits)) continue
    var id = Number(digits)
    if (source === null || id < source) source = id
  }
  return source
}

// Scope by the compositor's actual active workspace IDs, never by the bar's
// per-monitor labels (two displayed "1" labels may mean IDs 1 and 11).
function listSwitcherClients(clients, monitors, describe) {
  var byId = Object.create(null)
  var byMinimizedName = Object.create(null)
  var focusedRoute = null
  var outputs = monitors || []
  for (var i = 0; i < outputs.length; i++) {
    var monitor = outputs[i]
    if (!monitor || monitor.disabled === true || (monitor.mirrorOf && monitor.mirrorOf !== "none")) continue
    var workspace = monitor.activeWorkspace
    var id = workspace ? Number(workspace.id) : 0
    var name = workspace ? stringValue(workspace.name) : ""
    if (!isFinite(id) || id <= 0 || Math.floor(id) !== id || !name || name.indexOf("special:") === 0) continue
    var route = {
      workspaceId: id,
      workspaceName: name,
      minimizedWorkspaceName: "special:omarchy-minimized-" + id
    }
    byId[id] = route
    byMinimizedName[route.minimizedWorkspaceName] = route
    if (monitor.focused === true && focusedRoute === null) focusedRoute = route
  }

  var visible = []
  var minimized = []
  var routes = Object.create(null)
  var values = clients || []
  for (var j = 0; j < values.length; j++) {
    var client = values[j]
    if (!client || client.mapped !== true || hasEmbeddedNul(client.class) || hasEmbeddedNul(client.initialClass)) continue
    var address = stringValue(client.address)
    if (!address || routes[address]) continue
    var clientWorkspace = client.workspace
    if (!clientWorkspace) continue
    var clientName = stringValue(clientWorkspace.name)
    var destination = byId[Number(clientWorkspace.id)]
    if (destination && destination.workspaceName === clientName) {
      visible.push(client)
      routes[address] = destination
      continue
    }
    destination = byMinimizedName[clientName]
    if (!destination && clientName === sharedMinimizedName) {
      // A tagged window belongs to the workspace it was minimized from; without a
      // tag the shared store says nothing about its origin, so it follows the
      // focused workspace exactly like the dock's own restore does.
      var sourceId = minimizedSourceWorkspaceId(client.tags)
      destination = sourceId === null ? focusedRoute : (byId[sourceId] || null)
    }
    if (!destination) continue
    minimized.push(client)
    // Restore routing keeps the window's own store: it may be the shared one, and
    // activation re-checks the live workspace against this name before moving it.
    routes[address] = {
      workspaceId: destination.workspaceId,
      workspaceName: destination.workspaceName,
      minimizedWorkspaceName: clientName
    }
  }

  return listSwitcherToplevels(visible, minimized, function(client) {
    var description = describe(client) || {}
    description.route = routes[stringValue(client.address)]
    return description
  })
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

// Shared state format with Lua: old positive-only lists had no explicit Tiling
// overrides. Missing state and new workspace names therefore inherit Float.
function parseWorkspaceModes(contents) {
    var modes = Object.create(null);
    var lines = String(contents || "").split("\n");
    var versioned = false;
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "");
        if (line === "# float-panel-workspaces-v2") versioned = true;
        else if (versioned && line.slice(0, 5) === "tile\t" && line.length > 5)
            modes[line.slice(5)] = false;
    }
    return modes;
}

function workspaceFloatEnabled(modes, name) {
    return String(name || "") !== "" && modes[String(name)] !== false;
}
