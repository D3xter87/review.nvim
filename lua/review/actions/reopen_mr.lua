-- Thin wrapper for :ReviewOpen — delegates to controller.reopen_mr_session.
-- Kept as a separate module for symmetry with other commands' actions.

local M = {}

function M.run(opts)
  require("review.controller").reopen_mr_session(opts or {})
end

return M
