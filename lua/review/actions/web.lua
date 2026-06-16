-- :ReviewWeb [branch|!iid]
--
-- Opens the MR/PR's web URL in the system default browser. View-only flow,
-- so target resolution is done with state_filter="all" — closed and merged
-- MRs are valid targets too (you may want to refer to a historical PR even
-- after it's been merged).
--
-- Uses `vim.ui.open()` on Neovim 0.10+ (cross-platform); falls back to
-- platform-specific commands (`open` on macOS, `xdg-open` on Linux,
-- `rundll32 url.dll,FileProtocolHandler` on Windows) for older builds.

local M = {}

local controller = require("review.controller")
local notify_util = require("review.util.notify")

local function notify(msg, level) notify_util.legacy(msg, level) end

local function open_external(url)
  if type(vim.ui.open) == "function" then
    local ok, err = pcall(vim.ui.open, url)
    if ok then return true end
    notify_util.warn("vim.ui.open failed: " .. tostring(err))
    -- fall through to OS fallback in case ui.open's own opener was wrong
  end

  local cmd
  if vim.fn.has("mac") == 1 then cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then cmd = { "xdg-open", url }
  elseif vim.fn.has("win32") == 1 then cmd = { "rundll32", "url.dll,FileProtocolHandler", url }
  end
  if not cmd then return false end
  local ok = pcall(vim.system, cmd, { detach = true })
  return ok
end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    local url = target_ctx.mr.web_url
    if not url or url == "" then
      notify_util.warn("MR has no web URL")
      return
    end
    if open_external(url) then
      notify("opened " .. url)
    else
      notify_util.warn("could not open browser - copy URL manually: " .. url)
    end
  end, "all")
end

return M
