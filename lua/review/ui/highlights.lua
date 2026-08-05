-- Icons + signs for discussions.
--   💬 ReviewComment      non-resolvable note (global / issue / review summary)
--   ❌ ReviewUnresolved   resolvable thread with at least one unresolved note
--   ✅ ReviewResolved     resolvable thread fully resolved
--
-- Non-resolvable notes (issue comments in GitHub, review summaries, GitLab
-- individual notes) are conceptually just messages — they don't have a "to
-- resolve" lifecycle, so they get the speech-bubble icon instead of ❌.
--
-- Placement is *lazy*: diffview only creates a file's buffers the first time
-- you open that file, so a one-shot pass at session start would only ever mark
-- the file that happens to be loaded right then (which is why, before this,
-- icons appeared only for notes created in the running session — the refresh
-- that followed the POST ran while that file's buffer was open). Instead we
-- cache the anchors per session tab and (re)place them every time a diff
-- buffer shows up.

local M = {}

local discussion_util = require("review.util.discussion")
local diffview_int = require("review.diffview.integration")
local state_mod = require("review.state")
local git = require("review.git.rebase")

local SIGN_GROUP = "review_comment"
local SIGN_COMMENT = "ReviewComment"
local SIGN_UNRESOLVED = "ReviewUnresolved"
local SIGN_RESOLVED = "ReviewResolved"
local AUGROUP = "ReviewSigns"

M.ICON_COMMENT = "💬"
M.ICON_UNRESOLVED = "❌"
M.ICON_RESOLVED = "✅"

---Gutter anchors per session tabpage: { path, line, side, sign }[].
---@type table<integer, table[]>
local anchors_by_tab = {}

local function ensure_signs()
  if not vim.fn.sign_getdefined(SIGN_COMMENT)[1] then
    vim.fn.sign_define(SIGN_COMMENT, { text = M.ICON_COMMENT, texthl = "DiagnosticInfo" })
  end
  if not vim.fn.sign_getdefined(SIGN_UNRESOLVED)[1] then
    vim.fn.sign_define(SIGN_UNRESOLVED, { text = M.ICON_UNRESOLVED, texthl = "DiagnosticError" })
  end
  if not vim.fn.sign_getdefined(SIGN_RESOLVED)[1] then
    vim.fn.sign_define(SIGN_RESOLVED, { text = M.ICON_RESOLVED, texthl = "DiagnosticOk" })
  end
end

---Returns the icon for a discussion's state. Used by the panel and gutter.
---@param d table
function M.icon_for(d)
  if not discussion_util.is_resolvable(d) then
    return M.ICON_COMMENT
  end
  if discussion_util.is_resolved(d) then
    return M.ICON_RESOLVED
  end
  return M.ICON_UNRESOLVED
end

local function sign_for(d)
  if not discussion_util.is_resolvable(d) then return SIGN_COMMENT end
  if discussion_util.is_resolved(d) then return SIGN_RESOLVED end
  return SIGN_UNRESOLVED
end

---JSON nulls arrive as vim.NIL — treat them (and non-strings) as absent.
local function str(v)
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""))
end

---Flattens discussions into per-side gutter anchors. A note anchored to a
---context line carries both old_line and new_line — it gets a sign in both
---panes, each at its own line number.
---
---Each anchor keeps a reference to the discussion it came from, so the same
---index that decides WHERE an icon goes also answers "which thread is on this
---line?" for |review-note-preview| (M.discussions_at). The reference is safe
---to hold: M.refresh rebuilds every anchor whenever the session's discussions
---are re-fetched.
---@param discussions table[]|nil
---@return table[]
local function anchors_for(discussions)
  local out = {}
  for _, d in ipairs(discussions or {}) do
    local sign = sign_for(d)
    -- Use the first note's position (the anchor); replies inherit it.
    local first = d.notes and d.notes[1]
    local pos = first and first.position
    if type(pos) == "table" and pos ~= vim.NIL then
      local new_path, old_path = str(pos.new_path), str(pos.old_path)
      local new_line, old_line = tonumber(pos.new_line), tonumber(pos.old_line)
      if new_path and new_line then
        out[#out + 1] = { path = normalize(new_path), line = new_line, side = "new",
          sign = sign, discussion = d }
      end
      if old_path and old_line then
        out[#out + 1] = { path = normalize(old_path), line = old_line, side = "old",
          sign = sign, discussion = d }
      end
    end
  end
  return out
