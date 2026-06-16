local M = {}

local diffview_int = require("review.diffview.integration")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target)
  if not target or not target.position or target.position == vim.NIL then
    notify("this comment is not anchored to a file", vim.log.levels.WARN)
    return
  end
  local pos = target.position
  local path = pos.new_path or pos.old_path
  local line = tonumber(pos.new_line or pos.old_line)
  local side = pos.new_line and "new" or "old"
  if not path or not line then
    notify("comment position is incomplete", vim.log.levels.WARN)
    return
  end
  local ok, err = diffview_int.jump_to(path, line, side)
  if not ok then
    notify((err or "jump failed"), vim.log.levels.WARN)
  end
end

return M
