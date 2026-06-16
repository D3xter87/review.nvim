-- Toggle resolve state across every resolvable discussion. If any thread is
-- still unresolved, resolve them all; otherwise (everything already resolved)
-- unresolve them all. After the batch completes we refresh discussions once.

local M = {}

local controller = require("review.controller")
local state_mod = require("review.state")
local discussion_util = require("review.util.discussion")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

function M.run()
  local ctx = controller.get_ctx()
  if not ctx then return end

  local discussions = state_mod.state.discussions or {}
  local resolvable = {}
  local unresolved_count = 0
  for _, d in ipairs(discussions) do
    if discussion_util.is_resolvable(d) then
      table.insert(resolvable, d)
      if not discussion_util.is_resolved(d) then
        unresolved_count = unresolved_count + 1
      end
    end
  end

  if #resolvable == 0 then
    notify("no resolvable threads", vim.log.levels.WARN)
    return
  end

  local desired = unresolved_count > 0  -- any unresolved → resolve all; else flip
  local pending = 0
  local errors = 0
  local changed = 0

  for _, d in ipairs(resolvable) do
    local already = discussion_util.is_resolved(d)
    if already ~= desired then
      pending = pending + 1
    end
  end

  if pending == 0 then
    -- Nothing to do (e.g. desired matches state for every thread).
    notify("all threads already in target state")
    return
  end

  for _, d in ipairs(resolvable) do
    local already = discussion_util.is_resolved(d)
    if already ~= desired then
      ctx.provider.resolve_discussion(ctx.remote, ctx.mr.iid, d.id, desired, function(ok, err)
        if not ok then
          errors = errors + 1
          notify((err or "failed for one thread"), vim.log.levels.WARN)
        else
          changed = changed + 1
        end
        pending = pending - 1
        if pending == 0 then
          notify(string.format("%d thread(s) %s%s",
            changed,
            desired and "resolved" or "unresolved",
            errors > 0 and (" (" .. errors .. " failed)") or ""))
          controller.refresh_discussions()
        end
      end)
    end
  end
end

return M
