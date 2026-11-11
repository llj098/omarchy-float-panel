#!/usr/bin/env bash
# Real-desktop verification that never touches the user's session.
#
# A plugin change that moves windows or draws overlays cannot be checked against the
# live session without disturbing whoever is using the machine, and a second session
# testing at the same time would collide with the same windows. So this script builds
# its own desktop: a nested Hyprland instance on a private runtime directory, its host
# window parked in a dedicated special workspace by a window rule (it is never drawn on
# the user's outputs), a separate Omarchy shell running the working-tree plugin inside
# that instance, and grim pointed at the nested output.
#
# Nothing outside the nested instance is moved, minimised or focused: the scenarios
# build the minimized stores from the plugin's own Lua contract, and the two stores
# (the plugin's per-workspace one and Omarchy's shared one) are exercised in turn.
#
# Start it from inside the session, e.g.
#   hyprctl dispatch '(function() return hl.dsp.exec_cmd("bash <repo>/scripts/desktop-background-verify.sh") end)()'
#
# Results: .debug/bg/logs/*.log, .debug/bg/shots/*.png, .debug/bg/summary.txt
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
BG=$REPO/.debug/bg
RT=/tmp/fpbg-real
PLUGIN=fatlj.float-panel
PARK_WS="special:fp-bg"
PARK_CLASS="aquamarine"   # measured class of the nested compositor's host window
OUT=$BG/logs
SHOTS=$BG/shots
SUMMARY=$BG/summary.txt

HOST_RT=${XDG_RUNTIME_DIR:?}
HOST_SIG=${HYPRLAND_INSTANCE_SIGNATURE:?}
HOST_DISPLAY=${WAYLAND_DISPLAY:?}

mkdir -p "$OUT" "$SHOTS"
: > "$SUMMARY"
rm -f "$SHOTS"/*.png

say() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
host() { XDG_RUNTIME_DIR=$HOST_RT HYPRLAND_INSTANCE_SIGNATURE=$HOST_SIG hyprctl "$@"; }

unpark() {
  host eval 'if _fp_bg_park then _fp_bg_park:set_enabled(false); _fp_bg_park = nil end
             if _fp_bg_sub then _fp_bg_sub:remove(); _fp_bg_sub = nil end' >/dev/null 2>&1
}

# Fail closed: nothing is driven until the nested instance answers on its own display.
nested_ready() {
  [[ -S $RT/${NESTED_DISPLAY:-none} ]] || return 1
  nested monitors -j 2>/dev/null | grep -q '"name"'
}

# The nested output can disappear mid-run (its host window is re-created). Capturing
# then would connect to whatever display answers, so every capture verifies the
# instance and the output first.
nested_output_alive() {
  nested_ready || return 1
  nested monitors -j 2>/dev/null | grep -q "\"${NESTED_OUTPUT:-none}\""
}

cleanup() {
  set +e
  for pid in ${QS_PID:-} ${NESTED_PID:-}; do kill "$pid" 2>/dev/null; done
  sleep 1
  unpark
  # The shell starts its own inotify helper for plugin reloads; it outlives the
  # instance and must not be left watching a removed directory.
  ps -eo pid,args | awk '/fpbg-real/ && !/awk/ {print $1}' | xargs -r kill 2>/dev/null
  rm -rf "$RT"
}
trap cleanup EXIT

# ------------------------------------------------------------------ private stage
rm -rf "$RT"
mkdir -p "$RT/home/.config/omarchy/plugins/$PLUGIN" "$RT/home/.local/state/omarchy" "$RT/home/.cache" "$RT/home/.local/share"
chmod 700 "$RT"
ln -s "$HOST_RT/$HOST_DISPLAY" "$RT/host-wayland"
printf 'hl.config({ general = { gaps_out = 8, border_size = 1 }, decoration = { rounding = 0 } })\n' > "$RT/hypr.lua"

# The plugin under test is the working tree, not the deployed copy.
for f in AppSwitcher.qml TaskList.qml TaskListModel.js ReconnectingEventSocket.qml manifest.json; do
  cp "$REPO/$f" "$RT/home/.config/omarchy/plugins/$PLUGIN/$f"
done
# The shell rejects a hand-written minimal config as unreadable and silently falls back
# to its builtin one, which would load no third-party plugin at all.
cp "$HOME/.config/omarchy/shell.json" "$RT/home/.config/omarchy/shell.json"

# --------------------------------------------------------------- nested instance
host eval "_fp_bg_park = hl.window_rule({ name = \"fp-bg-park\", match = { class = \"^($PARK_CLASS)\$\" }, workspace = \"$PARK_WS\" })
           _fp_bg_sub = hl.on('window.open', function(w)
             if w and (tostring(w.class or ''):lower():find('$PARK_CLASS') or tostring(w.title or ''):lower():find('$PARK_CLASS')) then
               hl.dispatch(hl.dsp.window.move({ workspace = '$PARK_WS', follow = false, window = w }))
             end
           end)" >/dev/null 2>&1

XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=host-wayland HOME=$RT/home \
  Hyprland -c "$RT/hypr.lua" > "$OUT/nested-hyprland.log" 2>&1 &
NESTED_PID=$!

for _ in $(seq 1 80); do
  NESTED_DISPLAY=$(ls "$RT" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
  [[ -n ${NESTED_DISPLAY:-} ]] && break
  sleep 0.25
done
NSIG=$(basename "$(ls -d "$RT"/hypr/*/ 2>/dev/null | head -1)" 2>/dev/null)
if [[ -z ${NSIG:-} || -z ${NESTED_DISPLAY:-} ]]; then
  say "FAIL: nested Hyprland did not start"; tail -5 "$OUT/nested-hyprland.log" | tee -a "$SUMMARY"; exit 1
