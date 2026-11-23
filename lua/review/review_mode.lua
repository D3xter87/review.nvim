-- Review mode: while it is on, new comments are held back as PENDING notes
-- (GitLab draft notes / GitHub pending review) and go out together when the
-- review is submitted. See review.util.pending for the note shape and
-- actions/review_{start,submit,discard}.lua for the mode's own commands.
--
-- `session.review.active` is a LATCH. It is set by "start review" and whenever
-- the server reports a pending review that already exists (started in the
-- browser or in an earlier session), and cleared ONLY by submit / discard.
-- It must never drop on its own — deleting the last pending note, or a failed
-- refresh, would otherwise silently turn the next comment into a public one,
-- which cannot be taken back.

local M = {}

local state_mod = require("review.state")
local notify_util = require("review.util.notify")

---The session's pending-review state, or nil without a session.
---@param tabnr integer
---@return table|nil
function M.get(tabnr)
  local session = state_mod.get_for_tab(tabnr)
  return session and session.review or nil
end

---Folds what a provider fetch reported into the session, keeping the latch.
---`review` is nil when the provider could not tell: nothing changes then.
---@param session table|nil
---@param review table|nil  third value of provider.fetch_mr_discussions
function M.apply(session, review)
  if not session or not review then return end
  local prev = session.review or {}
  review.active = prev.active == true or review.exists == true
  session.review = review
  if review.active and not prev.active then
    -- The mode changes what `c` / `s` / `a` do, so never switch it on silently.
    notify_util.legacy(string.format(
      "pending review found (%d note%s): new comments are held back until you submit or discard it",
      review.count or 0, (review.count or 0) == 1 and "" or "s"))
  end
end

---Clears the latch. Only submit / discard call this.
---@param tabnr integer
function M.finish(tabnr)
  local review = M.get(tabnr)
  if not review then return end
  review.active = false
  review.exists = false
  review.count = 0
  review.summary = nil
end

---Whether the provider can hold comments back at all.
---@param ctx table  ReviewCtx
---@return boolean
function M.is_supported(ctx)
  if type(ctx.provider.create_pending) ~= "function" then return false end
  local review = M.get(ctx.tabnr)
  return not (review and review.supported == false)
end

---Whether a comment written NOW belongs to the pending review. Actions read
---this once, before opening the prompt, and stick to the answer: the prompt's
---title promises it, and a refresh landing while the user types must not
---change where the text goes.
---@param ctx table  ReviewCtx
---@return boolean
function M.is_active(ctx)
  local review = M.get(ctx.tabnr)
  return review ~= nil and review.active == true and M.is_supported(ctx)
end

---Prompt title that says where the text will go.
---@param base string
---@param as_pending boolean
---@return string
function M.title(base, as_pending)
  if as_pending then return base .. " [pending review]" end
  return base
end

---Posts a new thread: held back when `as_pending`, published otherwise.
---@param ctx table  ReviewCtx
---@param as_pending boolean  from M.is_active, read before the prompt opened
---@param body string
---@param position table|nil  provider.build_position result (nil = global)
---@param cb fun(ok: boolean, err: string|nil)
function M.post(ctx, as_pending, body, position, cb)
  if as_pending then
    ctx.provider.create_pending(ctx.remote, ctx.mr.iid, body, position, {}, cb)
  else
    ctx.provider.post_discussion(ctx.remote, ctx.mr.iid, body, position, cb)
  end
end

---Replies to a thread: held back when `as_pending`, published otherwise.
---@param ctx table  ReviewCtx
---@param as_pending boolean
---@param discussion table|nil  the thread object (required when pending)
---@param discussion_id any
---@param body string
---@param cb fun(ok: boolean, err: string|nil)
function M.reply(ctx, as_pending, discussion, discussion_id, body, cb)
  if as_pending then
    if not discussion then
      return cb(false, "thread not found in cache, refresh first")
    end
    ctx.provider.create_pending(ctx.remote, ctx.mr.iid, body, nil, { reply_to = discussion }, cb)
  else
    ctx.provider.add_reply(ctx.remote, ctx.mr.iid, discussion_id, body, cb)
  end
end

return M
