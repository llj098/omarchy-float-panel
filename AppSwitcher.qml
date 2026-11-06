import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "TaskListModel.js" as TaskListModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var snapshot: []
  property int selectedIndex: -1
  property var targetScreen: null
  property bool snapshotRequestPending: false
  property var pendingClients: null
  property var pendingMonitors: null
  property bool commitWhenReady: false
  property int pendingDirection: 0
  property bool debugEnabled: false
  property string layerState: "hidden"
  property bool hideWhenMapped: false
  property var pendingActivation: null
  readonly property string switcherNamespace: "fatlj-app-switcher"

  readonly property string luaLogWirePrefix: "custom>>fatlj.float-panel:log:"
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color selectedBorder: Color.menu.selectedBorder
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)

  function debugLog(event, fields) {
    if (debugEnabled) console.info("[fatlj.float-panel] " + event + " " + JSON.stringify(fields || {}))
  }

  function acceptLuaLogLine(line) {
    var value = String(line || "")
    if (value.indexOf(luaLogWirePrefix) === 0)
      console.info(value.slice(luaLogWirePrefix.length))
  }

  function acceptCompositorEvent(line) {
    acceptLuaLogLine(line)
    var value = String(line || "")
    if (value === "openlayer>>" + switcherNamespace && layerState === "mapping") {
      layerState = "mapped"
      if (hideWhenMapped) hideSwitcherLayer()
    } else if (value === "closelayer>>" + switcherNamespace && layerState !== "hidden") {
      // The compositor emits this while unmapping, before its own refocus.
      // Our new IPC request is serviced only after that callback has finished.
      var activation = layerState === "closing" ? pendingActivation : null
      abortPresentation()
      if (activation) activateSelection(activation)
    }
  }

  function abortPresentation() {
    pendingActivation = null
    hideWhenMapped = false
    layerState = "hidden"
    opened = false
    snapshot = []
    selectedIndex = -1
    resetRequest()
  }

  function activateSelection(selection) {
    dispatchActivation(selection.target, selection.destination, selection.sourceName, selection.minimizedName)
  }

  function hideSwitcherLayer() {
    if (layerState === "mapped") layerState = "closing"
    opened = false
    snapshot = []
    selectedIndex = -1
    if (layerState === "hidden") {
      // A quick Alt release can finish before any overlay was ever requested.
      var activation = pendingActivation
      pendingActivation = null
      hideWhenMapped = false
      if (activation) activateSelection(activation)
    }
  }

  function closeSwitcher(selection) {
    resetRequest()
    pendingActivation = selection
    hideWhenMapped = true
    // Do not guess whether a map is still in flight on the Wayland connection.
    // Wait for its open event, then unmap and wait for the matching close.
    if (layerState !== "mapping") hideSwitcherLayer()
  }

  function screenForMonitorId(monitorId) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var monitor = Hyprland.monitorFor(screens[i])
      if (monitor && Number(monitor.id) === Number(monitorId)) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function desktopEntry(appId) {
    var id = String(appId || "")
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    return id ? (DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)) : null
  }

  function iconSource(icon) {
    if (shell && shell.appLibrary) return shell.appLibrary.iconSource(icon)
    var value = String(icon || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value || "application-x-executable", true)
  }

  function clientAddress(client) {
    return String(client && client.address || "").replace(/^0x/, "")
  }

  function describeClient(client) {
    if (!client || client.mapped !== true || TaskListModel.hasEmbeddedNul(client.class) || TaskListModel.hasEmbeddedNul(client.initialClass))
      return { ignored: true }

    var appId = String(client.class || client.initialClass || "")
    var entry = desktopEntry(appId)
    var name = entry && shell && shell.appLibrary ? shell.appLibrary.entryName(entry) : (entry ? entry.name : "")
    return {
      key: appId || ("window:" + clientAddress(client)),
      appId: appId,
      name: name || appId || client.title || "Application",
      iconSource: iconSource(entry ? entry.icon : appId),
      address: clientAddress(client),
      title: String(client.title || ""),
      order: TaskListModel.launchOrderFromTags(client.tags),
      mru: Number(client.focusHistoryID),
      activated: Number(client.focusHistoryID) === 0
    }
  }

  function requestBegin(direction) {
    if (hideWhenMapped || layerState === "closing") return
    if (snapshotRequestPending) {
      pendingDirection += direction
      return
    }
    pendingDirection = direction
    pendingClients = null
    pendingMonitors = null
    snapshotRequestPending = true
    commitWhenReady = false
    luaLogSocket.connected = true
    clientsSocket.connected = true
    monitorsSocket.connected = true
  }

  function resetRequest() {
    snapshotRequestPending = false
    clientsSocket.connected = false
    monitorsSocket.connected = false
    pendingClients = null
    pendingMonitors = null
    pendingDirection = 0
    commitWhenReady = false
  }

  function acceptClientsResponse(text) {
    if (!snapshotRequestPending || pendingClients !== null) return
    var clients
    try {
      clients = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!Array.isArray(clients)) return
    pendingClients = clients
    clientsSocket.connected = false
    completeBegin()
  }

  function acceptMonitorsResponse(text) {
    if (!snapshotRequestPending || pendingMonitors !== null) return
    var monitors
    try {
      monitors = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!Array.isArray(monitors)) return
    pendingMonitors = monitors
    monitorsSocket.connected = false
    completeBegin()
  }

  function completeBegin() {
    // Responses may arrive in either order. Alt release must wait for both,
    // including when the focused monitor has no active window at all.
    if (!snapshotRequestPending || pendingClients === null || pendingMonitors === null) return
    var clients = pendingClients
    var monitors = pendingMonitors
    var direction = pendingDirection
    var shouldCommit = commitWhenReady
    resetRequest()
    beginFromSnapshot(clients, monitors, direction, !shouldCommit)
    if (shouldCommit) commit()
  }

  function beginFromSnapshot(clients, monitors, direction, showPanel) {
    var items = TaskListModel.listSwitcherClients(clients, monitors, function(client) {
      return root.describeClient(client)
    })
    if (items.length === 0) return

    var monitorId = null
    for (var j = 0; j < monitors.length; j++) {
      if (monitors[j] && monitors[j].focused === true) { monitorId = monitors[j].id; break }
    }
    var activeIndex = -1
    for (var i = 0; i < items.length; i++) {
      var window = items[i].representative
      if (items[i].active && !window.minimized &&
          (monitorId === null || Number(window.toplevel.monitor) === Number(monitorId))) {
        activeIndex = i
        break
      }
    }
    if (items.length === 1 && activeIndex === 0) return
    snapshot = items
    targetScreen = screenForMonitorId(monitorId)
    // Several repeated Shift+Tabs can arrive while the requests are pending.
    var start = activeIndex >= 0 ? activeIndex : (direction > 0 ? -1 : 0)
    selectedIndex = ((start + direction) % items.length + items.length) % items.length
    if (showPanel !== false) {
      if (!luaLogSocket.connected) {
        abortPresentation()
        return
      }
      layerState = "mapping"
      opened = true
    }
    debugLog("switcher.begin", { monitor: monitorId, candidates: items.length, selected: selectedIndex })
    Qt.callLater(function() { list.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
  }

  function step(direction) {
    if (hideWhenMapped || layerState === "closing") return
    if (!opened) {
      requestBegin(direction)
      return
    }
    if (snapshot.length === 0) return
    selectedIndex = (selectedIndex + direction + snapshot.length) % snapshot.length
    debugLog("switcher.step", { direction: direction, selected: selectedIndex })
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function cancel() {
    closeSwitcher(null)
  }

  function windowSelector(address) {
    var value = String(address || "")
    return value ? "address:0x" + value : ""
  }

  function luaString(value) {
    return JSON.stringify(String(value || ""))
  }

  function dispatchActivation(target, destination, sourceName, minimizedName) {
    var actions = [
      "local selected = hl.get_window(" + luaString(target) + ")",
      "if not selected or not selected.workspace then return end",
      "local destination_workspace = hl.get_workspace(" + destination + ")",
      "if not destination_workspace or destination_workspace.name ~= " + luaString(sourceName) + " or not destination_workspace.monitor or destination_workspace.monitor.active_workspace ~= destination_workspace then return end",
      "local selected_workspace = selected.workspace.name",
      "if selected_workspace ~= " + luaString(sourceName) + " and selected_workspace ~= " + luaString(minimizedName) + " then return end"
    ]
    // Re-check the live location: a window can be minimized/restored while the
    // list is open. Never move an already-visible window or steal a moved one.
    actions.push("if selected_workspace == " + luaString(minimizedName) + " then hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(destination) + ", follow = false, window = selected })) end")
    actions.push("if tonumber(selected.fullscreen) ~= 0 then local workspace = selected.workspace; local windows = hl.get_windows(); for i = #windows, 1, -1 do local window = windows[i]; if window.workspace == workspace and window.floating and not window.pinned and tonumber(window.fullscreen) == 0 and window.allowed_over_fullscreen then hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"bottom\", window = window })) end end end")
    // alter_zorder itself simulates pointer movement in Hyprland 0.56.2.
    // Finish with explicit focus so follow_mouse cannot undo this handoff.
    actions.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"top\", window = selected }))")
    actions.push("hl.dispatch(hl.dsp.focus({ window = selected }))")
    debugLog("switcher.activate", { target: target, destination: destination })
    Hyprland.dispatch("(function() return function() " + actions.join("; ") + " end end)()")
  }

  function commit() {
    if (hideWhenMapped || layerState === "closing") return "pending-close"
    if (snapshotRequestPending) {
      commitWhenReady = true
      return "pending-commit"
    }
    if (selectedIndex < 0 || selectedIndex >= snapshot.length) return "inactive"

    var group = snapshot[selectedIndex]
    var selected = group && group.representative ? group.representative : null
    var address = selected ? String(selected.address || "") : ""
    var target = windowSelector(address)
    var route = selected ? selected.route : null
    var destination = route ? String(route.workspaceId) : ""
    var sourceName = route ? route.workspaceName : ""
    var minimizedName = route ? route.minimizedWorkspaceName : ""
    if (!target || !destination) {
      cancel()
      return "invalid-selection"
    }
    closeSwitcher({ target: target, destination: destination, sourceName: sourceName, minimizedName: minimizedName })
    return layerState === "hidden" ? "activated:" + address : "pending-close"
  }

  Socket {
    id: luaLogSocket
    path: Hyprland.eventSocketPath
    connected: true
    onConnectionStateChanged: if (!connected) root.abortPresentation()
    onError: root.abortPresentation()
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.acceptCompositorEvent(data) }
    }
  }

  Socket {
    id: clientsSocket
    path: Hyprland.requestSocketPath
    connected: false
    onConnectionStateChanged: {
      if (connected && root.snapshotRequestPending) {
        write("j/clients")
        flush()
      }
    }
    onError: root.resetRequest()
    parser: StdioCollector {
      waitForEnd: false
      onDataChanged: root.acceptClientsResponse(text)
    }
  }

  Socket {
    id: monitorsSocket
    path: Hyprland.requestSocketPath
    connected: false
    onConnectionStateChanged: {
      if (connected && root.snapshotRequestPending) {
        write("j/monitors")
        flush()
      }
    }
    onError: root.resetRequest()
    parser: StdioCollector {
      waitForEnd: false
      onDataChanged: root.acceptMonitorsResponse(text)
    }
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/float-panel-debug"
    watchChanges: true
    printErrors: false
    onLoaded: root.debugEnabled = true
    onLoadFailed: root.debugEnabled = false
    onFileChanged: reload()
  }

  GlobalShortcut {
    appid: "fatlj.float-panel"
    name: "alt-tab-next"
    description: "Select next application"
    onPressed: root.step(1)
  }

  GlobalShortcut {
    appid: "fatlj.float-panel"
    name: "alt-tab-previous"
    description: "Select previous application"
    onPressed: root.step(-1)
  }

  GlobalShortcut {
    appid: "fatlj.float-panel"
    name: "alt-release"
    description: "Activate selected application"
    onReleased: root.commit()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; right: true; bottom: true; left: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: root.switcherNamespace
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(520), panel.width - Style.gapsOut * 2)
      height: Math.min(root.snapshot.length * root.rowHeight + Style.spacing.panelPadding * 2,
                       panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

      ListView {
        id: list
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        clip: true
        spacing: Style.spacing.xs
        model: root.snapshot
        currentIndex: root.selectedIndex
        boundsBehavior: Flickable.StopAtBounds

        delegate: BorderSurface {
          id: row
          required property int index
          required property var modelData
          readonly property bool selected: index === root.selectedIndex
          width: ListView.view.width
          height: root.rowHeight
          radius: Style.cornerRadius
          color: selected ? root.selectedBackground : "transparent"
          borderSpec: selected ? root.selectedBorderSpec : Border.none()

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.spacing.md

            Image {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              height: width
              source: row.modelData.iconSource
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.spacing.rowPaddingX * 2 - Style.space(32) - parent.spacing
              text: row.modelData.title && row.modelData.title !== row.modelData.name
                ? row.modelData.name + " — " + row.modelData.title
                : row.modelData.name
              color: row.selected ? root.selectedText : root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
