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
assert manifest["barWidget"]["allowMultiple"] is True
assert manifest["barWidget"]["defaults"]["mode"] == "Task List"
mode_schema = next(item for item in manifest["barWidget"]["schema"] if item["key"] == "mode")
assert mode_schema["type"] == "enum"
assert mode_schema["options"] == ["Task List", "Float Toggle"]
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
    'widgetMode === "Float Toggle"',
    "toggleWidget || (workspaceFloatEnabled && taskGroups.length > 0)",
    "BarIconButton",
    'text: "󰖲"',
    "dimmed: !active",
    'button === Qt.LeftButton',
    "root.toggleWorkspaceMode()",
    "fatlj_float_panel.toggle_workspace_mode(",
    "workspace.toplevels.values",
    "minimizedWorkspace.toplevels.values",
    "Hyprland.refreshToplevels()",
    "TaskListModel.launchOrderFromTags(ipc.tags)",
    "Qt.LeftButton",
    "address:0x",
    "hl.dsp.window.move",
    "hl.dsp.window.alter_zorder",
    "hl.dsp.focus",
    "Hyprland.dispatch",
    "local selected = hl.get_window",
    "if not selected or not selected.workspace then return end",
    "window = selected",
    'decision.action === "hide-all"',
    'decision.targets',
    '"tasklist.activate"',
    'float-panel-debug',
    "TaskListModel.actionForGroup",
    '"addresses": addresses.join(",")',
    "ipc.mapped !== true",
    "TaskListModel.hasEmbeddedNul(ipc.class)",
    '"ignored": true',
):
    assert required in qml, f"TaskList.qml missing required contract: {required}"

task_activation = qml[qml.index("    function activateGroup("):qml.index("    FileView {")]
assert task_activation.index("Hyprland.dispatch") < task_activation.index("Hyprland.refreshToplevels()"), \
    "TaskList clicks must reconcile stale toplevels after dispatch"
assert "target: Hyprland.toplevels" not in qml, \
    "toplevel value changes are already reactive and must not recursively request another refresh"

