-- ============================================================================
-- review.nvim — Merge Request / Pull Request review for Neovim
-- ============================================================================
-- Public entry point. Real implementation lives in `review.controller` and
-- supporting modules (`providers/`, `ui/`, `actions/`, `diffview/`).
--
-- Supports GitLab (REST API v4) and GitHub (REST + minimal GraphQL) with
-- feature parity: approve / revoke / merge / close, inline comments,
-- multi-line suggestions, resolvable discussion threads, draft toggle, MR
-- info editing, auto-merge, and more.
--
-- See `:help review` for the full reference, including command list,
-- key-maps, configuration schema, and authentication paths.
-- ============================================================================

local M = {}

---Apply user configuration. See |review-config| for the schema; every key is
---optional. Typically called via lazy.nvim's `opts = {...}`.
---@param opts? table
function M.setup(opts)
  require("review.config").setup(opts)
end

---Start a review session. Equivalent to `:Review` with the matching arg.
---@param opts? table  { branch = "<name>" } or { iid = <number> }
function M.open(opts)
  require("review.controller").open(opts)
end

---The :DiffviewOpen call review.nvim is making right now, or nil when the
---view being opened is not ours. Meant for diffview hooks (`view_opened`)
---that add UI of their own to diff views and should leave a review session
---alone — see |review-diffview-request|.
---
---`kind` is "session" for the MR diff a session lives in (it gets the bottom
---panel) and "commit" for the single-commit diff opened from the Commits
---panel (a plain diffview tab).
---@return { kind: "session"|"commit", rev: string, mr: table|nil }|nil
function M.diffview_request()
  -- No require: if the integration was never loaded, it is not opening
  -- anything, and a hook must not pull the plugin in just to ask.
  local integration = package.loaded["review.diffview.integration"]
  return integration and integration.request or nil
end

return M
