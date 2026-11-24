-- Floating form: a column of fields followed by action lines. Used by
-- :ReviewCreate and :ReviewClose (the merge dialog keeps its own, older
-- implementation in merge_dialog.lua).
--
-- Field kinds:
--   checkbox  <Space> / <CR> toggles it.
--   text      <CR> opens an input_prompt prefilled with the value; the line
--             shows its first line, cut at 40 characters. `single_line`
--             joins what was typed into one line (titles).
--   choice    <CR> calls `field.pick(current, set)`; `set(value, hint)`
--             stores the new value and redraws.
-- A field with `hidden = true` is neither drawn nor returned.
--
-- Keys:
--   <CR> on an action line   submit (after `validate`, when given)
--   <Esc> / <C-c> / q        cancel

local M = {}

local input_prompt = require("review.ui.input_prompt")
local notify_util = require("review.util.notify")

---@class ReviewFormField
---@field id string
---@field kind "checkbox"|"text"|"choice"
---@field label string
---@field value any            boolean for checkbox, string otherwise
---@field hint string|nil      shown after the value (choice / text)
---@field empty string|nil     shown when a text value is empty (default "(none)")
---@field single_line boolean|nil
---@field prompt string|nil    input_prompt title for a text field (default: label)
---@field pick (fun(current: any, set: fun(value: any, hint: string|nil)))|nil
---@field hidden boolean|nil

---@param opts {
---  title: string,
---  header: string|nil,                 -- first line inside the float
---  fields: ReviewFormField[],
---  actions: { id: string, label: string }[],
---  start: "first_field"|"first_action"|nil,  -- where the cursor starts (default first_field)
---  validate: (fun(values: table): string|nil)|nil,
---  on_submit: fun(action_id: string, values: table),
---  on_cancel: (fun())|nil,
---}
function M.open(opts)
  local fields = {}
  for _, f in ipairs(opts.fields or {}) do
    if not f.hidden then table.insert(fields, vim.deepcopy(f)) end
  end
  local by_id = {}
  for _, f in ipairs(fields) do by_id[f.id] = f end

  local label_width = 0
  for _, f in ipairs(fields) do
    if f.kind ~= "checkbox" then label_width = math.max(label_width, vim.fn.strdisplaywidth(f.label)) end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "review-form", { buf = buf })

  -- line_targets[i] = { kind = "field"|"action"|"info", id = ... }
  local line_targets = {}

  local function short(value)
    local first = (value or ""):match("^[^\r\n]*")
    local cut = vim.fn.strcharpart(first, 0, 40)
    return cut .. (cut ~= value and "…" or "")
  end

  local function render()
    local lines = {}
    line_targets = {}
    local function push(text, target)
      table.insert(lines, text)
      line_targets[#lines] = target
    end

    if opts.header then
      push("  " .. opts.header, { kind = "info" })
      push("", { kind = "info" })
    end
    for _, f in ipairs(fields) do
      local text
      if f.kind == "checkbox" then
        text = string.format("    %s %s", f.value and "[x]" or "[ ]", f.label)
      else
        local value = f.value or ""
        local shown = value ~= "" and short(value) or (f.empty or "(none)")
        local pad = string.rep(" ", label_width - vim.fn.strdisplaywidth(f.label))
        text = string.format("    %s:%s  %s", f.label, pad, shown)
        if f.hint and f.hint ~= "" then text = text .. "  " .. f.hint end
      end
      push(text, { kind = "field", id = f.id })
    end
    push("", { kind = "info" })
    for _, a in ipairs(opts.actions or {}) do
      push(string.format("    ▶ %s", a.label), { kind = "action", id = a.id })
    end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end
  render()

  local width = math.max(60, math.floor(vim.o.columns * 0.5))
  local height = math.min(#line_targets, math.floor(vim.o.lines * 0.6))
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
    title = " " .. (opts.title or "Form") .. " ",
    title_pos = "center",
    footer = " <CR>=edit/toggle/run  <Space>=toggle  <Esc>/<C-c>/q=cancel ",
    footer_pos = "center",
  })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  local want = opts.start == "first_action" and "action" or "field"
  for i, t in ipairs(line_targets) do
    if t.kind == want then
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
    return line_targets[vim.api.nvim_win_get_cursor(win)[1]]
  end

  -- Prompts and pickers open windows of their own; hand focus back to the
  -- form rather than to whatever sits underneath.
  local function refocus()
    if not closed and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end

  local function edit_text(f)
    input_prompt.open({
      title = f.prompt or f.label,
      prefill = (f.value or "") ~= "" and vim.split(f.value, "\r?\n") or nil,
      on_submit = function(lines)
        refocus()
        if closed then return end
        if f.single_line then
          local parts = {}
          for _, line in ipairs(lines) do
            line = vim.trim(line)
            if line ~= "" then table.insert(parts, line) end
          end
          f.value = table.concat(parts, " ")
        else
          f.value = vim.trim(table.concat(lines, "\n"))
        end
        render()
      end,
      on_cancel = refocus,
    })
  end

  local function values()
    local out = {}
    for _, f in ipairs(fields) do out[f.id] = f.value end
    return out
  end

  local function activate_field(f, from_space)
    if f.kind == "checkbox" then
      f.value = not f.value
      return render()
    end
    if from_space then return end
    if f.kind == "text" then return edit_text(f) end
    if f.kind == "choice" and f.pick then
      f.pick(f.value, function(value, hint)
        vim.schedule(function()
          refocus()
          if closed or value == nil then return end
          f.value = value
          f.hint = hint
          render()
        end)
      end)
    end
  end

  local function activate()
    local t = current_target()
    if not t then return end
    if t.kind == "field" then return activate_field(by_id[t.id], false) end
    if t.kind ~= "action" then return end
    local v = values()
    local problem = opts.validate and opts.validate(v)
    if problem then return notify_util.warn(problem) end
    close()
    opts.on_submit(t.id, v)
  end

  local function toggle()
    local t = current_target()
    if t and t.kind == "field" then activate_field(by_id[t.id], true) end
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

  -- Scoped to this window: the prompts opened from the form close windows of
  -- their own, which must not use up a `once` handler.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        closed = true
        if opts.on_cancel then opts.on_cancel() end
      end
    end,
  })

  return buf, win
end

return M
