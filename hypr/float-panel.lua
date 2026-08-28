-- Per-workspace floating mode and minimize bindings for Omarchy/Hyprland Lua.
-- Load this file after require("default.hypr.omarchy") so the `o` helpers exist.

local home = os.getenv("HOME") or ""
local state_path = home .. "/.local/state/omarchy/float-panel-workspaces"
local float_workspaces = {}

-- Negative float gaps inherit general.gaps_out in Hyprland 0.56.2, keeping
-- native floating maximization inside the same gapped workspace work area.
hl.config({ general = { float_gaps = -1 } })

-- WeChat's XWayland WM_NORMAL_HINTS block interactive shrinking on fractional-scale
-- monitors even though the client accepts smaller configure sizes. Override only the
-- compositor's minimum; the application remains free to lay out its own contents.
hl.window_rule({
  name = "float-panel-wechat-min-size",
  match = { class = "^wechat$", xwayland = true },
  min_size = { 1, 1 },
})

local order_tag_prefix = "float-panel-order-"
local geometric_max_tag_prefix = "float-panel-geometric-max-v1-"
local side_intent_tag_prefix = "float-panel-side-v1-"

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

local apply_workspace_mode

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

local function floating_window_bounds(monitor)
  local area = monitor_work_area(monitor)
  if not area then return nil end

  local gaps = config_gap("general.float_gaps")
  if gaps.top < 0 or gaps.right < 0 or gaps.bottom < 0 or gaps.left < 0 then
    gaps = config_gap("general.gaps_out")
  end
  local border = math.max(0, tonumber(hl.get_config("general.border_size")) or 0)
  local left = area.x + gaps.left + border
  local top = area.y + gaps.top + border
  local right = area.x + area.width - gaps.right - border
  local bottom = area.y + area.height - gaps.bottom - border

  return {
    left = left,
    top = top,
    right = right,
    bottom = bottom,
    width = math.max(1, right - left),
    height = math.max(1, bottom - top),
  }
end

local function encode_hex(value)
  return (tostring(value or ""):gsub(".", function(character)
    return string.format("%02x", string.byte(character))
  end))
end

local function decode_hex(value)
  if type(value) ~= "string" or value == "" or #value % 2 ~= 0 or value:find("[^0-9a-f]") then return nil end
  return (value:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end))
end

local function encode_integer(value)
  value = math.floor(tonumber(value) or 0)
  return (value < 0 and "n" or "p") .. tostring(math.abs(value))
end

local function decode_integer(value)
  if type(value) ~= "string" then return nil end
  local sign, digits = value:match("^([pn])(%d+)$")
  if not sign then return nil end
  local number = tonumber(digits)
  return sign == "n" and -number or number
end

local function workspace_selector(workspace)
  if not workspace then return "" end
  return tostring(workspace.config_name or workspace.name or "")
end

