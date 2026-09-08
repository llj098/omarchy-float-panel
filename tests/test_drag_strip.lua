local module = dofile("hypr/drag-strip.lua")
local count = 0
local function eq(a, b, label)
  assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  count = count + 1
end

local function fixture(capabilities)
  local f = { calls = {}, accepts = {}, sequence = 0 }
  local native, policy = {}, {}
  native.capabilities = function()
    return capabilities or { decoration_input_v1 = true, drag_lifecycle_v1 = true }
  end
  local function record(name, ...)
    table.insert(f.calls, { name, ... })
    if f.reenter then f.reenter(name, ...) end
    return true
  end
  for _, name in ipairs({ "decoration_set", "decoration_remove", "decoration_capture", "decoration_release" }) do
    native[name] = function(...) return record(name, ...) end
  end
  local current
  native.drag_begin = function(address, mode)
    record("drag_begin", address, mode)
    f.sequence = f.sequence + 1
    current = { window = f.by_address[address], mode = mode, sequence = f.sequence }
    f.api.drag(current.window, "begin", mode, current.sequence)
    if f.reject then
      f.api.drag(current.window, "rejected", mode, current.sequence)
      current = nil
      return false
    end
    return true
  end
  native.drag_finish = function(address)
    record("drag_finish", address)
    if not current then return true end
    local operation = current
    current = nil
    if f.final_step then f.final_step(operation.window) end
    f.api.drag(operation.window, "end", operation.mode, operation.sequence)
    return true
  end
  policy.identity = function(w) return w.id end
  policy.address = function(w) return w.address end
  policy.eligible = function(w) return w.eligible end
  policy.destination_valid = function(w) return w.valid_destination ~= false end
  policy.style = function() return f.style or { height = 6, color = 0xff8899aa, cursor = "grab" } end
  policy.snapshot = function(w)
    return { x = w.x, y = w.y, width = w.width, height = w.height, workspace = w.workspace }
  end
  policy.equal = function(a, b)
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
  end
  policy.accept = function(w, final, before)
    table.insert(f.accepts, { window = w, final = final, before = before })
    w.managed = false
    w.prev = final
    if w.persistent then w.saves = (w.saves or 0) + 1 end
    if f.on_accept then f.on_accept(w) end
  end
  f.by_address = {}
  f.native = native
  f.api = module.new(native, policy)
  function f.window(id, address)
    local w = { id = id, address = address or id, eligible = true,
      x = 100, y = 100, width = 800, height = 600, workspace = "2", managed = true, persistent = true }
    f.by_address[w.address] = w
    f.api.reconcile(w)
    return w
  end
  function f.number(name)
    local n = 0
    for _, call in ipairs(f.calls) do if call[1] == name then n = n + 1 end end
    return n
  end
  function f.pointer(w, phase, button) f.api.pointer(w, phase, button or 272) end
  return f
end