end

---Resolves what a buffer renders. Prefers diffview's own bookkeeping; falls
---back to suffix-matching the buffer name (working-tree buffers of a LOCAL
---rev are plain files, not `diffview://` ones).
---@param bufnr integer
---@return { path: string|nil, oldpath: string|nil, side: string|nil, bufname: string|nil }|nil
local function buf_target(bufnr)
  local t = diffview_int.buf_diff_target(bufnr)
  if t then
    return {
      path = normalize(t.path),
      oldpath = t.oldpath and normalize(t.oldpath) or nil,
      side = t.side,
    }
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  -- A `diffview://` buffer that diffview itself didn't claim above is one of
  -- its panels, not file content — it renders no source line, so it can't
  -- carry an anchor. Without this it would fall through as a working-tree
  -- buffer and match nothing, which is harmless for signs but makes the
  -- "is this buffer reviewable?" question below answer yes.
  if name:match("^diffview://") then return nil end
  return { bufname = normalize(name), side = "new" }
end

local function anchor_matches(anchor, target)
  if anchor.side ~= target.side then return false end
  if target.bufname then
    -- Name-based fallback: the buffer path must END on the repo-relative path,
    -- on a component boundary (so "foo/bar.lua" doesn't match "myfoo/bar.lua").
    local name = target.bufname
    return name == anchor.path or name:sub(-(#anchor.path + 1)) == ("/" .. anchor.path)
  end
  local want = (target.side == "old" and target.oldpath) or target.path
  return want == anchor.path
end

-- `current_branch` shells out to git, and a single place_all() pass asks for it
-- once per buffer, so the answer is cached for a moment. A branch switch is a
-- deliberate, out-of-editor act; noticing it up to a second late is fine, and
-- refresh() drops the cache anyway.
local BRANCH_TTL_MS = 1000
local branch_cache = { value = nil, at = nil }

local function now_ms()
  local uv = vim.uv or vim.loop
  return uv and uv.now() or 0
end

local function current_branch()
  local t = now_ms()
  if branch_cache.at and (t - branch_cache.at) < BRANCH_TTL_MS then
    return branch_cache.value
  end
  local ok, b = pcall(git.current_branch)
  branch_cache.value = ok and b or nil
  branch_cache.at = t
  return branch_cache.value
end

---The session whose notes apply to whatever the current tabpage is showing.
---
---In a review session's own tab: that session, so two concurrent reviews of the
---same file stay independent.
---
---In any OTHER tab the buffers are plain working-tree files, and the session
---that explains them is the one whose source branch is checked out — the
---"review running in a background tab while I read the code locally" case.
---Keying on the branch rather than just taking any live session stops an
---unrelated review from decorating the same path/line numbers with notes that
---were never written about this code.
---@return ReviewSession|nil session
---@return integer|nil tabnr  the tabpage that session is anchored to
function M.active_session()
  local tabnr = vim.api.nvim_get_current_tabpage()
  if anchors_by_tab[tabnr] then
    return state_mod.get_for_tab(tabnr), tabnr
  end

  local branch = current_branch()
  if not branch then return nil end
  for t, session in state_mod.iter() do
    local src = session.mr and session.mr.source_branch
    if session.branch == branch or src == branch then
      return session, t
    end
  end
  return nil
end

---@return table[]|nil
local function active_anchors()
  local _, tabnr = M.active_session()
  return tabnr and anchors_by_tab[tabnr] or nil
end

---(Re)places this session's signs in a single buffer. Idempotent.
---@param bufnr integer
function M.place_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end

  local anchors = active_anchors()
  if not anchors then return end

  local target = buf_target(bufnr)
  if not target then return end

  ensure_signs()
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, a in ipairs(anchors) do
    if a.line >= 1 and a.line <= line_count and anchor_matches(a, target) then
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, a.sign, bufnr,
        { lnum = a.line, priority = 100 })
    end
  end
end

---True when `bufnr` is something this session's anchors could apply to — a
---diffview content buffer or a named working-tree file. Panels, scratch
---buffers and unnamed buffers are not. Used to decide where the
---|review-note-preview| key-map belongs.
---@param bufnr integer
---@return boolean
function M.is_review_target(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  return buf_target(bufnr) ~= nil
end

---Anchors of the tab's session that sit on `lnum` of `bufnr`, in anchor order.
---
---This is the read side of the very index that places the gutter icons, so it
---holds the invariant users care about: the preview is available exactly where
---an icon is visible — including in a plain editing tab whose branch is under
---review in a background tab (see active_anchors). Resolution depends on the
---current tabpage, so it must never be cached by bufnr: the same working-tree
---file open in two session tabs legitimately answers differently in each.
---@param bufnr integer
---@param lnum integer
---@return table[] hits  anchors: { path, line, side, sign, discussion }
---@return boolean has_target  false when the buffer isn't reviewable at all
function M.discussions_at(bufnr, lnum)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return {}, false end
  local target = buf_target(bufnr)
  if not target then return {}, false end

  local anchors = active_anchors()
  if not anchors then return {}, true end

  -- A note on a context line yields one anchor per side; `anchor_matches`
  -- already filters by side, but dedup makes the "one entry per thread"
  -- contract independent of that.
  local out, seen = {}, {}
  for _, a in ipairs(anchors) do
    if a.line == lnum and a.discussion and not seen[a.discussion]
        and anchor_matches(a, target) then
      seen[a.discussion] = true
      out[#out + 1] = a
    end
  end
  return out, true
end

---(Re)places signs across every loaded buffer.
function M.place_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.place_buf(bufnr)
    end
  end
end

---Wires the buffer-load hooks. Idempotent — one set of autocmds serves every
---session; each callback resolves the anchors of the tab it fires in.
function M.setup()
  if vim.fn.exists("#" .. AUGROUP) == 1 then return end
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufReadPost" }, {
    group = group,
    callback = function(args) M.place_buf(args.buf) end,
  })

  -- Switching tabs re-fires no buffer event for buffers that are already
  -- displayed, but it DOES change which session's anchors apply (see
  -- active_anchors). Without this, walking from the review tab into an editing
  -- tab — or back — would leave the previous tab's icons in place.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function() M.place_all() end,
  })

  -- Diffview swaps buffers into its layout windows itself; these fire once the
  -- content is in place, and cover the paths where the plain buffer events
  -- don't reach us (initial layout, file switches in the panel).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewDiffBufRead", "DiffviewDiffBufWinEnter", "DiffviewViewPostLayout" },
    callback = function() M.place_all() end,
  })
