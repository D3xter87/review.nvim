-- Helpers for PENDING notes: comments of a review that has been started but
-- not submitted yet (GitLab draft notes, GitHub pending review).
--
-- The word is "pending" on purpose: "draft" already means the MR / PR draft
-- status everywhere else in the plugin (is_draft, set_draft, ReviewDraft).
--
-- A pending note has the shape of a normalized note plus:
--   id            "pending:<raw id>"  -- can never collide with a published id
--   pending       true
--   pending_id    the provider's own id (GitLab draft note id / GitHub node id)
--   pending_kind  "inline" | "reply" | "global" | "summary"
--   reply_to      id of the published discussion it answers (replies only)
--   resolvable    false  -- nothing to resolve until it is published
--
-- Providers weave them into the discussion list (M.merge) so the panel, the
-- gutter signs and the preview float render them without a second code path.

local M = {}

M.ID_PREFIX = "pending:"

---JSON nulls arrive as vim.NIL, which is truthy: a position full of them reads
---as "has a path" to every consumer. Returns a copy without them, or nil when
---no path survives (a global note).
---@param pos any
---@return table|nil
function M.clean_position(pos)
  if type(pos) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(pos) do
    if v ~= vim.NIL then out[k] = v end
  end
  local has_path = (type(out.new_path) == "string" and out.new_path ~= "")
      or (type(out.old_path) == "string" and out.old_path ~= "")
  if not has_path then return nil end
  return out
end

---Weaves pending notes into a freshly normalized discussion list.
---
---A pending reply is appended to the thread it answers. Everything else — a
---new inline thread, a global note, the review summary, and a reply whose
---thread is not in the list — becomes a single-note pseudo-discussion, so a
---pending note is never silently dropped.
---
---`discussions` is mutated (its threads gain notes); it must be the list of
---the fetch in progress, never one a session already holds.
---@param discussions table[]
---@param notes table[]|nil
---@return table[]
function M.merge(discussions, notes)
  local by_id = {}
  for _, d in ipairs(discussions) do
    if d.id ~= nil then by_id[d.id] = d end
  end
  for _, n in ipairs(notes or {}) do
    local parent = n.reply_to ~= nil and by_id[n.reply_to] or nil
    if parent and not parent.pending then
      table.insert(parent.notes, n)
    else
      table.insert(discussions, {
        id = n.id,
        pending = true,
        kind = "pending",
        individual_note = true,
        notes = { n },
      })
    end
  end
  return discussions
end

---@param discussions table[]|nil
---@param id any
---@return table|nil
function M.find_discussion(discussions, id)
  for _, d in ipairs(discussions or {}) do
    if d.id == id then return d end
  end
  return nil
end

---@param discussions table[]|nil
---@param discussion_id any
---@param note_id any
---@return table|nil note, table|nil discussion
function M.find_note(discussions, discussion_id, note_id)
  local d = M.find_discussion(discussions, discussion_id)
  if not d then return nil end
  for _, n in ipairs(d.notes or {}) do
    if n.id == note_id then return n, d end
  end
  return nil, d
end

---Number of pending notes in a discussion list.
---@param discussions table[]|nil
---@return integer
function M.count(discussions)
  local total = 0
  for _, d in ipairs(discussions or {}) do
    for _, n in ipairs(d.notes or {}) do
      if n.pending then total = total + 1 end
    end
  end
  return total
end

return M
