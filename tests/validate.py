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

activation = switcher[switcher.index("  function dispatchActivation("):switcher.index("  function commit()")]
live_target = "local selected = hl.get_window("
fullscreen_guard = "selected and tonumber(selected.fullscreen) ~= 0"
lower = 'hl.dsp.window.alter_zorder({ mode = \\"bottom\\", window = window })'
focus = 'hl.dsp.focus({ window = '
raise_top = 'hl.dsp.window.alter_zorder({ mode = \\"top\\", window = '
assert live_target in activation
assert fullscreen_guard in activation
assert "window.workspace == workspace" in activation
assert "window.allowed_over_fullscreen" in activation
assert activation.index(live_target) < activation.index(fullscreen_guard) < activation.index(lower) < activation.index(focus) < activation.index(raise_top)
assert activation.count(lower) == 1, "fullscreen cleanup must remain conditional and normal activation unchanged"
assert "Number(ipc.fullscreen)" not in switcher, "mutable fullscreen state must not come from stale lastIpcObject"
assert "dispatchActivation(target, workspaceName === minimizedName, destination)" in switcher

lua = (ROOT / "hypr" / "float-panel.lua").read_text()
for required in (
    'hl.on("window.open"',
    'hl.on("window.move_to_workspace"',
    'hl.on("workspace.move_to_monitor"',
    "fit_migrated_float_workspace(workspace)",
    "floating_window_bounds(window.monitor)",
    "window.mapped ~= true",
    "window.hidden == true",
    "window.floating ~= true",
    "tonumber(window.fullscreen)",
    "tonumber(size.x)",
    "tonumber(size.y)",
    "hl.get_windows()",
    "hl.dsp.window.tag",
    'order_tag_prefix = "float-panel-order-"',
    'o.bind("SUPER + SHIFT + T"',
    'o.bind("SUPER + M"',
    'o.bind("SUPER + UP"',
    'o.bind("SUPER + DOWN"',
    'o.bind("SUPER + F"',
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
    '{ "SUPER + code:20", "Expand window left", -100, 0 }',
    '{ "SUPER + code:21", "Shrink window left", 100, 0 }',
    '{ "SUPER + SHIFT + code:20", "Shrink window up", 0, -100 }',
    '{ "SUPER + SHIFT + code:21", "Expand window down", 0, 100 }',
    '{ "SUPER + ALT + code:20", "Expand window left a little", -25, 0 }',
    '{ "SUPER + ALT + code:21", "Shrink window left a little", 25, 0 }',
    '{ "SUPER + SHIFT + ALT + code:20", "Shrink window up a little", 0, -25 }',
    '{ "SUPER + SHIFT + ALT + code:21", "Expand window down a little", 0, 25 }',
    '{ "SUPER + CTRL + code:20", "Expand window left a lot", -300, 0 }',
    '{ "SUPER + CTRL + code:21", "Shrink window left a lot", 300, 0 }',
    '{ "SUPER + CTRL + SHIFT + code:20", "Shrink window up a lot", 0, -300 }',
    '{ "SUPER + CTRL + SHIFT + code:21", "Expand window down a lot", 0, 300 }',
    'hl.unbind("SUPER + UP")',
    'hl.unbind("SUPER + DOWN")',
    'hl.unbind("SUPER + F")',
    'hl.config({ general = { float_gaps = -1 } })',
    'hl.dsp.window.fullscreen({',
    'mode = "maximized"',
    'action = direction == "u" and "set" or "unset"',
    'hl.dsp.window.fullscreen_state({',
    "internal = 2",
    "client = 0",
    'action = "toggle"',
    "hl.get_active_monitor()",
    'config_gap("general.float_gaps")',
    'config_gap("general.gaps_out")',
    "relative = true",
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

assert "Qt.callLater(function() { root.dispatchActivation" not in switcher
assert lua.count('hl.on("workspace.move_to_monitor"') == 1
assert 'hl.on("monitor.removed"' not in lua
for forbidden in ("callLater", "Timer", "poll", "mouse_button"):
    assert forbidden not in lua, f"migration repair must not use delayed/blanket workaround: {forbidden}"

print("STATIC_VALIDATION_OK")