end

---Recomputes a session's anchors and re-places them everywhere.
---@param discussions table[]|nil  normalized discussions; defaults to the session's
---@param tabnr integer|nil  the session's tabpage; defaults to the current one.
---  Must be passed when refreshing from OUTSIDE the session's tab (e.g. after
---  resolving a thread from an editing tab), otherwise the anchors would be
---  filed under the wrong tabpage — where clear() would never find them and the
---  branch fallback in active_session() would be bypassed.
function M.refresh(discussions, tabnr)
  ensure_signs()
  M.setup()
  branch_cache.at = nil  -- a session may have just started on a new branch

  tabnr = tabnr or vim.api.nvim_get_current_tabpage()
  if discussions == nil then
    local session = state_mod.get_for_tab(tabnr)
    discussions = session and session.discussions
  end
  anchors_by_tab[tabnr] = anchors_for(discussions)

  -- Drop anchors of tabs that went away without a close() (e.g. :tabclose).
  for tab in pairs(anchors_by_tab) do
    if not vim.api.nvim_tabpage_is_valid(tab) then anchors_by_tab[tab] = nil end
  end

  M.place_all()
end

---Removes the current session's signs. Tears the hooks down with the last one.
function M.clear()
  anchors_by_tab[vim.api.nvim_get_current_tabpage()] = nil
  pcall(vim.fn.sign_unplace, SIGN_GROUP)
  if next(anchors_by_tab) == nil then
    pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  else
    -- Other sessions are still live: restore what the blanket unplace wiped.
    M.place_all()
  end
end

return M
