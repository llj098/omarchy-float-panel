import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "TaskListModel.js" as TaskListModel
import qs.Commons
import qs.Ui

BarWidget {
    id: root

    readonly property var barWindow: root.QsWindow.window
    readonly property var monitor: barWindow && barWindow.screen ? Hyprland.monitorFor(barWindow.screen) : null
    readonly property var workspace: monitor ? monitor.activeWorkspace : null
    readonly property string minimizedWorkspaceName: workspace ? "special:omarchy-minimized-" + workspace.id : ""
    readonly property var minimizedWorkspace: findWorkspaceByName(minimizedWorkspaceName)
    property var floatWorkspaceNames: ({})
    property bool debugEnabled: false
    property bool clientsRequestPending: false
    property var pendingActivationGroup: null
    property string pendingWorkspaceName: ""
    property var groupCycleStarts: ({})
    readonly property string widgetMode: settings && settings.mode ? String(settings.mode) : "Task List"
    readonly property bool toggleWidget: widgetMode === "Float Toggle"
    readonly property bool regularWorkspace: workspace && workspace.id > 0
    readonly property bool workspaceFloatEnabled: regularWorkspace && floatWorkspaceNames[String(workspace.name || "")] === true
    readonly property var taskGroups: TaskListModel.groupToplevels(workspace ? workspace.toplevels.values : [], minimizedWorkspace ? minimizedWorkspace.toplevels.values : [], function(toplevel) {
        return root.describeToplevel(toplevel);
    })

    function debugLog(event, fields) {
        if (!debugEnabled)
            return ;

        console.info("[fatlj.float-panel] " + event + " " + JSON.stringify(fields || {}));
    }

    function setFloatWorkspaceState(contents) {
        var names = {};
        var lines = String(contents || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var name = lines[i].replace(/\r$/, "");
            if (name)
                names[name] = true;

        }
        floatWorkspaceNames = names;
    }

    function findWorkspaceByName(name) {
        if (!name)
            return null;

        var workspaces = Hyprland.workspaces.values;
        for (var i = 0; i < workspaces.length; i++) {
            if (workspaces[i].name === name)
                return workspaces[i];

        }
        return null;
    }

    function rawAppId(toplevel) {
        if (toplevel && toplevel.wayland && toplevel.wayland.appId)
            return String(toplevel.wayland.appId);

        var ipc = toplevel ? toplevel.lastIpcObject : null;
        return ipc ? String(ipc.class || ipc.initialClass || "") : "";
    }

    function desktopEntry(appId) {
        var id = String(appId || "");
        if (id.slice(-8) === ".desktop")
            id = id.slice(0, -8);

        if (!id)
            return null;

        return DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
    }

    function iconSource(icon) {
        var value = String(icon || "");
        if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0)
            return value;

        if (value.charAt(0) === "/")
            return Util.fileUrl(value);

        if (value) {
            var resolved = Quickshell.iconPath(value, true);
            if (resolved)
                return resolved;

        }
        return Quickshell.iconPath("application-x-executable", true);
    }

    function describeToplevel(toplevel) {
        var ipc = toplevel ? toplevel.lastIpcObject : null;
        if (!ipc || ipc.mapped !== true || TaskListModel.hasEmbeddedNul(ipc.class) || TaskListModel.hasEmbeddedNul(ipc.initialClass))
            return {
            "ignored": true
        };

        var appId = rawAppId(toplevel);
        var entry = desktopEntry(appId);
        return {
            "key": appId || ("window:" + String(toplevel.address || "")),
            "appId": appId,
            "name": entry ? entry.name : (appId || toplevel.title || "Application"),
            "iconSource": iconSource(entry ? entry.icon : appId),
            "address": String(toplevel.address || ""),
            "title": String(toplevel.title || ""),
            "order": TaskListModel.launchOrderFromTags(ipc.tags),
            "activated": toplevel.activated === true,
            "urgent": toplevel.urgent === true
        };
    }

    function workspaceSelector(targetWorkspace) {
        if (!targetWorkspace)
            return "";

        if (targetWorkspace.id > 0)
            return String(targetWorkspace.id);

        return "name:" + String(targetWorkspace.name || "");
    }

    function windowSelector(address) {
        var value = String(address || "");
        return value ? "address:0x" + value : "";
    }

    function luaString(value) {
        return JSON.stringify(String(value || ""));
    }

    function toggleWorkspaceMode() {
        var workspaceId = workspace ? Number(workspace.id) : 0;
        if (workspaceId <= 0)
            return ;

        debugLog("toggle.click", {
            "workspace": String(workspace.name || workspaceId),
            "enabled": !workspaceFloatEnabled
        });
        Hyprland.dispatch("(function() return function() if fatlj_float_panel and type(fatlj_float_panel.toggle_workspace_mode) == \"function\" then fatlj_float_panel.toggle_workspace_mode(" + workspaceId + ") end end end)()");
    }

    function activateGroup(group) {
        if (!workspace || !group || clientsRequestPending)
            return ;

        pendingActivationGroup = group;
        pendingWorkspaceName = String(workspace.name || "");
        clientsRequestPending = true;
        clientsSocket.connected = true;
    }

    function acceptClientsResponse(text) {
        if (!clientsRequestPending)
            return ;

        var clients;
        try {
            clients = JSON.parse(String(text || ""));
        } catch (error) {
            return ;
        }
        if (!Array.isArray(clients))
            return ;

        var group = pendingActivationGroup;
        var sourceName = pendingWorkspaceName;
        clientsRequestPending = false;
        pendingActivationGroup = null;
        pendingWorkspaceName = "";
        clientsSocket.connected = false;
        if (!workspace || String(workspace.name || "") !== sourceName)
            return ;

        activateGroupFromClients(group, clients);
    }

    function activateGroupFromClients(group, clients) {
        if (!workspace || !group)
            return ;

        var groupKey = String(group.key || "");
        var decision = TaskListModel.actionForGroup(group, clients, groupCycleStarts[groupKey]);
        if (!decision || !decision.action)
            return ;
        if (decision.cycleComplete)
            delete groupCycleStarts[groupKey];
        else if (decision.cycleStart)
            groupCycleStarts[groupKey] = String(decision.cycleStart);

        var sourceName = String(workspace.name || "");
        var destination = workspaceSelector(workspace);
        if (!sourceName || !destination)
            return ;

        var statements = [];
        var addresses = [];
        if (decision.action === "hide-all") {
            var targets = decision.targets || [];
            for (var i = 0; i < targets.length; i++) {
                var hideTarget = windowSelector(targets[i].address);
                if (!hideTarget)
                    continue;

                addresses.push(targets[i].address);
                var variable = "selected_" + i;
                statements.push("local " + variable + " = hl.get_window(" + luaString(hideTarget) + ")");
                statements.push("if " + variable + " and " + variable + ".workspace and " + variable + ".workspace.name == " + luaString(sourceName) + " then hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(minimizedWorkspaceName) + ", follow = false, window = " + variable + " })) end");
            }
        } else {
            var item = decision.target;
            var target = item ? windowSelector(item.address) : "";
            if (!target)
                return ;

            addresses.push(item.address);
            statements.push("local selected = hl.get_window(" + luaString(target) + ")");
            statements.push("if not selected or not selected.workspace then return end");
            statements.push("local selected_workspace = selected.workspace.name");
            statements.push("if selected_workspace ~= " + luaString(sourceName) + " and selected_workspace ~= " + luaString(minimizedWorkspaceName) + " then return end");
            statements.push("if selected_workspace == " + luaString(minimizedWorkspaceName) + " then hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(destination) + ", follow = false, window = selected })) end");
            statements.push("hl.dispatch(hl.dsp.focus({ window = selected }))");
            statements.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"top\", window = selected }))");
        }
        if (statements.length === 0)
            return ;

        debugLog("tasklist.activate", {
            "action": decision.action,
            "addresses": addresses.join(","),
            "workspace": sourceName
        });
        Hyprland.dispatch("(function() return function() " + statements.join("; ") + " end end)()");
        // Reconcile after every click so a dead compositor address cannot
        // remain as an inert TaskList icon.
        Hyprland.refreshToplevels();
    }

    Socket {
        id: clientsSocket
        path: Hyprland.requestSocketPath
        connected: false
        onConnectionStateChanged: {
            if (connected && root.clientsRequestPending) {
                write("j/clients");
                flush();
            }
        }
        onError: {
            root.clientsRequestPending = false;
            root.pendingActivationGroup = null;
            root.pendingWorkspaceName = "";
            connected = false;
        }
        parser: StdioCollector {
            waitForEnd: false
            onDataChanged: root.acceptClientsResponse(text)
        }
    }

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/float-panel-workspaces"
        watchChanges: true
        printErrors: false
        onLoaded: root.setFloatWorkspaceState(text())
        onLoadFailed: root.setFloatWorkspaceState("")
        onFileChanged: reload()
    }

    FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/float-panel-debug"
        watchChanges: true
        printErrors: false
        onLoaded: root.debugEnabled = true
        onLoadFailed: root.debugEnabled = false
        onFileChanged: reload()
    }

    Component.onCompleted: Hyprland.refreshToplevels()

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "openwindow" || event.name === "closewindow" ||
                    event.name === "movewindow" || event.name === "movewindowv2")
                Hyprland.refreshToplevels();

        }
    }

    moduleName: "fatlj.float-panel"
    visible: regularWorkspace && (toggleWidget || (workspaceFloatEnabled && taskGroups.length > 0))
    implicitWidth: visible ? (toggleWidget ? floatToggleButton.implicitWidth : taskGrid.implicitWidth) : 0
    implicitHeight: visible ? (toggleWidget ? floatToggleButton.implicitHeight : taskGrid.implicitHeight) : 0

    BarIconButton {
        id: floatToggleButton

        anchors.fill: parent
        visible: root.toggleWidget
        bar: root.bar
        text: "󰖲"
        active: root.workspaceFloatEnabled
        dimmed: !active
        useActiveColor: false
        tooltipText: active ? "Switch this workspace to Tiling" : "Switch this workspace to Float"
        onPressed: function(button) {
            if (button === Qt.LeftButton)
                root.toggleWorkspaceMode();

        }
    }

    GridLayout {
        id: taskGrid

        anchors.fill: parent
        visible: !root.toggleWidget
        columns: root.vertical ? 1 : Math.max(1, root.taskGroups.length)
        rows: root.vertical ? Math.max(1, root.taskGroups.length) : 1
        columnSpacing: 0
        rowSpacing: 0

        Repeater {
            model: root.taskGroups

            WidgetButton {
                id: appButton

                required property var modelData

                bar: root.bar
                labelVisible: false
                hasVisualContent: true
                active: modelData.active
                dimmed: modelData.allMinimized
                fixedWidth: root.barSize
                fixedHeight: root.barSize
                tooltipText: modelData.name + (modelData.count > 1 ? " (" + modelData.count + ")" : "")
                onPressed: function(button) {
                    if (button === Qt.LeftButton)
                        root.activateGroup(modelData);

                }

                Image {
                    anchors.centerIn: parent
                    width: Math.round(Math.min(parent.width, parent.height) * 0.64)
                    height: width
                    source: appButton.modelData.iconSource
                    sourceSize.width: width * Screen.devicePixelRatio
                    sourceSize.height: height * Screen.devicePixelRatio
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                }

                Rectangle {
                    visible: appButton.modelData.active
                    color: root.bar ? root.bar.urgent : Color.urgent
                    radius: 1
                    width: root.vertical ? 2 : Math.round(parent.width * 0.45)
                    height: root.vertical ? Math.round(parent.height * 0.45) : 2
                    anchors.right: root.vertical ? parent.right : undefined
                    anchors.bottom: root.vertical ? undefined : parent.bottom
                    anchors.horizontalCenter: root.vertical ? undefined : parent.horizontalCenter
                    anchors.verticalCenter: root.vertical ? parent.verticalCenter : undefined
                }

            }

        }

    }

}
