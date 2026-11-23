-- Discards the pending review: deletes every pending note without publishing
-- anything, and leaves review mode. See review.review_mode.

local M = {}

local controller = require("review.controller")
local review_mode = require("review.review_mode")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

---@param tabnr integer|nil  session tab; nil = resolve from where the user is
function M.run(tabnr)
  local ctx = controller.resolve_ctx(tabnr)
  if not ctx then
    notify("no review session", vim.log.levels.WARN)
    return
  end
  local review = review_mode.get(ctx.tabnr)
  if not review or type(ctx.provider.discard_review) ~= "function" then return end
  local count = review.count or 0
  if not review.active and count == 0 then
    notify("no review in progress")
    return
  end

  if count > 0 then
    local question = string.format(
      "Discard the pending review? %d pending note%s will be deleted.",
      count, count == 1 and "" or "s")
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then return end
  end

  ctx.provider.discard_review(ctx.remote, ctx.mr.iid, function(ok, err)
    if not ok then
      -- Review mode stays on: some notes may still be there.
      notify((err or "failed to discard review"), vim.log.levels.ERROR)
      controller.refresh_discussions(ctx.tabnr)
      return
    end
    review_mode.finish(ctx.tabnr)
    notify("pending review discarded")
    controller.refresh_discussions(ctx.tabnr)
  end)
end

return M
