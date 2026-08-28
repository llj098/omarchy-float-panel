#!/usr/bin/env python3

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "manifest.json").read_text())

assert manifest["schemaVersion"] == 1
assert manifest["id"] == "fatlj.float-panel"
assert manifest["kinds"] == ["bar-widget", "overlay"]
assert manifest["keepLoaded"] is True
assert manifest["entryPoints"]["barWidget"] == "TaskList.qml"
assert manifest["entryPoints"]["overlay"] == "AppSwitcher.qml"
assert manifest["barWidget"]["allowMultiple"] is False
assert (ROOT / manifest["entryPoints"]["barWidget"]).is_file()
assert (ROOT / manifest["entryPoints"]["overlay"]).is_file()

qml = (ROOT / "TaskList.qml").read_text()
for required in (
    "Hyprland.monitorFor",
    "monitor.activeWorkspace",
    'import Quickshell.Io',
    'float-panel-workspaces',
    "watchChanges: true",
    "onFileChanged: reload()",
    "workspace.id > 0",
    "workspaceFloatEnabled && taskGroups.length > 0",
    "workspace.toplevels.values",
    "minimizedWorkspace.toplevels.values",
    "Hyprland.toplevels",
    "Hyprland.refreshToplevels()",
    "TaskListModel.launchOrderFromTags(ipc.tags)",
    "Qt.LeftButton",
    "address:0x",
    "hl.dsp.window.move",
    "hl.dsp.window.alter_zorder",
    "hl.dsp.focus",
    "TaskListModel.actionForGroup",
    "ipc.mapped !== true",
    "TaskListModel.hasEmbeddedNul(ipc.class)",
    '"ignored": true',
):
    assert required in qml, f"TaskList.qml missing required contract: {required}"

switcher = (ROOT / "AppSwitcher.qml").read_text()
for required in (
    "GlobalShortcut",
    'name: "alt-tab-next"',
    'name: "alt-tab-previous"',
    'name: "alt-release"',
    "onReleased: root.commit()",
    "TaskListModel.groupSwitcherToplevels",
    "Hyprland.activeToplevel",
    "active.workspace",
    "Hyprland.focusedWorkspace",
    "workspace.monitor || Hyprland.focusedMonitor",
    "Qt.callLater(function() { root.dispatchActivation",
    "special:omarchy-minimized-",
    "ipc.mapped !== true",
    "TaskListModel.hasEmbeddedNul(ipc.class)",
    "Color.menu.background",
    "Color.menu.selectedBackground",
    "Color.menu.selectedBorder",
    "Style.font.menuFamily",
    "Border.surfaceSpec",
    "WlrKeyboardFocus.None",
    "Hyprland.dispatch",
    "hl.dsp.window.alter_zorder",
):
    assert required in switcher, f"AppSwitcher.qml missing required contract: {required}"

lua = (ROOT / "hypr" / "float-panel.lua").read_text()
for required in (
    'hl.on("window.open"',
    'hl.on("window.move_to_workspace"',
    "hl.get_windows()",
    "hl.dsp.window.tag",
    'order_tag_prefix = "float-panel-order-"',
    'o.bind("SUPER + SHIFT + T"',
    'o.bind("SUPER + M"',
    'o.bind("SUPER + TAB"',
    'o.bind("SUPER + SHIFT + TAB"',
    'workspace = next_window and "e+1" or "e-1"',
    'o.bind("ALT + TAB"',
    'o.bind("ALT + SHIFT + TAB"',
    'o.bind("ALT + ALT_L"',
    'o.bind("ALT + ALT_R"',
    'hl.dsp.global("fatlj.float-panel:alt-tab-next")',
    '{ release = true, transparent = true }',
    'hl.unbind("SUPER + LEFT")',
    "hl.get_active_monitor()",
    'config_gap("general.gaps_out")',
    "hl.dsp.window.resize",
    'name = "float-panel-wechat-min-size"',
    "min_size = { 1, 1 }",
    "special:omarchy-minimized-",
):
    assert required in lua, f"float-panel.lua missing required contract: {required}"

for forbidden in ("hyprbars", "hyprctl clients", "workspace 9", "workspace = \"9\""):
    assert forbidden not in qml
    assert forbidden not in switcher
    assert forbidden not in lua

print("STATIC_VALIDATION_OK")
