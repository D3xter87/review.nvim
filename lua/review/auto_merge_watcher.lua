-- Background watcher for scheduled auto-merges.
--
-- After :ReviewMerge → "Set auto-merge", the MR is left in a "merge when
-- pipeline succeeds" state. The user is no longer reviewing — we want them
-- to find out asynchronously when the merge actually lands or when the
-- pipeline fails and the auto-merge is cancelled.
--
-- The watcher polls the MR every `auto_merge_watcher.poll_interval_ms`
-- (default 30 s) and resolves on the first terminal signal:
--
--   * mr.state == "merged"                          → success notification
--   * mr.state == "closed"                          → cancelled (MR closed)
--   * merge_when_pipeline_succeeds flips to false   → cancelled (pipeline
--     failure / manual cancel — both providers expose this flag and clear
--     it the moment auto-merge is no longer pending)
--
-- After `auto_merge_watcher.timeout_ms` (default 1 h) without resolution we
-- stop and inform the user — auto-merges sometimes get stuck and we don't
-- want to poll forever. Set `auto_merge_watcher.enabled = false` in setup()
-- to disable polling entirely (the merge dialog still schedules auto-merge
-- on the forge; you just won't get notified when it lands).
--
-- Watchers live for the lifetime of the Neovim process; they intentionally
-- survive review-session teardown so the user gets the verdict regardless
-- of what they do in the editor afterwards.

local M = {}

local notify_util = require("review.util.notify")

local watchers = {}  -- key (string)  → { timer, started_at, ... }

-- Reads `auto_merge_watcher` block from user config; falls back to
-- conservative defaults so the module still works if the user wiped the
-- config table.
local function watcher_cfg()
  local cfg = require("review.config").get()
  local w = cfg.auto_merge_watcher or {}
  return {
    enabled = w.enabled ~= false,
    interval_ms = tonumber(w.poll_interval_ms) or (30 * 1000),
    timeout_ms = tonumber(w.timeout_ms) or (60 * 60 * 1000),
  }
end

local function key_for(remote, iid)
  return tostring(remote.host or "?") .. ":" .. tostring(remote.path or "?") .. "!" .. tostring(iid)
end

local function stop(key)
  local w = watchers[key]
  if not w then return end
  if w.timer and not w.timer:is_closing() then
    pcall(w.timer.stop, w.timer)
    pcall(w.timer.close, w.timer)
  end
  watchers[key] = nil
end

local function elapsed_ms(w)
  return (vim.uv or vim.loop).now() - w.started_at
end

-- One polling tick — fetches fresh MR state and decides whether to resolve.
local function tick(key)
  local w = watchers[key]
  if not w then return end

  if elapsed_ms(w) > w.timeout_ms then
    notify_util.event(string.format(
      "!%s auto-merge still pending after timeout - check forge UI",
      tostring(w.iid)))
    stop(key)
    return
  end

  w.provider.fetch_mr_details(w.remote, w.iid, function(mr, _)
    if not watchers[key] then return end  -- cancelled while in flight
    if not mr then
      -- Transient API failure — keep watching; we'll retry next tick.
      return
    end

    if mr.state == "merged" then
      notify_util.event(string.format("!%s auto-merge completed (merged into %s)",
        tostring(mr.iid), mr.target_branch or "?"))
      stop(key)
      return
    end

    if mr.state == "closed" then
      notify_util.warn(string.format(
        "!%s closed before auto-merge - auto-merge cancelled",
        tostring(mr.iid)))
      stop(key)
      return
    end

    if mr.merge_when_pipeline_succeeds == false then
      -- Most likely cause: pipeline failed and the forge cancelled the
      -- pending merge. Could also be a manual cancel via the UI; either
      -- way the original :ReviewMerge intent didn't go through.
      notify_util.warn(string.format(
        "!%s auto-merge cancelled - pipeline failed or merge blocked",
        tostring(mr.iid)))
      stop(key)
      return
    end
    -- Otherwise still pending; do nothing, next tick will retry.
  end)
end

---Start watching an auto-merge for the given context. If a watcher already
---exists for this (remote, iid) pair we reuse it instead of stacking timers.
---@param ctx table  { provider, remote, mr } from controller.with_target
function M.watch(ctx)
  if not ctx or not ctx.mr or not ctx.mr.iid then return end
  local cfg = watcher_cfg()
  if not cfg.enabled then return end

  local key = key_for(ctx.remote, ctx.mr.iid)
  if watchers[key] then return end  -- already polling this MR

  local timer = (vim.uv or vim.loop).new_timer()
  watchers[key] = {
    timer = timer,
    provider = ctx.provider,
    remote = ctx.remote,
    iid = ctx.mr.iid,
    started_at = (vim.uv or vim.loop).now(),
    timeout_ms = cfg.timeout_ms,
  }

  timer:start(cfg.interval_ms, cfg.interval_ms, vim.schedule_wrap(function()
    tick(key)
  end))
end

---Stop all watchers — used when Neovim is exiting or for explicit cleanup.
function M.stop_all()
  for key in pairs(watchers) do
    stop(key)
  end
end

---Returns the number of active watchers (useful for debugging / status line).
function M.count()
  local n = 0
  for _ in pairs(watchers) do n = n + 1 end
  return n
end

return M
