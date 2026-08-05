-- Adds a reply to an existing discussion thread. Triggered by 'a' in the
-- :ReviewNotes panel; works on any line that maps to a discussion (head,
-- body, or another reply).

local M = {}

local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

---@param target table  { discussion_id, ... } as built by the panel / preview
---@param tabnr integer|nil  the session's tab. Required when called from a tab
---  that hosts no session — e.g. the note-preview float over a working-tree
---  file while the review sits in a background tab.
function M.run(target, tabnr)
  local ctx = controller.get_ctx(tabnr)
  if not ctx then return end
  if not target or not target.discussion_id then
    notify("no thread under cursor", vim.log.levels.WARN)
    return
  end

  input_prompt.open({
    title = "Reply to thread",
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      if body:gsub("%s", "") == "" then
        notify("empty reply, skipped", vim.log.levels.WARN)
        return
      end
      ctx.provider.add_reply(ctx.remote, ctx.mr.iid, target.discussion_id, body, function(ok, err)
        if not ok then
          notify((err or "failed to reply"), vim.log.levels.ERROR)
          return
        end
        notify("reply posted")
        controller.refresh_discussions(tabnr)
      end)
    end,
  })
end

return M
