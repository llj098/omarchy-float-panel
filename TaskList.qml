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
    readonly property bool workspaceFloatEnabled: workspace && workspace.id > 0 && floatWorkspaceNames[String(workspace.name || "")] === true
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

    function activateGroup(group) {
        if (!workspace || !group || !group.representative)
            return ;

        var item = group.representative;
        var target = windowSelector(item.address);
        var action = TaskListModel.actionForGroup(group);
        if (!target || !action)
            return ;

        var statements = [
            "local selected = hl.get_window(" + luaString(target) + ")",
            "if not selected then return end"
        ];
        if (action === "hide") {
            statements.push("hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(minimizedWorkspaceName) + ", follow = false, window = selected }))");
        } else {
            if (action === "restore") {
                var destination = workspaceSelector(workspace);
                if (!destination)
                    return ;

                statements.push("hl.dispatch(hl.dsp.window.move({ workspace = " + luaString(destination) + ", follow = false, window = selected }))");
            }
            statements.push("hl.dispatch(hl.dsp.focus({ window = selected }))");
            statements.push("hl.dispatch(hl.dsp.window.alter_zorder({ mode = \"top\", window = selected }))");
        }
        debugLog("tasklist.activate", {
            "action": action,
            "address": item.address,
            "workspace": String(workspace.name || "")
        });
        Hyprland.dispatch("(function() return function() " + statements.join("; ") + " end end)()");
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
        target: Hyprland.toplevels

        function onValuesChanged() {
            Hyprland.refreshToplevels();
        }
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "openwindow" || event.name === "closewindow" ||
                    event.name === "movewindow" || event.name === "movewindowv2")
                Hyprland.refreshToplevels();

        }
    }

    moduleName: "fatlj.float-panel"
    visible: workspaceFloatEnabled && taskGroups.length > 0
    implicitWidth: visible ? taskGrid.implicitWidth : 0
    implicitHeight: visible ? taskGrid.implicitHeight : 0

    GridLayout {
        id: taskGrid

        anchors.fill: parent
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
