-- Floating checkbox picker. Reusable for labels / assignees / reviewers
-- (multi-select) and milestones (single-select via the `single` flag).
--
-- Keys:
--   <Space>          toggle current line
--   <CR>             submit (calls on_submit with the selected_ids map)
--   <Esc>/<C-c>/q    cancel

local M = {}

---@class MultiSelectItem
---@field id any        unique identifier
---@field label string  display string

---@param opts {
---  title: string,
---  items: MultiSelectItem[],
---  selected_ids: table<any, boolean>|nil,
---  single: boolean|nil,
---  on_submit: fun(selected_ids: table<any, boolean>),
---  on_cancel: (fun()) | nil,
---}
function M.open(opts)
  opts = opts or {}
  local items = opts.items or {}
  local selected = vim.deepcopy(opts.selected_ids or {})
  local single = opts.single == true

  if #items == 0 then
    vim.notify("nothing to pick", vim.log.levels.WARN, { title = "Review" })
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "review-pick", { buf = buf })

  local function render()
    local lines = {}
    for _, it in ipairs(items) do
      local mark = selected[it.id] and "[x]" or "[ ]"
      table.insert(lines, string.format("%s %s", mark, it.label))
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  render()

  local width = math.max(40, math.floor(vim.o.columns * 0.4))
  local height = math.min(#items + 2, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local hint = single
    and " <Space>=select  <CR>=submit  <Esc>/<C-c>/q=cancel "
    or  " <Space>=toggle  <CR>=submit  <Esc>/<C-c>/q=cancel "

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Pick") .. " ",
    title_pos = "center",
    footer = hint,
    footer_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
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

  local function toggle()
    local row_idx = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row_idx]
    if not item then return end
    if single then
      -- Replace current selection with this one (or clear if already selected).
      local was = selected[item.id]
      selected = {}
      if not was then selected[item.id] = true end
    else
      selected[item.id] = not selected[item.id] or nil
    end
    render()
  end

  local function submit()
    close()
    opts.on_submit(selected)
  end

  local function cancel()
    close()
    if opts.on_cancel then opts.on_cancel() end
  end

  local map_opts = { buffer = buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "<Space>", toggle, map_opts)
  vim.keymap.set("n", "<CR>", submit, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)
  vim.keymap.set("n", "<C-c>", cancel, map_opts)
  vim.keymap.set("n", "q", cancel, map_opts)

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    callback = function(args)
      if tonumber(args.match) == win and not closed then
        closed = true
        if opts.on_cancel then opts.on_cancel() end
      end
    end,
  })

  return buf, win
end

return M
