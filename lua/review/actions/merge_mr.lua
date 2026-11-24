-- Opens the merge dialog and dispatches the chosen action (immediate merge
-- or auto-merge after pipeline). Pre-fills sane defaults from the MR object
-- and surfaces blocked-state hints when GitLab won't merge yet.
--
-- Accepts target_opts to optionally target an MR/PR other than the active
-- session. When the target is the active session (is_ephemeral=false) AND the
-- user picks "Merge now", we tear down the local session afterwards. For
-- ephemeral targets we just notify and leave any active session intact.

local M = {}

local controller = require("review.controller")
local merge_dialog = require("review.ui.merge_dialog")
local auto_merge_watcher = require("review.auto_merge_watcher")
local notify_util = require("review.util.notify")
local close_issue = require("review.util.close_issue")

local function notify(msg, level)
  notify_util.legacy(msg, level)
end

---Makes the description close exactly `refs` before the merge goes out — the
---forge reads the closing lines at merge time, so they have to be saved first.
---Unlike the refs trailer this is not best-effort: the caller aborts the merge
---on error, because merging without the references would silently drop what
---the user ticked.
---@param ctx table
---@param refs string[]      issues to close; empty = remove existing closing lines
---@param had_lines boolean  the description already carried closing lines
---@param template string
---@param cb fun(err: string|nil, changed: boolean)
local function write_close_issues(ctx, refs, had_lines, template, cb)
  -- Box left unticked on an MR that never had closing lines: nothing to do,
  -- and no reason to spend two extra API calls on every merge.
  if #refs == 0 and not had_lines then return cb(nil, false) end

  local provider, remote, iid = ctx.provider, ctx.remote, ctx.mr.iid
  if type(provider.fetch_mr_details) ~= "function"
      or type(provider.update_mr) ~= "function" then
    return cb("this provider cannot update the description", false)
  end

  notify_util.progress("updating !" .. tostring(iid) .. " description...")
  -- ctx.mr may be a stale session snapshot; rewrite what the forge has now.
  provider.fetch_mr_details(remote, iid, function(fresh, err)
    if not fresh then return cb(err or "failed to fetch MR", false) end
    local body = close_issue.apply(fresh.description or "", refs, template)
    if not body then return cb(nil, false) end
    provider.update_mr(remote, iid, { description = body }, function(ok, uerr)
      if not ok then return cb(uerr or "failed to update description", false) end
      cb(nil, true)
    end)
  end)
end

