-- :ReviewRebase [branch|!iid]
--
-- Rebases the MR's source branch onto its target without disturbing the
-- user's currently-checked-out branch. The rebase runs in a dedicated git
-- worktree at `<repo>/.git/review-rebase/<sanitized_source>`; on success we
-- push the rewritten history with `--force-with-lease` and clean up.
--
-- On conflict we open a brand-new tab, set `:tcd` to the worktree, and
-- launch `:DiffviewOpen` (which auto-detects the merge state). The user
-- resolves and closes the tab — there is no separate continue/abort
-- subcommand:
--
--   * tab closed with no unmerged paths -> `git rebase --continue`
--     (more conflicts re-open another tab; final success pushes & cleans up)
--   * tab closed with unmerged paths    -> `git rebase --abort` + cleanup
--
-- Special case: when `source_branch == current branch`, a worktree would
-- conflict ("branch is already checked out"). We fall back to in-place
-- rebase in the main repo (the user is already on it, so "no branch
-- change" is moot).

local M = {}

local controller = require("review.controller")
local rebase = require("review.git.rebase")
local notify_util = require("review.util.notify")

local function notify(msg, level) notify_util.legacy(msg, level) end

-- ---------------------------------------------------------- success / push

local function finish_with_push(worktree, source, on_done)
  notify_util.progress(string.format("rebased %s, pushing (force-with-lease)...", source))
  rebase.push(worktree, source, function(res)
    if res.ok then
      notify(string.format("!%s rebased & pushed", source))
    else
      notify(string.format(
        "%s rebased locally; push failed: %s (run `git push --force-with-lease` manually)",
        source, res.error or "?"), vim.log.levels.WARN)
    end
    rebase.cleanup(worktree, function()
      if on_done then on_done() end
    end)
  end)
end

-- In-place variant: branch already current; no worktree to clean up. Push
-- runs in the main repo's cwd.
local function finish_in_place_with_push(repo_root, source)
  notify_util.progress(string.format("rebased %s, pushing (force-with-lease)...", source))
  rebase.push(repo_root, source, function(res)
    if res.ok then
      notify(string.format("!%s rebased & pushed", source))
    else
      notify(string.format(
        "%s rebased locally; push failed: %s (run `git push --force-with-lease` manually)",
        source, res.error or "?"), vim.log.levels.WARN)
    end
  end)
end

-- ---------------------------------------------------------- conflict tab

-- Forward declaration — open_conflict_tab and on_tab_closed reference each
-- other (a "continue" that lands in another conflict re-opens the tab).
local open_conflict_tab

local function on_tab_closed(worktree, source, target)
  rebase.check_state(worktree, function(state)
    if state.unmerged then
      -- User closed without resolving everything -> abort.
      notify(string.format("rebase of %s aborted (unmerged files left)", source),
        vim.log.levels.WARN)
      rebase.abort(worktree, function()
        rebase.cleanup(worktree)
      end)
      return
    end
    -- All conflicts resolved (or none mid-rebase) -> continue.
    rebase.continue_rebase(worktree, function(res)
      if res.conflict then
        -- Another batch of conflicts surfaced — re-open a fresh tab.
        notify("more conflicts after continue — opening conflict view")
        open_conflict_tab(worktree, source, target)
        return
      end
      if not res.ok then
        notify("rebase --continue failed: " .. (res.error or "?"),
          vim.log.levels.ERROR)
        rebase.abort(worktree, function() rebase.cleanup(worktree) end)
        return
      end
      finish_with_push(worktree, source)
    end)
  end)
end

-- Per-tab augroup so multiple parallel rebases (different branches) don't
-- step on each other's TabClosed handlers.
local function watch_tab(tabnr, worktree, source, target)
  local group = vim.api.nvim_create_augroup("ReviewRebaseTab_" .. tostring(tabnr), { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      -- TabClosed fires for every tab. We only react when OUR tab handle is
      -- gone (compare against handle, not tabnr-position which can shift).
      if vim.api.nvim_tabpage_is_valid(tabnr) then return end
      pcall(vim.api.nvim_del_augroup_by_name, "ReviewRebaseTab_" .. tostring(tabnr))
      on_tab_closed(worktree, source, target)
    end,
  })
end

open_conflict_tab = function(worktree, source, target)
  vim.cmd("tabnew")
  local tabnr = vim.api.nvim_get_current_tabpage()
  -- Tab-local cwd so user's other tabs aren't affected. fnameescape handles
  -- spaces / special chars on Windows paths.
  vim.cmd("tcd " .. vim.fn.fnameescape(worktree))
  -- Diffview's merge_tool view (configured in plugins/git/diffview.lua) will
  -- pick up the in-progress rebase automatically.
  local ok, err = pcall(vim.cmd, "DiffviewOpen")
  if not ok then
    notify("DiffviewOpen failed: " .. tostring(err) ..
      " — resolve conflicts under " .. worktree .. " then close the tab",
      vim.log.levels.WARN)
  end
  notify(string.format(
    "rebase conflict on %s. Resolve, stage, then close this tab to continue (or close with conflicts to abort).",
    source))
  watch_tab(tabnr, worktree, source, target)
end

-- ---------------------------------------------------------- entry point

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, _is_eph)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    local source = target_ctx.mr.source_branch
    local target = target_ctx.mr.target_branch
    if not source or source == "" or not target or target == "" then
      notify("MR is missing source or target branch", vim.log.levels.WARN); return
    end

    local repo_root = rebase.repo_root()
    if not repo_root then
      notify("not inside a git repo", vim.log.levels.ERROR); return
    end

    -- In-place fallback when the branch is already checked out in the main
    -- repo (worktree add would fail otherwise).
    local current = rebase.current_branch()
    if current == source then
      notify(string.format(
        "%s is the current branch — running in-place rebase on %s", source, target))
      rebase.start_in_place(repo_root, target, function(res)
        if res.ok then return finish_in_place_with_push(repo_root, source) end
        if res.conflict then
          notify("rebase conflict — resolve via your usual diff tools, then run "
              .. "`git rebase --continue` or `git rebase --abort`",
            vim.log.levels.WARN)
          return
        end
        notify((res.error or "rebase failed"), vim.log.levels.ERROR)
      end)
      return
    end

    -- Refuse to stack rebases on the same branch.
    local worktree = rebase.worktree_path(repo_root, source)
    if rebase.worktree_exists(worktree) then
      notify(string.format(
        "rebase already in progress for %s (worktree at %s) — finish or remove it first",
        source, worktree), vim.log.levels.WARN)
      return
    end

    notify_util.progress(string.format("rebasing %s on %s (worktree)...", source, target))
    rebase.start(repo_root, source, target, function(res)
      if res.ok then return finish_with_push(res.worktree, source) end
      if res.conflict then return open_conflict_tab(res.worktree, source, target) end
      if res.branch_busy then
        -- Edge case: branch checked out in some OTHER worktree (not our
        -- current branch). Worktree add can't proceed; bail.
        notify("" .. res.error, vim.log.levels.WARN); return
      end
      notify((res.error or "rebase failed"), vim.log.levels.ERROR)
      if res.worktree then rebase.cleanup(res.worktree) end
    end)
  end)
end

return M
