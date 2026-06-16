-- Per-session state for review.nvim. Sessions are keyed by their diffview
-- tabpage handle: each open `:Review` lives in its own tab and gets its own
-- session table here. Code that needs the "active" session looks it up by
-- the current tabpage (controller.get_active_ctx() / state.get_active()).
--
-- Backwards-compat shim: `M.state` is a metatable proxy that read/writes the
-- active session's fields. Pre-multi-session call sites that did
-- `state_mod.state.discussions` still work as long as the current tab IS a
-- review session tab. New code should prefer the explicit
-- `M.get_for_tab(tabnr)` / `M.get_active()` accessors.

local M = {}

---@class ReviewSession
---@field mr table|nil
---@field commits table[]
---@field discussions table[]
---@field participants table[]
---@field pickers table
---@field provider_cache table
---@field panel { buf: integer|nil, win: integer|nil, mode: string, cursor_line: integer, line_targets: table }
---@field highlights { ns_id: integer|nil, signs: table }
---@field diffview_tabnr integer|nil
---@field branch string
---@field provider_name string

---@type table<integer, ReviewSession>
M.sessions = {}

local function new_session()
  return {
    mr = nil,
    commits = {},
    discussions = {},
    participants = {},
    pickers = { members = nil, labels = nil, milestones = nil, branches = nil },
    provider_cache = {},
    panel = {
      buf = nil,
      win = nil,
      mode = "info",
      cursor_line = 1,
      line_targets = {},
    },
    highlights = { ns_id = nil, signs = {} },
    diffview_tabnr = nil,
    branch = "",
    provider_name = "",
  }
end

---Allocate (or reset) the session attached to `tabnr` and return it.
---@param tabnr integer
---@return ReviewSession
function M.create_for_tab(tabnr)
  M.sessions[tabnr] = new_session()
  M.sessions[tabnr].diffview_tabnr = tabnr
  return M.sessions[tabnr]
end

---@param tabnr integer
---@return ReviewSession|nil
function M.get_for_tab(tabnr)
  return M.sessions[tabnr]
end

---@param tabnr integer
function M.delete_for_tab(tabnr)
  M.sessions[tabnr] = nil
end

---Returns the session for the currently-focused tab (or nil when the user
---is in a non-review tab).
---@return ReviewSession|nil
function M.get_active()
  local ok, tabnr = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then return nil end
  return M.sessions[tabnr]
end

---Iterates every live session: `for tabnr, session in M.iter() do ... end`
---@return fun(): integer|nil, ReviewSession|nil
function M.iter()
  return pairs(M.sessions)
end

---Drops every session entry (no UI teardown — that's the controller's job).
function M.clear_all()
  M.sessions = {}
end

---Backwards-compatible facade: reads/writes target the active session's
---fields (via __index/__newindex). Returns nil-ish writes when there is no
---active session — callers should prefer the explicit accessors above for
---write operations on a known session.
M.state = setmetatable({}, {
  __index = function(_, key)
    local s = M.get_active()
    return s and s[key] or nil
  end,
  __newindex = function(_, key, value)
    local s = M.get_active()
    if s then s[key] = value end
  end,
})

---@deprecated  No-op kept for legacy callers. Use M.delete_for_tab(tabnr).
function M.reset() end

return M
