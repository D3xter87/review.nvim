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
---@param discussions table[]
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
        out[#out + 1] = { path = normalize(new_path), line = new_line, side = "new", sign = sign }
      end
      if old_path and old_line then
        out[#out + 1] = { path = normalize(old_path), line = old_line, side = "old", sign = sign }
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

---(Re)places this session's signs in a single buffer. Idempotent.
---@param bufnr integer
function M.place_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end

  local tabnr = vim.api.nvim_get_current_tabpage()
  local anchors = anchors_by_tab[tabnr]
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

  -- Diffview swaps buffers into its layout windows itself; these fire once the
  -- content is in place, and cover the paths where the plain buffer events
  -- don't reach us (initial layout, file switches in the panel).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewDiffBufRead", "DiffviewDiffBufWinEnter", "DiffviewViewPostLayout" },
    callback = function() M.place_all() end,
  })
end

---Recomputes the active session's anchors and re-places them everywhere.
---@param discussions table[]|nil  normalized discussions; defaults to the session's
function M.refresh(discussions)
  ensure_signs()
  M.setup()

  local tabnr = vim.api.nvim_get_current_tabpage()
  if discussions == nil then
    local session = state_mod.get_active()
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