local function parse_geometric_max_tag(tag)
  if type(tag) ~= "string" or tag:sub(1, #geometric_max_tag_prefix) ~= geometric_max_tag_prefix then return nil end
  local body = tag:sub(#geometric_max_tag_prefix + 1)
  local x, y, width, height, workspace_id, source_hex =
    body:match("^([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([0-9a-f]+)$")
  if not x then return nil end

  local result = {
    raw = tag,
    x = decode_integer(x),
    y = decode_integer(y),
    width = decode_integer(width),
    height = decode_integer(height),
    workspace_id = decode_integer(workspace_id),
    source = decode_hex(source_hex),
  }
  if not result.x or not result.y or not result.width or not result.height or result.width < 1 or result.height < 1 or
      not result.workspace_id or not result.source or result.source == "" then return nil end
  return result
end

local function window_geometric_max_metadata(window)
  for _, tag in ipairs(window and window.tags or {}) do
    local metadata = parse_geometric_max_tag(tag)
    if metadata then return metadata end
  end
  return nil
end

local function make_geometric_max_tag(window, workspace)
  local at = window and window.at or nil
  local size = window and window.size or nil
  if not at or not size then return nil end
  return geometric_max_tag_prefix .. table.concat({
    encode_integer(at.x), encode_integer(at.y), encode_integer(size.x), encode_integer(size.y),
    encode_integer(workspace.id), encode_hex(workspace_selector(workspace)),
  }, "-")
end

local function add_window_tag(window, tag)
  hl.dispatch(hl.dsp.window.tag({ tag = "+" .. tag, window = window }))
end

local function remove_window_tag(window, tag)
  hl.dispatch(hl.dsp.window.tag({ tag = "-" .. tag, window = window }))
end

local function side_geometry(side, monitor)
  local area = monitor_work_area(monitor)
  if not area then return nil end
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
  return {
    x = side == "left" and outer_x + border or outer_x + left_outer_width + middle_gap + border,
    y = outer_y + border,
    width = math.max(1, outer_half_width - border * 2),
    height = math.max(1, outer_height - border * 2),
  }
end

local function parse_side_intent_tag(tag)
  if type(tag) ~= "string" or tag:sub(1, #side_intent_tag_prefix) ~= side_intent_tag_prefix then return nil end
  local body = tag:sub(#side_intent_tag_prefix + 1)
  local side, x, y, width, height, monitor_x, monitor_y, workspace_id, source_hex =
    body:match("^([lr])%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([pn]%d+)%-([0-9a-f]+)$")
  if not side then return nil end
  local result = {
    raw = tag, side = side == "l" and "left" or "right",
    x = decode_integer(x), y = decode_integer(y), width = decode_integer(width), height = decode_integer(height),
    monitor_x = decode_integer(monitor_x), monitor_y = decode_integer(monitor_y),
    workspace_id = decode_integer(workspace_id), source = decode_hex(source_hex),
  }
  if not result.x or not result.y or not result.width or not result.height or result.width < 1 or result.height < 1 or
      not result.monitor_x or not result.monitor_y or not result.workspace_id or not result.source or result.source == "" then return nil end
  return result
end

local function window_side_intent(window)
  for _, tag in ipairs(window and window.tags or {}) do
    local metadata = parse_side_intent_tag(tag)
    if metadata then return metadata end
  end
  return nil
end

local function make_side_intent_tag(window, workspace, side, geometry)
  local monitor = window and window.monitor or nil
  if not monitor or not geometry then return nil end
  return side_intent_tag_prefix .. table.concat({
    side == "left" and "l" or "r",
    encode_integer(geometry.x), encode_integer(geometry.y), encode_integer(geometry.width), encode_integer(geometry.height),
    encode_integer(monitor.x), encode_integer(monitor.y), encode_integer(workspace.id), encode_hex(workspace_selector(workspace)),
  }, "-")
end

local function clear_side_intent(window)
  local metadata = window_side_intent(window)
  if metadata then remove_window_tag(window, metadata.raw) end
end

local function update_side_intent(window, workspace, side, geometry)
  local old = window_side_intent(window)
  local tag = make_side_intent_tag(window, workspace, side, geometry)
  if not tag or (old and old.raw == tag) then return end
  if old then remove_window_tag(window, old.raw) end
  add_window_tag(window, tag)
end

local function geometry_clamped_to_bounds(metadata, bounds)
  local width = math.max(1, math.min(metadata.width, bounds.width))
  local height = math.max(1, math.min(metadata.height, bounds.height))
  return {
    x = math.max(bounds.left, math.min(bounds.right - width, metadata.x)),
    y = math.max(bounds.top, math.min(bounds.bottom - height, metadata.y)),
    width = width,
    height = height,
  }
end

local function fit_window_to_floating_bounds(window)
  if not window or window.mapped ~= true or window.hidden == true or window.floating ~= true then return end
  if (tonumber(window.fullscreen) or 0) ~= 0 then return end

  local bounds = floating_window_bounds(window.monitor)
  local at = window.at
  local size = window.size
  if not bounds or not at or not size then return end

  local metadata = window_geometric_max_metadata(window)
  if metadata then
    if tonumber(size.x) ~= bounds.width or tonumber(size.y) ~= bounds.height then
      hl.dispatch(hl.dsp.window.resize({ x = bounds.width, y = bounds.height, window = window }))
    end
    local current_at = window.at or at
    if tonumber(current_at.x) ~= bounds.left or tonumber(current_at.y) ~= bounds.top then
      hl.dispatch(hl.dsp.window.move({ x = bounds.left, y = bounds.top, window = window }))
    end
    return
  end

  local side = window_side_intent(window)
  if side then
    local monitor_x = math.floor(tonumber(window.monitor and window.monitor.x) or 0)
    local monitor_y = math.floor(tonumber(window.monitor and window.monitor.y) or 0)
    local translated_x = side.x + monitor_x - side.monitor_x
    local translated_y = side.y + monitor_y - side.monitor_y
    local current_x, current_y = tonumber(at.x), tonumber(at.y)
    local same_size = tonumber(size.x) == side.width and tonumber(size.y) == side.height
    local still_managed = same_size and ((current_x == side.x and current_y == side.y) or
      (current_x == translated_x and current_y == translated_y))
    if not still_managed then
      remove_window_tag(window, side.raw)
    else
      local geometry = side_geometry(side.side, window.monitor)
      if not geometry then return end
      if tonumber(size.x) ~= geometry.width or tonumber(size.y) ~= geometry.height then
        hl.dispatch(hl.dsp.window.resize({ x = geometry.width, y = geometry.height, window = window }))
      end
      local current_at = window.at or at
      if tonumber(current_at.x) ~= geometry.x or tonumber(current_at.y) ~= geometry.y then
        hl.dispatch(hl.dsp.window.move({ x = geometry.x, y = geometry.y, window = window }))
      end
      update_side_intent(window, window.workspace, side.side, geometry)
      return
    end
  end

  local old_width = math.max(1, tonumber(size.x) or 1)
  local old_height = math.max(1, tonumber(size.y) or 1)
  local width = math.min(old_width, bounds.width)
  local height = math.min(old_height, bounds.height)
  if width ~= old_width or height ~= old_height then
    hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))
    local resized = window.size or {}
    width = math.max(1, tonumber(resized.x) or width)
    height = math.max(1, tonumber(resized.y) or height)
  end
  local x = math.max(bounds.left, math.min(bounds.right - width, tonumber(at.x) or bounds.left))
  local y = math.max(bounds.top, math.min(bounds.bottom - height, tonumber(at.y) or bounds.top))
  local current_at = window.at or at
  if x ~= tonumber(current_at.x) or y ~= tonumber(current_at.y) then
    hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
  end
end

local function restore_geometric_max(window)
  local metadata = window_geometric_max_metadata(window)
  local bounds = window and floating_window_bounds(window.monitor) or nil
  if not metadata or not bounds then return false end
  local side = window_side_intent(window)
  local geometry = side and side_geometry(side.side, window.monitor) or geometry_clamped_to_bounds(metadata, bounds)
  if not geometry then return false end
  hl.dispatch(hl.dsp.window.resize({ x = geometry.width, y = geometry.height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = geometry.x, y = geometry.y, window = window }))
  remove_window_tag(window, metadata.raw)
  if side then update_side_intent(window, window.workspace, side.side, geometry) end
  return true
end

local function maximize_geometric_window(window, workspace)
  if not window or window_geometric_max_metadata(window) or window.floating ~= true or (tonumber(window.fullscreen) or 0) ~= 0 then return false end
  local bounds = floating_window_bounds(window.monitor)
  local tag = make_geometric_max_tag(window, workspace)
  if not bounds or not tag then return false end
  add_window_tag(window, tag)
  hl.dispatch(hl.dsp.window.resize({ x = bounds.width, y = bounds.height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = bounds.left, y = bounds.top, window = window }))
  hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = window }))
  return true
