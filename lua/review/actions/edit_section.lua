-- Section editor for the description panel. Dispatches by section_id to
-- either an input prompt (text) or the multi_select picker (users / labels /
-- milestone). After every successful update we refresh MR details so the
-- panel re-renders with the new value.

local M = {}

local controller = require("review.controller")
local input_prompt = require("review.ui.input_prompt")
local multi_select = require("review.ui.multi_select")

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

local function refresh()
  controller.refresh_mr_details()
  -- Participants list shifts whenever assignees/reviewers/labels change in
  -- ways that pull new people into the conversation, so refresh that too.
  controller.refresh_participants()
end

-- ---------------------------------------------------------- toggles

local function toggle_draft()
  local ctx = controller.get_ctx()
  if not ctx then return end
  if type(ctx.provider.set_draft) ~= "function" then
    notify("provider does not support draft toggle", vim.log.levels.WARN); return
  end
  local desired = not ctx.mr.is_draft
  ctx.provider.set_draft(ctx.remote, ctx.mr.iid, desired, function(ok, err)
    if not ok then
      notify((err or "failed to toggle draft"), vim.log.levels.ERROR); return
    end
    notify("!" .. tostring(ctx.mr.iid) ..
      (desired and " marked as draft" or " marked ready for review"))
    refresh()
  end)
end

-- ---------------------------------------------------------- text editors

local function edit_title()
  local ctx = controller.get_ctx()
  if not ctx then return end
  input_prompt.open({
    title = "Edit title",
    prefill = { ctx.mr.title or "" },
    on_submit = function(lines)
      local title = table.concat(lines, " "):gsub("^%s+", ""):gsub("%s+$", "")
      if title == "" then
        notify("empty title, skipped", vim.log.levels.WARN)
        return
      end
      ctx.provider.update_mr(ctx.remote, ctx.mr.iid, { title = title }, function(ok, err)
        if not ok then
          notify((err or "failed to update title"), vim.log.levels.ERROR); return
        end
        notify("title updated"); refresh()
      end)
    end,
  })
end

local function edit_description()
  local ctx = controller.get_ctx()
  if not ctx then return end
  input_prompt.open({
    title = "Edit MR description",
    prefill = vim.split(ctx.mr.description or "", "\n", { plain = true }),
    on_submit = function(lines)
      local body = table.concat(lines, "\n")
      ctx.provider.update_mr(ctx.remote, ctx.mr.iid, { description = body }, function(ok, err)
        if not ok then
          notify((err or "failed to update description"), vim.log.levels.ERROR); return
        end
        notify("description updated"); refresh()
      end)
    end,
  })
end

local function edit_time_tracking()
  local ctx = controller.get_ctx()
  if not ctx then return end
  local ts = ctx.mr.time_stats or {}
  local current = ts.human_time_estimate or ""
  input_prompt.open({
    title = "Set time estimate (e.g. 3h, 1d 2h, empty to reset)",
    prefill = { current },
    on_submit = function(lines)
      local duration = table.concat(lines, " "):gsub("^%s+", ""):gsub("%s+$", "")
      ctx.provider.set_time_estimate(ctx.remote, ctx.mr.iid, duration, function(ok, err)
        if not ok then
          notify((err or "failed to set time estimate"), vim.log.levels.ERROR); return
        end
        notify("time estimate updated"); refresh()
      end)
    end,
  })
end

-- ---------------------------------------------------------- pickers

local function pick_users(field_label, current_users, payload_key)
  local ctx = controller.get_ctx()
  if not ctx then return end
  controller.get_picker_options("members", function(members, err)
    if not members then
      notify((err or "failed to load members"), vim.log.levels.ERROR); return
    end
    local items = {}
    for _, u in ipairs(members) do
      table.insert(items, {
        id = u.id,
        label = string.format("@%s  (%s)", u.username or "?", u.name or "?"),
      })
    end
    local selected_ids = {}
    for _, u in ipairs(current_users or {}) do selected_ids[u.id] = true end

    multi_select.open({
      title = field_label,
      items = items,
      selected_ids = selected_ids,
      on_submit = function(picked)
        local ids = {}
        for id, _ in pairs(picked) do table.insert(ids, id) end
        -- GitLab requires an empty array to clear the field, sending nil
        -- leaves it untouched. vim.json.encode({}) yields {} not [], so we
        -- force an array via vim.empty_dict()-like trick using setmetatable.
        local payload = {}
        if #ids == 0 then
          payload[payload_key] = setmetatable({}, { __jsontype = "array" })
        else
          payload[payload_key] = ids
        end
        ctx.provider.update_mr(ctx.remote, ctx.mr.iid, payload, function(ok, err2)
          if not ok then
            notify((err2 or ("failed to update " .. field_label)), vim.log.levels.ERROR); return
          end
          notify("" .. field_label .. " updated"); refresh()
        end)
      end,
    })
  end)
