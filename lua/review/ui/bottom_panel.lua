-- Bottom split holding the rotating panel: commits | info | notes.
-- One buffer, mode-specific render + buffer-local keymaps. The active mode is
-- stored in state.panel.mode; changing modes re-renders the buffer in place.
--
-- line_targets[i] = metadata for line i, used by mode-specific keymaps to act
-- on whatever the cursor is on (a commit sha, a discussion id, etc.).

local M = {}

local state_mod = require("review.state")
local config_mod = require("review.config")
local highlights = require("review.ui.highlights")
local discussion_util = require("review.util.discussion")
local panel_hl = require("review.ui.panel_highlights")

local FT = "review-panel"

local TITLE = {
  commits = "Commits",
  info = "Info",
  notes = "Notes",
}

-- Each hint entry is a { key, label } pair so the winbar can spell out what
-- each binding does (e.g. "<CR>:open  q:end review") rather than just listing
-- raw keys. build_winbar joins them with two spaces.
local HINTS = {
  commits = {
    { "<CR>", "open commit diff" },
    { "[",    "prev mode" },
    { "]",    "next mode" },
    { "q",    "end review" },
  },
  info = {
    { "e", "edit section" },
    { "[", "prev mode" },
    { "]", "next mode" },
    { "q", "end review" },
  },
  notes = {
    { "<CR>", "jump to file" },
    { "a",    "reply" },
    { "c",    "new global note" },
    { "d",    "delete" },
    { "e",    "edit" },
    { "r",    "toggle resolve" },
    { "R",    "toggle resolve all" },
    { "s",    "cycle sort" },
    { "[",    "prev mode" },
    { "]",    "next mode" },
    { "q",    "end review" },
  },
}

-- Sort modes for the Notes panel. Cycled with `s`. Default = "status".
local SORT_ORDER = { "status", "file", "date", "author" }
local SORT_KEYS = {
  status = function(d)
    -- 0 = unresolved (top), 1 = resolved, 2 = non-resolvable (informational)
    if discussion_util.is_resolvable(d) then
      return discussion_util.is_resolved(d) and 1 or 0
    end
    return 2
  end,
  file = function(d)
    local pos = d.notes[1] and d.notes[1].position
    return (pos and (pos.new_path or pos.old_path)) or "~"  -- tilde sorts last
  end,
  date = function(d)
    return d.notes[1] and d.notes[1].created_at or ""
  end,
  author = function(d)
    return (d.notes[1] and d.notes[1].author) or "~"
  end,
}

local function next_sort(mode)
  for i, m in ipairs(SORT_ORDER) do
    if m == mode then return SORT_ORDER[(i % #SORT_ORDER) + 1] end
  end
  return SORT_ORDER[1]
end

---Returns a stable, sorted COPY of `discussions` according to `mode`.
local function sort_discussions(discussions, mode)
  local key_fn = SORT_KEYS[mode] or SORT_KEYS.status
  local indexed = {}
  for i, d in ipairs(discussions) do indexed[i] = { i = i, d = d } end
  table.sort(indexed, function(a, b)
    local ka, kb = key_fn(a.d), key_fn(b.d)
    if ka == kb then return a.i < b.i end  -- stable secondary key
    if mode == "date" then return ka > kb end  -- newest first
    return ka < kb
  end)
  local out = {}
  for i, item in ipairs(indexed) do out[i] = item.d end
  return out
end

local function format_hints(entries)
  if not entries then return "q:end review" end
  local parts = {}
  for _, e in ipairs(entries) do
    table.insert(parts, e[1] .. ":" .. e[2])
  end
  return table.concat(parts, "  ")
end

-- Hooks injected by the controller / commands so this module stays UI-only.
M.hooks = {
  on_commit_open = nil,             -- fun(sha)
  on_section_edit = nil,            -- fun(section_id)  e.g. "title", "labels", ...
  on_comment_jump = nil,            -- fun(target)
  on_comment_delete = nil,          -- fun(target)
  on_comment_edit = nil,            -- fun(target)
  on_comment_reply = nil,           -- fun(target)         a
  on_comment_resolve_toggle = nil,  -- fun(target)         r
  on_comment_resolve_all = nil,     -- fun()               R
  on_global_comment = nil,          -- fun()
  on_close = nil,                   -- fun()
}

local function panel_state() return state_mod.state.panel end

local function set_lines(lines)
  local p = panel_state()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = p.buf })
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = p.buf })
end

