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
  property string capturedWorkspaceName: ""
  property string capturedWorkspaceSelector: ""
  property string minimizedWorkspaceName: ""
  property var targetScreen: null
  property bool clientsRequestPending: false
  property bool commitWhenReady: false
  property int pendingDirection: 0
  property bool debugEnabled: false

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
    if (clientsRequestPending) {
      pendingDirection += direction
      return
    }
    pendingDirection = direction
    clientsRequestPending = true
    commitWhenReady = false
    clientsSocket.connected = true
  }

  function acceptClientsResponse(text) {
    if (!clientsRequestPending) return
    var clients
    try {
      clients = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!Array.isArray(clients)) return

    clientsRequestPending = false
    clientsSocket.connected = false
    var direction = pendingDirection
    var shouldCommit = commitWhenReady
    pendingDirection = 0
    commitWhenReady = false
    beginFromClients(clients, direction)
    if (shouldCommit) commit()
  }

  function beginFromClients(clients, direction) {
    var active = null
    for (var i = 0; i < clients.length; i++) {
      var client = clients[i]
      var workspaceName = client && client.workspace ? String(client.workspace.name || "") : ""
      if (client && client.mapped === true && Number(client.focusHistoryID) === 0 && workspaceName.indexOf("special:") !== 0) {
        active = client
        break
      }
    }
    if (!active || !active.workspace) return

    var sourceName = String(active.workspace.name || "")
    var workspaceId = Number(active.workspace.id)
    if (!sourceName || !isFinite(workspaceId) || workspaceId <= 0) return

    var minimizedName = "special:omarchy-minimized-" + String(workspaceId)
    var visible = []
    var minimized = []
    for (var j = 0; j < clients.length; j++) {
      var candidate = clients[j]
      var candidateWorkspace = candidate && candidate.workspace ? String(candidate.workspace.name || "") : ""
      if (candidateWorkspace === sourceName) visible.push(candidate)
      else if (candidateWorkspace === minimizedName) minimized.push(candidate)
    }

    var items = TaskListModel.listSwitcherToplevels(
      visible,
      minimized,
      function(client) { return root.describeClient(client) }
    )
    if (items.length < 2) return

    snapshot = items
    capturedWorkspaceName = sourceName
    capturedWorkspaceSelector = String(workspaceId)
    minimizedWorkspaceName = minimizedName
    targetScreen = screenForMonitorId(active.monitor)

    var activeIndex = -1
    for (var k = 0; k < items.length; k++) {
      if (items[k].active) { activeIndex = k; break }
    }
    selectedIndex = activeIndex >= 0
      ? (activeIndex + direction + items.length) % items.length
      : (direction > 0 ? 0 : items.length - 1)
    opened = true
    debugLog("switcher.begin", { workspace: capturedWorkspaceName, candidates: items.length, selected: selectedIndex })
    Qt.callLater(function() { list.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
  }

  function step(direction) {
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
    opened = false
    snapshot = []
    selectedIndex = -1
    commitWhenReady = false
  }

  function windowSelector(address) {
    var value = String(address || "")
    return value ? "address:0x" + value : ""
  }

  function luaString(value) {
    return JSON.stringify(String(value || ""))
  }

  function dispatchActivation(target, restore, destination, sourceName, minimizedName) {
    var actions = [
      "local selected = hl.get_window(" + luaString(target) + ")",
      "if not selected or not selected.workspace then return end",
      "local selected_workspace = selected.workspace.name",
      "if selected_workspace ~= " + luaString(sourceName) + " and selected_workspace ~= " + luaString(minimizedName) + " then return end"
    ]
    if (restore)
      actions.push("hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(destination) + ", follow = false, window = selected }))")
    actions.push("if tonumber(selected.fullscreen) ~= 0 then local workspace = selected.workspace; local windows = hl.get_windows(); for i = #windows, 1, -1 do local window = windows[i]; if window.workspace == workspace and window.floating and not window.pinned and tonumber(window.fullscreen) == 0 and window.allowed_over_fullscreen then hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"bottom\", window = window })) end end end")
    actions.push("hl.dispatch(hl.dsp.focus({ window = selected }))")
    actions.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"top\", window = selected }))")
    debugLog("switcher.activate", { target: target, restore: restore, destination: destination })
    Hyprland.dispatch("(function() return function() " + actions.join("; ") + " end end)()")
  }

  function commit() {
    if (clientsRequestPending) {
      commitWhenReady = true
      return "pending-commit"
    }
    if (!opened || selectedIndex < 0 || selectedIndex >= snapshot.length) return "inactive"

    var group = snapshot[selectedIndex]
    var selected = group && group.representative ? group.representative : null
    var address = selected ? String(selected.address || "") : ""
    var target = windowSelector(address)
    var destination = capturedWorkspaceSelector
    var sourceName = capturedWorkspaceName
    var minimizedName = minimizedWorkspaceName
    var restore = selected ? selected.minimized === true : false
    cancel()
    if (!target || !destination) return "invalid-selection"

    dispatchActivation(target, restore, destination, sourceName, minimizedName)
    return "activated:" + address
  }

  Socket {
    id: luaLogSocket
    path: Hyprland.eventSocketPath
    connected: true
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.acceptLuaLogLine(data) }
    }
  }

  Socket {
    id: clientsSocket
    path: Hyprland.requestSocketPath
    connected: false
    onConnectionStateChanged: {
      if (connected && root.clientsRequestPending) {
        write("j/clients")
        flush()
      }
    }
    onError: {
      root.clientsRequestPending = false
      root.commitWhenReady = false
      root.pendingDirection = 0
      connected = false
    }
    parser: StdioCollector {
      waitForEnd: false
      onDataChanged: root.acceptClientsResponse(text)
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
    WlrLayershell.namespace: "fatlj-app-switcher"
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
