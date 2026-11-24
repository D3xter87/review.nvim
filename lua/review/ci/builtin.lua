-- Built-in CI adapter, used when `ci.adapter` is not configured: the status
-- of the MR/PR's pipeline straight from the forge API review.nvim already
-- talks to. No job actions or logs -- `O` opens the pipeline in the browser.
-- A CI/CD plugin plugged in through `ci.adapter` replaces it (|review-ci|).
--
--   GitLab: the MR's latest pipeline (what its MR page shows).
--   GitHub: the head commit's check runs and commit statuses, one row each.

local M = {}

M.name = "built-in"

---@param target ReviewTarget
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch(target, cb)
  local controller = package.loaded["review.controller"]
  local ctx = controller and controller.get_ctx(target.tabnr)
  if not ctx then return cb(nil, "no review session") end
  local provider = ctx.provider
  if type(provider.fetch_pipeline_status) ~= "function" then
    return cb(nil, "provider '" .. tostring(provider.name) .. "' has no pipeline status")
  end
  provider.fetch_pipeline_status(ctx.remote, ctx.mr, cb)
end

return M
