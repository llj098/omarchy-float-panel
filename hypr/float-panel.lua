-- Per-workspace floating mode and minimize bindings for Omarchy/Hyprland Lua.
-- Load this file after require("default.hypr.omarchy") so the `o` helpers exist.

local home = os.getenv("HOME") or ""
local state_path = home .. "/.local/state/omarchy/float-panel-workspaces"
local float_workspaces = {}

local function workspace_is_regular(workspace)
  return workspace ~= nil and workspace.special ~= true
end

local function workspace_key(workspace)
  return workspace and tostring(workspace.name or "") or ""
end

local function load_float_workspaces()
  local file = io.open(state_path, "r")
  if not file then return end

  for line in file:lines() do
    if line ~= "" then float_workspaces[line] = true end
  end
  file:close()
end

local function save_float_workspaces()
  local names = {}
  for name, enabled in pairs(float_workspaces) do
    if enabled then table.insert(names, name) end
  end
  table.sort(names)

  local temporary_path = state_path .. ".tmp"
  local file = io.open(temporary_path, "w")
  if not file then return false end

  for _, name in ipairs(names) do file:write(name, "\n") end
  file:close()

  if not os.rename(temporary_path, state_path) then
    os.remove(temporary_path)
    return false
  end
  return true
end

local function workspace_float_enabled(workspace)
  return float_workspaces[workspace_key(workspace)] == true
end

local function set_window_floating(window, enabled)
  if not window then return end
  hl.dispatch(hl.dsp.window.float({
    action = enabled and "on" or "off",
    window = window,
  }))
end

local function apply_workspace_mode(workspace)
  if not workspace_is_regular(workspace) then return end

  local enabled = workspace_float_enabled(workspace)
  for _, window in ipairs(workspace:get_windows()) do
    set_window_floating(window, enabled)
  end
end

local function toggle_active_workspace_mode()
  local workspace = hl.get_active_workspace()
  if not workspace_is_regular(workspace) then return end

  local key = workspace_key(workspace)
  local enabled = not workspace_float_enabled(workspace)
  float_workspaces[key] = enabled or nil
  save_float_workspaces()
  apply_workspace_mode(workspace)

  local mode = enabled and "floating" or "tiling"
  hl.exec_cmd("omarchy-notification-send " .. o.shell_quote("Workspace " .. key .. " set to " .. mode))
end

local function minimize_active_window()
  local window = hl.get_active_window()
  local workspace = window and window.workspace or nil
  if not workspace_is_regular(workspace) then return end

  local minimized_workspace = "special:omarchy-minimized-" .. tostring(workspace.id)
  hl.dispatch(hl.dsp.window.move({
    workspace = minimized_workspace,
    follow = false,
    window = window,
  }))
end

load_float_workspaces()

-- Re-apply persisted floating modes when this module is loaded after a config reload.
for _, workspace in ipairs(hl.get_workspaces()) do
  if workspace_float_enabled(workspace) then apply_workspace_mode(workspace) end
end

hl.on("window.open", function(window)
  local workspace = window and window.workspace or nil
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    set_window_floating(window, true)
  end
end)

hl.on("window.move_to_workspace", function(window, workspace)
  if not workspace_is_regular(workspace) then return end
  set_window_floating(window, workspace_float_enabled(workspace))
end)

o.bind("SUPER + SHIFT + T", "Toggle workspace floating mode", toggle_active_workspace_mode)
o.bind("SUPER + M", "Minimize window", minimize_active_window)
