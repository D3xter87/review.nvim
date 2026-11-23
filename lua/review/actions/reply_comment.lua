-- Adds a reply to an existing discussion thread. Triggered by 'a' in the
-- :ReviewNotes panel; works on any line that maps to a discussion (head,
-- body, or another reply).

local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local input_prompt = require("review.ui.input_prompt")
local pending_util = require("review.util.pending")
local review_mode = require("review.review_mode")

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

  local session = state_mod.get_for_tab(ctx.tabnr)
  local discussion = pending_util.find_discussion(session and session.discussions, target.discussion_id)
  -- A thread that exists only in the pending review has nothing published to
  -- answer yet (and on GitHub a reply to it would land as a public comment).
  if discussion and discussion.pending then
    notify("this note is still pending: edit it (e) instead of replying", vim.log.levels.WARN)
    return
  end

  -- Decided once, here: the title promises where the text goes.
  local as_pending = review_mode.is_active(ctx)

  input_prompt.open({
    title = review_mode.title("Reply to thread", as_pending),
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      if body:gsub("%s", "") == "" then
        notify("empty reply, skipped", vim.log.levels.WARN)
        return
      end
      review_mode.reply(ctx, as_pending, discussion, target.discussion_id, body, function(ok, err)
        if not ok then
          notify((err or "failed to reply"), vim.log.levels.ERROR)
          return
        end
        notify(as_pending and "reply added to pending review" or "reply posted")
        controller.refresh_discussions(ctx.tabnr)
      end)
    end,
  })
end

return M
