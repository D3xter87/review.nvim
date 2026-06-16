-- Visual-mode 's' in a diffview content buffer: prefills the prompt with the
-- selected lines (so the user edits the existing code), then posts a GitLab
-- suggestion. Multi-line ranges set N = end_line - start_line in the fence.

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
  if target.side ~= "new" then
    notify("suggestions only apply to the new (right) side", vim.log.levels.WARN)
    return
  end

  local s_pos = vim.fn.getpos("'<")
  local e_pos = vim.fn.getpos("'>")
  local start_line = s_pos[2]
  local end_line = e_pos[2]
  if start_line == 0 or end_line == 0 then
    notify("no visual selection", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local extra = end_line - start_line   -- N in suggestion:-0+N

  -- start_line is read by the GitHub provider for multi-line ranges; the
  -- GitLab provider ignores it (multi-line is encoded in the suggestion fence).
  local position = ctx.provider.build_position(ctx.mr, {
    new_path = target.path, old_path = target.path,
    new_line = end_line, start_line = start_line,
  })

  input_prompt.open({
    title = string.format("Suggestion"),
    prefill = lines,
    on_submit = function(edited)
      local body = ctx.provider.format_suggestion(edited, extra)
      ctx.provider.post_discussion(ctx.remote, ctx.mr.iid, body, position, function(ok, err)
        if not ok then
          notify((err or "failed to post suggestion"), vim.log.levels.ERROR)
          return
        end
        notify("suggestion posted")
        controller.refresh_discussions()
      end)
    end,
  })
end

return M
