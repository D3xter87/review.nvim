-- Read-only float with a commit's full message and stat, opened from a row of
-- the Commits panel (|review-panel-commits|).
--
-- Deliberately NOT vim.lsp.util.open_floating_preview: that one sizes itself
-- to the room inside the CURRENT window, and the bottom panel is a dozen rows
-- tall at best — a commit message got three lines. This float hangs above the
-- cursor row and may use the editor's whole height.
--
-- Same manners as |review-note-preview|: pressing the key again steps INTO
-- the float (scroll, yank), `q` / <Esc> there closes it, and it closes by
-- itself when the cursor moves on in the panel.

local M = {}

local api = vim.api

local MAX_WIDTH = 120
local MIN_WIDTH = 50

local S = { win = nil, ids = {} }

function M.is_open()
  return S.win ~= nil and api.nvim_win_is_valid(S.win)
end

function M.close()
  for _, id in ipairs(S.ids) do pcall(api.nvim_del_autocmd, id) end
  S.ids = {}
  if M.is_open() then pcall(api.nvim_win_close, S.win, true) end
  S.win = nil
end

---Moves the cursor into the open float. Returns false when there is none.
---@return boolean
function M.enter()
  if not M.is_open() then return false end
  api.nvim_set_current_win(S.win)
  return true
end

---@param lines string[]
---@param origin integer  window the float belongs to (the panel)
function M.open(lines, origin)
  M.close()
  if not origin or not api.nvim_win_is_valid(origin) or #lines == 0 then return end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_set_option_value("filetype", "git", { buf = buf })

  -- As wide as the longest line and as tall as the text (wrapped lines
  -- counted), both capped by the editor: 2 cells of border each way, and for
  -- the height the rows between the tab line and the cursor row.
  local width = MIN_WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, MAX_WIDTH, vim.o.columns - 4)
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local pos = vim.fn.screenpos(origin, api.nvim_win_get_cursor(origin)[1], 1)
  local cursor_row = pos.row > 0 and pos.row or (vim.o.lines - 2)  -- 1-based
  local height = math.max(1, math.min(rows, cursor_row - 4))

  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SW",
    row = cursor_row - 1,  -- bottom edge sits right above the cursor row
    col = 2,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    zindex = 60,
  })
  api.nvim_set_option_value("wrap", true, { win = win })
  api.nvim_set_option_value("linebreak", true, { win = win })
  api.nvim_set_option_value("winhighlight",
    "NormalFloat:ReviewPreviewNormal,FloatBorder:ReviewPreviewBorder", { win = win })
  S.win = win

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      M.close()
      if api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
    end, { buffer = buf, silent = true, noremap = true, nowait = true })
  end

  -- Closed as soon as the cursor moves on in the panel or focus leaves the
  -- pair (panel + float). Scheduled, so stepping INTO the float — which
  -- fires BufLeave on the panel first — is seen as "inside" and keeps it.
  local function close_unless_inside()
    vim.schedule(function()
      if api.nvim_get_current_win() ~= S.win then M.close() end
    end)
  end
  local row = api.nvim_win_get_cursor(origin)[1]
  S.ids = {
    api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
      buffer = api.nvim_win_get_buf(origin),
      callback = function(ev)
        -- Still on the row the float describes: sideways motion, or the
        -- CursorMoved a jump onto this row had pending when the key was hit.
        local same_row = api.nvim_win_is_valid(origin)
          and api.nvim_win_get_cursor(origin)[1] == row
        if not (ev.event == "CursorMoved" and same_row) then close_unless_inside() end
      end,
    }),
    api.nvim_create_autocmd("WinLeave", { buffer = buf, callback = close_unless_inside }),
  }
end

return M
