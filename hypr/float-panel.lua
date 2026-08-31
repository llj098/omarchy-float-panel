-- Per-workspace floating mode and minimize bindings for Omarchy/Hyprland Lua.
-- Load this file after require("default.hypr.omarchy") so the `o` helpers exist.

local home = os.getenv("HOME") or ""
local state_path = home .. "/.local/state/omarchy/float-panel-workspaces"
local geometry_state_path = home .. "/.local/state/omarchy/float-panel-geometries"
local debug_flag_path = home .. "/.local/state/omarchy/float-panel-debug"
local debug_log_path = rawget(_G, "FLOAT_PANEL_DEBUG_LOG_PATH") or "/tmp/float-panel-debug.log"
local debug_log_limit = 5 * 1024 * 1024
local native_bridge_path = home .. "/.config/omarchy/plugins/fatlj.float-panel/native/build/float-panel-native.so"
local float_workspaces = {}

-- The read-only native bridge exposes compositor-owned relationships, window
-- types, and placement flags without patching Hyprland or launching an external
-- process. On the first load Hyprland loads
-- the .so after evaluating the config, then reloads the Lua config with the
-- registered callback available.
do
  local bridge = io.open(native_bridge_path, "r")
  if bridge then
    bridge:close()
    if type(hl.plugin) == "table" and type(hl.plugin.load) == "function" then
      hl.plugin.load(native_bridge_path)
    end
  end
end

local native_float_panel = type(hl.plugin) == "table" and type(hl.plugin.float_panel) == "table" and
  hl.plugin.float_panel or nil
local native_window_semantics = native_float_panel and type(native_float_panel.window_semantics) == "function" and
  native_float_panel.window_semantics or nil

local function read_native_window_semantics(window)
  local address = tostring(window and window.address or "")
  if not native_window_semantics or address == "" then return nil, "unavailable" end
  local ok, result = pcall(native_window_semantics, address)
  if not ok then return nil, "error" end
  if type(result) ~= "table" or result.found ~= true then return nil, "not-found" end
  return result, "found"
end

local function debug_flag_enabled()
  local file = io.open(debug_flag_path, "r")
  if not file then return false end
  file:close()
  return true
end

local debug_enabled = debug_flag_enabled()

