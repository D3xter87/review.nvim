local M = {}

local controller = require("review.controller")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target)
  local ctx = controller.get_ctx()
  if not ctx then return end
  if not target or not target.discussion_id or not target.note_id then
    notify("nothing to delete here", vim.log.levels.WARN)
    return
  end

  local choice = vim.fn.confirm("Delete this note?", "&Yes\n&No", 2)
  if choice ~= 1 then return end

  ctx.provider.delete_note(ctx.remote, ctx.mr.iid, target.discussion_id, target.note_id, function(ok, err)
    if not ok then
      notify((err or "failed to delete"), vim.log.levels.ERROR)
      return
    end
    notify("note deleted")
    controller.refresh_discussions()
  end)
end

return M