end

local function clear_geometric_max_metadata_for_workspace(workspace)
  local selector = workspace_selector(workspace)
  for _, window in ipairs(hl.get_windows()) do
    local metadata = window_geometric_max_metadata(window)
    if metadata and metadata.source == selector then remove_window_tag(window, metadata.raw) end
    local side = window_side_intent(window)
    if side and side.source == selector then remove_window_tag(window, side.raw) end
  end
end

apply_workspace_mode = function(workspace)
  if not workspace_is_regular(workspace) then return end
  local enabled = workspace_float_enabled(workspace)
  if not enabled then clear_geometric_max_metadata_for_workspace(workspace) end
  for _, window in ipairs(workspace:get_windows()) do set_window_floating(window, enabled) end
end

local function defensively_fit_float_workspace(workspace)
  if not (workspace_is_regular(workspace) and workspace_float_enabled(workspace)) then return end

  for _, window in ipairs(workspace:get_windows()) do
    fit_window_to_floating_bounds(window)
  end
end

local function mode_aware_resize(dx, dy)
  local workspace = hl.get_active_workspace()
  if not (workspace_is_regular(workspace) and workspace_float_enabled(workspace)) then
    hl.dispatch(hl.dsp.window.resize({ x = dx, y = dy, relative = true }))
    return
  end

  local window = hl.get_active_window()
  if window_geometric_max_metadata(window) then restore_geometric_max(window) end
  clear_side_intent(window)
  local bounds = window and floating_window_bounds(window.monitor) or nil
  local at = window and window.at or nil
  local size = window and window.size or nil
  if not bounds or not at or not size then return end

  local old_width = math.max(1, tonumber(size.x) or 1)
  local old_height = math.max(1, tonumber(size.y) or 1)
  local width = math.max(1, math.min(bounds.width, old_width + dx))
  local height = math.max(1, math.min(bounds.height, old_height + dy))
  local x = math.max(bounds.left, math.min(bounds.right - width, (tonumber(at.x) or bounds.left) - (width - old_width) / 2))
  local y = math.max(bounds.top, math.min(bounds.bottom - height, (tonumber(at.y) or bounds.top) - (height - old_height) / 2))

  hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
