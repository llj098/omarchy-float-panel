#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python -m json.tool manifest.json >/dev/null
python tests/validate.py
node --check TaskListModel.js
node tests/test_model.js
luac -p hypr/float-panel.lua

TMP_HOME=$(mktemp -d)
trap 'rm -r "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/.local/state/omarchy"
HOME="$TMP_HOME" lua tests/test_float_panel.lua

FORMATTED_QML=$(mktemp)
trap 'rm -r "$TMP_HOME"; rm -f "$FORMATTED_QML"' EXIT
for qml in TaskList.qml AppSwitcher.qml; do
  qmlformat "$qml" >"$FORMATTED_QML"
  test -s "$FORMATTED_QML"
done
OMARCHY_ROOT=${OMARCHY_SOURCE:-${OMARCHY_PATH:-/usr/share/omarchy}}
if [[ -d "$OMARCHY_ROOT/shell/Ui" ]]; then
  qmllint -I "$OMARCHY_ROOT/shell" TaskList.qml AppSwitcher.qml
  if [[ -x "$OMARCHY_ROOT/bin/omarchy-plugin-validate" ]]; then
    "$OMARCHY_ROOT/bin/omarchy-plugin-validate" .
  fi
else
  qmllint TaskList.qml AppSwitcher.qml
fi

printf '%s\n' VALIDATION_OK
