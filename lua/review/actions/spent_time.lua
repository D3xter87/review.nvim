-- :ReviewTime [branch|!iid] [duration]  and panel `e` on the "Spent time" section.
--
-- There is no menu: both entry points go straight to a single duration field,
-- prefilled with the MR's current total. The leading sign picks the operation,
-- so one field covers all three:
--
--   1h30m   set the total to 1h30m   (no sign = absolute)
--   +30m    add 30m
--   -30m    subtract 30m
--   0       clear the spent time
--
-- GitLab only offers add (negative durations subtract) and reset, so "set" is
-- reset-then-add, chained so a failed reset never becomes an add on top of the
-- old total. Subtraction is clamped locally: taking away at least as much as is
-- logged resets to zero instead of sending a negative GitLab would reject with
-- "Time to subtract exceeds the total time spent".
--
-- The panel path calls run({}) — with an empty target, controller.with_target
-- resolves the active session and reports is_ephemeral=false, which is what
-- gates the refresh. An explicit target (`:ReviewTime !319`) resolves
-- ephemerally and must leave any running session's panel untouched.
--
-- When `spent_time_refs_line.enabled` is set, every successful change is also
-- mirrored into the MR description as a "refs <BRANCH> #time <total>" trailer
-- (see util/refs_line.lua). That runs for ephemeral targets too — it edits the
-- MR we just touched, not the session.

local M = {}

local config = require("review.config")
local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")
local refs_line = require("review.util.refs_line")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