switcher = (ROOT / "AppSwitcher.qml").read_text()
for required in (
    "GlobalShortcut",
    'name: "alt-tab-next"',
    'name: "alt-tab-previous"',
    'name: "alt-release"',
    "onReleased: root.commit()",
    "TaskListModel.listSwitcherToplevels",
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
    '"switcher.activate"',
    'float-panel-debug',
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
assert "groupSwitcherToplevels" not in switcher
assert "floatWorkspaceNames" not in switcher and "workspaceFloatEnabled" not in switcher, \
    "Alt-Tab must remain available on regular Tiling workspaces"

lua = (ROOT / "hypr" / "float-panel.lua").read_text()
for required in (
    'hl.on("window.open"',
    'hl.on("window.close"',
    'hl.on("hyprland.shutdown"',
    'hl.on("window.move_to_workspace"',
    'hl.on("workspace.move_to_monitor"',
    'hl.on("monitor.layout_changed"',
    'hl.on("layer.opened"',
    "workspace.monitor == monitor",
    "local function safe_ipairs(values)",
    "local value = rawget(values, index)",
    "for _, workspace in safe_ipairs(hl.get_workspaces()) do",
    "for _, window in safe_ipairs(hl.get_windows()) do",
    "for _, window in safe_ipairs(workspace:get_windows()) do",
    "defensively_fit_float_workspace(workspace)",
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
    "local function toggle_workspace_mode(workspace, event)",
    "fatlj_float_panel.toggle_workspace_mode = function(workspace_selector)",
    'toggle_workspace_mode(hl.get_workspace(workspace_selector), "ui.toggle_mode")',
    'o.bind("SUPER + M"',
    'o.bind("SUPER + UP"',
    'o.bind("SUPER + DOWN"',
    'o.bind("SUPER + F"',
    'o.bind("SUPER + TAB"',
    'o.bind("SUPER + SHIFT + TAB"',
    'workspace = next_workspace and "m+1" or "m-1"',
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
    'hl.dsp.window.fullscreen_state({',
    'geometric_max_tag_prefix = "float-panel-geometric-max-v1-"',
    'side_intent_tag_prefix = "float-panel-side-v1-"',
    'geometry_slot_tag_prefix = "float-panel-geometry-slot-v1-"',
    'float-panel-geometries',
    'native/build/float-panel-native.so',
    'hl.plugin.load(native_bridge_path)',
    'native_float_panel.window_semantics',
    'read_native_window_semantics(window)',
    'safely_install_xwayland_size_constraints(window)',
    'hl.dsp.window.set_prop({ prop = "min_size"',
    'hl.dsp.window.set_prop({ prop = "max_size"',
    'window_persistence_semantics(window)',
    'local function window_persistence_policy(semantics)',
    'semantics.xwayland == false',
    'window_type == "normal" or window_type == "dialog"',
    'return false, "transient"',
    'return false, "has-parent"',
    'return false, "override-redirect"',
    'window.initial_class',
    'window.xdg_tag',
    'load_geometry_records()',
    'save_geometry_records()',
    'claim_geometry_slot(window, workspace)',
    'debug_log_limit = 5 * 1024 * 1024',
    'debug_window_action("bind.direction"',
    "local function debug_window_geometry(event, window, workspace, fields)",
    'debug_window_geometry("event.window_open_before"',
    'debug_window_geometry("event.window_open_after"',
    "fields.initial_class = window and window.initial_class",
    "geometry_slot = slot or \"none\"",
    "restored_intent = record and record.intent or \"none\"",
    'debug_log("event.layer_opened"',
    'refresh_workspace_xwayland_size_hints(workspace)',
    'for _, window in safe_ipairs(hl.get_windows()) do safely_install_xwayland_size_constraints(window) end',
    'window_side_intent(window)',
    'side_geometry(side.side, window.monitor)',
    'update_side_intent(window, workspace, side, geometry)',
    'local observed = at and size and {',
    'adopt_existing_side_intent(window, workspace)',
    'make_geometric_max_tag(window, workspace)',
    'window_geometric_max_metadata(window)',
    'hl.dsp.window.alter_zorder({ mode = "top", window = window })',
    'clear_geometric_max_metadata_for_workspace(workspace)',
    "internal = 2",
    "client = 0",
    'action = "toggle"',
    "local function active_window_context()",
    "window.workspace, window.monitor",
    "hl.get_active_monitor()",
    'config_gap("general.float_gaps")',
    'config_gap("general.gaps_out")',
    "relative = true",
    "hl.dsp.window.resize",
    'semantics.parent_address',
    'semantics.position_specified == true',
    'semantics.program_position == true',
    'semantics.user_position == true',
    'pcall(hl.get_window, "address:" .. parent_address)',
    'initial_placement = "parent"',
    "special:omarchy-minimized-",
):
    assert required in lua, f"float-panel.lua missing required contract: {required}"

for unsafe_iteration in (
    " in ipairs(hl.get_windows())",
    " in ipairs(hl.get_workspaces())",
    " in ipairs(workspace:get_windows())",
):
    assert unsafe_iteration not in lua, f"Hyprland proxy lists must use safe iteration: {unsafe_iteration}"

for forbidden in ("hyprbars", "hyprctl clients", "workspace 9", "workspace = \"9\""):
    assert forbidden not in qml
    assert forbidden not in switcher
    assert forbidden not in lua

assert "native_float_panel.apply_xwayland_size_hints" not in lua, \
    "Lua must consume read-only native facts and apply constraints through the standard dispatcher"

assert "bar.run" not in qml and "hyprctl dispatch" not in qml, \
    "TaskList actions must use one in-process Hyprland request"
assert "wechat" not in lua.lower() and "min_size = { 1, 1 }" not in lua, \
    "XWayland constraints must not use an application-class override"
assert "Timer {" not in qml, "TaskList IPC refresh must be event-driven"
assert "Qt.callLater(function() { list.positionViewAtIndex" in switcher, \
    "AppSwitcher must position its list after QML has applied the snapshot"
assert 'hl.unbind("SUPER + CTRL + TAB")' not in lua, \
    "Omarchy's former-workspace binding must remain enabled"
assert lua.count('hl.on("workspace.move_to_monitor"') == 1
assert lua.count('hl.on("monitor.layout_changed"') == 1
assert lua.count('hl.on("layer.opened"') == 1
assert 'hl.on("workspace.work_area_changed"' not in lua
assert 'hl.on("monitor.removed"' not in lua
for forbidden_event in ('layer.closed', 'config.props_refreshed'):
    assert f'hl.on("{forbidden_event}"' not in lua, "layout repair must not stitch unrelated events"
assert not (ROOT / "patches" / "hyprland-0.56.2-work-area-event.patch").exists(), \
    "the plugin must not require a custom Hyprland build"
native_main = (ROOT / "native" / "src" / "main.cpp").read_text()
for required in (
    "HyprlandAPI::addLuaFunction",
    '"float_panel", "window_semantics"',
    "window->parent()",
    "m_transient",
    "m_atoms",
    "isX11OverrideRedirect()",
    "XCB_ICCCM_SIZE_HINT_P_POSITION",
    "XCB_ICCCM_SIZE_HINT_US_POSITION",
    "xwaylandSizeToReal",
    "GIT_COMMIT_HASH",
):
    assert required in native_main, f"native bridge missing required contract: {required}"
for raw_field in (
    '"found"', '"xwayland"', '"has_parent"', '"parent_address"', '"transient"',
    '"override_redirect"', '"window_type"', '"program_position"', '"user_position"',
    '"position_specified"', '"has_xwayland_size_hints"', '"xwayland_min_size_raw"',
    '"xwayland_min_size_logical"', '"xwayland_max_size_raw"', '"xwayland_max_size_logical"',
):
    assert raw_field in native_main, f"native metadata bridge missing raw fact: {raw_field}"
assert native_main.count('removeLuaFunction(pluginHandle, "float_panel"') == 1, \
    "the single read-only native binding must be removed on plugin exit"
for forbidden_native_effect in (
    "apply_xwayland_size_hints", "minSizeOverride", "maxSizeOverride", "PRIORITY_SET_PROP",
):
    assert forbidden_native_effect not in native_main, \
        f"native bridge must remain read-only: {forbidden_native_effect}"
assert "persistent_candidate" not in native_main and "persistentCandidate" not in native_main, \
    "native metadata bridge must not own persistence policy"
assert not (ROOT / "native" / "src" / "window_policy.hpp").exists()
assert not (ROOT / "native" / "tests" / "test_window_policy.cpp").exists()
assert "wechat" not in native_main.lower() and "m_title" not in native_main, \
    "native metadata bridge must remain application-independent and title-free"
rounding = (ROOT / "native" / "src" / "size_hint_rounding.hpp").read_text()
assert "std::ceil(converted)" in rounding and "std::floor(converted)" in rounding
assert "raw >= 5" in rounding, "finite XWayland max threshold must match CWindow::maxSize()"
assert (ROOT / "native" / "tests" / "test_size_hint_rounding.cpp").is_file()
policy_tests = (ROOT / "tests" / "test_float_panel.lua").read_text()
for policy_case in (
    '"wayland"', '"normal"', '"dialog"', '"parent"', '"transient"',
    '"override"', '"utility"', '"tooltip"', '"bridge-error"', '"not-found"',
):
    assert policy_case in policy_tests, f"Lua persistence policy matrix missing: {policy_case}"
assert "synthetic native bridge failure" in policy_tests
assert "must fail closed without stripping an existing tag" in policy_tests

assert 'mode = "maximized"' not in lua, "Float maximize must not use Hyprland's single fullscreen owner"
assert "monocle" not in lua.lower() and "workspace_rule" not in lua, "geometry maximize must not change tiled layouts"
assert 'workspace = next_workspace and "e+1" or "e-1"' not in lua, "cross-monitor workspace cycling must not break same-monitor boundary wrap"
assert "hl.dsp.window.cycle_next" not in lua and "hl.dsp.window.bring_to_top" not in lua, "Super+Tab must remain workspace navigation in every mode"
for forbidden in ("callLater", "Timer", "poll", "mouse_button"):
    assert forbidden not in lua, f"migration repair must not use delayed/blanket workaround: {forbidden}"

print("STATIC_VALIDATION_OK")