local function debug_log(event, fields)
  if not debug_enabled then return end

  local current = io.open(debug_log_path, "r")
  local size = current and current:seek("end") or 0
  if current then current:close() end
  if size >= debug_log_limit then
    os.remove(debug_log_path .. ".1")
    os.rename(debug_log_path, debug_log_path .. ".1")
  end

  local parts = { os.date("!%Y-%m-%dT%H:%M:%SZ"), tostring(event) }
  local keys = {}
  for key in pairs(fields or {}) do table.insert(keys, key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = tostring(fields[key]):gsub("[%s\r\n]+", "_")
    table.insert(parts, tostring(key) .. "=" .. value)
  end

  local file = io.open(debug_log_path, "a")
  if not file then return end
  file:write(table.concat(parts, " "), "\n")
  file:close()
end

-- Negative float gaps inherit general.gaps_out in Hyprland 0.56.2, keeping
-- native floating maximization inside the same gapped workspace work area.
hl.config({ general = { float_gaps = -1 } })

hl.window_rule({
  name = "fatlj-float-panel-ignore-min-size",
  min_size = { 1, 1 },
})

local order_tag_prefix = "float-panel-order-"
local geometric_max_tag_prefix = "float-panel-geometric-max-v1-"
local side_intent_tag_prefix = "float-panel-side-v1-"
local geometry_slot_tag_prefix = "float-panel-geometry-slot-v1-"
local geometry_records = {}
local geometry_claims = {}
local geometry_window_claims = {}
local reflow_anchors = {}

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

local function safe_ipairs(values)
  if type(values) ~= "table" then values = {} end

  local index = 0
  return function()
    index = index + 1
    local value = rawget(values, index)
    if value == nil then return nil end
    return index, value
  end
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
local persist_window_placement
local persist_workspace_placements

local function active_window_context()
  local window = hl.get_active_window()
  if window then return window, window.workspace, window.monitor end

  local workspace = hl.get_active_workspace()
  return nil, workspace, workspace and workspace.monitor or hl.get_active_monitor()
end

local function select_monitor(monitor)
  local focused_monitor = hl.get_active_monitor()
  if monitor and monitor ~= focused_monitor then
    hl.dispatch(hl.dsp.focus({ monitor = monitor }))
  end
end

local function debug_window_action(event, window, workspace, fields)
  if not debug_enabled then return end
  local focused_workspace = hl.get_active_workspace()
  local focused_monitor = hl.get_active_monitor()
  fields = fields or {}
  fields.window = window and window.address or "nil"
  fields.window_workspace = workspace and workspace.name or "nil"
  fields.window_monitor = window and window.monitor and window.monitor.name or "nil"
  fields.focused_workspace = focused_workspace and focused_workspace.name or "nil"
  fields.focused_monitor = focused_monitor and focused_monitor.name or "nil"
  debug_log(event, fields)
end

local function debug_window_geometry(event, window, workspace, fields)
  if not debug_enabled then return end
  fields = fields or {}
  local at = window and window.at or nil
  local size = window and window.size or nil
  fields.class = window and window.class or "nil"
  fields.initial_class = window and window.initial_class or "nil"
  fields.x = at and at.x or "nil"
  fields.y = at and at.y or "nil"
  fields.width = size and size.x or "nil"
  fields.height = size and size.y or "nil"
  fields.floating = window and window.floating == true or false
  fields.xwayland = window and window.xwayland == true or false
  debug_window_action(event, window, workspace, fields)
end

local function toggle_workspace_mode(workspace, event)
  if not workspace_is_regular(workspace) then return end

  local key = workspace_key(workspace)
  local enabled = not workspace_float_enabled(workspace)
  debug_window_action(event or "ui.toggle_mode", hl.get_active_window(), workspace, { enabled = enabled })
  if not enabled and persist_workspace_placements then persist_workspace_placements(workspace) end
  float_workspaces[key] = enabled or nil
  save_float_workspaces()
  apply_workspace_mode(workspace)

  local mode = enabled and "floating" or "tiling"
  hl.exec_cmd("omarchy-notification-send " .. o.shell_quote("Workspace " .. key .. " set to " .. mode))
end

local function toggle_active_workspace_mode()
  local _, workspace = active_window_context()
  if not workspace_is_regular(workspace) then
    workspace = hl.get_active_workspace()
  end
  toggle_workspace_mode(workspace, "bind.toggle_mode")
end

fatlj_float_panel = fatlj_float_panel or {}
fatlj_float_panel.toggle_workspace_mode = function(workspace_selector)
  toggle_workspace_mode(hl.get_workspace(workspace_selector), "ui.toggle_mode")
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
  -- Match Hyprland's CMonitor::m_size calculation: transform, divide by
  -- scale, then round to the nearest logical pixel before reservations.
  local logical_width = math.floor(pixel_width / scale + 0.5)
  local logical_height = math.floor(pixel_height / scale + 0.5)
  local width = math.max(1, logical_width - left - right)
  local height = math.max(1, logical_height - top - bottom)

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

local function make_side_intent_tag(window, workspace, side, geometry, target_monitor)
  local monitor = target_monitor or (window and window.monitor or nil)
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

local function update_side_intent(window, workspace, side, geometry, target_monitor)
  local old = window_side_intent(window)
  local at, size = window and window.at or nil, window and window.size or nil
  local observed = at and size and {
    x = tonumber(at.x), y = tonumber(at.y), width = tonumber(size.x), height = tonumber(size.y),
  } or geometry
  local tag = make_side_intent_tag(window, workspace, side, observed, target_monitor)
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

local function nearest_integer(value)
  value = tonumber(value) or 0
  return value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
end

local function geometry_window_token(window)
  if not window then return nil end
  local address = tostring(window.address or "")
  if address ~= "" then return address end
  if window.stable_id ~= nil then return "stable:" .. tostring(window.stable_id) end
  return tostring(window)
end

local function copy_bounds(bounds)
  return bounds and {
    left = bounds.left, top = bounds.top, right = bounds.right, bottom = bounds.bottom,
    width = bounds.width, height = bounds.height,
  } or nil
end

local function window_box(window)
  local at, size = window and window.at or nil, window and window.size or nil
  if not at or not size then return nil end
  return {
    x = tonumber(at.x), y = tonumber(at.y),
    width = tonumber(size.x), height = tonumber(size.y),
  }
end

local function boxes_equal(a, b)
  return a and b and a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function bounds_equal(a, b)
  return a and b and a.left == b.left and a.top == b.top and a.width == b.width and a.height == b.height
end

local function monitor_snapshot(monitor)
  return monitor and {
    name = tostring(monitor.name or ""),
    x = tonumber(monitor.x) or 0,
    y = tonumber(monitor.y) or 0,
  } or nil
end

-- Original/source/placement fields stay immutable between explicit rebases;
-- topology reflow updates only the observed last-applied state.
local function rebase_reflow_anchor(window, monitor, bounds, source_workspace)
  local token = geometry_window_token(window)
  local box = window_box(window)
  bounds = bounds or floating_window_bounds(monitor or (window and window.monitor or nil))
  monitor = monitor or (window and window.monitor or nil)
  source_workspace = source_workspace or (window and window.workspace or nil)
  if not token or not box or not bounds or box.width < 1 or box.height < 1 then return nil end

  local travel_x = math.max(0, bounds.width - box.width)
  local travel_y = math.max(0, bounds.height - box.height)
  local function ratio(offset, travel)
    if travel <= 0 then return 0 end
    return math.max(0, math.min(1, offset / travel))
  end
  local anchor = {
    original_box = { x = box.x, y = box.y, width = box.width, height = box.height },
    source_bounds = copy_bounds(bounds),
    source_monitor = monitor_snapshot(monitor),
    source_workspace = workspace_is_regular(source_workspace) and workspace_selector(source_workspace) or nil,
    placement = {
      x = ratio(box.x - bounds.left, travel_x),
      y = ratio(box.y - bounds.top, travel_y),
      width = box.width / bounds.width,
      height = box.height / bounds.height,
    },
    last_applied = window_box(window) or { x = box.x, y = box.y, width = box.width, height = box.height },
    last_bounds = copy_bounds(bounds),
    last_monitor = monitor_snapshot(monitor),
  }
  reflow_anchors[token] = anchor
  return anchor
end

local function clear_reflow_anchor(window)
  local token = geometry_window_token(window)
  if token then reflow_anchors[token] = nil end
end

local function reflow_anchor(window)
  local token = geometry_window_token(window)
  return token and reflow_anchors[token] or nil
end

local function format_bounds(bounds)
  if not bounds then return "nil" end
  return table.concat({ bounds.left, bounds.top, bounds.width, bounds.height }, ",")
end

local function format_box(box)
  if not box then return "nil" end
  return table.concat({ box.x, box.y, box.width, box.height }, ",")
end

local function debug_reflow(stage, trigger, window, workspace, bounds, anchor, fields)
  if not debug_enabled or not trigger then return end
  fields = fields or {}
  fields.trigger = trigger
  fields.source_bounds = format_bounds(anchor and anchor.source_bounds or bounds)
  fields.target_bounds = format_bounds(bounds)
  fields.anchor = format_box(anchor and anchor.original_box or nil)
  fields.anchor_monitor = anchor and anchor.source_monitor and
    table.concat({ anchor.source_monitor.name, anchor.source_monitor.x, anchor.source_monitor.y }, ",") or "nil"
  fields.placement_ratios = anchor and table.concat({
    string.format("%.6f", anchor.placement.x), string.format("%.6f", anchor.placement.y),
    string.format("%.6f", anchor.placement.width), string.format("%.6f", anchor.placement.height),
  }, ",") or "nil"
  fields.last_applied = format_box(anchor and anchor.last_applied or nil)
  fields.actual_geometry = format_box(window_box(window))
  debug_window_action("reflow.window_" .. stage, window, workspace, fields)
end

local function side_intent_still_managed(window, side)
  local at, size, monitor = window and window.at or nil, window and window.size or nil, window and window.monitor or nil
  if not side or not at or not size or not monitor then return false end
  local monitor_x = math.floor(tonumber(monitor.x) or 0)
  local monitor_y = math.floor(tonumber(monitor.y) or 0)
  local translated_x = side.x + monitor_x - side.monitor_x
  local translated_y = side.y + monitor_y - side.monitor_y
  local current_x, current_y = tonumber(at.x), tonumber(at.y)
  return tonumber(size.x) == side.width and tonumber(size.y) == side.height and
    ((current_x == side.x and current_y == side.y) or (current_x == translated_x and current_y == translated_y))
end

local function fit_window_to_floating_bounds(window, target_monitor, source_workspace, trust_intent, trigger, preserve_anchor)
  if not window or window.mapped ~= true or window.hidden == true or window.floating ~= true then return end
  if (tonumber(window.fullscreen) or 0) ~= 0 then return end

  target_monitor = target_monitor or window.monitor
  source_workspace = source_workspace or window.workspace
  local bounds = floating_window_bounds(target_monitor)
  local at = window.at
  local size = window.size
  if not bounds or not at or not size then return end

  local anchor = reflow_anchor(window)
  debug_reflow("before", trigger, window, source_workspace, bounds, anchor, {
    decision = "pending", requested_resize = "none", requested_move = "none",
  })

  local function finish(decision, requested_resize, requested_move)
    anchor = reflow_anchor(window)
    debug_reflow("decision", trigger, window, source_workspace, bounds, anchor, {
      decision = decision,
      requested_resize = requested_resize or "none",
      requested_move = requested_move or "none",
    })
    if anchor then
      anchor.last_applied = window_box(window)
      anchor.last_bounds = copy_bounds(bounds)
      anchor.last_monitor = monitor_snapshot(target_monitor)
    end
    debug_reflow("after", trigger, window, source_workspace, bounds, anchor, {
      decision = decision,
      requested_resize = requested_resize or "none",
      requested_move = requested_move or "none",
    })
  end

  local metadata = window_geometric_max_metadata(window)
  if metadata then
    local resize_request, move_request
    if tonumber(size.x) ~= bounds.width or tonumber(size.y) ~= bounds.height then
      resize_request = tostring(bounds.width) .. "," .. tostring(bounds.height)
      hl.dispatch(hl.dsp.window.resize({ x = bounds.width, y = bounds.height, window = window }))
    end
    local current_at = window.at or at
    if tonumber(current_at.x) ~= bounds.left or tonumber(current_at.y) ~= bounds.top then
      move_request = tostring(bounds.left) .. "," .. tostring(bounds.top)
      hl.dispatch(hl.dsp.window.move({ x = bounds.left, y = bounds.top, window = window }))
    end
    finish("managed-max", resize_request, move_request)
    return
  end

  local side = window_side_intent(window)
  if side then
    if not trust_intent and not side_intent_still_managed(window, side) then
      remove_window_tag(window, side.raw)
      anchor = rebase_reflow_anchor(window, target_monitor, bounds, source_workspace)
    else
      local geometry = side_geometry(side.side, target_monitor)
      if not geometry then return end
      local resize_request, move_request
      if tonumber(size.x) ~= geometry.width or tonumber(size.y) ~= geometry.height then
        resize_request = tostring(geometry.width) .. "," .. tostring(geometry.height)
        hl.dispatch(hl.dsp.window.resize({ x = geometry.width, y = geometry.height, window = window }))
      end
      local current_at = window.at or at
      if tonumber(current_at.x) ~= geometry.x or tonumber(current_at.y) ~= geometry.y then
        move_request = tostring(geometry.x) .. "," .. tostring(geometry.y)
        hl.dispatch(hl.dsp.window.move({ x = geometry.x, y = geometry.y, window = window }))
      end
      update_side_intent(window, source_workspace, side.side, geometry, target_monitor)
      finish("managed-" .. side.side, resize_request, move_request)
      return
    end
  end

  local before = window_box(window)
  anchor = anchor or rebase_reflow_anchor(window, target_monitor, bounds, source_workspace)
  if trigger and anchor and not preserve_anchor and not boxes_equal(before, anchor.last_applied) and
      (bounds_equal(bounds, anchor.last_bounds) or before.width ~= anchor.last_applied.width or before.height ~= anchor.last_applied.height) then
    anchor = rebase_reflow_anchor(window, target_monitor, bounds, source_workspace)
  end
  if not anchor then return end

  local width, height, x, y
  if bounds_equal(bounds, anchor.source_bounds) then
    width, height = anchor.original_box.width, anchor.original_box.height
    x, y = anchor.original_box.x, anchor.original_box.y
  elseif trigger then
    width = nearest_integer(anchor.placement.width * bounds.width)
    height = nearest_integer(anchor.placement.height * bounds.height)
    local travel_x = math.max(0, bounds.width - width)
    local travel_y = math.max(0, bounds.height - height)
    x = bounds.left + nearest_integer(anchor.placement.x * travel_x)
    y = bounds.top + nearest_integer(anchor.placement.y * travel_y)
  else
    width, height = before.width, before.height
    x, y = before.x, before.y
  end

  width = math.max(1, math.min(width, bounds.width))
  height = math.max(1, math.min(height, bounds.height))
  local resize_request, move_request
  if width ~= before.width or height ~= before.height then
    resize_request = tostring(width) .. "," .. tostring(height)
    hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))
    local resized = window.size or {}
    width = math.max(1, math.min(tonumber(resized.x) or width, bounds.width))
    height = math.max(1, math.min(tonumber(resized.y) or height, bounds.height))
    if trigger and not bounds_equal(bounds, anchor.source_bounds) then
      x = bounds.left + nearest_integer(anchor.placement.x * math.max(0, bounds.width - width))
      y = bounds.top + nearest_integer(anchor.placement.y * math.max(0, bounds.height - height))
    end
  end
  x = math.max(bounds.left, math.min(bounds.right - width, x))
  y = math.max(bounds.top, math.min(bounds.bottom - height, y))
  local current_at = window.at or at
  if x ~= tonumber(current_at.x) or y ~= tonumber(current_at.y) then
    move_request = tostring(x) .. "," .. tostring(y)
    hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
  end
  finish(trigger and "free-anchor" or "free-fit", resize_request, move_request)
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
  rebase_reflow_anchor(window)
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
  rebase_reflow_anchor(window)
  return true
