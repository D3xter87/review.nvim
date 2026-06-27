-- Current visual selection range.
--
-- The '< / '> marks are only written by Neovim when you LEAVE visual mode, so
-- a keymap that fires while still in visual mode (our 'c' / 's' bindings) reads
-- a stale or unset range from them. getpos("v") (the other end of the current
-- selection) and getpos(".") (the cursor) are valid mid-selection, so we use
-- those instead.

local M = {}

---Returns start_line, end_line (1-indexed, start <= end) of the CURRENT visual
---selection, or nil if there is none.
---@return integer|nil start_line
---@return integer|nil end_line
function M.range()
  local a = vim.fn.getpos("v")[2]
  local b = vim.fn.getpos(".")[2]
  if a == 0 or b == 0 then return nil end
  if a > b then a, b = b, a end
  return a, b
end

return M
