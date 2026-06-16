-- :ReviewRevoke [branch|!iid]  — see actions/approve.lua for arg semantics.

local M = {}

local controller = require("review.controller")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    target_ctx.provider.unapprove(target_ctx.remote, target_ctx.mr.iid, function(ok, uerr)
      if not ok then
        notify((uerr or "revoke failed"), vim.log.levels.ERROR); return
      end
      notify("!" .. tostring(target_ctx.mr.iid) .. " approval revoked")
      if not is_ephemeral then
        controller.refresh_mr_details()
      end
    end)
  end)
end

return M
