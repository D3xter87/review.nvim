local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

local function find_note(target)
  for _, d in ipairs(state_mod.state.discussions or {}) do
    if d.id == target.discussion_id then
      for _, n in ipairs(d.notes or {}) do
        if n.id == target.note_id then return n end
      end
    end
  end
  return nil
end

function M.run(target)
  local ctx = controller.get_ctx()
  if not ctx then return end
  if not target or not target.discussion_id or not target.note_id then
    notify("nothing to edit here", vim.log.levels.WARN)
    return
  end
  local note = find_note(target)
  if not note then
    notify("note not found in cache, refresh first", vim.log.levels.WARN)
    return
  end

  input_prompt.open({
    title = "Edit note",
    prefill = vim.split(note.body or "", "\n", { plain = true }),
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      ctx.provider.update_note(ctx.remote, ctx.mr.iid, target.discussion_id, target.note_id, body, function(ok, err)
        if not ok then
          notify((err or "failed to update"), vim.log.levels.ERROR)
          return
        end
        notify("note updated")
        controller.refresh_discussions()
      end)
    end,
  })
end

return M
