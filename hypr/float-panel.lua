-- Per-workspace floating mode and minimize bindings for Omarchy/Hyprland Lua.
-- Load this file after require("default.hypr.omarchy") so the `o` helpers exist.

local home = os.getenv("HOME") or ""
local state_path = home .. "/.local/state/omarchy/float-panel-workspaces"
local float_workspaces = {}

-- WeChat's XWayland WM_NORMAL_HINTS block interactive shrinking on fractional-scale
-- monitors even though the client accepts smaller configure sizes. Override only the
-- compositor's minimum; the application remains free to lay out its own contents.
hl.window_rule({
  name = "float-panel-wechat-min-size",
  match = { class = "^wechat$", xwayland = true },
  min_size = { 1, 1 },
})

local order_tag_prefix = "float-panel-order-"

local function process_start_ticks(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then return nil end

  local file = io.open("/proc/" .. tostring(math.floor(pid)) .. "/stat", "r")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  if not line then return nil end

  -- Fields after the final ") " start at proc stat field 3; starttime is field 22.
  local fields = line:match("^%d+ %(.+%) (.+)$")
  if not fields then return nil end
  local index = 0
  for value in fields:gmatch("%S+") do
    index = index + 1
    if index == 20 then return tonumber(value) end
  end
  return nil
end

local function tag_window_launch_order(window)
  local start_ticks = window and process_start_ticks(window.pid) or nil
  if not start_ticks then return end

  hl.dispatch(hl.dsp.window.tag({
    tag = "+" .. order_tag_prefix .. string.format("%.0f", start_ticks),
    window = window,
  }))
end

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

local function monitor_work_area(monitor)
  if not monitor then return nil end

  local scale = tonumber(monitor.scale) or 1
  if scale <= 0 then scale = 1 end

  local pixel_width = tonumber(monitor.width) or 0
  local pixel_height = tonumber(monitor.height) or 0
  local transform = tonumber(monitor.transform) or 0
  if transform % 2 == 1 then
    pixel_width, pixel_height = pixel_height, pixel_width
  end

  local reserved = monitor.reserved or {}
  local left = tonumber(reserved.left) or 0
  local right = tonumber(reserved.right) or 0
  local top = tonumber(reserved.top) or 0
  local bottom = tonumber(reserved.bottom) or 0
  local width = math.max(1, math.floor(pixel_width / scale - left - right))
  local height = math.max(1, math.floor(pixel_height / scale - top - bottom))

  return {
    x = math.floor((tonumber(monitor.x) or 0) + left),
    y = math.floor((tonumber(monitor.y) or 0) + top),
    width = width,
    height = height,
  }
end

local function config_gap(name)
  local value = hl.get_config(name)
  if type(value) == "number" then
    return { top = value, right = value, bottom = value, left = value }
  end
  value = type(value) == "table" and value or {}
  return {
    top = tonumber(value.top) or 0,
    right = tonumber(value.right) or 0,
    bottom = tonumber(value.bottom) or 0,
    left = tonumber(value.left) or 0,
  }
end

local function snap_active_window(side)
  local window = hl.get_active_window()
  local area = monitor_work_area(hl.get_active_monitor())
  if not window or not area then return end

  local gaps_out = config_gap("general.gaps_out")
  local gaps_in = config_gap("general.gaps_in")
  local border = math.max(0, tonumber(hl.get_config("general.border_size")) or 0)
  local outer_x = area.x + gaps_out.left
  local outer_y = area.y + gaps_out.top
  local outer_width = math.max(1, area.width - gaps_out.left - gaps_out.right)
  local outer_height = math.max(1, area.height - gaps_out.top - gaps_out.bottom)
  local middle_gap = math.max(0, gaps_in.left + gaps_in.right)
  local halves_width = math.max(2, outer_width - middle_gap)
  local left_outer_width = math.floor(halves_width / 2)
  local outer_half_width = side == "left" and left_outer_width or halves_width - left_outer_width
  local x = side == "left" and outer_x + border or outer_x + left_outer_width + middle_gap + border
  local y = outer_y + border
  local width = math.max(1, outer_half_width - border * 2)
  local height = math.max(1, outer_height - border * 2)

  set_window_floating(window, true)
  -- Resize first so Hyprland does not clamp the old, wider window before placing it.
  hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
end

local function focus_or_snap(direction)
  local workspace = hl.get_active_workspace()
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    snap_active_window(direction == "l" and "left" or "right")
    return
  end

  hl.dispatch(hl.dsp.focus({ direction = direction }))
end

local function cycle_window(next_window)
  hl.dispatch(hl.dsp.window.cycle_next({ next = next_window }))
  hl.dispatch(hl.dsp.window.bring_to_top())
end

local function mode_aware_super_tab(next_window)
  local workspace = hl.get_active_workspace()
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    hl.dispatch(hl.dsp.focus({ workspace = next_window and "e+1" or "e-1" }))
    return
  end

  cycle_window(next_window)
end

load_float_workspaces()

-- Process start ticks survive focus/Z-order changes and let the shell reconstruct
-- launch order after its own restart without a separate ordering database.
for _, window in ipairs(hl.get_windows()) do
  tag_window_launch_order(window)
end

-- Re-apply persisted floating modes when this module is loaded after a config reload.
for _, workspace in ipairs(hl.get_workspaces()) do
  if workspace_float_enabled(workspace) then apply_workspace_mode(workspace) end
end

hl.on("window.open", function(window)
  tag_window_launch_order(window)
  local workspace = window and window.workspace or nil
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    set_window_floating(window, true)
  end
end)

hl.on("window.move_to_workspace", function(window, workspace)
  if not workspace_is_regular(workspace) then return end
  set_window_floating(window, workspace_float_enabled(workspace))
end)

hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("ALT + ALT_L")
hl.unbind("ALT + ALT_R")
o.bind("SUPER + LEFT", "Focus left / snap left in floating mode", function() focus_or_snap("l") end)
o.bind("SUPER + RIGHT", "Focus right / snap right in floating mode", function() focus_or_snap("r") end)
o.bind("SUPER + TAB", "Next workspace in floating / next window in tiling", function() mode_aware_super_tab(true) end)
o.bind("SUPER + SHIFT + TAB", "Previous workspace in floating / previous window in tiling", function() mode_aware_super_tab(false) end)
o.bind("ALT + TAB", "Select next application", hl.dsp.global("fatlj.float-panel:alt-tab-next"))
o.bind("ALT + SHIFT + TAB", "Select previous application", hl.dsp.global("fatlj.float-panel:alt-tab-previous"))
-- Keep modifier-release binds transparent so an intervening ALT+TAB chord does
-- not shadow them before Alt is released.
o.bind("ALT + ALT_L", "Activate selected application", hl.dsp.global("fatlj.float-panel:alt-release"), { release = true, transparent = true })
o.bind("ALT + ALT_R", "Activate selected application", hl.dsp.global("fatlj.float-panel:alt-release"), { release = true, transparent = true })
o.bind("SUPER + SHIFT + T", "Toggle workspace floating mode", toggle_active_workspace_mode)
o.bind("SUPER + M", "Minimize window", minimize_active_window)