end

local function clear_geometric_max_metadata_for_workspace(workspace)
  local selector = workspace_selector(workspace)
  for _, window in safe_ipairs(hl.get_windows()) do
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
  for _, window in safe_ipairs(workspace:get_windows()) do
    set_window_floating(window, enabled)
    if enabled then rebase_reflow_anchor(window) else clear_reflow_anchor(window) end
  end
  if not enabled then
    local minimized_name = "special:omarchy-minimized-" .. tostring(workspace.id)
    for _, window in safe_ipairs(hl.get_windows()) do
      if window.workspace and window.workspace.name == minimized_name then clear_reflow_anchor(window) end
    end
  end
end

local function adopt_existing_side_intent(window, workspace)
  if not window or window_side_intent(window) or window_geometric_max_metadata(window) then return end
  if window.mapped ~= true or window.hidden == true or window.floating ~= true or (tonumber(window.fullscreen) or 0) ~= 0 then return end
  local at, size = window.at, window.size
  if not at or not size then return end
  for _, side in ipairs({ "left", "right" }) do
    local expected = side_geometry(side, window.monitor)
    -- Some clients quantize configure sizes; only a 2px increment delta is
    -- accepted so unrelated near-half/free windows are never adopted.
    if expected and tonumber(at.x) == expected.x and tonumber(at.y) == expected.y and
        math.abs((tonumber(size.x) or 0) - expected.width) <= 2 and
        math.abs((tonumber(size.y) or 0) - expected.height) <= 2 then
      update_side_intent(window, workspace, side, expected)
      return
    end
  end
