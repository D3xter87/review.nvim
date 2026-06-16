-- Helpers for reasoning about discussion resolve state.
-- A discussion is "resolvable" if any of its non-system notes carries
-- resolvable=true (GitLab marks individual top-level discussions, not the
-- replies). It's "resolved" only when every resolvable note is resolved.

local M = {}

---@param d table  normalized discussion
function M.is_resolvable(d)
  if d.individual_note then return false end
  for _, n in ipairs(d.notes or {}) do
    if n.resolvable then return true end
  end
  return false
end

---@param d table  normalized discussion
function M.is_resolved(d)
  local saw_any = false
  for _, n in ipairs(d.notes or {}) do
    if n.resolvable then
      saw_any = true
      if not n.resolved then return false end
    end
  end
  return saw_any
end

---Counts resolvable threads and how many of them are still unresolved.
---@param discussions table[]
---@return integer unresolved, integer total
function M.counts(discussions)
  local total, unresolved = 0, 0
  for _, d in ipairs(discussions or {}) do
    if M.is_resolvable(d) then
      total = total + 1
      if not M.is_resolved(d) then unresolved = unresolved + 1 end
    end
  end
  return unresolved, total
end

return M
