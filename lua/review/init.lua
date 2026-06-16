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

return M
