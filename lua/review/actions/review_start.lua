-- Starts a pending review: from now on new comments, suggestions and replies
-- are held back (GitLab draft notes / GitHub pending review) until the review
-- is submitted or discarded. See review.review_mode.

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
  if not review_mode.is_supported(ctx) then
    notify("pending reviews are not available on this server", vim.log.levels.WARN)
    return
  end
  local review = review_mode.get(ctx.tabnr)
  if not review then return end
  if review.active then
    notify(string.format("a review is already in progress (%d pending)", review.count or 0))
    return
  end
  review.active = true
  notify("review started: comments are held back until you submit or discard it")
  controller.refresh_panel(ctx.tabnr)
end

return M
