-- Toggle resolve state on a single discussion. Looks up the current state in
-- the cached discussions list (no extra round-trip needed) and inverts it.

local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local discussion_util = require("review.util.discussion")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

---@param id any
---@param tabnr integer|nil  session tab; nil = the active one
local function find_discussion(id, tabnr)
  local session = tabnr and state_mod.get_for_tab(tabnr) or state_mod.get_active()
  for _, d in ipairs((session and session.discussions) or {}) do
    if d.id == id then return d end
  end
end

---@param target table  { discussion_id, ... } as built by the panel / preview
---@param tabnr integer|nil  the session's tab. Required when called from a tab
---  that hosts no session — e.g. the note-preview float over a working-tree
---  file while the review sits in a background tab.
function M.run(target, tabnr)
  local ctx = controller.get_ctx(tabnr)
  if not ctx then return end
  if not target or not target.discussion_id then return end

  local d = find_discussion(target.discussion_id, tabnr)
  if not d then return end
  if not discussion_util.is_resolvable(d) then
    notify("this thread is not resolvable", vim.log.levels.WARN)
    return
  end

  local desired = not discussion_util.is_resolved(d)
  ctx.provider.resolve_discussion(ctx.remote, ctx.mr.iid, d.id, desired, function(ok, err)
    if not ok then
      notify((err or "failed to toggle resolve"), vim.log.levels.ERROR)
      return
    end
    notify("thread " .. (desired and "resolved" or "unresolved"))
    controller.refresh_discussions(tabnr)
  end)
end

return M
