-- Submits the pending review: publishes every pending note at once, with an
-- optional summary comment and a verdict. See review.review_mode.

local M = {}

local controller = require("review.controller")
local review_mode = require("review.review_mode")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

local LABELS = {
  comment = "Comment",
  approve = "Approve",
  request_changes = "Request changes",
}

---@param tabnr integer|nil  session tab; nil = resolve from where the user is
function M.run(tabnr)
  local ctx = controller.resolve_ctx(tabnr)
  if not ctx then
    notify("no review session", vim.log.levels.WARN)
    return
  end
  if not review_mode.is_supported(ctx) or type(ctx.provider.submit_review) ~= "function" then
    notify("pending reviews are not available on this server", vim.log.levels.WARN)
    return
  end
  local review = review_mode.get(ctx.tabnr) or {}
  local count = review.count or 0
  local verdicts = ctx.provider.review_verdicts or { "comment" }

  vim.ui.select(verdicts, {
    prompt = string.format("Submit review (%d pending) as:", count),
    format_item = function(v) return LABELS[v] or v end,
  }, function(verdict)
    if not verdict then return end
    input_prompt.open({
      title = string.format("Review summary (optional) · %s · %d pending",
        LABELS[verdict] or verdict, count),
      prefill = review.summary and vim.split(review.summary, "\n", { plain = true }) or nil,
      on_submit = function(lines)
        local body = vim.trim(table.concat(lines, "\n"))
        if body == "" then body = nil end
        if verdict == "comment" and not body and count == 0 then
          notify("nothing to submit: no pending notes and no summary", vim.log.levels.WARN)
          return
        end
        notify_util.progress("review: submitting...")
        ctx.provider.submit_review(ctx.remote, ctx.mr.iid,
          { body = body, verdict = verdict, count = count },
          function(ok, err, warning)
            if not ok then
              notify((err or "failed to submit review"), vim.log.levels.ERROR)
              -- Part of it may have gone through: show what is really there.
              controller.refresh_discussions(ctx.tabnr)
              return
            end
            review_mode.finish(ctx.tabnr)
            notify(string.format("review submitted (%s)", LABELS[verdict] or verdict))
            if warning then notify(warning, vim.log.levels.WARN) end
            controller.refresh_discussions(ctx.tabnr)
            -- The verdict changes the approval state shown in the Info panel.
            if vim.api.nvim_get_current_tabpage() == ctx.tabnr then
              controller.refresh_mr_details()
            end
          end)
      end,
    })
  end)
end

return M
