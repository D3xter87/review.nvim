-- :ReviewRebase [branch|!iid]
--
-- Rebases the MR's source branch onto its target on origin, without touching
-- any local branch: the rebase starts from `origin/<source>`, goes onto
-- `origin/<target>` and the result is pushed back to `origin/<source>`. It
-- runs in a dedicated detached git worktree at
-- `<repo>/.git/review-rebase/<sanitized_source>`, so it doesn't matter which
-- branch the user has checked out (the source branch itself included), nor
-- whether their local copy of it is stale. The push is a force-with-lease
-- against the sha the rebase started from: anything pushed to the branch in
-- the meantime makes it fail rather than be overwritten.
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
-- After the push, an open review of the MR is reloaded on the new head.

local M = {}

local controller = require("review.controller")
local rebase = require("review.git.rebase")
local notify_util = require("review.util.notify")

local function notify(msg, level) notify_util.legacy(msg, level) end

-- ---------------------------------------------------------- session sync

-- How long to wait for the forge to pick up the push: GitLab recomputes an
-- MR's diff_refs asynchronously, so for a moment after the push it still
-- reports the pre-rebase head.
local POLL_INTERVAL_MS = 1000
local POLL_TRIES = 15

---Brings an open review of the MR onto the rebased branch. Its snapshot still
---holds the old base/head: :ReviewMerge would send a sha the forge rejects,
---and the diff and comment anchors would describe history that no longer
---exists. Waits until the forge reports `head` (the sha just pushed), then
---rebuilds the session — what closing and reopening the review does by hand.
---@param mr_ctx table  { provider, remote, mr } of the rebased MR
---@param head string|nil  HEAD of the rebased worktree; nil = don't compare
local function sync_session(mr_ctx, head)
  local remote, iid = mr_ctx.remote, mr_ctx.mr.iid
  local function session_tab()
    return (controller.find_session_by_mr(remote.host,
      remote.path or remote.owner_repo, iid))
  end
  if not session_tab() then return end

  local tries = 0
  local function poll()
    tries = tries + 1
    mr_ctx.provider.fetch_mr_details(remote, iid, function(mr)
      local caught_up = mr ~= nil and (head == nil or mr.head_sha == head)
      if not caught_up and tries < POLL_TRIES then
        return vim.defer_fn(poll, POLL_INTERVAL_MS)
      end
      -- Looked up again: the user may have closed (or reopened) the review
      -- while we waited.
      local tabnr = session_tab()
      if not tabnr then return end
      if not caught_up then
        notify(string.format(
          "!%s: the forge still reports the pre-rebase head; close and reopen the review once it catches up",
          tostring(iid)), vim.log.levels.WARN)
        return
      end
      controller.reload(tabnr, function(ok, err)
        if ok then
          notify(string.format("!%s review reloaded on the rebased head", tostring(iid)))
        else
          notify(string.format("!%s: reloading the review failed: %s",
            tostring(iid), err or "?"), vim.log.levels.WARN)
        end
      end)
    end)
  end
  poll()
end

-- ---------------------------------------------------------- success / push

---@class ReviewRebaseJob
---@field worktree string
---@field source string   MR source branch (on origin)
---@field target string   MR target branch (on origin)
---@field lease string    sha origin/<source> had when the rebase started
---@field mr_ctx table    { provider, remote, mr } of the rebased MR

---Pushes the rebased worktree HEAD to origin/<source>, removes the worktree,
---then syncs the open review of the MR.
---@param job ReviewRebaseJob
local function finish_with_push(job)
  local source = job.source
  notify_util.progress(string.format("rebased %s, pushing (force-with-lease)...", source))
  -- Read before the push: the worktree goes away right after it.
  rebase.head_sha(job.worktree, function(head)
    rebase.push(job.worktree, source, job.lease, function(res)
      if res.ok then
        notify(string.format("origin/%s rebased onto origin/%s & pushed", source, job.target))
        if rebase.current_branch() == source then
          notify(string.format(
            "your local %s still has the pre-rebase history; update it from origin/%s",
            source, source), vim.log.levels.WARN)
        end
      else
        notify(string.format(
          "push of the rebased %s failed (origin/%s moved since the rebase started?): %s",
          source, source, res.error or "?"), vim.log.levels.WARN)
      end
      rebase.cleanup(job.worktree)
      if res.ok then sync_session(job.mr_ctx, head) end
    end)
  end)
end

-- ---------------------------------------------------------- conflict tab

-- Forward declaration — open_conflict_tab and on_tab_closed reference each
-- other (a "continue" that lands in another conflict re-opens the tab).
local open_conflict_tab

---@param job ReviewRebaseJob
local function on_tab_closed(job)
  local worktree = job.worktree
  rebase.check_state(worktree, function(state)
    if state.unmerged then
      -- User closed without resolving everything -> abort.
      notify(string.format("rebase of %s aborted (unmerged files left)", job.source),
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
        open_conflict_tab(job)
        return
      end
      if not res.ok then
        notify("rebase --continue failed: " .. (res.error or "?"),
          vim.log.levels.ERROR)
        rebase.abort(worktree, function() rebase.cleanup(worktree) end)
        return
      end
      finish_with_push(job)
    end)
  end)
end

-- Per-tab augroup so multiple parallel rebases (different branches) don't
-- step on each other's TabClosed handlers.
---@param tabnr integer
---@param job ReviewRebaseJob
local function watch_tab(tabnr, job)
  local group = vim.api.nvim_create_augroup("ReviewRebaseTab_" .. tostring(tabnr), { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      -- TabClosed fires for every tab. We only react when OUR tab handle is
      -- gone (compare against handle, not tabnr-position which can shift).
      if vim.api.nvim_tabpage_is_valid(tabnr) then return end
      pcall(vim.api.nvim_del_augroup_by_name, "ReviewRebaseTab_" .. tostring(tabnr))
      on_tab_closed(job)
    end,
  })
end

---@param job ReviewRebaseJob
open_conflict_tab = function(job)
  local worktree = job.worktree
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
    job.source))
  watch_tab(tabnr, job)
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

    -- Refuse to stack rebases on the same branch.
    local worktree = rebase.worktree_path(repo_root, source)
    if rebase.worktree_exists(worktree) then
      notify(string.format(
        "rebase already in progress for %s (worktree at %s) — finish or remove it first",
        source, worktree), vim.log.levels.WARN)
      return
    end

    notify_util.progress(string.format(
      "rebasing origin/%s onto origin/%s (worktree)...", source, target))
    rebase.start(repo_root, source, target, function(res)
      local job = {
        worktree = res.worktree, source = source, target = target,
        lease = res.lease, mr_ctx = target_ctx,
      }
      if res.ok then return finish_with_push(job) end
      if res.conflict then return open_conflict_tab(job) end
      notify((res.error or "rebase failed"), vim.log.levels.ERROR)
      if res.worktree then rebase.cleanup(res.worktree) end
    end)
  end)
end

return M
