-- :ReviewClose [branch|!iid]
--
-- Opens an input prompt: any non-empty body is posted as a global discussion
-- before the close call; empty body just closes silently.
--
-- When closing the active session's MR (is_ephemeral=false) we also tear down
-- the local Review session — a closed MR has no actionable review surface.
-- For ephemeral targets we leave any running session intact.

local M = {}

local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    local iid = target_ctx.mr.iid

    input_prompt.open({
      title = "Close !" .. tostring(iid) .. " — optional comment (empty = close without)",
      on_submit = function(lines)
        local body = table.concat(lines, "\n")
        local has_comment = body:gsub("%s", "") ~= ""

        local function do_close()
          target_ctx.provider.close_mr(target_ctx.remote, iid, function(ok, cerr)
            if not ok then
              notify((cerr or "failed to close MR"), vim.log.levels.ERROR); return
            end
            notify(string.format("!%s closed", tostring(iid)))
            -- Only close the local session when the target IS the active one.
            if not is_ephemeral then
              controller.close()
            end
          end)
        end

        if has_comment then
          target_ctx.provider.post_discussion(target_ctx.remote, iid, body, nil, function(ok, perr)
            if not ok then
              notify("failed to post comment: " .. (perr or "?"), vim.log.levels.ERROR); return
            end
            do_close()
          end)
        else
          do_close()
        end
      end,
    })
  end)
end

return M
