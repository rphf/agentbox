--TODO: Consider a comment here
local wezterm = require("wezterm")

local M = {}

local function agentbox_session(pane)
  local ok, info = pcall(function() return pane:get_foreground_process_info() end)
  if not ok or not info or not info.argv then return nil end
  local argv = info.argv
  for i, arg in ipairs(argv) do
    if arg:match("^/.*/agentbox$") then
      local dir, j = info.cwd, i + 1
      while argv[j] == "-C" and argv[j + 1] do
        dir = argv[j + 1]:sub(1, 1) == "/" and argv[j + 1] or (info.cwd .. "/" .. argv[j + 1])
        j = j + 2
      end
      if argv[j] == "sh" and argv[j + 1] and argv[j + 1]:match("^%d+$") then
        return arg, dir, argv[j + 1]
      end
      return nil
    end
  end
end

function M.apply(config)
  config.keys = config.keys or {}
  table.insert(config.keys, {
    key = "v",
    mods = "CTRL",
    action = wezterm.action_callback(function(window, pane)
      local agentbox, dir, n = agentbox_session(pane)
      if agentbox then
        wezterm.run_child_process({ agentbox, "-C", dir, "clip", n })
      end
      window:perform_action(wezterm.action.SendKey({ key = "v", mods = "CTRL" }), pane)
    end),
  })
end

return M
