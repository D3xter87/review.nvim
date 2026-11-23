local M = {}

local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")
local review_mode = require("review.review_mode")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run()
  local ctx = controller.get_ctx()
  if not ctx then return end

  -- Decided once, here: the title promises where the text goes.
  local as_pending = review_mode.is_active(ctx)

  input_prompt.open({
    title = review_mode.title("Global MR comment", as_pending),
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      if body:gsub("%s", "") == "" then
        notify("empty comment, skipped", vim.log.levels.WARN)
        return
      end
      review_mode.post(ctx, as_pending, body, nil, function(ok, err)
        if not ok then
          notify((err or "failed to post comment"), vim.log.levels.ERROR)
          return
        end
        notify(as_pending and "global comment added to pending review" or "global comment posted")
        controller.refresh_discussions(ctx.tabnr)
      end)
    end,
  })
end

return M
