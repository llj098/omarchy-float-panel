local captured_binds = {}

local noop
noop = setmetatable({}, {
  __index = function() return noop end,
  __call = function() return noop end,
})

-- Match omarchy-menu-keybindings: unknown hl.* calls return the same proxy,
-- including get_windows() and get_workspaces().
hl = setmetatable({
  dsp = noop,
  bind = function() return noop end,
  get_config = function() return nil end,
}, {
  __index = function() return noop end,
})

o = {
  bind = function(keys)
    captured_binds[keys] = true
  end,
  shell_quote = function(value)
    return tostring(value)
  end,
}

dofile("hypr/float-panel.lua")

for _, keys in ipairs({
  "SUPER + SHIFT + T",
  "SUPER + LEFT",
  "SUPER + RIGHT",
  "SUPER + UP",
  "SUPER + DOWN",
  "ALT + TAB",
}) do
  assert(captured_binds[keys], "scanner must still reach binding registration: " .. keys)
end

print("KEYBINDING_SCANNER_TEST_OK")
