-- Floating merge dialog: 5 toggle options + 2 action lines.
--
-- Keys:
--   <Space> / <CR> on a checkbox  toggle
--   <CR> on an action line        submit (Merge now / Auto-merge)
--   <Esc> / <C-c> / q             cancel
--
-- Three checkboxes carry a value and so cannot be ticked blindly: ticking one
-- opens an input_prompt right away, and the box only ends up ticked when the
-- prompt is submitted with something in it. Cancelling the prompt leaves the
-- box as it was; unticking and ticking again reopens the prompt with what
-- was entered before. Activating an action never opens a prompt — by then
-- everything is already on screen.
--
--   "Edit commit title"        the first line of the merge (or squash)
--                              commit, prefilled with opts.default_title.
--   "Edit commit description"  everything below that line; starts empty
--                              unless opts.default_body is given.
--                              The two are independent — either, both or
--                              neither. Unticked = whatever the forge would
--                              write there. Each line shows its text once
--                              ticked.
--   "Close issue on merge"     the issues to close, prefilled with whatever
--                              the caller detected. The line shows the list,
--                              ticked or not, so it is always visible what
--                              would be closed.

local M = {}

local input_prompt = require("review.ui.input_prompt")
local close_issue = require("review.util.close_issue")
local notify_util = require("review.util.notify")

local CHECKBOXES = {
  { id = "delete_source", label = "Delete source branch" },
  { id = "squash",        label = "Squash commits" },
  { id = "edit_title",    label = "Edit commit title" },
  { id = "edit_body",     label = "Edit commit description" },
  { id = "close_issue",   label = "Close issue on merge" },
}

-- The free-text checkboxes: prompt title, and how the submitted lines become
-- the stored value. A title is one line by definition, so line breaks typed
-- into its prompt collapse into spaces.
local TEXTS = {
  edit_title = {
    prompt = "Merge commit title",
    read = function(lines)
      local parts = {}
      for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line ~= "" then table.insert(parts, line) end
      end
      return table.concat(parts, " ")
    end,
  },
  edit_body = {
    prompt = "Merge commit description",
    read = function(lines)
      return vim.trim(table.concat(lines, "\n"))
    end,
  },
}

local ACTIONS = {
  { id = "merge",      label = "Merge now" },
  { id = "auto_merge", label = "Set auto-merge (after pipeline)" },
}

---@param opts {
---  defaults: { delete_source: boolean|nil, squash: boolean|nil }|nil,
---  default_title: string|nil,                      -- prefill for "Edit commit title"; sent only once confirmed there
---  default_body: string|nil,                       -- prefill for "Edit commit description"
---  close_issues: { refs: string[]|nil, checked: boolean|nil }|nil,  -- prefill / initial state of "Close issue on merge"
---  blocked_reason: string|nil,                     -- shown above actions when present
---  on_submit: fun(action: "merge"|"auto_merge", choices: {
---    delete_source: boolean,
---    squash: boolean,
---    commit_title: string|nil,                     -- nil when its box is unticked
---    commit_body: string|nil,                      -- nil when its box is unticked
---    close_issues: string[],                       -- empty when the box is unticked
---  }),
---  on_cancel: (fun()) | nil,
---}
function M.open(opts)
  opts = opts or {}
  local close_opts = opts.close_issues or {}
  -- Survives unticking, so ticking the box again offers the same list.
  local issue_refs = vim.deepcopy(close_opts.refs or {})
  -- Same for the commit texts: the defaults until the user edits them.
  local text = {
    edit_title = opts.default_title or "",
    edit_body  = opts.default_body or "",
  }
  local checked = {
    delete_source = (opts.defaults and opts.defaults.delete_source) and true or false,
    squash        = (opts.defaults and opts.defaults.squash) and true or false,
    edit_title    = false,
    edit_body     = false,
    close_issue   = (close_opts.checked and #issue_refs > 0) and true or false,
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
      local label = cb.label
      if cb.id == "close_issue" and #issue_refs > 0 then
        label = label .. ": " .. table.concat(issue_refs, ", ")
      elseif TEXTS[cb.id] and checked[cb.id] then
        -- First line only; "…" stands for a cut-off line or further lines.
        local value = text[cb.id]
        local short = vim.fn.strcharpart(value:match("^[^\r\n]*"), 0, 40)
        label = label .. ": " .. short .. (short ~= value and "…" or "")
      end
      push(string.format("    %s %s", mark, label), { kind = "checkbox", id = cb.id })
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

  -- A prompt is a float of its own; hand focus back to the dialog rather than
  -- to whatever window sits underneath.
  local function refocus()
    if not closed and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end

  -- Asks for the commit title / description and ticks the box only when the
  -- answer is not empty.
  ---@param id "edit_title"|"edit_body"
  ---@param label string  the checkbox label, for the "stays off" warning
  local function ask_text(id, label)
    input_prompt.open({
      title = TEXTS[id].prompt,
      -- Nothing to prefill = an empty prompt that starts in insert mode.
      prefill = text[id] ~= "" and vim.split(text[id], "\r?\n") or nil,
      on_submit = function(lines)
        refocus()
        if closed then return end
        local value = TEXTS[id].read(lines)
        if value == "" then
          notify_util.warn(("nothing entered — \"%s\" stays off, the forge default is used"):format(label))
          return
        end
        text[id] = value
        checked[id] = true
        render()
      end,
      on_cancel = refocus,
    })
  end

  -- Asks which issues to close and ticks the box only when the answer names
  -- at least one. Cancelling the prompt leaves the box as it was.
  local function ask_issues()
    input_prompt.open({
      title = "Issues to close (one per line)",
      filetype = "text",
      prefill = issue_refs,
      on_submit = function(lines)
        refocus()
        if closed then return end
        local refs = close_issue.parse_refs(table.concat(lines, "\n"))
        if #refs == 0 then
          notify_util.warn("no issue given — \"Close issue on merge\" stays off")
          return
        end
        issue_refs = refs
        checked.close_issue = true
        render()
      end,
      on_cancel = refocus,
    })
  end

  local function toggle()
    local t = current_target()
    if not t or t.kind ~= "checkbox" then return end
    if t.id == "close_issue" and not checked.close_issue then
      return ask_issues()
    end
    if TEXTS[t.id] and not checked[t.id] then
      for _, cb in ipairs(CHECKBOXES) do
        if cb.id == t.id then return ask_text(t.id, cb.label) end
      end
    end
    checked[t.id] = not checked[t.id]
    render()
  end

  local function finalize(action_id)
    close()
    opts.on_submit(action_id, {
      delete_source = checked.delete_source == true,
      squash = checked.squash == true,
      commit_title = checked.edit_title and text.edit_title or nil,
      commit_body = checked.edit_body and text.edit_body or nil,
      close_issues = checked.close_issue and vim.deepcopy(issue_refs) or {},
    })
  end

  local function activate()
    local t = current_target()
    if not t then return end
    if t.kind == "checkbox" then return toggle() end
    if t.kind ~= "action" then return end
    finalize(t.id)
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
