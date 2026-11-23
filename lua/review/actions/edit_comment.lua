local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local input_prompt = require("review.ui.input_prompt")
local pending_util = require("review.util.pending")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target)
  local ctx = controller.get_ctx()
  if not ctx then return end
  if not target or not target.discussion_id or not target.note_id then
    notify("nothing to edit here", vim.log.levels.WARN)
    return
  end
  local session = state_mod.get_for_tab(ctx.tabnr)
  local note = pending_util.find_note(session and session.discussions, target.discussion_id, target.note_id)
  if not note then
    notify("note not found in cache, refresh first", vim.log.levels.WARN)
    return
  end

  input_prompt.open({
    title = note.pending and "Edit pending note" or "Edit note",
    prefill = vim.split(note.body or "", "\n", { plain = true }),
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      local function done(ok, err)
        if not ok then
          notify((err or "failed to update"), vim.log.levels.ERROR)
          return
        end
        notify(note.pending and "pending note updated" or "note updated")
        controller.refresh_discussions(ctx.tabnr)
      end
      -- A pending note lives behind its own endpoints (and ids): sending it
      -- down the published-note path would address some unrelated comment.
      if note.pending then
        if body:gsub("%s", "") == "" then
          notify("empty note, not saved (delete it with d instead)", vim.log.levels.WARN)
          return
        end
        ctx.provider.update_pending(ctx.remote, ctx.mr.iid, note, body, done)
      else
        ctx.provider.update_note(ctx.remote, ctx.mr.iid, target.discussion_id, target.note_id, body, done)
      end
    end,
  })
end

return M