fi
nested() { XDG_RUNTIME_DIR=$RT HYPRLAND_INSTANCE_SIGNATURE=$NSIG hyprctl "$@"; }
say "nested instance: display=$NESTED_DISPLAY sig=${NSIG:0:20}..."

# Report where the nested window landed: it must never be on a user-visible workspace.
PARK_INFO=""
for _ in $(seq 1 120); do
  PARK_INFO=$(host clients -j | python3 -c "
import json, sys
want = int(sys.argv[1])
for c in json.load(sys.stdin):
    if c.get('pid') == want:
        print(c['workspace']['name'], repr(c.get('class')))
        break
" "$NESTED_PID")
  [[ -n ${PARK_INFO:-} ]] && break
  sleep 0.05
done
PARKED=${PARK_INFO%% *}
if [[ -n ${PARK_INFO:-} && $PARKED != "$PARK_WS" ]]; then
  ADDR=$(host clients -j | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c.get('pid') == int(sys.argv[1]): print(c['address']); break
" "$NESTED_PID")
  host dispatch "(function() return hl.dsp.window.move({ workspace = \"$PARK_WS\", follow = false, window = \"address:$ADDR\" }) end)()" >/dev/null 2>&1
  sleep 0.2
  PARKED=$(host clients -j | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c.get('pid') == int(sys.argv[1]): print(c['workspace']['name']); break
" "$NESTED_PID")
fi
if [[ $PARKED != "$PARK_WS" ]]; then
  say "ABORT: the nested window is not parked (at ${PARKED:-<none>}); it would be visible on the user's output"
  exit 1
fi
say "nested window: ${PARK_INFO:-<not found>} -> parked (user-visible: no)"
NESTED_OUTPUT=$(nested monitors -j | python3 -c "import json, sys; print(json.load(sys.stdin)[0]['name'])")
say "nested output: $NESTED_OUTPUT"

# ---------------------------------------------------------------- shell in nested
XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=$NESTED_DISPLAY HYPRLAND_INSTANCE_SIGNATURE=$NSIG \
HOME=$RT/home XDG_CONFIG_HOME=$RT/home/.config XDG_STATE_HOME=$RT/home/.local/state \
XDG_CACHE_HOME=$RT/home/.cache XDG_DATA_HOME=$RT/home/.local/share \
OMARCHY_PATH=/usr/share/omarchy QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 \
  quickshell -n -p /usr/share/omarchy/shell > "$OUT/quickshell.log" 2>&1 &
QS_PID=$!

shell_call() {
  XDG_RUNTIME_DIR=$RT OMARCHY_PATH=/usr/share/omarchy OMARCHY_SHELL_IPC_TIMEOUT=2s \
    omarchy-shell "$@" 2>&1
}

ready=no
for _ in $(seq 1 80); do
  if shell_call shell ping >/dev/null 2>&1; then ready=yes; break; fi
  sleep 0.25
done
say "nested Omarchy shell ready: $ready"
if [[ $ready != yes ]]; then tail -15 "$OUT/quickshell.log" | tee -a "$SUMMARY"; exit 1; fi

# Debug records go to the shell's stdout, which is this log.
: > "$RT/home/.local/state/omarchy/float-panel-debug"
sleep 0.5

nested dispatch '(function() return hl.dsp.exec_cmd("alacritty --class fp-bg-one --title fp-bg-one") end)()' >/dev/null 2>&1
nested dispatch '(function() return hl.dsp.exec_cmd("alacritty --class fp-bg-two --title fp-bg-two") end)()' >/dev/null 2>&1
sleep 2.5
say "nested clients: $(nested clients -j | python3 -c "
import json, sys
print([(c['class'], c['workspace']['name']) for c in json.load(sys.stdin)])")"

status() { shell_call shell call $PLUGIN status '{}'; }
press() {
  nested_ready || { say "press skipped: nested instance not answering"; return 0; }
  nested dispatch '(function() return hl.dsp.global("fatlj.float-panel:alt-tab-next") end)()' >/dev/null 2>&1
}
commit() { shell_call shell call $PLUGIN commit '{}'; }
step() {
  # Guarded scenario step: reports and skips instead of guessing on a dead instance.
  if ! nested_ready; then say "$1 skipped: nested instance not answering"; return 0; fi
  nested eval "$2" >/dev/null 2>&1
}
shot() {
  local err
  if ! nested_output_alive; then
    say "shot SKIPPED for $1: nested output $NESTED_OUTPUT is gone (instance no longer trustworthy)"
    return 0
  fi
  err=$(XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=$NESTED_DISPLAY timeout 15 grim -o "$NESTED_OUTPUT" "$SHOTS/$1.png" 2>&1)
  if [[ -f $SHOTS/$1.png ]]; then say "shot: $SHOTS/$1.png ($(stat -c%s "$SHOTS/$1.png") bytes) $err"
  else say "shot FAILED for $1: ${err:-timeout}"; fi
}

# --------------------------------------- A: the plugin's own per-workspace store
nested eval 'for _, w in ipairs(hl.get_windows()) do if w.workspace and w.workspace.special ~= true then hl.dispatch(hl.dsp.window.move({ workspace = "special:omarchy-minimized-1", follow = false, window = w })) end end' >/dev/null 2>&1
sleep 1
say "A workspaces: $(nested workspaces -j | python3 -c "import json, sys; print([(w['name'], w['windows']) for w in json.load(sys.stdin)])")"
say "A status before: $(status)"
press; sleep 1
say "A status after Alt+Tab: $(status)"
shot A-plugin-store

# ------------------------------------------ B: Omarchy's shared minimized store
say "A commit: $(commit)"; sleep 1.2
nested eval 'for _, w in ipairs(hl.get_windows()) do if w.workspace and w.workspace.name ~= "special:minimized" then hl.dispatch(hl.dsp.window.tag({ tag = "+omarchy-minimized-from-1", window = w })); hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = w })) end end' >/dev/null 2>&1
sleep 1
say "B workspaces: $(nested workspaces -j | python3 -c "import json, sys; print([(w['name'], w['windows']) for w in json.load(sys.stdin)])")"
say "B status before: $(status)"
press; sleep 1
say "B status after Alt+Tab: $(status)"
shot B-shared-store
say "B commit: $(commit)"; sleep 1.5
say "B clients after activation: $(nested clients -j | python3 -c "
import json, sys
print([(c['class'], c['workspace']['name']) for c in json.load(sys.stdin)])")"

say "--- switcher records from the nested shell ---"
grep -E "switcher\.(begin|activate|activation|request_ignored|recover_unmapped)" "$OUT/quickshell.log" | tail -12 | tee -a "$SUMMARY"
