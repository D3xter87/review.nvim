local M = {}

local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run()
  local ctx = controller.get_ctx()
  if not ctx then return end

  input_prompt.open({
    title = "Global MR comment",
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      if body:gsub("%s", "") == "" then
        notify("empty comment, skipped", vim.log.levels.WARN)
        return
      end
      ctx.provider.post_discussion(ctx.remote, ctx.mr.iid, body, nil, function(ok, err)
        if not ok then
          notify((err or "failed to post comment"), vim.log.levels.ERROR)
          return
        end
        notify("global comment posted")
        controller.refresh_discussions()
      end)
    end,
  })
end

return M