local function clear_buffer_keymaps()
  local p = panel_state()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  for _, key in ipairs({ "<CR>", "d", "e", "c", "a", "r", "R", "s" }) do
    pcall(vim.api.nvim_buf_del_keymap, p.buf, "n", key)
  end
end

local function map(key, fn)
  local p = panel_state()
  vim.keymap.set("n", key, fn, { buffer = p.buf, silent = true, noremap = true, nowait = true })
end

local function current_target()
  local p = panel_state()
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(p.win)[1]
  return p.line_targets[row]
end

-- ---------------------------------------------------------------- renderers

local function render_commits()
  local p = panel_state()
  p.line_targets = {}
  local commits = state_mod.state.commits or {}
  local lines = {}
  if #commits == 0 then
    table.insert(lines, "(no commits)")
    set_lines(lines)
    panel_hl.clear(p.buf)
    return
  end
  for _, c in ipairs(commits) do
    local short = c.short_id or (c.id and c.id:sub(1, 8)) or "????????"
    local line = string.format("%s  %s — %s", short, c.author_name or "?", c.title or "")
    table.insert(lines, line)
    p.line_targets[#lines] = { kind = "commit", sha = c.id, short = short }
  end
  set_lines(lines)
  panel_hl.clear(p.buf)
  panel_hl.apply_commits(p.buf, lines, p.line_targets)
  clear_buffer_keymaps()
  map("<CR>", function()
    local t = current_target()
    if t and t.sha and M.hooks.on_commit_open then M.hooks.on_commit_open(t.sha) end
  end)
end

local function format_seconds(s)
  s = tonumber(s) or 0
  if s <= 0 then return "0" end
  local hours = math.floor(s / 3600)
  local mins = math.floor((s % 3600) / 60)
  if hours > 0 and mins > 0 then return string.format("%dh %dm", hours, mins) end
  if hours > 0 then return string.format("%dh", hours) end
  return string.format("%dm", mins)
end

-- Compact "approved (1/2)" / "approved (3)" / "not approved" string.
-- Returns nil when the provider hasn't populated mr.approval (info skipped).
local function format_approval(ap)
  if not ap then return nil end
  local count = #(ap.approved_by or {})
  if count == 0 then return "not approved" end
  if ap.required and ap.required > 0 then
    return string.format("approved (%d/%d)", count, ap.required)
  end
  return string.format("approved (%d)", count)
end

-- Map detailed_merge_status / merge_status into a one-token blocker label.
-- detailed_merge_status (GitLab) is the most precise; fall back to the older
-- merge_status / has_conflicts when it's not populated.
local READY_LABELS = {
  mergeable                = "ready to merge",
  ci_must_pass             = "needs pipeline",
  ci_still_running         = "needs pipeline",
  discussions_not_resolved = "unresolved threads",
  draft_status             = "draft",
  not_approved             = "needs approval",
  conflict                 = "conflicts",
  not_open                 = nil,  -- state line already conveys this
}

local function format_ready(mr)
  local d = mr.detailed_merge_status
  if d and READY_LABELS[d] ~= nil then return READY_LABELS[d] end
  if mr.has_conflicts then return "conflicts" end
  if mr.merge_status == "can_be_merged" then return "ready to merge" end
  if mr.merge_status == "cannot_be_merged" then return "not mergeable" end
  if mr.merge_status == "checking" then return "checking..." end
  return nil
end

local function user_display(u)
  if not u then return "?" end
  if u.name and u.name ~= u.username then
    return string.format("@%s (%s)", u.username or "?", u.name)
  end
  return "@" .. (u.username or "?")
end

local function user_list_short(users)
  if not users or #users == 0 then return "(none)" end
  local parts = {}
  for _, u in ipairs(users) do table.insert(parts, "@" .. (u.username or "?")) end
  return table.concat(parts, ", ")
end

---Returns the line index where the section content begins, ready to be
---extended by content lines that should also belong to the section.
local function push_section(lines, p, section_id, label)
  table.insert(lines, "")
  p.line_targets[#lines] = { kind = "section_gap" }
  table.insert(lines, string.format("── %s ──", label))
  p.line_targets[#lines] = { kind = "section_header", section = section_id }
end

local function push_content(lines, p, section_id, text)
  for _, l in ipairs(vim.split(text or "", "\n", { plain = true })) do
    table.insert(lines, l)
    p.line_targets[#lines] = { kind = "section_body", section = section_id }
  end
end

local function render_description()
  local p = panel_state()
  p.line_targets = {}
  local mr = state_mod.state.mr
  local lines = {}
  if not mr then
    table.insert(lines, "(no MR loaded)")
    set_lines(lines)
    return
  end

  -- Header: !iid · author · branch flow · state · [approval] · [ready state].
  -- Not part of any editable section, so cursor on these lines does nothing
  -- on `e`. Approval / ready segments are appended only when populated and
  -- never duplicated (e.g. "needs approval" doesn't appear twice).
  local header_parts = {
    "!" .. tostring(mr.iid),
    "by @" .. (mr.author_name or "?"),
    (mr.source_branch or "?") .. " → " .. (mr.target_branch or "?"),
    mr.state or "?",
  }
  local approval = format_approval(mr.approval)
  local ready = format_ready(mr)
  if approval then table.insert(header_parts, approval) end
  if ready and ready ~= approval then table.insert(header_parts, ready) end
  table.insert(lines, table.concat(header_parts, "  •  "))
  p.line_targets[#lines] = { kind = "header" }

  push_section(lines, p, "draft", "Draft")
  push_content(lines, p, "draft", mr.is_draft and "[x] yes" or "[ ] no")

  push_section(lines, p, "title", "Title")
  push_content(lines, p, "title", mr.title or "")

  push_section(lines, p, "target_branch", "Target branch")
  push_content(lines, p, "target_branch",
    (mr.target_branch and mr.target_branch ~= "") and mr.target_branch or "(unset)")

  push_section(lines, p, "description", "Description")
  push_content(lines, p, "description", (mr.description ~= nil and mr.description ~= "") and mr.description or "(empty)")

  push_section(lines, p, "assignees", "Assignees")
  push_content(lines, p, "assignees", user_list_short(mr.assignees))

  push_section(lines, p, "reviewers", "Reviewers")
  push_content(lines, p, "reviewers", user_list_short(mr.reviewers))

  push_section(lines, p, "labels", "Labels")
  push_content(lines, p, "labels",
    (mr.labels and #mr.labels > 0) and table.concat(mr.labels, ", ") or "(none)")

  push_section(lines, p, "milestone", "Milestone")
  push_content(lines, p, "milestone",
    (mr.milestone and mr.milestone.title) or "(none)")

  -- Time tracking section is provider-dependent. GitLab returns a struct
  -- (possibly with zero values) → visible. GitHub has no time tracking API
  -- and returns nil → section skipped entirely.
  if mr.time_stats then
    push_section(lines, p, "time_tracking", "Time tracking")
    local ts = mr.time_stats
    local est = ts.human_time_estimate or (ts.time_estimate and ts.time_estimate > 0 and format_seconds(ts.time_estimate)) or "(none)"
    local spent = ts.human_total_time_spent or (ts.total_time_spent and ts.total_time_spent > 0 and format_seconds(ts.total_time_spent)) or "0"
    push_content(lines, p, "time_tracking", string.format("Estimate: %s\nSpent: %s", est, spent))
  end

  push_section(lines, p, "participants", "Participants")
  local participants = state_mod.state.participants or {}
  if #participants == 0 then
    push_content(lines, p, "participants", "(none)")
  else
    for _, u in ipairs(participants) do
      table.insert(lines, "  " .. user_display(u))
      p.line_targets[#lines] = { kind = "section_body", section = "participants" }
    end
  end

  set_lines(lines)
  panel_hl.clear(p.buf)
  panel_hl.apply_info(p.buf, lines, p.line_targets)
  clear_buffer_keymaps()
  map("e", function()
    local t = current_target()
    if not t or not t.section then return end
    if M.hooks.on_section_edit then M.hooks.on_section_edit(t.section) end
  end)
end

local function render_comments()
  local p = panel_state()
  p.line_targets = {}
  p.notes_sort = p.notes_sort or "status"
  local lines = {}
  local raw_discussions = state_mod.state.discussions or {}
  local discussions = sort_discussions(raw_discussions, p.notes_sort)

  local visible = 0
  for _, d in ipairs(discussions) do
    if not (d.notes[1] and d.notes[1].system) then
      visible = visible + 1
      local first = d.notes[1]
      local pos = first and first.position
      local icon = highlights.icon_for(d)
      local header
      if pos and pos ~= vim.NIL and (pos.new_path or pos.old_path) then
        header = string.format("%s %s:%s  @%s",
          icon,
          pos.new_path or pos.old_path,
          tostring(pos.new_line or pos.old_line or "?"),
          first.author or "?")
      else
        header = string.format("%s (global)  @%s", icon, (first and first.author) or "?")
      end
      table.insert(lines, header)
      p.line_targets[#lines] = {
        kind = "discussion_head",
        discussion_id = d.id,
        note_id = first and first.id,
        position = pos,
      }
      local body = (first and first.body) or ""
      for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(lines, "    " .. l)
        p.line_targets[#lines] = {
          kind = "discussion_body",
          discussion_id = d.id,
          note_id = first and first.id,
          position = pos,
        }
      end
      for i = 2, #d.notes do
        local n = d.notes[i]
        if not n.system then
          local first_line = true
          for _, l in ipairs(vim.split(n.body or "", "\n", { plain = true })) do
            if first_line then
              table.insert(lines, string.format("    ↳ @%s: %s", n.author or "?", l))
              first_line = false
            else
              table.insert(lines, "         " .. l)
            end
            p.line_targets[#lines] = {
              kind = "reply",
              discussion_id = d.id,
              note_id = n.id,
              position = pos,
            }
          end
        end
      end
      table.insert(lines, "")
      p.line_targets[#lines] = nil
    end
  end

  if visible == 0 then
    table.insert(lines, "(no notes)")
  end
  set_lines(lines)
  panel_hl.clear(p.buf)
  panel_hl.apply_notes(p.buf, lines, p.line_targets)

  clear_buffer_keymaps()
  map("<CR>", function()
    local t = current_target()
    if t and M.hooks.on_comment_jump then M.hooks.on_comment_jump(t) end
  end)
  map("d", function()
    local t = current_target()
    if t and M.hooks.on_comment_delete then M.hooks.on_comment_delete(t) end
  end)
  map("e", function()
    local t = current_target()
    if t and M.hooks.on_comment_edit then M.hooks.on_comment_edit(t) end
  end)
  map("c", function()
    if M.hooks.on_global_comment then M.hooks.on_global_comment() end
  end)
  map("a", function()
    local t = current_target()
    if t and M.hooks.on_comment_reply then M.hooks.on_comment_reply(t) end
  end)
  map("r", function()
    local t = current_target()
    if t and M.hooks.on_comment_resolve_toggle then M.hooks.on_comment_resolve_toggle(t) end
  end)
  map("R", function()
    if M.hooks.on_comment_resolve_all then M.hooks.on_comment_resolve_all() end
  end)
  map("s", function()
    p.notes_sort = next_sort(p.notes_sort or "status")
    M.refresh()
  end)
end

local RENDERERS = {
  commits = render_commits,
  info = render_description,
  notes = render_comments,
}

-- ---------------------------------------------------------------- public API

local function build_winbar(mode)
  local title = TITLE[mode] or "Panel"
  local hints = format_hints(HINTS[mode])
  if mode == "notes" then
    local unresolved, total = discussion_util.counts(state_mod.state.discussions)
    local status_icon
    if total == 0 then
      status_icon = highlights.ICON_COMMENT
    elseif unresolved > 0 then
      status_icon = highlights.ICON_UNRESOLVED
    else
      status_icon = highlights.ICON_RESOLVED
    end
    local sort_mode = (panel_state().notes_sort) or "status"
    return string.format("  %s  %d/%d %s  │  sort: %s  │  %s",
      title, unresolved, total, status_icon, sort_mode, hints)
  end
  return string.format("  %s  │  %s", title, hints)
end

---Foldexpr called by Neovim. Returns the fold level for `lnum` (1-indexed)
---based on `line_targets[lnum].kind`. Discussion heads start a new fold at
---level 1; bodies and replies stay at level 1; everything else (separators,
---empty lines) is level 0.
function M.fold_expr(lnum)
  local p = panel_state()
  local target = p.line_targets and p.line_targets[lnum]
  if not target then return "0" end
  if target.kind == "discussion_head" then return ">1" end
  if target.kind == "discussion_body" or target.kind == "reply" then return "1" end
  return "0"
end

local function setup_notes_folds()
  local p = panel_state()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return end
  -- foldmethod / foldexpr / foldenable / foldlevel / foldcolumn are all
  -- WINDOW-local options (not buffer-local). Pass `win = ...` not `buf =`.
  pcall(vim.api.nvim_set_option_value, "foldmethod", "expr", { win = p.win })
  pcall(vim.api.nvim_set_option_value, "foldexpr",
    "v:lua.require'review.ui.bottom_panel'.fold_expr(v:lnum)",
    { win = p.win })
  pcall(vim.api.nvim_set_option_value, "foldenable", true, { win = p.win })
  pcall(vim.api.nvim_set_option_value, "foldlevel", 0, { win = p.win })
  pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = p.win })
  -- Recompute folds from scratch (the buffer was just rewritten).
  pcall(vim.api.nvim_win_call, p.win, function() vim.cmd("silent! normal! zx") end)
end

local function clear_folds()
  local p = panel_state()
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return end
  pcall(vim.api.nvim_set_option_value, "foldmethod", "manual", { win = p.win })
  pcall(vim.api.nvim_set_option_value, "foldexpr", "0", { win = p.win })
  pcall(vim.api.nvim_win_call, p.win, function() vim.cmd("silent! normal! zE") end)
end

function M.set_mode(mode)
  if not RENDERERS[mode] then return end
  local p = panel_state()
  p.mode = mode
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  RENDERERS[mode]()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_set_option_value, "winbar", build_winbar(mode), { win = p.win })
  end
  if mode == "notes" then
    setup_notes_folds()
  else
    clear_folds()
  end
end

---Move the panel cursor to the head line of the discussion with `discussion_id`,
---then collapse all other folds and expand only this one (`zM` then `zv`).
---No-op if panel is closed, mode is not "notes", or the discussion isn't
---rendered in the current line_targets (e.g. system note, filtered out).
---@param discussion_id any
function M.scroll_to_discussion(discussion_id)
  local p = panel_state()
  if p.mode ~= "notes" then return end
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return end
  if not discussion_id then return end
  for line, target in pairs(p.line_targets or {}) do
    if target and target.kind == "discussion_head" and target.discussion_id == discussion_id then
      pcall(vim.api.nvim_win_set_cursor, p.win, { line, 0 })
      pcall(vim.api.nvim_win_call, p.win, function()
        vim.cmd("silent! normal! zMzv")
      end)
      return
    end
  end
end

---Collapse every fold in the notes panel. Used by the cursor-driven
---auto-expand path when the diffview cursor isn't on any commented line —
---the panel returns to its default "all collapsed" state.
function M.collapse_all()
  local p = panel_state()
  if p.mode ~= "notes" then return end
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return end
  pcall(vim.api.nvim_win_call, p.win, function()
    vim.cmd("silent! normal! zM")
  end)
end

function M.refresh()
  local p = panel_state()
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  M.set_mode(p.mode or "commits")
end

-- Public mode order used by the `[` / `]` keymaps.
local MODE_CYCLE = { "info", "commits", "notes" }

---Switches to the mode `step` slots away from the current one (1 = next,
----1 = previous). Wraps around at both ends.
---@param step integer
function M.cycle_mode(step)
  local p = panel_state()
  local current = p.mode or "info"
  local idx
  for i, m in ipairs(MODE_CYCLE) do
    if m == current then idx = i; break end
  end
  if not idx then idx = 1 end
  local n = #MODE_CYCLE
  -- Lua's modulo on negative offsets needs the +n nudge to land in [1, n].
  local next_idx = ((idx - 1 + step) % n + n) % n + 1
  M.set_mode(MODE_CYCLE[next_idx])
end

function M.open(initial_mode)
  local cfg = config_mod.get()
  local height = (cfg.panel and cfg.panel.height) or 12
  local p = panel_state()

  -- Define / link highlight groups once per Nvim session. Idempotent inside.
  panel_hl.setup_groups()

  vim.cmd(string.format("botright %dsplit", height))
  p.win = vim.api.nvim_get_current_win()

  p.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(p.win, p.buf)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = p.buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = p.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = p.buf })
  vim.api.nvim_set_option_value("filetype", FT, { buf = p.buf })

  vim.api.nvim_set_option_value("wrap", false, { win = p.win })
  vim.api.nvim_set_option_value("number", false, { win = p.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = p.win })
  vim.api.nvim_set_option_value("cursorline", true, { win = p.win })

  -- Always-on keymaps: persist across mode switches because they aren't
  -- mode-specific (clear_buffer_keymaps doesn't touch them).
  --   q       close the panel (delegates to controller).
  --   ] / [   cycle bottom panel mode forward / backward through
  --           info -> commits -> notes -> info ...
  local opts = { buffer = p.buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "q", function()
    if M.hooks.on_close then M.hooks.on_close() end
  end, opts)
  vim.keymap.set("n", "]", function() M.cycle_mode(1) end, opts)
  vim.keymap.set("n", "[", function() M.cycle_mode(-1) end, opts)

  M.set_mode(initial_mode or "commits")
end

function M.close()
  local p = panel_state()
  if p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  p.win = nil
  p.buf = nil
end

function M.is_open()
  local p = panel_state()
  return p.win ~= nil and vim.api.nvim_win_is_valid(p.win)
end

return M