end

local function snap_active_window(side)
  local window = hl.get_active_window()
  if window_geometric_max_metadata(window) then restore_geometric_max(window) end
  local workspace = hl.get_active_workspace()
  local geometry = window and side_geometry(side, window.monitor or hl.get_active_monitor()) or nil
  if not window or not geometry then return end

  set_window_floating(window, true)
  -- Resize first so Hyprland does not clamp the old, wider window before placing it.
  hl.dispatch(hl.dsp.window.resize({ x = geometry.width, y = geometry.height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = geometry.x, y = geometry.y, window = window }))
  update_side_intent(window, workspace, side, geometry)
end

local function mode_aware_direction(direction)
  local workspace = hl.get_active_workspace()
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    if direction == "l" or direction == "r" then
      snap_active_window(direction == "l" and "left" or "right")
    elseif direction == "u" then
      maximize_geometric_window(hl.get_active_window(), workspace)
    else
      restore_geometric_max(hl.get_active_window())
    end
    return
  end

  hl.dispatch(hl.dsp.focus({ direction = direction }))
end

local function mode_aware_fullscreen()
  local workspace = hl.get_active_workspace()
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    hl.dispatch(hl.dsp.window.fullscreen_state({
      internal = 2,
      client = 0,
      action = "toggle",
    }))
    return
  end

  hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen" }))
end

local function workspace_super_tab(next_workspace)
  -- m±1 wraps the existing regular workspaces on the compositor's focused
  -- monitor, excluding special workspaces without creating missing IDs.
  hl.dispatch(hl.dsp.focus({ workspace = next_workspace and "m+1" or "m-1" }))
end

load_float_workspaces()

-- Process start ticks survive focus/Z-order changes and let the shell reconstruct
-- launch order after its own restart without a separate ordering database.
for _, window in ipairs(hl.get_windows()) do
  tag_window_launch_order(window)
end

-- Re-apply persisted floating modes and repair geometry if this module loads
-- after a monitor migration already happened.
for _, workspace in ipairs(hl.get_workspaces()) do
  if workspace_float_enabled(workspace) then
    apply_workspace_mode(workspace)
    defensively_fit_float_workspace(workspace)
  end
end

hl.on("window.open", function(window)
  tag_window_launch_order(window)
  local workspace = window and window.workspace or nil
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then
    set_window_floating(window, true)
  end
end)

