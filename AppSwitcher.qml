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
  property var mruAddresses: []
  property bool debugEnabled: false

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

  function findWorkspaceByName(name) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name || "") === name) return values[i]
    }
    return null
  }

  function screenForMonitor(monitor) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (Hyprland.monitorFor(screens[i]) === monitor) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function rawAppId(toplevel) {
    if (toplevel && toplevel.wayland && toplevel.wayland.appId)
      return String(toplevel.wayland.appId)
    var ipc = toplevel ? toplevel.lastIpcObject : null
    return ipc ? String(ipc.class || ipc.initialClass || "") : ""
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

  function mruRank(address, ipcRank) {
    var index = mruAddresses.indexOf(String(address || ""))
    if (index >= 0) return index
    var rank = Number(ipcRank)
    return isFinite(rank) && rank >= 0 ? mruAddresses.length + rank : null
  }

  function describeToplevel(toplevel) {
    var ipc = toplevel ? toplevel.lastIpcObject : null
    if (!ipc || ipc.mapped !== true || TaskListModel.hasEmbeddedNul(ipc.class) || TaskListModel.hasEmbeddedNul(ipc.initialClass))
      return { ignored: true }

    var appId = rawAppId(toplevel)
    var entry = desktopEntry(appId)
    var name = entry && shell && shell.appLibrary ? shell.appLibrary.entryName(entry) : (entry ? entry.name : "")
    return {
      key: appId || ("window:" + String(toplevel.address || "")),
      appId: appId,
      name: name || appId || toplevel.title || "Application",
      iconSource: iconSource(entry ? entry.icon : appId),
      address: String(toplevel.address || ""),
      title: String(toplevel.title || ""),
      order: TaskListModel.launchOrderFromTags(ipc.tags),
      mru: mruRank(toplevel.address, ipc.focusHistoryID),
      activated: Number(ipc.focusHistoryID) === 0 || (Hyprland.activeToplevel &&
        String(Hyprland.activeToplevel.address || "").replace(/^0x/, "") === String(toplevel.address || "").replace(/^0x/, ""))
    }
  }

  function seedMru() {
    var ranked = []
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject
      var rank = ipc ? Number(ipc.focusHistoryID) : -1
      if (isFinite(rank) && rank >= 0)
        ranked.push({ address: String(values[i].address || ""), rank: rank })
    }
    ranked.sort(function(a, b) { return a.rank - b.rank })
    mruAddresses = ranked.map(function(item) { return item.address })
    touchActive()
  }

  function touchActive() {
    var active = Hyprland.activeToplevel
    var address = active ? String(active.address || "") : ""
    if (!address) return
    var next = [address]
    for (var i = 0; i < mruAddresses.length; i++) {
      if (mruAddresses[i] !== address) next.push(mruAddresses[i])
    }
    mruAddresses = next
  }

  function currentRegularWorkspace() {
    var active = Hyprland.activeToplevel
    var activeWorkspace = active ? active.workspace : null
    if (activeWorkspace && String(activeWorkspace.name || "").indexOf("special:") !== 0)
      return activeWorkspace

    var focused = Hyprland.focusedWorkspace
    return focused && String(focused.name || "").indexOf("special:") !== 0 ? focused : null
  }

  function begin(direction) {
    var workspace = currentRegularWorkspace()
    if (!workspace) return

    var minimizedName = "special:omarchy-minimized-" + String(workspace.id)
    var minimized = findWorkspaceByName(minimizedName)
    var items = TaskListModel.listSwitcherToplevels(
      workspace.toplevels.values,
      minimized ? minimized.toplevels.values : [],
      function(toplevel) { return root.describeToplevel(toplevel) }
    )
    if (items.length < 2) return

    snapshot = items
    capturedWorkspaceName = String(workspace.name || "")
    capturedWorkspaceSelector = workspace.id > 0 ? String(workspace.id) : "name:" + capturedWorkspaceName
    minimizedWorkspaceName = minimizedName
    targetScreen = screenForMonitor(workspace.monitor || Hyprland.focusedMonitor)

    var activeIndex = -1
    for (var i = 0; i < items.length; i++) {
      if (items[i].active) { activeIndex = i; break }
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
      begin(direction)
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
  }

  function windowSelector(address) {
    var value = String(address || "")
    return value ? "address:0x" + value : ""
  }

  function luaString(value) {
    return JSON.stringify(String(value || ""))
  }

  function dispatchActivation(target, restore, destination) {
    var actions = []
    if (restore)
      actions.push("hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(destination) + ", follow = false, window = " + luaString(target) + " }))")
    actions.push("local selected = hl.get_window(" + luaString(target) + "); if selected and tonumber(selected.fullscreen) ~= 0 then local workspace = selected.workspace; local windows = hl.get_windows(); for i = #windows, 1, -1 do local window = windows[i]; if window.workspace == workspace and window.floating and not window.pinned and tonumber(window.fullscreen) == 0 and window.allowed_over_fullscreen then hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"bottom\", window = window })) end end end")
    actions.push("hl.dispatch(hl.dsp.focus({ window = " + luaString(target) + " }))")
    actions.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"top\", window = " + luaString(target) + " }))")
    debugLog("switcher.activate", { target: target, restore: restore, destination: destination })
    Hyprland.dispatch("(function() return function() " + actions.join("; ") + " end end)()")
  }

  function commit() {
    if (!opened || selectedIndex < 0 || selectedIndex >= snapshot.length) return "inactive"

    var group = snapshot[selectedIndex]
    var selected = group && group.representative ? group.representative : null
    var address = selected ? String(selected.address || "") : ""
    var target = windowSelector(address)
    var destination = capturedWorkspaceSelector
    var sourceName = capturedWorkspaceName
    var minimizedName = minimizedWorkspaceName
    cancel()
    if (!target || !destination) return "invalid-selection"

    var current = null
    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].address || "") === address) { current = values[i]; break }
    }
    var ipc = current ? current.lastIpcObject : null
    if (!current || !ipc || ipc.mapped !== true || TaskListModel.hasEmbeddedNul(ipc.class) || TaskListModel.hasEmbeddedNul(ipc.initialClass)) return "stale-window"

    var workspaceName = current.workspace ? String(current.workspace.name || "") : ""
    if (workspaceName !== sourceName && workspaceName !== minimizedName) return "moved-window"

    dispatchActivation(target, workspaceName === minimizedName, destination)
    return "activated:" + address
  }

  Component.onCompleted: seedMru()

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/float-panel-debug"
    watchChanges: true
    printErrors: false
    onLoaded: root.debugEnabled = true
    onLoadFailed: root.debugEnabled = false
    onFileChanged: reload()
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.touchActive() }
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
