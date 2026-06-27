-- Visual-mode 's' in a diffview content buffer: prefills the prompt with the
-- selected lines (so the user edits the existing code), then posts a GitLab
-- suggestion. Multi-line ranges set N = end_line - start_line in the fence.

local M = {}

local controller = require("review.controller")
local diffview_int = require("review.diffview.integration")
local input_prompt = require("review.ui.input_prompt")
local visual = require("review.util.visual")
local hunks = require("review.util.hunks")

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

  local start_line, end_line = visual.range()
  if not start_line then
    notify("no visual selection", vim.log.levels.WARN)
    return
  end

  -- Clamp the selection into a single diff hunk so the suggestion range stays
  -- valid (and the prefill matches what's actually being commented on).
  local ranges = hunks.ranges(ctx.mr.base_sha, ctx.mr.head_sha, target.path, "new")
  local cs, ce, adjusted = hunks.clamp(ranges, start_line, end_line)
  if not cs then
    notify("selection is outside the diff", vim.log.levels.WARN)
    return
  end
  if adjusted then
    notify_util.progress("review: selection adjusted to lines " .. cs .. "-" .. ce)
  end
  start_line, end_line = cs, ce

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local extra = end_line - start_line   -- N in suggestion:-0+N

  -- Position opts for both ends. GitHub anchors on the END line and encodes the
  -- range via start_line; GitLab anchors on the START line and extends N lines
  -- down via the fence (so start_old_line carries the anchor's old_line for a
  -- valid line_code on context lines).
  local start_anchor = hunks.pos(ctx.mr.base_sha, ctx.mr.head_sha, target.path, "new", start_line)
      or { new_line = start_line }
  local end_anchor = hunks.pos(ctx.mr.base_sha, ctx.mr.head_sha, target.path, "new", end_line)
      or { new_line = end_line }
  local position = ctx.provider.build_position(ctx.mr, {
    new_path = target.path, old_path = target.path,
    side = "new",
    new_line = end_line, old_line = end_anchor.old_line,
    start_line = start_line, start_old_line = start_anchor.old_line,
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
