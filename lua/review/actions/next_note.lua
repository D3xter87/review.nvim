-- ]r / [r — walk the review's UNRESOLVED threads without leaving the code.
--
-- Stops only on ❌ threads (resolvable and not yet resolved). ✅ resolved ones
-- are done, and 💬 non-resolvable notes (issue comments, review summaries) have
-- no resolve lifecycle, so neither is something to work through.
--
-- Navigation is by NEW-side line, because that is what both a checked-out
-- working-tree file and the right-hand diff pane show. A thread anchored only
-- to a removed line (old_line, no new_line) has no counterpart in the current
-- code and is skipped.
--
-- Order is (path, line), and it runs off the end of the current file into the
-- next file that still has unresolved threads, wrapping around at the end — so
-- repeated ]r walks the whole review.

local M = {}

local highlights = require("review.ui.highlights")
local diffview_int = require("review.diffview.integration")
local discussion_util = require("review.util.discussion")
local git = require("review.git.rebase")
local notify_util = require("review.util.notify")

local function str(v)
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""))
end

---Every unresolved thread of `session`, as { path, line, id }, sorted by
---(path, line) so "next" is a well-defined step.
---@param session table
---@return table[]
local function targets_for(session)
  local out = {}
  for _, d in ipairs((session and session.discussions) or {}) do
    if discussion_util.is_resolvable(d) and not discussion_util.is_resolved(d) then
      local first = d.notes and d.notes[1]
      local pos = first and first.position
      if type(pos) == "table" then
        local path = str(pos.new_path)
        local line = tonumber(pos.new_line)
        if path and line then
          out[#out + 1] = { path = normalize(path), line = line, id = d.id }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return a.line < b.line
  end)
  return out
end

---Where the cursor currently is, in the same (repo-relative path, new-side
---line) space as the targets. Path is nil when the buffer isn't part of the
---repo — then navigation just starts from the top.
---@return string|nil path, integer line
local function cursor_location()
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  local t = diffview_int.buf_diff_target(buf)
  if t and t.path then return normalize(t.path), line end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil, line end
  name = normalize(name)
  local root = git.repo_root()
  if root then
    root = normalize(root)
    if name:sub(1, #root + 1) == root .. "/" then
      return name:sub(#root + 2), line
    end
  end
  return nil, line
end

---First target strictly after (path, line) in `dir` order, wrapping around.
---@param list table[]
---@param path string|nil
---@param line integer
---@param dir 1|-1
---@return table|nil
local function pick(list, path, line, dir)
  if #list == 0 then return nil end
  if not path then
    return dir > 0 and list[1] or list[#list]
  end
  if dir > 0 then
    for _, t in ipairs(list) do
      if t.path > path or (t.path == path and t.line > line) then return t end
    end
    return list[1]  -- wrap
  end
  for i = #list, 1, -1 do
    local t = list[i]
    if t.path < path or (t.path == path and t.line < line) then return t end
  end
  return list[#list]  -- wrap
end

---Puts the cursor on `line`, clamped to the buffer. A note's line can sit past
---the end of a locally edited file; without the clamp the move would silently
---fail and we'd report a jump that never happened.
local function place_cursor(line)
  local last = vim.api.nvim_buf_line_count(0)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(line, last)), 0 })
  vim.cmd("normal! zvzz")
end

---Moves the cursor to `target`, opening its file when it isn't the current one.
---@param target table
---@param cur_path string|nil
local function goto_target(target, cur_path)
  if cur_path == target.path then
    place_cursor(target.line)
    return true
  end

  -- Different file. Inside diffview, let it switch the file in its own layout;
  -- in an ordinary tab just edit the working-tree file.
  if diffview_int.buf_diff_target(vim.api.nvim_get_current_buf()) then
    local ok, err = diffview_int.jump_to(target.path, target.line, "new")
    if not ok then
      notify_util.warn(err or ("cannot open " .. target.path))
      return false
    end
    return true
  end

  local root = git.repo_root()
  if not root then
    notify_util.warn("not a git repository")
    return false
  end
  local abs = normalize(root) .. "/" .. target.path
  if vim.fn.filereadable(abs) ~= 1 then
    notify_util.warn(target.path .. " is not in the working tree")
    return false
  end
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  place_cursor(target.line)
  return true
end

---@param dir 1|-1  1 = next (]r), -1 = previous ([r)
function M.run(dir)
  local session = highlights.active_session()
  if not session then
    notify_util.progress("no review session applies to this tab")
    return
  end

  local list = targets_for(session)
  if #list == 0 then
    notify_util.event("no unresolved threads")
    return
  end

  local cur_path, cur_line = cursor_location()
  local target = pick(list, cur_path, cur_line, dir)
  if not target then return end

  if goto_target(target, cur_path) then
    -- Which one of how many, so walking the review has a sense of progress.
    local idx
    for i, t in ipairs(list) do if t == target then idx = i end end
    notify_util.progress(string.format("unresolved %d/%d — %s:%d",
      idx or 0, #list, target.path, target.line))
  end
end

return M
