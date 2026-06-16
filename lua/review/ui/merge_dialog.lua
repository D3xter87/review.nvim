-- Floating merge dialog: 3 toggle options + 2 action lines.
--
-- Keys:
--   <Space> / <CR> on a checkbox  toggle
--   <CR> on an action line        submit (Merge now / Auto-merge)
--   <Esc> / <C-c> / q             cancel
--
-- "Edit commit message" controls whether opts.commit_message is sent. We open
-- a dedicated input_prompt for the message only when the user activates an
-- action with that option enabled — avoiding a multi-step modal when the
-- user just wants the GitLab-default message.

local M = {}

local input_prompt = require("review.ui.input_prompt")

local CHECKBOXES = {
  { id = "delete_source", label = "Delete source branch" },
  { id = "squash",        label = "Squash commits" },
  { id = "edit_message",  label = "Edit commit message" },
}

local ACTIONS = {
  { id = "merge",      label = "Merge now" },
  { id = "auto_merge", label = "Set auto-merge (after pipeline)" },
}

---@param opts {
---  defaults: { delete_source: boolean|nil, squash: boolean|nil }|nil,
---  default_message: string|nil,                    -- prefill for "Edit commit message"
---  blocked_reason: string|nil,                     -- shown above actions when present
---  on_submit: fun(action: "merge"|"auto_merge", choices: {
---    delete_source: boolean,
---    squash: boolean,
---    commit_message: string|nil,
---  }),
---  on_cancel: (fun()) | nil,
---}
function M.open(opts)
  opts = opts or {}
  local checked = {
    delete_source = (opts.defaults and opts.defaults.delete_source) and true or false,
    squash        = (opts.defaults and opts.defaults.squash) and true or false,
    edit_message  = false,
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "review-merge", { buf = buf })

  -- line_targets[i] = { kind = "checkbox"|"action"|"info", id = ... }
  local line_targets = {}

  local function render()
    local lines = {}
    local function push(text, target)
      table.insert(lines, text)
      line_targets[#lines] = target
    end

    push("  Merge options:", { kind = "info" })
    push("", { kind = "info" })
    for _, cb in ipairs(CHECKBOXES) do
      local mark = checked[cb.id] and "[x]" or "[ ]"
      push(string.format("    %s %s", mark, cb.label), { kind = "checkbox", id = cb.id })
    end
    push("", { kind = "info" })

    if opts.blocked_reason then
      push("  ! " .. opts.blocked_reason, { kind = "info" })
      push("", { kind = "info" })
    end

    push("  Actions:", { kind = "info" })
    for _, a in ipairs(ACTIONS) do
      push(string.format("    ▶ %s", a.label), { kind = "action", id = a.id })
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  render()

  local width = math.max(50, math.floor(vim.o.columns * 0.5))
  local height = math.min(#line_targets + 2, math.floor(vim.o.lines * 0.6))
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
    title = " Merge MR ",
    title_pos = "center",
    footer = " <Space>/<CR>=toggle  <CR>=run on action  <Esc>/<C-c>/q=cancel ",
    footer_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  -- Place cursor on the first checkbox line for fast keyboard interaction.
  for i, t in ipairs(line_targets) do
    if t.kind == "checkbox" then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      break
    end
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function current_target()
    local row_idx = vim.api.nvim_win_get_cursor(win)[1]
    return line_targets[row_idx]
  end

  local function toggle()
    local t = current_target()
    if not t or t.kind ~= "checkbox" then return end
    checked[t.id] = not checked[t.id]
    render()
  end

  local function finalize(action_id, message)
    close()
    opts.on_submit(action_id, {
      delete_source = checked.delete_source == true,
      squash = checked.squash == true,
      commit_message = checked.edit_message and (message or nil) or nil,
    })
  end

  local function activate()
    local t = current_target()
    if not t then return end
    if t.kind == "checkbox" then return toggle() end
    if t.kind ~= "action" then return end

    if checked.edit_message then
      -- Open input prefilled with the default; user submits to actually merge.
      input_prompt.open({
        title = (t.id == "auto_merge") and "Auto-merge commit message" or "Merge commit message",
        prefill = vim.split(opts.default_message or "", "\n", { plain = true }),
        on_submit = function(lines)
          finalize(t.id, table.concat(lines, "\n"))
        end,
      })
    else
      finalize(t.id, nil)
    end
  end

  local function cancel()
    close()
    if opts.on_cancel then opts.on_cancel() end
  end

  local map_opts = { buffer = buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "<Space>", toggle, map_opts)
  vim.keymap.set("n", "<CR>", activate, map_opts)
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
