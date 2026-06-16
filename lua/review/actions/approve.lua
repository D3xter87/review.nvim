-- :ReviewApprove [branch|!iid]
--
-- No arg: approve the active session's MR; or, if no session, discover open
-- MRs on the current branch (vim.ui.select if >1) and approve the chosen one.
-- With arg: approve the specified MR/PR — does not affect a running session.

local M = {}

local controller = require("review.controller")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    target_ctx.provider.approve(target_ctx.remote, target_ctx.mr.iid, function(ok, aerr)
      if not ok then
        notify((aerr or "approve failed"), vim.log.levels.ERROR); return
      end
      notify("!" .. tostring(target_ctx.mr.iid) .. " approved")
      -- Refresh MR details only when we acted on the active session, so the
      -- panel reflects the new approval state.
      if not is_ephemeral then
        controller.refresh_mr_details()
      end
    end)
  end)
end

return M