hl.on("window.move_to_workspace", function(window, workspace)
  local metadata = window_geometric_max_metadata(window)
  local side = window_side_intent(window)
  local placements = {}
  if metadata then table.insert(placements, metadata) end
  if side then table.insert(placements, side) end
  for _, placement in ipairs(placements) do
    if placement then
      local expected_special = "special:omarchy-minimized-" .. tostring(placement.workspace_id)
      local returning_to_source = workspace_is_regular(workspace) and workspace_selector(workspace) == placement.source and workspace_float_enabled(workspace)
      if not (workspace and workspace.special == true and workspace.name == expected_special) and not returning_to_source then
        remove_window_tag(window, placement.raw)
        if placement == metadata then metadata = nil else side = nil end
      end
    end
  end
  if workspace_is_regular(workspace) then
    set_window_floating(window, workspace_float_enabled(workspace))
  elseif metadata or side then
    set_window_floating(window, true)
  end
end)

-- Hyprland emits this only after the workspace monitor, every member window's
-- monitor, floating position translation, and native fullscreen reflow finish.
hl.on("workspace.move_to_monitor", function(workspace, _monitor)
  defensively_fit_float_workspace(workspace)
end)

-- Hyprland emits this after monitor layout changes. It carries no monitor, so
-- inspect every plugin-enabled regular Float workspace defensively.
hl.on("monitor.layout_changed", function()
  for _, workspace in ipairs(hl.get_workspaces()) do
    defensively_fit_float_workspace(workspace)
  end
end)

local resize_bindings = {
  { "SUPER + code:20", "Expand window left", -100, 0 },
  { "SUPER + code:21", "Shrink window left", 100, 0 },
  { "SUPER + SHIFT + code:20", "Shrink window up", 0, -100 },
  { "SUPER + SHIFT + code:21", "Expand window down", 0, 100 },
  { "SUPER + ALT + code:20", "Expand window left a little", -25, 0 },
  { "SUPER + ALT + code:21", "Shrink window left a little", 25, 0 },
  { "SUPER + SHIFT + ALT + code:20", "Shrink window up a little", 0, -25 },
  { "SUPER + SHIFT + ALT + code:21", "Expand window down a little", 0, 25 },
  { "SUPER + CTRL + code:20", "Expand window left a lot", -300, 0 },
  { "SUPER + CTRL + code:21", "Shrink window left a lot", 300, 0 },
  { "SUPER + CTRL + SHIFT + code:20", "Shrink window up a lot", 0, -300 },
  { "SUPER + CTRL + SHIFT + code:21", "Expand window down a lot", 0, 300 },
}
for _, binding in ipairs(resize_bindings) do
  local keys, description, dx, dy = binding[1], binding[2], binding[3], binding[4]
  hl.unbind(keys)
  o.bind(keys, description, function() mode_aware_resize(dx, dy) end)
end

hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")
hl.unbind("SUPER + F")
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("ALT + ALT_L")
hl.unbind("ALT + ALT_R")
o.bind("SUPER + LEFT", "Focus left / snap left in floating mode", function() mode_aware_direction("l") end)
o.bind("SUPER + RIGHT", "Focus right / snap right in floating mode", function() mode_aware_direction("r") end)
o.bind("SUPER + UP", "Focus up / maximize in floating mode", function() mode_aware_direction("u") end)
o.bind("SUPER + DOWN", "Focus down / restore in floating mode", function() mode_aware_direction("d") end)
o.bind("SUPER + F", "Full screen", mode_aware_fullscreen)
o.bind("SUPER + TAB", "Next workspace", function() workspace_super_tab(true) end)
o.bind("SUPER + SHIFT + TAB", "Previous workspace", function() workspace_super_tab(false) end)
o.bind("ALT + TAB", "Select next application", hl.dsp.global("fatlj.float-panel:alt-tab-next"))
o.bind("ALT + SHIFT + TAB", "Select previous application", hl.dsp.global("fatlj.float-panel:alt-tab-previous"))
-- Keep modifier-release binds transparent so an intervening ALT+TAB chord does
-- not shadow them before Alt is released.
o.bind("ALT + ALT_L", "Activate selected application", hl.dsp.global("fatlj.float-panel:alt-release"), { release = true, transparent = true })
o.bind("ALT + ALT_R", "Activate selected application", hl.dsp.global("fatlj.float-panel:alt-release"), { release = true, transparent = true })
o.bind("SUPER + SHIFT + T", "Toggle workspace floating mode", toggle_active_workspace_mode)
o.bind("SUPER + M", "Minimize window", minimize_active_window)
