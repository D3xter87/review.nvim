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

local function notify(msg, level)
  notify_util.legacy(msg, level)
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

    local default_message = (mr.title or "")
        .. (mr.iid and string.format(" (!%s)", mr.iid) or "")

    merge_dialog.open({
      defaults = {
        delete_source = true,
        squash = mr.squash == true,
      },
      default_message = default_message,
      blocked_reason = blocked_reason(mr),
      on_submit = function(action, choices)
        local payload = {
          squash = choices.squash,
          should_remove_source_branch = choices.delete_source,
          merge_when_pipeline_succeeds = (action == "auto_merge"),
          sha = mr.head_sha,
        }
        if choices.commit_message and choices.commit_message ~= "" then
          if choices.squash then
            payload.squash_commit_message = choices.commit_message
          else
            payload.merge_commit_message = choices.commit_message
          end
        end

        notify_util.progress((action == "auto_merge"
            and ("scheduling auto-merge for !" .. tostring(mr.iid) .. "...")
            or ("merging !" .. tostring(mr.iid) .. "...")))
        target_ctx.provider.merge_mr(target_ctx.remote, mr.iid, payload, function(ok, merr, updated)
          if not ok then
            notify((merr or "merge failed"), vim.log.levels.ERROR); return
          end
          if action == "auto_merge" then
            notify("auto-merge scheduled for !" .. tostring(mr.iid))
            -- Kick off a background poller — survives review session
            -- teardown and notifies the user when the merge lands or the
            -- pipeline fails.
            auto_merge_watcher.watch(target_ctx)
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
            -- Tear down the local session ONLY when this merge was for the
            -- active review. Out-of-band merges leave the session intact.
            if not is_ephemeral then
              controller.close()
            end
          end
        end)
      end,
    })
  end)
end

return M
