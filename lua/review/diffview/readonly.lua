-- Forces every diffview content buffer to be read-only while a review session
-- is active. The autocmd group is owned by the review controller so it can be
-- torn down on close().

local M = {}

local integration = require("review.diffview.integration")

local AUGROUP = "ReviewDiffviewReadonly"

function M.apply()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufReadPost" }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      if not integration.is_diffview_buf(bufnr) then return end
      pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
      pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
    end,
  })
end

function M.clear()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
end

return M
