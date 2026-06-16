-- Diffview integration: opens a 3-dot range (merge-base) so the diff matches
-- what GitLab/GitHub show in their MR view, then exposes helpers for actions
-- (path/side detection, jump-to-file).

local M = {}

local state_mod = require("review.state")

---Opens DiffviewOpen for the MR's base...head range.
---@param mr table  normalized MR with base_sha + head_sha
function M.open(mr)
  if not mr or not mr.base_sha or not mr.head_sha then
    return false, "MR is missing base/head sha"
  end
  local cmd = string.format("DiffviewOpen %s...%s", mr.base_sha, mr.head_sha)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then return false, tostring(err) end
  state_mod.state.diffview_tabnr = vim.api.nvim_get_current_tabpage()
  return true
end

---Closes the diffview tab if still open. Safe to call when already closed.
---When the diffview tab happens to be the only tab in nvim, DiffviewClose
---would close the last tab and exit nvim entirely — we open an empty fallback
---tab first to keep the editor alive.
function M.close()
  local tabnr = state_mod.state.diffview_tabnr
  if not tabnr then return end
  if vim.api.nvim_tabpage_is_valid(tabnr) then
    if vim.fn.tabpagenr("$") <= 1 then
      pcall(vim.cmd, "tabnew")
    end
    pcall(vim.api.nvim_set_current_tabpage, tabnr)
    pcall(vim.cmd, "DiffviewClose")
  end
  state_mod.state.diffview_tabnr = nil
end

---Returns true if the given buffer belongs to a diffview view (file panel or
---a diff content buffer).
---@param bufnr integer
function M.is_diffview_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^diffview://") then return true end
  local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok and (ft == "DiffviewFiles" or ft == "DiffviewFileHistory") then return true end
  return false
end

---For the current window in diffview, returns { path, side }.
---side ∈ { "old", "new" } based on diffview's own view layout.
---Returns nil if we can't determine it.
---@return { path: string, side: "old"|"new" }|nil
function M.current_diff_target()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local view = lib.get_current_view()
  if not view or not view.cur_layout then return nil end

  local cur_win = vim.api.nvim_get_current_win()
  local layout = view.cur_layout
  local file = view.panel and view.panel.cur_file
  if not file then return nil end

  local side
  if layout.a and layout.a.file and layout.a.file.bufnr and vim.fn.win_findbuf(layout.a.file.bufnr)[1] == cur_win then
    side = "old"
  elseif layout.b and layout.b.file and layout.b.file.bufnr and vim.fn.win_findbuf(layout.b.file.bufnr)[1] == cur_win then
    side = "new"
  end

  if not side then
    -- fallback: pick by which window holds the current buffer
    local cur_buf = vim.api.nvim_win_get_buf(cur_win)
    if layout.a and layout.a.file and layout.a.file.bufnr == cur_buf then side = "old" end
    if layout.b and layout.b.file and layout.b.file.bufnr == cur_buf then side = "new" end
  end

  if not side then return nil end

  local path = file.path
  return { path = path, side = side }
end

---Jumps to the diffview view, focuses the file at `path`, and moves cursor to
---`line`. `side` selects which window (old/new). Used by jump_to_comment.
---@param path string
---@param line integer
---@param side "old"|"new"
function M.jump_to(path, line, side)
  local tabnr = state_mod.state.diffview_tabnr
  if not tabnr or not vim.api.nvim_tabpage_is_valid(tabnr) then
    return false, "diffview tab not open"
  end
  vim.api.nvim_set_current_tabpage(tabnr)

  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return false, "diffview not loaded" end
  local view = lib.get_current_view()
  if not view then return false, "no current diffview view" end

  -- Find the file entry by path and select it via diffview actions.
  local files = view.panel and view.panel:ordered_file_list() or {}
  local target
  for _, f in ipairs(files) do
    if f.path == path then target = f; break end
  end
  if not target then return false, "file not in diffview: " .. path end

  if view.set_file then
    pcall(view.set_file, view, target, true)
  end

  vim.schedule(function()
    local layout = view.cur_layout
    local target_bufnr
    if side == "old" and layout and layout.a and layout.a.file then
      target_bufnr = layout.a.file.bufnr
    elseif layout and layout.b and layout.b.file then
      target_bufnr = layout.b.file.bufnr
    end
    if target_bufnr then
      local wins = vim.fn.win_findbuf(target_bufnr)
      if wins and wins[1] then
        vim.api.nvim_set_current_win(wins[1])
        pcall(vim.api.nvim_win_set_cursor, wins[1], { line, 0 })
      end
    end
  end)

  return true
end

return M