end

local function defensively_fit_float_workspace(workspace, trigger)
  if not (workspace_is_regular(workspace) and workspace_float_enabled(workspace)) then return end

  -- Pinned windows intentionally use the same monitor-bound fitting path.
  -- Pinning changes workspace visibility, not the monitor work-area limits.
  for _, window in safe_ipairs(workspace:get_windows()) do
    fit_window_to_floating_bounds(window, nil, workspace, false, trigger, false)
  end

  -- Minimized windows belong to a special workspace and are absent from
  -- workspace:get_windows(). Reflow them against their source workspace now,
  -- while its post-migration monitor is authoritative. Their source anchor is
  -- never rebased from special-workspace translation or shutdown geometry.
  local minimized_name = "special:omarchy-minimized-" .. tostring(workspace.id)
  for _, window in safe_ipairs(hl.get_windows()) do
    if window.workspace and window.workspace.special == true and window.workspace.name == minimized_name then
      fit_window_to_floating_bounds(window, workspace.monitor, workspace, true, trigger, true)
    end
  end
end

local function rebase_workspace_reflow_anchors(workspace)
  if not (workspace_is_regular(workspace) and workspace_float_enabled(workspace)) then return end
  for _, window in safe_ipairs(workspace:get_windows()) do rebase_reflow_anchor(window) end
  local minimized_name = "special:omarchy-minimized-" .. tostring(workspace.id)
  for _, window in safe_ipairs(hl.get_windows()) do
    if window.workspace and window.workspace.special == true and window.workspace.name == minimized_name then
      rebase_reflow_anchor(window, workspace.monitor, nil, workspace)
    end
  end
end

local function mode_aware_resize(dx, dy)
  local window, workspace = active_window_context()
  if not window then return end
  local float_mode = workspace_is_regular(workspace) and workspace_float_enabled(workspace)
  debug_window_action("bind.resize", window, workspace, { dx = dx, dy = dy, float = float_mode })
  if not float_mode then
    hl.dispatch(hl.dsp.window.resize({ x = dx, y = dy, relative = true, window = window }))
    return
  end

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
  rebase_reflow_anchor(window)
end

local function snap_active_window(window, workspace, side)
  if not window then return end
  if window_geometric_max_metadata(window) then restore_geometric_max(window) end
  local geometry = side_geometry(side, window.monitor)
  if not geometry then return end

  set_window_floating(window, true)
  -- Resize first so Hyprland does not clamp the old, wider window before placing it.
  hl.dispatch(hl.dsp.window.resize({ x = geometry.width, y = geometry.height, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = geometry.x, y = geometry.y, window = window }))
  update_side_intent(window, workspace, side, geometry)
  rebase_reflow_anchor(window)
end

