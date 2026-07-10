-- Diffview integration: opens a 3-dot range (merge-base) so the diff matches
-- what GitLab/GitHub show in their MR view, then exposes helpers for actions
-- (path/side detection, jump-to-file).

local M = {}

local state_mod = require("review.state")
local git = require("review.git.rebase")
local notify_util = require("review.util.notify")

---Verifies a rev resolves to a commit in the local object store.
---@param repo string  repo root (for -C)
---@param sha string
---@param cb fun(present: boolean)
local function rev_present(repo, sha, cb)
  git._run({ "git", "-C", repo, "rev-parse", "-q", "--verify", sha .. "^{commit}" },
    nil, nil, function(res) cb(res.ok) end)
end

---Ensures base_sha and head_sha exist locally, fetching them from origin when
---they don't. When reviewing someone else's MR (e.g. via :ReviewRequest) the
---source branch is usually not present locally, so the SHAs GitLab reports in
---diff_refs aren't in the object store and DiffviewOpen fails with
---"Not a valid commit name". The merge-base (base_sha) is an ancestor of the
---source branch tip, so fetching source + target branches brings both revs.
---@param repo string  repo root the commits must live in
---@param mr table  normalized MR with base_sha/head_sha + source/target branch
---@param cb fun(ok: boolean, err: string|nil)
local function ensure_revs(repo, mr, cb)
  rev_present(repo, mr.base_sha, function(base_ok)
    rev_present(repo, mr.head_sha, function(head_ok)
      if base_ok and head_ok then return cb(true) end

      notify_util.progress("fetching MR commits...")
      local args = { "git", "-C", repo, "fetch", "origin" }
      if mr.source_branch then table.insert(args, mr.source_branch) end
      if mr.target_branch and mr.target_branch ~= mr.source_branch then
        table.insert(args, mr.target_branch)
      end

      git._run(args, nil, nil, function(fres)
        if not fres.ok then
          return cb(false, "git fetch failed: " ..
            ((fres.stderr or "(no stderr)"):gsub("%s+$", "")) ..
            " - check your network / VPN and retry")
        end
        -- Re-verify: a successful fetch doesn't guarantee the exact SHAs are
        -- reachable (e.g. the source branch was force-pushed or deleted).
        rev_present(repo, mr.base_sha, function(b2)
          rev_present(repo, mr.head_sha, function(h2)
            if b2 and h2 then return cb(true) end
            cb(false, "MR commits not found on origin after fetch " ..
              "(source branch may have been deleted or force-pushed)")
          end)
        end)
      end)
    end)
  end)
end

---Opens DiffviewOpen for the MR's base...head range. Fetches the commits from
---origin first when they aren't present locally, and pins diffview to the
---resolved repo with `-C`. Async: `cb(ok, err)`.
---
---The `-C<repo>` is essential inside git submodules: without it diffview infers
---the repo from the active buffer / cwd, which for a submodule working tree can
---resolve to the SUPERPROJECT — whose object store doesn't contain the MR's
---commits — so `git merge-base base head` fails with "Not a valid commit name"
---and the diff never opens. Pinning to `repo` (where we just verified the
---commits exist) makes it deterministic.
---@param mr table  normalized MR with base_sha + head_sha
---@param cb fun(ok: boolean, err: string|nil)
function M.open(mr, cb)
  if not mr or not mr.base_sha or not mr.head_sha then
    return cb(false, "MR is missing base/head sha")
  end
  local repo = git.repo_root()
  if not repo then return cb(false, "not a git repository") end

  ensure_revs(repo, mr, function(ok, err)
    if not ok then return cb(false, err) end

    local cmd = string.format("DiffviewOpen -C%s %s...%s",
      vim.fn.fnameescape(repo), mr.base_sha, mr.head_sha)
    local vok, verr = pcall(vim.cmd, cmd)
    if not vok then return cb(false, tostring(verr)) end

    -- diffview logs rev-parse failures instead of raising them, so a
    -- successful pcall doesn't mean a view opened. Confirm one did, otherwise
    -- report a real error instead of silently leaving the session diff-less.
    local lok, lib = pcall(require, "diffview.lib")
    if lok and not lib.get_current_view() then
      return cb(false, "diffview did not open the diff (see :messages)")
    end

    state_mod.state.diffview_tabnr = vim.api.nvim_get_current_tabpage()
    cb(true)
  end)
end

---Runs `DiffviewOpen <rev_arg>` pinned to the current repo via `-C`, so it
---works inside git submodules (see M.open for why). Best-effort — used for the
---"open a single commit's diff" panel action. Returns false + err on failure.
---@param rev_arg string  e.g. "<sha>^!"
---@return boolean ok, string|nil err
function M.open_rev(rev_arg)
  local repo = git.repo_root()
  local cmd = repo
    and string.format("DiffviewOpen -C%s %s", vim.fn.fnameescape(repo), rev_arg)
    or ("DiffviewOpen " .. rev_arg)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then return false, tostring(err) end
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
