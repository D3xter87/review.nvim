-- Visual-mode 'c' in a diffview content buffer: opens an empty input prompt
-- and posts a new inline discussion anchored to the end of the visual range.

local M = {}

local controller = require("review.controller")
local diffview_int = require("review.diffview.integration")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run()
  local ctx = controller.get_ctx()
  if not ctx then return end

  local target = diffview_int.current_diff_target()
  if not target then
    notify("cannot determine diff target (path/side)", vim.log.levels.WARN)
    return
  end

  local e_pos = vim.fn.getpos("'>")
  local end_line = e_pos[2]
  if end_line == 0 then
    notify("no visual selection", vim.log.levels.WARN)
    return
  end

  local position
  if target.side == "new" then
    position = ctx.provider.build_position(ctx.mr, {
      new_path = target.path, old_path = target.path, new_line = end_line,
    })
  else
    position = ctx.provider.build_position(ctx.mr, {
      new_path = target.path, old_path = target.path, old_line = end_line,
    })
  end

  input_prompt.open({
    title = "Line comment",
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      if body:gsub("%s", "") == "" then
        notify("empty comment, skipped", vim.log.levels.WARN)
        return
      end
      ctx.provider.post_discussion(ctx.remote, ctx.mr.iid, body, position, function(ok, err)
        if not ok then
          notify((err or "failed to post comment"), vim.log.levels.ERROR)
          return
        end
        notify("comment posted")
        controller.refresh_discussions()
      end)
    end,
  })
end

return M
