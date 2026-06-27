-- Visual-mode 'c' in a diffview content buffer: opens an empty input prompt
-- and posts a new inline discussion anchored to the end of the visual range.

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

  local start_line, end_line = visual.range()
  if not start_line then
    notify("no visual selection", vim.log.levels.WARN)
    return
  end

  -- Clamp the selection into a diff hunk so we never send out-of-range line
  -- numbers to the API. Comments anchor on the end line.
  local ranges = hunks.ranges(ctx.mr.base_sha, ctx.mr.head_sha, target.path, target.side)
  local cs, ce, adjusted = hunks.clamp(ranges, start_line, end_line)
  if not cs then
    notify("selection is outside the diff", vim.log.levels.WARN)
    return
  end
  if adjusted then notify_util.progress("review: anchored to line " .. ce) end

  -- Look up the exact (new_line, old_line) pair for the anchor line. Context
  -- lines carry both — GitLab needs both to form a valid line_code.
  local anchor = hunks.pos(ctx.mr.base_sha, ctx.mr.head_sha, target.path, target.side, ce)
      or (target.side == "new" and { new_line = ce } or { old_line = ce })

  local position = ctx.provider.build_position(ctx.mr, {
    new_path = target.path, old_path = target.path,
    side = target.side,
    new_line = anchor.new_line,
    old_line = anchor.old_line,
  })

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