local function mode_aware_direction(direction)
  local window, workspace = active_window_context()
  local float_mode = workspace_is_regular(workspace) and workspace_float_enabled(workspace)
  debug_window_action("bind.direction", window, workspace, { direction = direction, float = float_mode })
  if float_mode then
    if direction == "l" or direction == "r" then
      snap_active_window(window, workspace, direction == "l" and "left" or "right")
    elseif direction == "u" then
      maximize_geometric_window(window, workspace)
    else
      restore_geometric_max(window)
    end
    return
  end

  select_monitor(window and window.monitor or nil)
  hl.dispatch(hl.dsp.focus({ direction = direction }))
end

local function mode_aware_fullscreen()
  local window, workspace = active_window_context()
  if not window then return end
  local float_mode = workspace_is_regular(workspace) and workspace_float_enabled(workspace)
  debug_window_action("bind.fullscreen", window, workspace, { float = float_mode })
  if float_mode then
    if persist_window_placement then persist_window_placement(window, workspace) end
    hl.dispatch(hl.dsp.window.fullscreen_state({
      internal = 2,
      client = 0,
      action = "toggle",
      window = window,
    }))
    return
  end

  hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen", window = window }))
end

local function workspace_super_tab(next_workspace)
  local window = hl.get_active_window()
  local target_monitor = window and window.monitor or hl.get_active_monitor()
  debug_window_action("bind.workspace_cycle", window, window and window.workspace or hl.get_active_workspace(), {
    direction = next_workspace and "next" or "previous",
    target_monitor = target_monitor and target_monitor.name or "nil",
  })
  select_monitor(target_monitor)

  -- m±1 wraps existing regular workspaces on the selected monitor, excludes
  -- special workspaces, and does not create missing workspace IDs.
  hl.dispatch(hl.dsp.focus({ workspace = next_workspace and "m+1" or "m-1" }))
end

local valid_geometry_intents = {
  free = true, left = true, right = true,
  ["max-free"] = true, ["max-left"] = true, ["max-right"] = true,
}

local function decode_optional_hex(value)
  if value == "" then return "" end
  return decode_hex(value)
end

local function placement_record_key(workspace_name, class, role)
  return workspace_name .. "\0" .. class .. "\0" .. role
end

local function placement_identity(window, workspace)
  if not window or not workspace_is_regular(workspace) then return nil end
  local class = tostring(window.initial_class or "")
  if class == "" then class = tostring(window.class or "") end
  if class == "" then return nil end
  local role = type(window.xdg_tag) == "string" and window.xdg_tag or ""
  local workspace_name = workspace_selector(workspace)
  if workspace_name == "" then return nil end
  return {
    workspace = workspace_name,
    class = class,
    role = role,
    key = placement_record_key(workspace_name, class, role),
  }
end

local function make_geometry_slot_tag(identity, slot)
  return geometry_slot_tag_prefix .. table.concat({
    encode_hex(identity.workspace), encode_hex(identity.class), encode_hex(identity.role), tostring(slot),
  }, "-")
end

