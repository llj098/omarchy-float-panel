#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Arch/Omarchy installs Qt tools here without adding them to PATH.
export PATH="${PATH}:/usr/lib/qt6/bin"

python -m json.tool manifest.json >/dev/null
python tests/validate.py
node --check TaskListModel.js
node tests/test_model.js
node tests/test_switcher.js
python tests/test_event_socket.py
luac -p hypr/float-panel.lua
luac -p hypr/drag-strip.lua
lua tests/test_drag_strip.lua
make -C native test
if pkg-config --exists hyprland lua; then
  make -C native all
fi

TMP_HOME=$(mktemp -d)
trap 'rm -r "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/.local/state/omarchy"
HOME="$TMP_HOME" lua tests/test_workspace_modes.lua
HOME="$TMP_HOME" lua tests/test_float_panel.lua
HOME="$TMP_HOME" timeout 5 lua tests/test_keybinding_scanner.lua

FORMATTED_QML=$(mktemp)
trap 'rm -r "$TMP_HOME"; rm -f "$FORMATTED_QML"' EXIT
for qml in TaskList.qml AppSwitcher.qml ReconnectingEventSocket.qml; do
  qmlformat "$qml" >"$FORMATTED_QML"
  test -s "$FORMATTED_QML"
done
OMARCHY_ROOT=${OMARCHY_SOURCE:-${OMARCHY_PATH:-/usr/share/omarchy}}
if [[ -d "$OMARCHY_ROOT/shell/Ui" ]]; then
  qmllint -I "$OMARCHY_ROOT/shell" TaskList.qml AppSwitcher.qml ReconnectingEventSocket.qml
  if [[ -x "$OMARCHY_ROOT/bin/omarchy-plugin-validate" ]]; then
    "$OMARCHY_ROOT/bin/omarchy-plugin-validate" .
  fi
else
  qmllint TaskList.qml AppSwitcher.qml ReconnectingEventSocket.qml
fi

printf '%s\n' VALIDATION_OK
