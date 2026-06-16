-- Toggle resolve state on a single discussion. Looks up the current state in
-- the cached discussions list (no extra round-trip needed) and inverts it.

local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local discussion_util = require("review.util.discussion")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

local function find_discussion(id)
  for _, d in ipairs(state_mod.state.discussions or {}) do
    if d.id == id then return d end
  end
end

function M.run(target)
  local ctx = controller.get_ctx()
  if not ctx then return end
  if not target or not target.discussion_id then return end

  local d = find_discussion(target.discussion_id)
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
    controller.refresh_discussions()
  end)
end

return M
