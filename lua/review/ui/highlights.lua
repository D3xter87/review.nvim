-- Icons + signs for discussions.
--   💬 ReviewComment      non-resolvable note (global / issue / review summary)
--   ❌ ReviewUnresolved   resolvable thread with at least one unresolved note
--   ✅ ReviewResolved     resolvable thread fully resolved
--
-- Non-resolvable notes (issue comments in GitHub, review summaries, GitLab
-- individual notes) are conceptually just messages — they don't have a "to
-- resolve" lifecycle, so they get the speech-bubble icon instead of ❌.

local M = {}

local discussion_util = require("review.util.discussion")

local SIGN_GROUP = "review_comment"
local SIGN_COMMENT = "ReviewComment"
local SIGN_UNRESOLVED = "ReviewUnresolved"
local SIGN_RESOLVED = "ReviewResolved"

M.ICON_COMMENT = "💬"
M.ICON_UNRESOLVED = "❌"
M.ICON_RESOLVED = "✅"

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

---@param discussions table[]  normalized discussions
function M.refresh(discussions)
  ensure_signs()
  pcall(vim.fn.sign_unplace, SIGN_GROUP)

  for _, d in ipairs(discussions or {}) do
    local sign_name
    if not discussion_util.is_resolvable(d) then
      sign_name = SIGN_COMMENT
    elseif discussion_util.is_resolved(d) then
      sign_name = SIGN_RESOLVED
    else
      sign_name = SIGN_UNRESOLVED
    end
    -- Use the first note's position (the anchor); replies inherit it.
    local first = d.notes and d.notes[1]
    local pos = first and first.position
    if type(pos) == "table" and pos ~= vim.NIL then
      local path = pos.new_path or pos.old_path
      local line = pos.new_line or pos.old_line
      if path and line and tonumber(line) then
        M._place_for_path(path, tonumber(line), sign_name)
      end
    end
  end
end

function M._place_for_path(path, line, sign_name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and (name:sub(-#path) == path or name:find(path, 1, true)) then
        pcall(vim.fn.sign_place, 0, SIGN_GROUP, sign_name, bufnr,
          { lnum = line, priority = 100 })
      end
    end
  end
end

function M.clear()
  pcall(vim.fn.sign_unplace, SIGN_GROUP)
end

return M
