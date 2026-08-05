-- Read-only float showing the discussion thread anchored to the cursor's line.
--
-- Availability is defined by the gutter: wherever review.ui.highlights placed an
-- icon, the key works — diffview content buffers (side resolved via diffview's
-- own layout) and plain working-tree files of the session (matched by name).
-- The lookup is highlights.discussions_at, i.e. the READ side of the very index
-- that positions the icons, so the two can never disagree.
--
-- Interaction mirrors a fold preview: the first press opens the float WITHOUT
-- focus, the second moves the cursor into it, `q` / <Esc> closes. Moving the
-- cursor in the origin window dismisses it. The float is deliberately inert —
-- reply / resolve / edit stay in the Notes panel so there's one place that
-- mutates a thread.
--
-- Suggestions are rendered as a diff rather than as a raw ```suggestion fence;
-- see review.util.suggestion for the parsing and review.util.blob for where the
-- replaced ("-") lines come from.

local M = {}

local config_mod = require("review.config")
local highlights = require("review.ui.highlights")
local panel_hl = require("review.ui.panel_highlights")
local suggestion = require("review.util.suggestion")
local blob = require("review.util.blob")
local diffview_int = require("review.diffview.integration")
local notify_util = require("review.util.notify")

local FT = "review-note"

---@type { win: integer|nil, buf: integer|nil, origin_win: integer|nil,
---         origin_buf: integer|nil, origin_line: integer|nil,
---         owners: table[], session_tab: integer|nil,
---         ids: integer[], closing: boolean }
local S = { ids = {}, owners = {}, closing = false }

-- region Helpers

---JSON nulls arrive as vim.NIL — treat them (and non-strings) as absent.
local function str(v)
  if type(v) ~= "string" or v == "" then return nil end
  return v
end

local function normalize(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""))
end

local function cfg()
  local c = config_mod.get().note_preview
  if type(c) ~= "table" then return nil end
  return c
end

---The configured key, or nil when the feature is switched off.
---@return string|nil
local function resolve_key()
  local c = cfg()
  if not c then return nil end
  local key = c.key
  if key == false or key == nil or key == "" then return nil end
  return key
end

---"3 minutes ago" style stamp from an ISO-8601 created_at. Returns nil when the
---timestamp is missing or unparseable — the header simply omits the segment.
---@param iso string|nil
---@return string|nil
local function relative_date(iso)
  iso = str(iso)
  if not iso then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)")
  if not y then return nil end
  local ok, t = pcall(os.time, {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  if not ok or not t then return nil end
  -- created_at is UTC; os.time read the fields as local, so undo the offset.
  local now = os.time()
  local utc_skew = os.difftime(now, os.time(os.date("!*t", now)))
  local diff = os.difftime(now, t + utc_skew)
  if diff < 0 then diff = 0 end
  if diff < 60 then return "just now" end
  if diff < 3600 then return string.format("%dm ago", math.floor(diff / 60)) end
  if diff < 86400 then return string.format("%dh ago", math.floor(diff / 3600)) end
  if diff < 86400 * 30 then return string.format("%dd ago", math.floor(diff / 86400)) end
  return os.date("%Y-%m-%d", t)
end

-- endregion

-- region Content

---Resolves the NEW-side source a suggestion replaces.
---
---A suggestion always applies to the new side, whichever pane the reader is in,
---so this goes to the object store at head_sha rather than to the buffer under
---the cursor: a working-tree buffer may carry uncommitted edits, which would
---render a diff that looks right and isn't. The buffer is used only when
---diffview vouches for it being that exact new-side content.
---@param pos table
---@param origin_buf integer
---@return fun(): string[]|nil
local function origin_fetcher(pos, origin_buf)
  return function()
    local new_path = str(pos.new_path)
    if not new_path then return nil end

    local t = diffview_int.buf_diff_target(origin_buf)
    if t and t.side == "new" and normalize(t.path) == normalize(new_path) then
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, origin_buf, 0, -1, false)
      if ok and lines then return lines end
    end

    -- Not get_active(): in an ordinary editing tab there IS no active session,
    -- and this feature's whole point is to work there. Ask highlights which
    -- session applies to this tab — the same answer the anchors came from.
    local session = highlights.active_session()
    local head = session and session.mr and session.mr.head_sha
    return blob.lines(head, new_path)
  end
end

---Renders one thread: header, the anchor note's body (with any suggestion
---turned into a diff), then its replies.
---@param d table  normalized discussion
---@param anchor table  the matching gutter anchor
---@param origin_buf integer
---@param push fun(text: string, kind: string)
local function render_thread(d, anchor, origin_buf, push)
  local first = d.notes and d.notes[1]
  if not first then return end
  local pos = type(first.position) == "table" and first.position or nil

  local head = string.format("%s %s:%d  @%s",
    highlights.icon_for(d), anchor.path, anchor.line, str(first.author) or "?")
  local when = relative_date(first.created_at)
  if when then head = head .. "  · " .. when end
  push(head, "head")

  local body, kinds = suggestion.render(first.body, pos, origin_fetcher(pos or {}, origin_buf))
  for i, l in ipairs(body) do
    push(l, kinds[i] == "text" and "body" or kinds[i])
  end

  -- Replies. System notes ("changed this line in version 2") are bookkeeping,
  -- not conversation — the Notes panel hides them too.
  for i = 2, #(d.notes or {}) do
    local n = d.notes[i]
    if n and not n.system then
      push("", "body")
      local rbody, rkinds = suggestion.render(n.body, pos, origin_fetcher(pos or {}, origin_buf))
      local author = str(n.author) or "?"
      if #rbody == 0 then
        push(string.format("↳ @%s:", author), "reply")
      end
      for j, l in ipairs(rbody) do
        if j == 1 and rkinds[j] == "text" then
          push(string.format("↳ @%s: %s", author, l), "reply")
        elseif j == 1 then
          push(string.format("↳ @%s:", author), "reply")
          push("  " .. l, rkinds[j])
        else
          push("  " .. l, rkinds[j] == "text" and "reply" or rkinds[j])
        end
      end
    end
  end
end

---Builds the float's contents for every thread anchored to the line.
---
---`owners[i]` is the discussion that row i belongs to — the float's equivalent
---of the panel's `line_targets` (bottom_panel.lua), and what lets the in-float
---resolve / reply keys act on the thread under the cursor rather than guessing
---when several threads share a line.
---@param hits table[]  anchors from highlights.discussions_at
---@param origin_buf integer
---@return string[] lines, string[] kinds, integer[] separator_rows, table[] owners
local function build(hits, origin_buf)
  local lines, kinds, seps, owners = {}, {}, {}, {}
  local current
  local function push(text, kind)
    lines[#lines + 1] = text
    kinds[#kinds + 1] = kind
    owners[#lines] = current
  end

  for i, hit in ipairs(hits) do
    if i > 1 then
      current = nil  -- the gap between threads belongs to neither
      push("", "body")
      seps[#seps + 1] = #lines + 1  -- filled once the width is known
      push("", "separator")
      push("", "body")
    end
    current = hit.discussion
    render_thread(hit.discussion, hit, origin_buf, push)
  end
  current = nil

  -- Never end on a blank row: it reads as a rendering glitch inside a border.
  while #lines > 0 and lines[#lines] == "" do
    owners[#lines] = nil
    table.remove(lines)
    table.remove(kinds)
  end
  return lines, kinds, seps, owners
end

-- endregion

-- region Float

---Width, height and the true wrapped row count. Height must count WRAPPED rows
---because the float wraps prose — using #lines would clip long comments.
---@return integer width, integer height, integer rows
local function measure(lines, c)
  local max_width = tonumber(c.max_width) or 80
  local max_height = tonumber(c.max_height) or 20

  local w = 1
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(l))
  end
  w = math.max(20, math.min(w, max_width, vim.o.columns - 4))

  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / w))
  end
  local h = math.max(1, math.min(rows, max_height, vim.o.lines - 6))
  return w, h, rows
end

local function del_autocmds()
  for _, id in ipairs(S.ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  S.ids = {}
end

---@return boolean
function M.is_open()
  return S.win ~= nil and vim.api.nvim_win_is_valid(S.win)
end

---Closes the float and resets state. Idempotent and re-entrancy safe: WinClosed
---fires from inside nvim_win_close, so close() is reached recursively.
function M.close()
  if S.closing then return end
  S.closing = true

  del_autocmds()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    pcall(vim.api.nvim_win_close, S.win, true)
  end
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    pcall(vim.api.nvim_buf_delete, S.buf, { force = true })
  end

  S.win, S.buf = nil, nil
  S.origin_win, S.origin_buf, S.origin_line = nil, nil, nil
  S.owners, S.session_tab = {}, nil
  S.closing = false
end

---Writes `lines` into the float's buffer and re-applies highlights. Split out
---because both the initial open and a post-action re-render need it, and the
---buffer is kept unmodifiable in between.
local function set_content(buf, lines, kinds)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_set_option_value("readonly", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  panel_hl.clear(buf)
  panel_hl.apply_note_preview(buf, lines, kinds)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("readonly", true, { buf = buf })
end

---@param hits table[]
---@param origin_buf integer
---@param origin_line integer
local function open(hits, origin_buf, origin_line)
  local c = cfg() or {}
  panel_hl.setup_groups()

  local lines, kinds, seps, owners = build(hits, origin_buf)
  if #lines == 0 then return end

  local width, height, rows = measure(lines, c)
  for _, row in ipairs(seps) do
    lines[row] = ("─"):rep(width)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", FT, { buf = buf })
  set_content(buf, lines, kinds)

  -- Flip above the cursor when there isn't room below, and pull left when the
  -- float would run off the right edge. screenrow/screencol are the right
  -- coordinate space for relative="cursor".
  local srow, scol = vim.fn.screenrow(), vim.fn.screencol()
  local below = vim.o.lines - srow - vim.o.cmdheight - 2
  local above = srow - 2
  if height > math.max(below, above) then
    height = math.max(1, math.max(below, above))
  end
  local row = (height + 2 <= below) and 1 or -(height + 2)
  local col = 0
  local overflow = (scol + width + 2) - vim.o.columns
  if overflow > 0 then col = -overflow end

  local key = resolve_key()
  local opts = {
    relative = "cursor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = c.border or "rounded",
    focusable = true,
    zindex = 50,
  }
  if opts.border ~= "none" then
    local title = (#hits > 1)
      and string.format(" %d threads · %s:%d ", #hits, hits[1].path, hits[1].line)
      or string.format(" %s:%d ", hits[1].path, hits[1].line)
    opts.title = title
    opts.title_pos = "center"
    -- Inside the float the action keys are live; from outside they aren't yet,
    -- so the hint leads with what gets you in there.
    local hints = { "q/<Esc> close" }
    if rows > height and key then
      table.insert(hints, 1, key .. " focus & scroll")
    end
    local acts = {}
    if c.resolve_key then acts[#acts + 1] = c.resolve_key .. " resolve" end
    if c.reply_key then acts[#acts + 1] = c.reply_key .. " reply" end
    if #acts > 0 then hints[#hints + 1] = table.concat(acts, "  ") end
    opts.footer = " " .. table.concat(hints, "  ·  ") .. " "
    opts.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(buf, false, opts)

  S.win, S.buf = win, buf
  S.origin_win = vim.api.nvim_get_current_win()
  S.origin_buf, S.origin_line = origin_buf, origin_line
  S.owners = owners
  -- Remember WHICH session these threads came from. In an editing tab there is
  -- no active session, so the resolve / reply keys can't look it up later —
  -- and the answer must not change under them if the user switches tabs.
  S.session_tab = select(2, highlights.active_session())

  -- A float inherits window options from the current window; the diff windows
  -- carry diff/fold settings that make no sense here, and `style = "minimal"`
  -- doesn't cover wrap or conceallevel.
  local wo = {
    wrap = true, linebreak = true, breakindent = true,
    conceallevel = 0, foldenable = false, cursorline = false,
    number = false, relativenumber = false, signcolumn = "no", scrolloff = 0,
    winhighlight = "NormalFloat:ReviewPreviewNormal,FloatBorder:ReviewPreviewBorder",
  }
  for name, value in pairs(wo) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end

  local map_opts = { buffer = buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "q", M.close, map_opts)
  vim.keymap.set("n", "<Esc>", M.close, map_opts)
  vim.keymap.set("n", "<C-c>", M.close, map_opts)
  -- Third press of the configured key closes: open -> focus -> close.
  if key then vim.keymap.set("n", key, M.close, map_opts) end
  if c.resolve_key then
    vim.keymap.set("n", c.resolve_key, M.resolve_under_cursor, map_opts)
  end
  if c.reply_key then
    vim.keymap.set("n", c.reply_key, M.reply_under_cursor, map_opts)
  end

  -- Dismiss when the cursor really moves in the origin window.
  --
  -- Two guards, both needed. The window check swallows the spurious event that
  -- fires for the origin buffer when focus moves INTO the float (this is what
  -- a `once` registration would burn itself on, forcing the re-arm dance).
  -- The line check keeps horizontal movement on the anchored line harmless.
  S.ids[#S.ids + 1] = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = origin_buf,
    callback = function()
      if not M.is_open() then return end
      if vim.api.nvim_get_current_win() ~= S.origin_win then return end
      local ok, pos = pcall(vim.api.nvim_win_get_cursor, S.origin_win)
      if ok and pos[1] == S.origin_line then return end
      M.close()
    end,
  })

  -- Walking out of the float dismisses it, same as `q`.
  S.ids[#S.ids + 1] = vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function() M.close() end,
  })

  -- The float is pinned to the cursor at creation time and does not follow the
  -- viewport, so anything that moves the viewport out from under it invalidates
  -- its position.
  S.ids[#S.ids + 1] = vim.api.nvim_create_autocmd(
    { "WinScrolled", "WinResized", "VimResized", "TabLeave" },
    { callback = function() M.close() end })

  -- Closed some other way (:q, :close, window wiped with its tab).
  S.ids[#S.ids + 1] = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    callback = function() M.close() end,
  })
end

-- endregion

-- region Public API

---Open the preview for the line under the cursor; focus it if it's already
---open; no-op when the cursor is inside it.
function M.toggle()
  if M.is_open() then
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == S.win then return end
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
    if cur_win == S.origin_win
        and vim.api.nvim_get_current_buf() == S.origin_buf
        and ok and pos[1] == S.origin_line then
      vim.api.nvim_set_current_win(S.win)
      return
    end
    -- Anchored somewhere else now (a Lua-driven jump can dodge CursorMoved):
    -- rebuild rather than showing a float that belongs to another line.
    M.close()
  end

  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local hits = highlights.discussions_at(buf, line)
  if #hits == 0 then
    notify_util.progress("no note on this line")
    return
  end
  open(hits, buf, line)
end

---The discussion the cursor is on inside the float, plus the session it belongs
---to. Returns nil when the cursor is on a separator / inter-thread gap.
---@return table|nil discussion, integer|nil session_tab
local function thread_under_cursor()
  if not M.is_open() then return nil end
  if vim.api.nvim_get_current_win() ~= S.win then return nil end
  local row = vim.api.nvim_win_get_cursor(S.win)[1]
  return S.owners[row], S.session_tab
end

---Panel-shaped target table, so the shared action modules take it unchanged.
local function target_for(d)
  local first = d.notes and d.notes[1]
  return {
    kind = "discussion_head",
    discussion_id = d.id,
    note_id = first and first.id,
    position = first and first.position,
  }
end

---Toggle resolve on the thread under the cursor in the float.
function M.resolve_under_cursor()
  local d, tab = thread_under_cursor()
  if not d then
    notify_util.progress("no thread under cursor")
    return
  end
  require("review.actions.resolve_thread").run(target_for(d), tab)
end

---Reply to the thread under the cursor in the float.
function M.reply_under_cursor()
  local d, tab = thread_under_cursor()
  if not d then
    notify_util.progress("no thread under cursor")
    return
  end
  -- The reply prompt is itself a float and steals focus; dismissing the preview
  -- first keeps one modal thing on screen at a time, and refresh_discussions
  -- would tear it down after posting anyway.
  local origin_win, origin_buf, origin_line = S.origin_win, S.origin_buf, S.origin_line
  M.close()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_set_current_win, origin_win)
    if origin_buf and origin_line then
      pcall(vim.api.nvim_win_set_cursor, origin_win, { origin_line, 0 })
    end
  end
  require("review.actions.reply_comment").run(target_for(d), tab)
end

---Re-render an open float against the session's current discussions.
---
---Called after a refresh so a resolve toggle done from inside the float shows
---up immediately (icon flips ❌ → ✅) instead of the float either going stale or
---vanishing. Closes when the line no longer carries any thread.
function M.refresh()
  if not M.is_open() then return end
  local origin_buf, origin_line = S.origin_buf, S.origin_line
  if not origin_buf or not origin_line then return end
  if not vim.api.nvim_buf_is_valid(origin_buf) then return M.close() end

  local hits = highlights.discussions_at(origin_buf, origin_line)
  if #hits == 0 then return M.close() end

  local lines, kinds, seps, owners = build(hits, origin_buf)
  if #lines == 0 then return M.close() end

  local width = vim.api.nvim_win_get_config(S.win).width
  for _, row in ipairs(seps) do
    lines[row] = ("─"):rep(width)
  end
  set_content(S.buf, lines, kinds)
  S.owners = owners
end

-- endregion

return M