local function parse_geometry_slot_tag(tag)
  if type(tag) ~= "string" or tag:sub(1, #geometry_slot_tag_prefix) ~= geometry_slot_tag_prefix then return nil end
  local workspace_hex, class_hex, role_hex, slot_text = tag:sub(#geometry_slot_tag_prefix + 1):match(
    "^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]*)%-(%d+)$")
  if not workspace_hex then return nil end
  local workspace_name = decode_hex(workspace_hex)
  local class = decode_hex(class_hex)
  local role = decode_optional_hex(role_hex)
  local slot = tonumber(slot_text)
  if not workspace_name or not class or class == "" or role == nil or not slot or slot < 1 then return nil end
  return {
    raw = tag,
    workspace = workspace_name,
    class = class,
    role = role,
    slot = math.floor(slot),
    key = placement_record_key(workspace_name, class, role),
  }
end

local geometry_window_semantics = {}

-- The native bridge reports compositor facts only. Keep persistence policy in
-- Lua so policy changes do not require rebuilding an ABI-coupled plugin.
local function window_persistence_policy(semantics)
  if semantics.override_redirect == true then return false, "override-redirect" end
  if semantics.transient == true then return false, "transient" end
  if semantics.has_parent == true then return false, "has-parent" end

  local window_type = tostring(semantics.window_type or "unknown")
  if semantics.xwayland == false then return true, "independent-" .. window_type end
  if semantics.xwayland == true and (window_type == "normal" or window_type == "dialog") then
    return true, "independent-" .. window_type
  end
  return false, "window-type-" .. window_type
end

local function window_persistence_semantics(window)
  local token = geometry_window_token(window)
  if not token then return false, "missing-window-token", nil end
  local cached = geometry_window_semantics[token]
  if cached then return cached.eligible, cached.reason, cached.semantics end

  local eligible, reason, semantics = false, "native-bridge-unavailable", nil
  local result, status = read_native_window_semantics(window)
  if status == "error" then
    reason = "native-bridge-error"
  elseif status == "not-found" then
    reason = "native-window-not-found"
  elseif result then
    semantics = result
    eligible, reason = window_persistence_policy(semantics)
  end

  geometry_window_semantics[token] = { eligible = eligible, reason = reason, semantics = semantics }
  return eligible, reason, semantics
end

local function forget_window_persistence_semantics(window)
  local token = geometry_window_token(window)
  if token then geometry_window_semantics[token] = nil end
end

local function release_geometry_slot(window, remove_tag)
  local token = geometry_window_token(window)
  local claim = token and geometry_window_claims[token] or nil
  if claim then
    local bucket = geometry_claims[claim.key]
    if bucket and bucket[claim.slot] == token then bucket[claim.slot] = nil end
    geometry_window_claims[token] = nil
  end
  if remove_tag then
    local tags = {}
    for _, tag in ipairs(window and window.tags or {}) do
      if parse_geometry_slot_tag(tag) then table.insert(tags, tag) end
    end
    for _, tag in ipairs(tags) do remove_window_tag(window, tag) end
  end
end

local function claim_geometry_slot(window, workspace)
  local token = geometry_window_token(window)
  if not token then return nil, nil end
  local eligible, reason = window_persistence_semantics(window)
  if not eligible then
    if reason ~= "native-bridge-unavailable" and reason ~= "native-bridge-error" and reason ~= "native-window-not-found" then
      release_geometry_slot(window, true)
    end
    return nil, nil
  end
  local identity = placement_identity(window, workspace)
  if not identity then return nil, nil end

  local existing = geometry_window_claims[token]
  if existing and existing.key == identity.key then
    local records = geometry_records[identity.key] or {}
    return identity, existing.slot, records[existing.slot]
  elseif existing then
    release_geometry_slot(window, true)
  end

  local claims = geometry_claims[identity.key]
  if not claims then
    claims = {}
    geometry_claims[identity.key] = claims
  end
  local records = geometry_records[identity.key] or {}

  for _, tag in ipairs(window.tags or {}) do
    local metadata = parse_geometry_slot_tag(tag)
    if metadata and metadata.key == identity.key and (not claims[metadata.slot] or claims[metadata.slot] == token) then
      claims[metadata.slot] = token
      geometry_window_claims[token] = { key = identity.key, slot = metadata.slot }
      return identity, metadata.slot, records[metadata.slot]
    end
  end

  release_geometry_slot(window, true)
  claims = geometry_claims[identity.key] or {}
  geometry_claims[identity.key] = claims

  local slots = {}
  for slot in pairs(records) do table.insert(slots, slot) end
  table.sort(slots)
  local slot
  for _, candidate in ipairs(slots) do
    if not claims[candidate] then
      slot = candidate
      break
    end
  end
  if not slot then
    slot = 1
    while claims[slot] or records[slot] do slot = slot + 1 end
  end

  claims[slot] = token
  geometry_window_claims[token] = { key = identity.key, slot = slot }
  add_window_tag(window, make_geometry_slot_tag(identity, slot))
  return identity, slot, records[slot]
end

local function split_tabs(line)
  local fields = {}
  for field in (line .. "\t"):gmatch("(.-)\t") do table.insert(fields, field) end
  return fields
end

local function parse_state_integer(value)
  if type(value) ~= "string" or not value:match("^-?%d+$") then return nil end
  return tonumber(value)
end

local function load_geometry_records()
  local file = io.open(geometry_state_path, "r")
  if not file then return end
  for line in file:lines() do
    local fields = split_tabs(line)
    if #fields == 14 and fields[1] == "v1" then
      local workspace_name = decode_hex(fields[2])
      local class = decode_hex(fields[3])
      local role = decode_optional_hex(fields[4])
      local slot = parse_state_integer(fields[5])
      local intent = fields[6]
      local x, y = parse_state_integer(fields[7]), parse_state_integer(fields[8])
      local width, height = parse_state_integer(fields[9]), parse_state_integer(fields[10])
      local bounds_left, bounds_top = parse_state_integer(fields[11]), parse_state_integer(fields[12])
      local bounds_width, bounds_height = parse_state_integer(fields[13]), parse_state_integer(fields[14])
      if workspace_name and workspace_name ~= "" and class and class ~= "" and role ~= nil and slot and slot >= 1 and
          valid_geometry_intents[intent] and x and y and width and width >= 1 and height and height >= 1 and
          bounds_left and bounds_top and bounds_width and bounds_width >= 1 and bounds_height and bounds_height >= 1 then
        local key = placement_record_key(workspace_name, class, role)
        geometry_records[key] = geometry_records[key] or {}
        geometry_records[key][slot] = {
          workspace = workspace_name, class = class, role = role, slot = slot, intent = intent,
          x = x, y = y, width = width, height = height,
          bounds_left = bounds_left, bounds_top = bounds_top,
          bounds_width = bounds_width, bounds_height = bounds_height,
        }
      end
    end
  end
  file:close()
end

local function save_geometry_records()
  local records = {}
  for _, bucket in pairs(geometry_records) do
    for _, record in pairs(bucket) do table.insert(records, record) end
  end
  table.sort(records, function(a, b)
    if a.workspace ~= b.workspace then return a.workspace < b.workspace end
    if a.class ~= b.class then return a.class < b.class end
    if a.role ~= b.role then return a.role < b.role end
    return a.slot < b.slot
  end)

  local temporary_path = geometry_state_path .. ".tmp"
  local file = io.open(temporary_path, "w")
  if not file then return false end
  for _, record in ipairs(records) do
    file:write(table.concat({
      "v1", encode_hex(record.workspace), encode_hex(record.class), encode_hex(record.role),
      tostring(record.slot), record.intent,
      tostring(record.x), tostring(record.y), tostring(record.width), tostring(record.height),
      tostring(record.bounds_left), tostring(record.bounds_top),
      tostring(record.bounds_width), tostring(record.bounds_height),
    }, "\t"), "\n")
  end
  file:flush()
  file:close()
  if not os.rename(temporary_path, geometry_state_path) then
    os.remove(temporary_path)
    return false
  end
  return true
end

local function source_float_workspace(window)
  local workspace = window and window.workspace or nil
  if workspace_is_regular(workspace) and workspace_float_enabled(workspace) then return workspace end
  local minimized_id = workspace and workspace.special == true and
    tostring(workspace.name or ""):match("^special:omarchy%-minimized%-(%-?%d+)$") or nil
  if not minimized_id then return nil end
  minimized_id = tonumber(minimized_id)
  for _, candidate in safe_ipairs(hl.get_workspaces()) do
    if workspace_is_regular(candidate) and tonumber(candidate.id) == minimized_id and workspace_float_enabled(candidate) then
      return candidate
    end
  end
  return nil
end

local function geometry_record_from_window(window)
  if not window or window.mapped ~= true or window.floating ~= true then return nil end
  local at, size = window.at, window.size
  local bounds = floating_window_bounds(window.monitor)
  if not at or not size or not bounds then return nil end

  local maximum = window_geometric_max_metadata(window)
  local side = window_side_intent(window)
  local anchor = reflow_anchor(window)
  local fullscreen = (tonumber(window.fullscreen) or 0) ~= 0
  local intent, geometry
  if maximum then
    intent = side and ("max-" .. side.side) or "max-free"
    geometry = maximum
  elseif side then
    if not fullscreen and not side_intent_still_managed(window, side) then
      remove_window_tag(window, side.raw)
      side = nil
    end
    if side then
      intent = side.side
      geometry = side
    end
  end
  if not intent then
    if fullscreen then return nil end
    intent = "free"
    -- A plugin reflow must not replace the durable placement with its fitted
    -- small-screen result. Native/user edits still win when actual geometry no
    -- longer matches the last box applied by this module.
    if anchor and boxes_equal(window_box(window), anchor.last_applied) then
      geometry = anchor.original_box
      bounds = anchor.source_bounds
    else
      geometry = { x = at.x, y = at.y, width = size.x, height = size.y }
    end
  end

  local width, height = nearest_integer(geometry.width), nearest_integer(geometry.height)
  if width < 1 or height < 1 then return nil end
  return {
    intent = intent,
    x = nearest_integer(geometry.x), y = nearest_integer(geometry.y),
    width = width, height = height,
    bounds_left = nearest_integer(bounds.left), bounds_top = nearest_integer(bounds.top),
    bounds_width = nearest_integer(bounds.width), bounds_height = nearest_integer(bounds.height),
  }
end

local function capture_window_placement(window, workspace)
  local identity, slot = claim_geometry_slot(window, workspace)
  local record = geometry_record_from_window(window)
  if not identity or not slot or not record then return false end
  record.workspace, record.class, record.role, record.slot = identity.workspace, identity.class, identity.role, slot
  geometry_records[identity.key] = geometry_records[identity.key] or {}
  geometry_records[identity.key][slot] = record
  return true
end

persist_window_placement = function(window, workspace)
  if capture_window_placement(window, workspace or source_float_workspace(window)) then
    return save_geometry_records()
  end
  return false
end

persist_workspace_placements = function(workspace)
  local changed = false
  if workspace_is_regular(workspace) then
    for _, window in safe_ipairs(workspace:get_windows()) do
      if capture_window_placement(window, workspace) then changed = true end
    end
  end
  if changed then save_geometry_records() end
end

local function scaled_placement_offset(offset, old_travel, new_travel)
  if new_travel <= 0 then return 0 end
  if old_travel <= 0 then return math.max(0, math.min(new_travel, nearest_integer(offset))) end
  return math.max(0, math.min(new_travel, nearest_integer(offset * new_travel / old_travel)))
end

local function restore_free_record(window, record)
  local bounds = floating_window_bounds(window and window.monitor or nil)
  if not bounds then return false end
  local width = math.max(1, math.min(record.width, bounds.width))
  local height = math.max(1, math.min(record.height, bounds.height))
  hl.dispatch(hl.dsp.window.resize({ x = width, y = height, window = window }))

  local actual = window.size or {}
  width = math.max(1, math.min(tonumber(actual.x) or width, bounds.width))
  height = math.max(1, math.min(tonumber(actual.y) or height, bounds.height))
  local old_travel_x = math.max(0, record.bounds_width - record.width)
  local old_travel_y = math.max(0, record.bounds_height - record.height)
  local new_travel_x = math.max(0, bounds.width - width)
  local new_travel_y = math.max(0, bounds.height - height)
  local x = bounds.left + scaled_placement_offset(record.x - record.bounds_left, old_travel_x, new_travel_x)
  local y = bounds.top + scaled_placement_offset(record.y - record.bounds_top, old_travel_y, new_travel_y)
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
  return true
end

local function restore_window_placement(window, workspace, record)
  if not record or (tonumber(window and window.fullscreen) or 0) ~= 0 then return false end
  if record.intent == "free" then
    return restore_free_record(window, record)
  elseif record.intent == "left" or record.intent == "right" then
    snap_active_window(window, workspace, record.intent)
    return true
  elseif record.intent == "max-left" or record.intent == "max-right" then
    snap_active_window(window, workspace, record.intent == "max-left" and "left" or "right")
    return maximize_geometric_window(window, workspace)
  elseif record.intent == "max-free" and restore_free_record(window, record) then
    return maximize_geometric_window(window, workspace)
  end
  return false
end

local function place_window_over_parent(window, semantics)
  if type(semantics) ~= "table" or semantics.position_specified == true or
      semantics.program_position == true or semantics.user_position == true then return false end
  local parent_address = tostring(semantics.parent_address or "")
  if parent_address == "" or parent_address == "0x0" or not parent_address:match("^0x%x+$") then return false end

  local ok, parent = pcall(hl.get_window, "address:" .. parent_address)
  if not ok or not parent then return false end
  local parent_at, parent_size = parent.at, parent.size
  local child_size = window and window.size or nil
  if not parent_at or not parent_size or not child_size then return false end

  local x = nearest_integer((tonumber(parent_at.x) or 0) +
    ((tonumber(parent_size.x) or 0) - (tonumber(child_size.x) or 0)) / 2)
  local y = nearest_integer((tonumber(parent_at.y) or 0) +
    ((tonumber(parent_size.y) or 0) - (tonumber(child_size.y) or 0)) / 2)
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = window }))
  return true