end

local function edit_assignees()
  local ctx = controller.get_ctx()
  if not ctx then return end
  pick_users("Assignees", ctx.mr.assignees, "assignee_ids")
end

local function edit_reviewers()
  local ctx = controller.get_ctx()
  if not ctx then return end
  pick_users("Reviewers", ctx.mr.reviewers, "reviewer_ids")
end

local function edit_labels()
  local ctx = controller.get_ctx()
  if not ctx then return end
  controller.get_picker_options("labels", function(labels, err)
    if not labels then
      notify((err or "failed to load labels"), vim.log.levels.ERROR); return
    end
    local items = {}
    for _, l in ipairs(labels) do
      table.insert(items, { id = l.name, label = l.name })
    end
    local selected_ids = {}
    for _, name in ipairs(ctx.mr.labels or {}) do selected_ids[name] = true end

    multi_select.open({
      title = "Labels",
      items = items,
      selected_ids = selected_ids,
      on_submit = function(picked)
        local names = {}
        for name, _ in pairs(picked) do table.insert(names, name) end
        ctx.provider.update_mr(ctx.remote, ctx.mr.iid, { labels = names }, function(ok, err2)
          if not ok then
            notify((err2 or "failed to update labels"), vim.log.levels.ERROR); return
          end
          notify("labels updated"); refresh()
        end)
      end,
    })
  end)
end

local function edit_target_branch()
  local ctx = controller.get_ctx()
  if not ctx then return end
  controller.get_picker_options("branches", function(branches, err)
    if not branches then
      notify((err or "failed to load branches"), vim.log.levels.ERROR); return
    end
    local items = {}
    local current_target = ctx.mr.target_branch
    local source = ctx.mr.source_branch
    for _, b in ipairs(branches) do
      -- Filter out the source branch (you can't merge a branch into itself).
      if b.name ~= source then
        table.insert(items, { id = b.name, label = b.name })
      end
    end
    if #items == 0 then
      notify("no branches available as merge target", vim.log.levels.WARN); return
    end
    local selected_ids = current_target and { [current_target] = true } or {}

    multi_select.open({
      title = "Target branch",
      items = items,
      selected_ids = selected_ids,
      single = true,
      on_submit = function(picked)
        local new_target
        for k, _ in pairs(picked) do new_target = k end
        if not new_target then return end
        if new_target == current_target then return end
        ctx.provider.update_mr(ctx.remote, ctx.mr.iid,
          { target_branch = new_target }, function(ok, err2)
          if not ok then
            notify((err2 or "failed to change target branch"), vim.log.levels.ERROR); return
          end
          notify("target branch -> " .. new_target); refresh()
        end)
      end,
    })
  end)
end

local function edit_milestone()
  local ctx = controller.get_ctx()
  if not ctx then return end
  controller.get_picker_options("milestones", function(milestones, err)
    if not milestones then
      notify((err or "failed to load milestones"), vim.log.levels.ERROR); return
    end
    local items = { { id = 0, label = "(none)" } }
    for _, m in ipairs(milestones) do
      table.insert(items, { id = m.id, label = m.title })
    end
    local selected_ids = {}
    if ctx.mr.milestone and ctx.mr.milestone.id then
      selected_ids[ctx.mr.milestone.id] = true
    else
      selected_ids[0] = true
    end

    multi_select.open({
      title = "Milestone",
      items = items,
      selected_ids = selected_ids,
      single = true,
      on_submit = function(picked)
        local id
        for k, _ in pairs(picked) do id = k end
        if id == nil then return end
        ctx.provider.update_mr(ctx.remote, ctx.mr.iid, { milestone_id = id }, function(ok, err2)
          if not ok then
            notify((err2 or "failed to update milestone"), vim.log.levels.ERROR); return
          end
          notify("milestone updated"); refresh()
        end)
      end,
    })
  end)
end

local DISPATCH = {
  draft = toggle_draft,
  title = edit_title,
  target_branch = edit_target_branch,
  description = edit_description,
  assignees = edit_assignees,
  reviewers = edit_reviewers,
  labels = edit_labels,
  milestone = edit_milestone,
  time_tracking = edit_time_tracking,
  -- participants is read-only by design.
}

---@param section_id string
function M.run(section_id)
  if not section_id then return end
  local fn = DISPATCH[section_id]
  if not fn then
    notify("section '" .. section_id .. "' is read-only", vim.log.levels.WARN)
    return
  end
  fn()
end

return M
