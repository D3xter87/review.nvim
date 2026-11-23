local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local pending_util = require("review.util.pending")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target)
  local ctx = controller.get_ctx()
  if not ctx then return end
  if not target or not target.discussion_id or not target.note_id then
    notify("nothing to delete here", vim.log.levels.WARN)
    return
  end

  local session = state_mod.get_for_tab(ctx.tabnr)
  local note = pending_util.find_note(session and session.discussions, target.discussion_id, target.note_id)
  local is_pending = note ~= nil and note.pending == true
  -- An id shaped like a pending one that is no longer in the cache must not
  -- fall through to the published-note endpoint.
  if not is_pending and type(target.note_id) == "string"
      and target.note_id:sub(1, #pending_util.ID_PREFIX) == pending_util.ID_PREFIX then
    notify("pending note not found in cache, refresh first", vim.log.levels.WARN)
    return
  end

  local question = is_pending and "Delete this pending note?" or "Delete this note?"
  local choice = vim.fn.confirm(question, "&Yes\n&No", 2)
  if choice ~= 1 then return end

  local function done(ok, err)
    if not ok then
      notify((err or "failed to delete"), vim.log.levels.ERROR)
      return
    end
    notify(is_pending and "pending note deleted" or "note deleted")
    controller.refresh_discussions(ctx.tabnr)
  end

  if is_pending then
    ctx.provider.delete_pending(ctx.remote, ctx.mr.iid, note, done)
  else
    ctx.provider.delete_note(ctx.remote, ctx.mr.iid, target.discussion_id, target.note_id, done)
  end
end

return M
