-- :ReviewClose [branch|!iid]
--
-- Opens a small dialog:
--   Comment                optional; a non-empty one is posted as a global
--                          discussion before the close call.
--   [ ] Delete source branch  deletes the MR's source branch on the remote
--                          after the close. Not offered for an MR from a
--                          fork, nor when the source is the default or a
--                          protected branch (or the branch list can't be
--                          read). The local branch is never touched.
--   ▶ Close                the cursor starts here: <CR> closes silently.
--
-- When closing the active session's MR (is_ephemeral=false) we also tear down
-- the local Review session — a closed MR has no actionable review surface.
-- For ephemeral targets we leave any running session intact.

local M = {}

local controller = require("review.controller")
local form_dialog = require("review.ui.form_dialog")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

local function nullable(v)
  if v == vim.NIL then return nil end
  return v
end

---True when the MR's source branch lives in another project/repository,
---which this token can't be expected to delete from. Exposed for tests.
---@param provider_name string
---@param raw table|nil  the forge's MR/PR payload
function M._from_fork(provider_name, raw)
  raw = raw or {}
  if provider_name == "github" then
    local head, base = nullable(raw.head), nullable(raw.base)
    local head_repo = head and nullable(head.repo)
    local base_repo = base and nullable(base.repo)
    -- A deleted fork leaves head.repo null.
    if not head_repo or not base_repo then return true end
    return head_repo.full_name ~= base_repo.full_name
  end
  local src, tgt = nullable(raw.source_project_id), nullable(raw.target_project_id)
  return src ~= nil and tgt ~= nil and src ~= tgt
end

---Calls cb(true) when deleting `source` may be offered.
local function can_delete_source(target_ctx, is_ephemeral, cb)
  local provider, mr = target_ctx.provider, target_ctx.mr
  local source = mr.source_branch
  if not source or not provider.delete_branch or M._from_fork(provider.name, mr.raw) then
    return cb(false)
  end
  local function check(branches)
    for _, b in ipairs(branches or {}) do
      if b.name == source then return cb(not b.default and not b.protected) end
    end
    cb(false)  -- already gone, or the list could not be read
  end
  if is_ephemeral then
    provider.fetch_branches(target_ctx.remote, check)
  else
    controller.get_picker_options("branches", check)
  end
end

function M.run(target_opts)
  controller.with_target(target_opts, function(target_ctx, err, is_ephemeral)
    if not target_ctx then
      notify((err or "no target"), vim.log.levels.WARN); return
    end
    local provider, remote, mr = target_ctx.provider, target_ctx.remote, target_ctx.mr
    local iid = mr.iid
    local source = mr.source_branch

    can_delete_source(target_ctx, is_ephemeral, function(can_delete)
      vim.schedule(function()
        form_dialog.open({
          title = "Close !" .. tostring(iid),
          header = ("%s -> %s"):format(source or "?", mr.target_branch or "?"),
          start = "first_action",
          fields = {
            { id = "comment", kind = "text", label = "Comment", value = "",
              empty = "(none - close silently)", prompt = "Comment posted before closing" },
            { id = "delete_source", kind = "checkbox", value = false, hidden = not can_delete,
              label = "Delete source branch origin/" .. tostring(source) },
          },
          actions = { { id = "close", label = "Close" } },
          on_submit = function(_, v)
            local function finish()
              -- Only close the local session when the target IS the active one.
              if not is_ephemeral then controller.close() end
            end

            local function do_close()
              provider.close_mr(remote, iid, function(ok, cerr)
                if not ok then
                  notify((cerr or "failed to close MR"), vim.log.levels.ERROR); return
                end
                if not v.delete_source then
                  notify(string.format("!%s closed", tostring(iid)))
                  return finish()
                end
                -- After the close: on GitHub deleting the head branch would
                -- close the PR by itself, without our state change.
                provider.delete_branch(remote, source, function(dok, derr)
                  if dok then
                    notify(string.format("!%s closed, branch %s deleted", tostring(iid), source))
                  else
                    notify(string.format("!%s closed, but deleting %s failed: %s",
                      tostring(iid), source, derr or "?"), vim.log.levels.WARN)
                  end
                  finish()
                end)
              end)
            end

            local body = v.comment or ""
            if body:gsub("%s", "") ~= "" then
              provider.post_discussion(remote, iid, body, nil, function(ok, perr)
                if not ok then
                  notify("failed to post comment: " .. (perr or "?"), vim.log.levels.ERROR); return
                end
                do_close()
              end)
            else
              do_close()
            end
          end,
        })
      end)
    end)
  end)
end

return M