for _, caps in ipairs({ {}, { maximize_request_event = true }, { decoration_input_v1 = true } }) do
  local f = fixture(caps)
  local w = f.window("fallback")
  f.pointer(w, "press")
  eq(f.api.enabled(), false, "fallback")
  eq(#f.calls, 0)
end

-- Paint is policy-only; no repeated update and no geometry/intent mutation.
do
  local f = fixture()
  local w = f.window("paint")
  eq(f.calls[1][3].visible, false)
  f.pointer(w, "enter")
  f.pointer(w, "enter")
  f.api.reconcile(w)
  eq(f.number("decoration_set"), 2)
  f.pointer(w, "leave")
  eq(f.number("decoration_set"), 3)
  eq(w.managed, true)
  eq(#f.accepts, 0)
  f.pointer(w, "press", 273)
  f.pointer(w, "release", 273)
  eq(f.number("drag_begin"), 0, "right button passes")
end

-- Click/no-op retains tags and persistence; release outside still finishes.
for _, outside in ipairs({ false, true }) do
  local f = fixture()
  local w = f.window("click")
  f.pointer(w, "enter")
  f.pointer(w, "press")
  eq(f.api.active(w), true)
  f.pointer(w, "press")
  eq(f.number("drag_begin"), 1)
  if outside then f.pointer(w, "leave") end
  f.pointer(w, "release", 273)
  eq(f.api.active(w), true, "unrelated release")
  f.pointer(w, "release")
  f.pointer(w, "release")
  eq(f.api.active(w), false)
  eq(f.number("drag_finish"), 1)
  eq(f.number("decoration_release"), 1)
  eq(w.managed, true)
  eq(w.saves, nil)
end

-- Model early workspace notification explicitly, then final native geometry.
do
  local f = fixture()
  local w = f.window("move")
  f.pointer(w, "press")
  w.workspace, w.x = "3", 200
  eq(f.api.active(w), true, "early workspace must be guarded by integrator")
  eq(#f.accepts, 0)
  f.final_step = function(window) window.x = 350 end
  f.pointer(w, "leave")
  f.pointer(w, "release")
  eq(#f.accepts, 1)
  eq(f.accepts[1].before.x, 100)
  eq(w.prev.x, 350)
  eq(w.prev.workspace, "3")
  eq(w.managed, false)
  eq(w.saves, 1)
  f.api.drag(w, "end", "move", f.sequence)
  eq(#f.accepts, 1, "duplicate terminal")
end

-- External native Super move/resize use the same post-end callback.
for _, mode in ipairs({ "move", "resize" }) do
  local f = fixture()
  local w = f.window(mode)
  w.persistent = false -- application-specified placement policy is injected
  f.api.drag(w, "begin", mode, "external-1")
  w.width = 900
  f.api.drag(w, "begin", mode, "external-1")
  f.api.drag(w, "end", mode, "stale")
  eq(f.api.active(w), true)
  f.on_accept = function(window) f.api.drag(window, "end", mode, "external-1") end
  f.api.drag(w, "end", mode, "external-1")
  eq(#f.accepts, 1)
  eq(f.accepts[1].before.width, 800)
  eq(w.saves, nil)
  eq(f.number("drag_finish"), 0, "never finish foreign interaction")
end

-- Invalid destination and aborted/rejected attempts never accept an edit.
for _, ending in ipairs({ "abort", "rejected", "end" }) do
  local f = fixture()
  local w = f.window(ending)
  f.api.drag(w, "begin", "move", 10)
  w.x, w.valid_destination = 400, false
  f.api.drag(w, ending, "move", 10)
  eq(#f.accepts, 0)
  eq(f.api.active(w), false)
end
do
  local f = fixture()
  f.reject = true
  local w = f.window("reject")
  f.pointer(w, "press")
  eq(f.api.active(w), false)
  eq(f.number("decoration_release"), 1)
  f.pointer(w, "release")
  eq(#f.accepts, 0)
end

-- Topology/lock interruption: cancel before finish, other windows remain free.
for _, action in ipairs({ "interrupt", "forget", "shutdown", "ineligible", "lost" }) do
  local f = fixture()
  local w = f.window(action)
  local other = f.window("other")
  f.pointer(w, "press")
  w.x = 400
  eq(f.api.active(other), false)
  if action == "ineligible" then
    w.eligible = false
    f.api.reconcile(w)
  elseif action == "lost" then f.pointer(w, "lost")
  else f.api[action](w) end
  eq(#f.accepts, 0, action .. " does not save aborted edit")
  eq(f.api.active(w), false)
  eq(f.number("decoration_release"), 1)
  f.pointer(w, "release")
  eq(#f.accepts, 0)
end

-- Reused address and late old close/end cannot affect the replacement.
do
  local f = fixture()
  local old = f.window("old", "0x123")
  f.pointer(old, "press")
  old.x = 700
  local new = f.window("new", "0x123")
  f.api.forget(old)
  f.api.drag(old, "end", "move", 1)
  eq(#f.accepts, 0)
  eq(f.number("decoration_remove"), 1)
  f.pointer(new, "press")
  new.x = 450
  f.pointer(new, "release")
  eq(#f.accepts, 1)
  eq(f.accepts[1].window, new)
end

-- Native calls can synchronously close the window; no continuation afterward.
for _, callback in ipairs({ "decoration_set", "decoration_capture", "drag_begin" }) do
  local f = fixture()
  local w = f.window(callback)
  f.reenter = function(name)
    if name ~= callback then return end
    f.reenter = nil
    f.api.forget(w)
  end
  if callback == "decoration_set" then f.pointer(w, "enter")
  else f.pointer(w, "press") end
  eq(f.api.active(w), false)
  eq(#f.accepts, 0)
end

-- Errors/missing native support are not permission to start an interaction.
do
  local f = fixture()
  local w = f.window("capture-failure")
  f.native.decoration_capture = function() return false end
  f.pointer(w, "press")
  eq(f.number("drag_begin"), 0)
  eq(f.api.active(w), false)
  f.native.decoration_capture = function() error("unavailable") end
  f.pointer(w, "press")
  eq(f.number("drag_begin"), 0)
  eq(#f.accepts, 0)
end
do
  local f = fixture()
  local w = f.window("foreign-interrupt")
  f.api.drag(w, "begin", "resize", 123)
  w.width = 950
  f.api.interrupt(w)
  f.api.drag(w, "end", "resize", 123)
  eq(f.number("drag_finish"), 0)
  eq(#f.accepts, 0)
  f.api.shutdown()
  local calls = #f.calls
  f.api.shutdown()
  f.api.reconcile(w)
  f.pointer(w, "press")
  eq(#f.calls, calls, "shutdown is permanent and idempotent")
end

-- Style changes reconcile even on an existing primitive; failed paint is retried.
do
  local f = fixture()
  local w = f.window("style-retry")
  local original = f.native.decoration_set
  local attempts = 0
  f.native.decoration_set = function(...)
    attempts = attempts + 1
    if attempts == 1 then return false end
    return original(...)
  end
  f.pointer(w, "enter")
  eq(attempts, 1)
  f.pointer(w, "enter")
  eq(attempts, 2, "a failed paint must not populate cache")
  f.pointer(w, "enter")
  eq(attempts, 2)
  f.style = { height = 10, hit_inset = 24, color = 0xff112233, cursor = "grab" }
  f.api.reconcile(w)
  eq(attempts, 3, "existing state receives style changes")
  eq(f.calls[#f.calls][3].height, 10)
  eq(f.calls[#f.calls][3].hit_inset, 24, "forward Lua inset without native corner policy")
  eq(f.style.visible, nil, "do not mutate policy-owned style tables")
  f.api.reconcile(w)
  eq(attempts, 3)
end

-- An externally terminated bridge operation releases capture/ownership immediately.
do
  local f = fixture()
  local w = f.window("early-end")
  f.pointer(w, "press")
  w.x = 420
  f.api.drag(w, "end", "move", 1)
  eq(f.number("decoration_release"), 1)
  eq(#f.accepts, 1)
  f.pointer(w, "leave")
  eq(f.calls[#f.calls][3].visible, false)
  f.pointer(w, "release")
  eq(f.number("drag_finish"), 0, "late release cannot end a foreign/new native operation")
end

print("drag-strip policy: " .. count .. " assertions passed (mock-only; not compositor acceptance)")