end

load_float_workspaces()
load_geometry_records()

-- Process start ticks survive focus/Z-order changes and let the shell reconstruct
-- launch order after its own restart without a separate ordering database.
for _, window in safe_ipairs(hl.get_windows()) do
  tag_window_launch_order(window)
  local workspace = source_float_workspace(window)
  if workspace then claim_geometry_slot(window, workspace) end
end

-- Re-apply persisted floating modes and repair geometry if this module loads
-- after a monitor migration already happened.
for _, workspace in safe_ipairs(hl.get_workspaces()) do
  if workspace_float_enabled(workspace) then
    apply_workspace_mode(workspace)
    for _, window in safe_ipairs(workspace:get_windows()) do adopt_existing_side_intent(window, workspace) end
    defensively_fit_float_workspace(workspace)
    rebase_workspace_reflow_anchors(workspace)
  end
end

hl.on("window.open", function(window)
  tag_window_launch_order(window)
  local workspace = window and window.workspace or nil
  local float_enabled = workspace_is_regular(workspace) and workspace_float_enabled(workspace)
  local persistence_eligible, persistence_reason, semantics = window_persistence_semantics(window)
  local slot, record, initial_placement
  debug_window_geometry("event.window_open_before", window, workspace, {
    float_workspace = float_enabled,
    persistence = persistence_reason,
  })
  if float_enabled then
    set_window_floating(window, true)
    local _, claimed_slot, claimed_record = claim_geometry_slot(window, workspace)
    slot, record = claimed_slot, claimed_record
    if persistence_eligible and record then
      restore_window_placement(window, workspace, record)
      initial_placement = "restored"
    elseif place_window_over_parent(window, semantics) then
      initial_placement = "parent"
    else
      initial_placement = "app"
    end
    fit_window_to_floating_bounds(window)
    rebase_reflow_anchor(window)
    if persistence_eligible and not record then persist_window_placement(window, workspace) end
  end
  debug_window_geometry("event.window_open_after", window, workspace, {
    float_workspace = float_enabled,
    geometry_slot = slot or "none",
    initial_placement = initial_placement or "none",
    persistence = persistence_reason,
    restored_intent = record and record.intent or "none",
  })
end)

