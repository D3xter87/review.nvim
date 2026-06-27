-- Floating multi-line input. Submit in normal mode via <CR> (so <CR> in insert
-- mode still inserts a newline — the body is markdown), or via <C-s> in either
-- normal or insert mode (like lazygit's commit). Cancel via <Esc>/<C-c>/q in
-- normal mode.
--
-- NOTE: <C-s> in a terminal is swallowed by TTY flow control (XOFF) unless the
-- user runs `stty -ixon`. It works out of the box in GUIs (Neovide, etc.).

local M = {}

---@param opts {
---  title: string,
---  prefill: string[]|nil,
---  filetype: string|nil,
---  on_submit: fun(lines: string[]),
---  on_cancel: (fun()) | nil,
---}
function M.open(opts)
  opts = opts or {}
  local prefill = opts.prefill or {}
  local title = opts.title or " input "
  local filetype = opts.filetype or "markdown"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
  if #prefill > 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill)
  end

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.max(8, math.floor(vim.o.lines * 0.4))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title:gsub("^%s+", ""):gsub("%s+$", "") .. "  (<C-s>=submit  n: <CR>=submit  <Esc>/<C-c>/q=cancel) ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Leave insert mode before closing, so submitting via <C-s> from insert
    -- doesn't leave the underlying buffer stuck in insert mode.
    vim.cmd("stopinsert")
    close()
    opts.on_submit(lines)
  end

  local function cancel()
    close()
    if opts.on_cancel then opts.on_cancel() end
  end

  local map_opts = { buffer = buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "<CR>", submit, map_opts)
  -- <C-s> submits from both normal and insert mode (lazygit-style commit).
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)
  vim.keymap.set("n", "<C-c>", cancel, map_opts)
  vim.keymap.set("n", "q", cancel, map_opts)

  -- Cancel on WinLeave so closing via :q or focus loss doesn't leave dangling state.
  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    callback = function(args)
      if tonumber(args.match) == win and not closed then
        closed = true
        if opts.on_cancel then opts.on_cancel() end
      end
    end,
  })

  -- Start in insert mode at end of buffer.
  if #prefill == 0 then
    vim.cmd("startinsert")
  else
    -- For prefilled (suggestion) — leave in normal mode so <CR>=submit is
    -- immediately available; user can press `i` to edit.
    vim.api.nvim_win_set_cursor(win, { #prefill, 0 })
  end

  return buf, win
end

return M