---Runs the user's `close_issue.on_merged` hook — the place for whatever has
---to happen outside the forge once the MR is really merged (an issue tracker
---transition, say). Only for merges that had the box ticked.
---@param ctx table
---@param refs string[]
---@param merged table|nil  the MR as last seen, when the caller has a fresher one
local function fire_on_merged(ctx, refs, merged)
  local hook = (require("review.config").get().close_issue or {}).on_merged
  if type(hook) ~= "function" or #refs == 0 then return end
  local ok, err = pcall(hook, {
    refs = vim.deepcopy(refs),
    mr = merged or ctx.mr,
    provider = ctx.provider.name,
  })
  if not ok then
    notify("close_issue.on_merged failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

---Once a merge has landed (right away, or when auto-merge completes): if the
---merged branch is STILL the one checked out locally, moves to the branch it
---was merged into and fast-forwards that to origin, so the merge is there
---locally too — the source branch is finished (and often deleted on the
---forge). Any other checkout is left alone: for an auto-merge the user may
---well have moved on by the time it lands. See `merge.checkout_target`.
---@param mr table
local function checkout_target(mr)
  if (require("review.config").get().merge or {}).checkout_target == false then return end
  local git = require("review.git.rebase")
  local source, target = mr.source_branch, mr.target_branch
  if not source or not target or source == target then return end
  if git.current_branch() ~= source then return end
  local root = git.repo_root()
  if not root then return end
  git.checkout(root, target, function(res)
    if not res.ok then
      notify(string.format("could not check out %s after the merge: %s",
        target, res.error or "?"), vim.log.levels.WARN)
      return
    end
    git.fast_forward(root, target, function(fres)
      if fres.ok then
        notify(string.format("checked out %s, up to date with origin (%s is merged)",
          target, source))
      else
        notify(string.format(
          "checked out %s (%s is merged), but could not fast-forward it to origin/%s: %s",
          target, source, target, fres.error or "?"), vim.log.levels.WARN)
      end
    end)
  end)
end

-- Maps GitLab's detailed_merge_status to a one-liner the user can act on.
local function blocked_reason(mr)
  local d = mr.detailed_merge_status
  if d == "ci_must_pass" or d == "ci_still_running" then
    return "Pipeline must pass before merge — auto-merge will wait."
  end
  if d == "discussions_not_resolved" then
    return "Unresolved threads block merge. Resolve them or override."
  end
  if d == "draft_status" then
    return "MR is marked as Draft."
  end
  if d == "not_approved" then
    return "Required approvals are missing."
  end
  if d == "conflict" or mr.has_conflicts then
    return "MR has conflicts — resolve before merging."
  end
  if mr.merge_status == "cannot_be_merged" then
    return "GitLab reports the MR cannot be merged in its current state."
  end
  return nil
end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    local mr = target_ctx.mr

    if mr.state == "merged" then
      notify("!" .. tostring(mr.iid) .. " is already merged", vim.log.levels.WARN); return
    end
    if mr.state == "closed" then
      notify("!" .. tostring(mr.iid) .. " is closed", vim.log.levels.WARN); return
    end

    local default_title = (mr.title or "")
        .. (mr.iid and string.format(" (!%s)", mr.iid) or "")

    -- Closing lines already in the description decide the checkbox's initial
    -- state; otherwise it starts unticked, prefilled with the branch's issue.
    local template = close_issue.template()
    local closing = close_issue.existing(mr.description, template)
    local had_closing = #closing > 0

    merge_dialog.open({
      defaults = {
        delete_source = true,
        squash = mr.squash == true,
      },
      default_title = default_title,
      close_issues = {
        refs = had_closing and closing
            or close_issue.prefill(mr, target_ctx.provider.name),
        checked = had_closing,
      },
      blocked_reason = blocked_reason(mr),
      on_submit = function(action, choices)
        local payload = {
          squash = choices.squash,
          should_remove_source_branch = choices.delete_source,
          merge_when_pipeline_succeeds = (action == "auto_merge"),
          sha = mr.head_sha,
          -- Title and description of the merge (or squash) commit, each only
          -- when its box was ticked. How they reach the forge is the
          -- provider's business: GitHub takes them separately, GitLab wants
          -- one message — hence the fallback title for "description only".
          commit_title = choices.commit_title,
          commit_body = choices.commit_body,
          default_commit_title = default_title,
        }

        ---@param description_changed boolean  closing lines were just written
        local function do_merge(description_changed)
          notify_util.progress((action == "auto_merge"
              and ("scheduling auto-merge for !" .. tostring(mr.iid) .. "...")
              or ("merging !" .. tostring(mr.iid) .. "...")))
          target_ctx.provider.merge_mr(target_ctx.remote, mr.iid, payload, function(ok, merr, updated)
            if not ok then
              notify((merr or "merge failed"), vim.log.levels.ERROR)
              -- The description edit went through even though the merge did
              -- not — show it rather than the pre-dialog snapshot.
              if description_changed and not is_ephemeral then
                controller.refresh_mr_details()
              end
              return
            end
            if action == "auto_merge" then
              notify("auto-merge scheduled for !" .. tostring(mr.iid))
              -- Kick off a background poller — survives review session
              -- teardown and notifies the user when the merge lands or the
              -- pipeline fails.
              auto_merge_watcher.watch(target_ctx, {
                on_merged = function(merged)
                  fire_on_merged(target_ctx, choices.close_issues or {}, merged)
                  checkout_target(mr)
                end,
              })
              -- Refresh details only when targeting the active session so the
              -- panel reflects the new auto-merge flag.
              if not is_ephemeral then
                if updated then
                  local state_mod = require("review.state")
                  target_ctx.mr = updated
                  state_mod.state.mr = updated
                end
                controller.refresh_mr_details()
              end
            else
              notify("!" .. tostring(mr.iid) .. " merged")
              fire_on_merged(target_ctx, choices.close_issues or {}, updated)
              -- Tear down the local session ONLY when this merge was for the
              -- active review. Out-of-band merges leave the session intact.
              if not is_ephemeral then
                controller.close()
              end
              checkout_target(mr)
            end
          end)
        end

        write_close_issues(target_ctx, choices.close_issues or {}, had_closing, template,
          function(cerr, changed)
            if cerr then
              notify("merge aborted: could not write issue references to the description: "
                .. cerr, vim.log.levels.ERROR)
              return
            end
            do_merge(changed)
          end)
      end,
    })
  end)
end

return M