hl.on("window.close", function(window)
  local workspace = source_float_workspace(window)
  if workspace then persist_window_placement(window, workspace) end
  release_geometry_slot(window, false)
  forget_window_persistence_semantics(window)
  clear_reflow_anchor(window)
end)

hl.on("hyprland.shutdown", function()
  local changed = false
  for _, window in safe_ipairs(hl.get_windows()) do
    local workspace = source_float_workspace(window)
    if workspace and capture_window_placement(window, workspace) then changed = true end
  end
  if changed then save_geometry_records() end
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
      local minimizing_to_source = workspace and workspace.special == true and workspace.name == expected_special
      local returning_to_source = workspace_is_regular(workspace) and workspace_selector(workspace) == placement.source and workspace_float_enabled(workspace)
      if minimizing_to_source and placement == side and not metadata and not side_intent_still_managed(window, side) then
        remove_window_tag(window, placement.raw)
        side = nil
      elseif not minimizing_to_source and not returning_to_source then
        remove_window_tag(window, placement.raw)
        if placement == metadata then metadata = nil else side = nil end
      end
    end
  end
  if workspace_is_regular(workspace) then
    local float_enabled = workspace_float_enabled(workspace)
    local anchor = reflow_anchor(window)
    local returning_to_source = (metadata and workspace_selector(workspace) == metadata.source) or
      (side and workspace_selector(workspace) == side.source) or
      (anchor and workspace_selector(workspace) == anchor.source_workspace)
    set_window_floating(window, float_enabled)
    release_geometry_slot(window, true)
    if float_enabled then claim_geometry_slot(window, workspace) end
    if not returning_to_source then clear_reflow_anchor(window) end
  elseif metadata or side then
    set_window_floating(window, true)
  end
end)

-- Hyprland emits this only after the workspace monitor, every member window's
-- monitor, floating position translation, and native fullscreen reflow finish.
hl.on("workspace.move_to_monitor", function(workspace, monitor)
  debug_log("event.workspace_move_to_monitor", {
    workspace = workspace and workspace.name or "nil",
    monitor = monitor and monitor.name or "nil",
  })
  defensively_fit_float_workspace(workspace, "workspace.move_to_monitor")
end)

-- Hyprland emits this after monitor layout changes. It carries no monitor, so
-- inspect every plugin-enabled Float workspace.
hl.on("monitor.layout_changed", function()
  debug_log("event.monitor_layout_changed")
  for _, workspace in safe_ipairs(hl.get_workspaces()) do
    defensively_fit_float_workspace(workspace, "monitor.layout_changed")
  end
end)

-- LayerSurface::onMap arranges exclusive reservations before this event.
hl.on("layer.opened", function(layer)
  local monitor = layer and layer.monitor or nil
  if not monitor then return end
  local reserved = monitor.reserved or {}
  debug_log("event.layer_opened", {
    monitor = monitor.name or "nil",
    reserved_bottom = tonumber(reserved.bottom) or 0,
    reserved_left = tonumber(reserved.left) or 0,
    reserved_right = tonumber(reserved.right) or 0,
    reserved_top = tonumber(reserved.top) or 0,
  })
  for _, workspace in safe_ipairs(hl.get_workspaces()) do
    if workspace_is_regular(workspace) and workspace_float_enabled(workspace) and workspace.monitor == monitor then
      defensively_fit_float_workspace(workspace, "layer.opened")
    end
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