-- GitLab measures a workday, not a calendar day: 1d = 8h and 1w = 5d (and
-- 1mo = 4w). We mirror that so the local seconds we compute are comparable
-- with the `total_time_spent` GitLab reports back.
local UNIT_SECONDS = {
  s = 1,
  m = 60,
  h = 3600,
  d = 8 * 3600,
  w = 5 * 8 * 3600,
  mo = 4 * 5 * 8 * 3600,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Converts a GitLab duration ("1h30m", "2d", "1mo 2w", "0") to seconds.
---Doubles as the validator: nil means "not a duration", so nothing is sent.
---@param s string  magnitude only — no leading sign
---@return integer|nil
local function duration_to_seconds(s)
  s = s:lower():gsub("%s+", "")
  if s == "" then return nil end
  if s:match("^0+$") then return 0 end

  local total, pos = 0, 1
  while pos <= #s do
    -- `%a+` is greedy, so "1mo" yields the "mo" unit rather than "m" + junk.
    local n, unit, next_pos = s:match("^(%d+)(%a+)()", pos)
    if not n then return nil end
    local secs = UNIT_SECONDS[unit]
    if not secs then return nil end
    total = total + tonumber(n) * secs
    pos = next_pos
  end
  return total
end

---@class SpentTimeOp
---@field mode "set"|"add"|"subtract"
---@field magnitude string   duration without a sign, as typed
---@field seconds integer    `magnitude` in seconds

---Splits a user-supplied value into an operation and a magnitude.
---@param s string
---@return SpentTimeOp|nil  nil when `s` is not a duration
local function parse_input(s)
  s = trim(s)
  local sign, rest = s:match("^([%+%-])%s*(.+)$")
  local magnitude = sign and trim(rest) or s
  local seconds = duration_to_seconds(magnitude)
  if not seconds then return nil end
  local mode = "set"
  if sign == "+" then mode = "add" elseif sign == "-" then mode = "subtract" end
  return { mode = mode, magnitude = magnitude, seconds = seconds }
end

---Rewrites the description trailer so it reports the total we just changed.
---Best-effort by design: the time is already saved on GitLab's side, so a
---failure here is a warning, never an error that would imply nothing happened.
---@param ctx table
---@param cb fun()  always called, success or not
local function sync_refs_line(ctx, cb)
  local opts = config.get().spent_time_refs_line or {}
  local provider, remote, iid = ctx.provider, ctx.remote, ctx.mr.iid
  if not opts.enabled
      or type(provider.fetch_mr_details) ~= "function"
      or type(provider.update_mr) ~= "function" then
    return cb()
  end

  local function failed(err)
    notify("spent time updated, but refs line sync failed: " .. err, vim.log.levels.WARN)
    cb()
  end

  -- ctx.mr is the pre-mutation snapshot and "set" is reset-then-add, so only a
  -- re-fetch knows the resulting total — and the description to rewrite.
  provider.fetch_mr_details(remote, iid, function(mr, err)
    if not mr then return failed(err or "failed to fetch MR") end
    if not mr.source_branch then return cb() end
    local ts = mr.time_stats or {}
    -- total_time_spent decides whether there is a trailer at all; the human
    -- string is only how it gets rendered.
    local human = (ts.total_time_spent or 0) > 0 and ts.human_total_time_spent or nil
    local body = refs_line.apply(mr.description or "", mr.source_branch, human)
    if not body then return cb() end
    provider.update_mr(remote, iid, { description = body }, function(ok, uerr)
      if not ok then return failed(uerr or "failed to update description") end
      cb()
    end)
  end)
end

---@param ctx table
---@param is_ephemeral boolean
---@param msg string  confirmation text
local function finish(ctx, is_ephemeral, msg)
  -- Sync first, refresh after, so the panel re-renders the new total and the
  -- new description in one pass.
  sync_refs_line(ctx, function()
    notify(msg)
    -- Refreshing acts on the ACTIVE session, so it is only correct when the
    -- target we just mutated is that session.
    if not is_ephemeral then
      controller.refresh_mr_details()
    end
  end)
end

---@param ctx table
---@param is_ephemeral boolean
---@param op SpentTimeOp
local function apply(ctx, is_ephemeral, op)
  local mode, magnitude, seconds = op.mode, op.magnitude, op.seconds
  local iid = ctx.mr.iid
  local provider, remote = ctx.provider, ctx.remote
  local ts = ctx.mr.time_stats or {}
  local current = ts.total_time_spent or 0
  local current_human = ts.human_total_time_spent or "0"

  local function reset(done_msg, then_fn)
    provider.reset_spent_time(remote, iid, function(ok, err)
      if not ok then
        notify((err or "failed to reset spent time"), vim.log.levels.ERROR); return
      end
      if then_fn then return then_fn() end
      finish(ctx, is_ephemeral, done_msg)
    end)
  end

  local function add(duration, done_msg)
    provider.add_spent_time(remote, iid, duration, function(ok, err)
      if not ok then
        notify((err or "failed to add spent time"), vim.log.levels.ERROR); return
      end
      finish(ctx, is_ephemeral, done_msg)
    end)
  end

  if mode == "add" then
    if seconds == 0 then
      notify("nothing to add", vim.log.levels.WARN); return
    end
    add(magnitude, string.format("!%s spent time +%s", tostring(iid), magnitude))
    return
  end

  if mode == "subtract" then
    if seconds == 0 then
      notify("nothing to subtract", vim.log.levels.WARN); return
    end
    -- Would hit zero or go negative → clear instead. GitLab rejects an
    -- over-subtraction outright, and a zero total is what the user meant.
    if seconds >= current then
      reset(string.format("!%s spent time cleared (-%s vs %s logged)",
        tostring(iid), magnitude, current_human))
      return
    end
    add("-" .. magnitude, string.format("!%s spent time -%s", tostring(iid), magnitude))
    return
  end

  -- mode == "set": absolute value, so zero the total first.
  if seconds == 0 then
    reset(string.format("!%s spent time cleared", tostring(iid)))
    return
  end
  reset(nil, function()
    add(magnitude, string.format("!%s spent time set to %s", tostring(iid), magnitude))
  end)
end

local INVALID_MSG = "invalid duration — use 1h30m to set, +30m to add, -30m to subtract, 0 to clear"

---@param ctx table
---@param is_ephemeral boolean
local function prompt(ctx, is_ephemeral)
  local ts = ctx.mr.time_stats or {}
  input_prompt.open({
    -- Prefilled with the current total, so the field always shows where you
    -- are before you decide what to type over it.
    prefill = { ts.human_total_time_spent or "0" },
    title = string.format(
      "Spent time on !%s — 1h30m sets · +30m adds · -30m subtracts · 0 clears",
      tostring(ctx.mr.iid)),
    on_submit = function(lines)
      local raw = trim(table.concat(lines, " "))
      if raw == "" then
        notify("empty duration, skipped", vim.log.levels.WARN); return
      end
      local op = parse_input(raw)
      if not op then
        notify(INVALID_MSG, vim.log.levels.WARN); return
      end
      apply(ctx, is_ephemeral, op)
    end,
  })
end

---@param target_opts { iid?: integer, branch?: string }|nil
---@param duration string|nil  when non-empty, applied directly without the prompt
function M.run(target_opts, duration)
  controller.with_target(target_opts or {}, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    if type(target_ctx.provider.add_spent_time) ~= "function"
        or type(target_ctx.provider.reset_spent_time) ~= "function" then
      notify("provider does not support time tracking", vim.log.levels.WARN); return
    end

    if duration and trim(duration) ~= "" then
      local op = parse_input(duration)
      if not op then
        notify(INVALID_MSG, vim.log.levels.WARN); return
      end
      apply(target_ctx, is_ephemeral, op)
      return
    end

    prompt(target_ctx, is_ephemeral)
  end)
end

return M
