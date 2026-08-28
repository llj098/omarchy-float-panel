#!/usr/bin/env python3

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "manifest.json").read_text())

assert manifest["schemaVersion"] == 1
assert manifest["id"] == "fatlj.float-panel"
assert manifest["kinds"] == ["bar-widget"]
assert manifest["entryPoints"]["barWidget"] == "TaskList.qml"
assert manifest["barWidget"]["allowMultiple"] is False
assert (ROOT / manifest["entryPoints"]["barWidget"]).is_file()

qml = (ROOT / "TaskList.qml").read_text()
for required in (
    "Hyprland.monitorFor",
    "monitor.activeWorkspace",
    "workspace.toplevels.values",
    "minimizedWorkspace.toplevels.values",
    "Qt.LeftButton",
    "address:0x",
    "hl.dsp.window.move",
    "hl.dsp.focus",
):
    assert required in qml, f"TaskList.qml missing required contract: {required}"

lua = (ROOT / "hypr" / "float-panel.lua").read_text()
for required in (
    'hl.on("window.open"',
    'hl.on("window.move_to_workspace"',
    'o.bind("SUPER + SHIFT + T"',
    'o.bind("SUPER + M"',
    "special:omarchy-minimized-",
):
    assert required in lua, f"float-panel.lua missing required contract: {required}"

for forbidden in ("hyprbars", "hyprctl clients", "workspace 9", "workspace = \"9\""):
    assert forbidden not in qml
    assert forbidden not in lua

print("STATIC_VALIDATION_OK")
