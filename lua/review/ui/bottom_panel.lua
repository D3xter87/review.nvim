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
local commit_preview = require("review.ui.commit_preview")
local git_log = require("review.git.log")

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
    { "K",    "message" },
    { "h/[",  "prev mode" },
    { "l/]",  "next mode" },
    { "q",    "end review" },
  },
  info = {
    { "j/k", "sections" },
    { "e", "edit section" },
    { "h/[", "prev mode" },
    { "l/]", "next mode" },
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
    { "h/[",  "prev mode" },
    { "l/]",  "next mode" },
    { "q",    "end review" },
  },
}

-- Sort modes for the Notes panel. Cycled with `s`. Default = "status".
local SORT_ORDER = { "status", "file", "date", "author" }
local SORT_KEYS = {
  status = function(d)
    -- -1 = pending (your own unsent notes, always on top), 0 = unresolved,
    -- 1 = resolved, 2 = non-resolvable (informational)
    if d.pending then return -1 end
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
    local created = d.notes[1] and d.notes[1].created_at
    -- A pending note may carry no date at all (GitLab drafts): it is newer
    -- than anything published, not older.
    if d.pending and not created then return "9999" end
    return created or ""
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
  on_review_start = nil,            -- fun()               P
  on_review_submit = nil,           -- fun()               S
  on_review_discard = nil,          -- fun()               X
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
  -- j / k too: Info maps them to section jumps, the other modes must get
  -- plain line motion back. K is the Commits float.
  for _, key in ipairs({ "<CR>", "d", "e", "c", "a", "r", "R", "s", "P", "S", "X", "j", "k", "K" }) do
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

-- Commit subjects longer than this are cut with an ellipsis, so the author
-- and date behind them stay on screen (the panel doesn't wrap).
local SUBJECT_MAX = 72
-- Width of the first column: an 8-char short sha, or "all".
local ID_WIDTH = 8

---Lines for the commit float (`K`) of the row `t`: the full message + stat
---from the local repo, or what the API gave us when the commit isn't there.
---@param t table  line target ("all" | "commit")
---@return string[]|nil
local function commit_float_lines(t)
  local s = state_mod.state
  local mr = s.mr
  if t.kind == "all" then
    local lines = s.repo and mr and git_log.describe(s.repo, nil, mr.base_sha, mr.head_sha)
    if not lines then return nil end
    table.insert(lines, 1, t.subject)
    table.insert(lines, 2, "")
    return lines
  end
  if t.kind ~= "commit" then return nil end
  local lines = s.repo and git_log.describe(s.repo, t.sha)
  if lines then return lines end
  local c = t.commit or {}
  return {
    "commit " .. (t.sha or "?"),
    "Author: " .. (c.author_name or "?"),
    "Date:   " .. (c.created_at or "?"),
    "",
    "    " .. (c.title or ""),
    "",
    "(commit is not in the local repository: no message body / stat)",
  }
end

-- One row per thing the MR consists of, laid out like diffview's file
-- history so the panel reads like the rest of the tab:
--
--   all       6 files | 120 34 | !42 all changes: 2 commits  feat -> main
--   a1b2c3d4  3 files |  18  7 | (HEAD -> feat) fix: subject…  author, 2 hours ago
--
-- The sha / subject / author come from the provider; stats, refs and the
-- relative date from the local repo (state.commit_info, loaded async by the
-- controller) — until / unless they arrive the columns show "-" and the date
-- falls back to the API's.
local function render_commits()
  local p = panel_state()
  p.line_targets = {}
  local commits = state_mod.state.commits or {}
  local mr = state_mod.state.mr
  local info = state_mod.state.commit_info or { by_sha = {} }
  local lines = {}
  if #commits == 0 then
    table.insert(lines, "(no commits)")
    set_lines(lines)
    panel_hl.clear(p.buf)
    clear_buffer_keymaps()
    return
  end

  local rows = {}
  if mr then
    local subject = string.format("!%s all changes: %d commit%s",
      tostring(mr.iid), #commits, #commits == 1 and "" or "s")
    table.insert(rows, {
      id = "all", id_hl = "ReviewCommitAll",
      stats = info.all,
      subject = subject,
      meta = (mr.source_branch or "?") .. " → " .. (mr.target_branch or "?"),
      target = { kind = "all", subject = subject },
    })
  end
  for _, c in ipairs(commits) do
    local short = c.short_id or (c.id and c.id:sub(1, ID_WIDTH)) or "????????"
    local extra = (c.id and info.by_sha[c.id]) or {}
    local date = extra.date or (c.created_at and c.created_at:sub(1, 10))
    table.insert(rows, {
      id = short, id_hl = "ReviewSha",
      stats = extra.stats,
      refs = extra.refs,
      subject = c.title or "",
      meta = (c.author_name or "?") .. (date and (", " .. date) or ""),
      target = { kind = "commit", sha = c.id, short = short, commit = c },
    })
  end

  local w_files, w_adds, w_dels = 1, 1, 1
  for _, r in ipairs(rows) do
    if r.stats then
      w_files = math.max(w_files, #tostring(r.stats.files))
      w_adds = math.max(w_adds, #tostring(r.stats.adds))
      w_dels = math.max(w_dels, #tostring(r.stats.dels))
    end
  end
  local function lpad(value, width)
    return string.rep(" ", math.max(width - #value, 0)) .. value
  end

  local marks = {}
  for i, r in ipairs(rows) do
    local text = ""
    local function add(str, group)
      if group then table.insert(marks, { i - 1, #text, #text + #str, group }) end
      text = text .. str
    end

    add(r.id .. string.rep(" ", math.max(ID_WIDTH - #r.id, 0)), r.id_hl)
    if r.stats then
      local n = r.stats.files
      add("  " .. lpad(tostring(n), w_files) .. (n == 1 and " file " or " files"), "ReviewCommitFiles")
      add(" | ", "ReviewCommitSep")
      add(lpad(tostring(r.stats.adds), w_adds), "ReviewCommitAdd")
      add(" ")
      add(lpad(tostring(r.stats.dels), w_dels), "ReviewCommitDel")
    else
      add("  " .. lpad("-", w_files) .. "      ", "ReviewCommitSep")
      add(" | ", "ReviewCommitSep")
      add(lpad("-", w_adds) .. " " .. lpad("-", w_dels), "ReviewCommitSep")
    end
    add(" | ", "ReviewCommitSep")
    if r.refs then add("(" .. r.refs .. ") ", "ReviewCommitRef") end
    local subject = r.subject
    if vim.fn.strchars(subject) > SUBJECT_MAX then
      subject = vim.fn.strcharpart(subject, 0, SUBJECT_MAX - 1) .. "…"
    end
    add(subject, "ReviewCommitSubject")
    if r.meta then add("  " .. r.meta, "ReviewCommitMeta") end

    table.insert(lines, text)
    p.line_targets[#lines] = r.target
  end

  set_lines(lines)
  panel_hl.clear(p.buf)
  panel_hl.apply_marks(p.buf, marks)
  clear_buffer_keymaps()
  map("<CR>", function()
    local t = current_target()
    if not t then return end
    if t.kind == "commit" and t.sha and M.hooks.on_commit_open then
      M.hooks.on_commit_open(t.sha)
    elseif t.kind == "all" then
      -- The session's own diff IS "all changes": go to its file list.
      pcall(vim.cmd, "DiffviewFocusFiles")
    end
  end)
  -- K: full commit message + stat in a float; K again steps into it.
  map("K", function()
    if commit_preview.enter() then return end
    local t = current_target()
    local float_lines = t and commit_float_lines(t)
    if float_lines then commit_preview.open(float_lines, p.win) end
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
-- Who approved, and under which rule, is the Approvals section's job.
local function format_approval(ap)
  if not ap then return nil end
  local count = #(ap.approved_by or {})
  if count == 0 then return "not approved" end
  if ap.required and ap.required > 0 then
    return string.format("approved (%d/%d)", count, ap.required)
  end
  return string.format("approved (%d)", count)
end

-- The provider's own answer to "are the approvals enough?": GitLab's
-- `approved` (rules satisfied) or GitHub's review decision. The count alone
-- can't tell -- approvals that satisfy no rule are counted too. nil when the
-- provider gave no verdict (the header then goes by the count).
---@return boolean|nil
local function approval_verdict(ap)
  if not ap then return nil end
  if ap.approved ~= nil then return ap.approved == true end
  if ap.decision then return ap.decision == "APPROVED" end
  return nil
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

-- Is the MR armed to merge itself once the pipeline / required checks pass?
-- Providers normalise this into mr.auto_merge = { enabled, strategy, set_by };
-- state that predates the field falls back to the flag the watcher uses.
local function auto_merge_enabled(mr)
  if mr.auto_merge then return mr.auto_merge.enabled == true end
  return mr.merge_when_pipeline_succeeds == true
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

-- ------------------------------------------------------ Approvals section

-- Cells a line may take before it runs off the panel (which doesn't wrap).
local function panel_text_width()
  local p = panel_state()
  if p and p.win and vim.api.nvim_win_is_valid(p.win) then
    local info = vim.fn.getwininfo(p.win)[1]
    local width = vim.api.nvim_win_get_width(p.win) - (info and info.textoff or 0)
    if width >= 40 then return width end
  end
  return 80
end

---"@a," "@b," "@c" (plus `extra` as a last item); "(none)" when empty.
local function name_tokens(names, extra)
  local tokens = {}
  for _, name in ipairs(names or {}) do table.insert(tokens, "@" .. name) end
  if extra then table.insert(tokens, extra) end
  if #tokens == 0 then return { "(none)" } end
  for i = 1, #tokens - 1 do tokens[i] = tokens[i] .. "," end
  return tokens
end

---`label` followed by `tokens`, broken into lines of at most `width` cells;
---continuation lines are indented to where the first token starts. A list
---of forty names would otherwise disappear past the panel's right edge.
---@return string[]
local function wrap_tokens(label, tokens, width)
  local cells = vim.fn.strdisplaywidth
  local pad = string.rep(" ", cells(label))
  local out, cur, fresh = {}, label, true
  for _, token in ipairs(tokens) do
    if not fresh and cells(cur) + 1 + cells(token) > width then
      table.insert(out, cur)
      cur, fresh = pad, true
    end
    cur = cur .. (fresh and "" or " ") .. token
    fresh = false
  end
  table.insert(out, cur)
  return out
end

---`list` without the names in `drop`.
local function names_except(list, drop)
  local skip, out = {}, {}
  for _, name in ipairs(drop or {}) do skip[name] = true end
  for _, name in ipairs(list or {}) do
    if not skip[name] then table.insert(out, name) end
  end
  return out
end

local DECISION_LABELS = {
  APPROVED          = "approved",
  CHANGES_REQUESTED = "changes requested",
  REVIEW_REQUIRED   = "review required",
}

---Who approved and what is still required. With per-rule state (GitLab
---Premium) one block per rule: `[x]` satisfied / `[ ]` not / `[-]`
---optional, who approved under it, and -- while it is open -- who else
---may. Otherwise the plain list of approvers plus whatever the provider
---says about the requirement.
---@return { text: string, hl: string|nil }[]
local function approval_lines(ap, width)
  local out = {}
  local function add(lines, hl)
    for _, l in ipairs(lines) do table.insert(out, { text = l, hl = hl }) end
  end

  local rules = ap.rules
  if rules and #rules > 0 then
    local counted = {}
    for _, rule in ipairs(rules) do
      vim.list_extend(counted, rule.approved_by or {})
      local name = rule.name .. (rule.type == "code_owner" and " (code owner)" or "")
      local given = #(rule.approved_by or {})
      if (rule.required or 0) <= 0 then
        add({ ("[-] %s  optional"):format(name) }, "ReviewMuted")
      elseif rule.approved then
        add({ ("[x] %s  %d/%d"):format(name, given, rule.required) }, "ReviewApprovalOk")
      else
        add({ ("[ ] %s  %d/%d"):format(name, given, rule.required) }, "ReviewApprovalMissing")
      end
      if given > 0 then
        add(wrap_tokens("    approved: ", name_tokens(rule.approved_by), width))
      end
      -- Who can still approve only matters while the rule is open.
      if not rule.approved or (rule.required or 0) <= 0 then
        local left = names_except(rule.eligible, rule.approved_by)
        local extra = rule.hidden_groups and "members of hidden groups" or nil
        if #left == 0 and not extra and rule.type == "any_approver" then extra = "anyone" end
        if #left > 0 or extra then
          add(wrap_tokens("    eligible: ", name_tokens(left, extra), width))
        end
      end
    end
    -- Approvals that satisfy no rule: counted in the header, required by nobody.
    local also = names_except(ap.approved_by, counted)
    if #also > 0 then
      add(wrap_tokens("Also approved: ", name_tokens(also), width))
    end
    return out
  end

  add(wrap_tokens("Approved by: ", name_tokens(ap.approved_by), width))
  if ap.changes_requested_by and #ap.changes_requested_by > 0 then
    add(wrap_tokens("Changes requested by: ", name_tokens(ap.changes_requested_by), width),
      "ReviewApprovalMissing")
  end
  -- nil = the provider doesn't say (GitHub); 0 = approvals are optional.
  if ap.required then
    add({ "Required: " .. (ap.required > 0 and tostring(ap.required) or "none") })
  end
  if ap.decision then
    add({ "Review decision: " .. (DECISION_LABELS[ap.decision] or ap.decision:lower()) },
      ap.decision == "APPROVED" and "ReviewApprovalOk" or "ReviewApprovalMissing")
  end
  return out
end

-- The tracker issue of the MR's source branch, when tracker.nvim is
-- installed (soft dependency: nothing breaks without it).
-- key → { status, summary, at (os.time of the fetch), fetching }.
local tracker_issues = {}
local TRACKER_FRESH = 30 -- seconds an issue's status counts as current

local function info_visible()
  local p = panel_state()
  return p and p.mode == "info" and p.buf and vim.api.nvim_buf_is_valid(p.buf)
end

---Fetch `key` again; the Info panel re-renders when it arrives.
local function tracker_fetch(tracker, key)
  local entry = tracker_issues[key] or {}
  if entry.fetching then return end
  entry.fetching = true
  tracker_issues[key] = entry
  tracker.get_issue(key, function(issue)
    tracker_issues[key] = {
      status = issue and issue.status and issue.status.name or entry.status or "?",
      summary = issue and issue.summary or entry.summary or "(not found)",
      at = os.time(),
    }
    if info_visible() then M.refresh() end
  end)
end

-- A change made through tracker.nvim (status, assignee, edit, …) shows at
-- once: its events carry the issue key.
pcall(vim.api.nvim_create_autocmd, "User", {
  group = vim.api.nvim_create_augroup("ReviewTrackerIssue", { clear = true }),
  pattern = { "TrackerTransitioned", "TrackerIssueUpdated", "TrackerAssigned", "TrackerBranchCreated" },
  callback = function(ev)
    local key = type(ev.data) == "table" and ev.data.key
    if key and tracker_issues[key] then
      tracker_issues[key].at = 0 -- stale: fetched again on the next render
      if info_visible() then M.refresh() end
    end
  end,
})

local tracker_issue

-- Changes made in Jira's web UI: checked when you come back to Neovim or to
-- the panel (a stale entry is fetched; the panel re-renders only when it
-- arrives, so the cursor stays put meanwhile).
pcall(vim.api.nvim_create_autocmd, { "FocusGained", "BufEnter" }, {
  group = "ReviewTrackerIssue",
  callback = function(ev)
    if not info_visible() then return end
    local p = panel_state()
    if ev.event == "BufEnter" and ev.buf ~= p.buf then return end
    local mr = state_mod.state.mr
    if mr then tracker_issue(mr.source_branch) end
  end,
})

---Key and last known details; a stale or missing entry is (re)fetched in
---the background while the old values stay on screen.
---@return string|nil key, { status: string, summary: string }|nil details
function tracker_issue(branch)
  local ok, tracker = pcall(require, "tracker.api")
  if not ok or not branch or branch == "" then return nil end
  local key_ok, key = pcall(tracker.current_issue_key, { branch = branch })
  if not key_ok or not key then return nil end
  local entry = tracker_issues[key]
  if not entry or (entry.at or 0) + TRACKER_FRESH < os.time() then tracker_fetch(tracker, key) end
  entry = tracker_issues[key]
  return key, entry and entry.status and entry or nil
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
  if auto_merge_enabled(mr) then table.insert(header_parts, "auto-merge") end
  table.insert(lines, table.concat(header_parts, "  •  "))
  p.line_targets[#lines] = { kind = "header", approval_ok = approval_verdict(mr.approval) }

  -- Issue of the source branch (tracker.nvim): `e` opens it.
  local issue_key, issue = tracker_issue(mr.source_branch)
  if issue_key then
    push_section(lines, p, "tracker", "Issue")
    push_content(lines, p, "tracker", issue
      and ("%s  [%s]  %s"):format(issue_key, issue.status, issue.summary)
      or (issue_key .. "  (loading…)"))
  end

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

  -- Read-only; skipped when the provider returned no approval state.
  if mr.approval then
    push_section(lines, p, "approvals", "Approvals")
    for _, l in ipairs(approval_lines(mr.approval, panel_text_width())) do
      table.insert(lines, l.text)
      p.line_targets[#lines] = { kind = "section_body", section = "approvals", hl = l.hl }
    end
  end

  push_section(lines, p, "labels", "Labels")
  push_content(lines, p, "labels",
    (mr.labels and #mr.labels > 0) and table.concat(mr.labels, ", ") or "(none)")

  push_section(lines, p, "milestone", "Milestone")
  push_content(lines, p, "milestone",
    (mr.milestone and mr.milestone.title) or "(none)")

  -- Time tracking is provider-dependent. GitLab returns a struct (possibly
  -- with zero values) → visible. GitHub has no time tracking API and returns
  -- nil → both sections skipped entirely.
  --
  -- Estimate and spent time are separate sections so that `e` can dispatch to
  -- two different editors: a plain duration prompt for the estimate, an
  -- add/set/reset menu for spent time.
  if mr.time_stats then
    local ts = mr.time_stats

    push_section(lines, p, "time_estimate", "Estimate")
    push_content(lines, p, "time_estimate",
      ts.human_time_estimate
      or (ts.time_estimate and ts.time_estimate > 0 and format_seconds(ts.time_estimate))
      or "(none)")

    push_section(lines, p, "time_spent", "Spent time")
    push_content(lines, p, "time_spent",
      ts.human_total_time_spent
      or (ts.total_time_spent and ts.total_time_spent > 0 and format_seconds(ts.total_time_spent))
      or "(none)")
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
    if t.section == "tracker" then
      local key = tracker_issue(mr.source_branch)
      local ok, tracker = pcall(require, "tracker")
      if key and ok then tracker.issue(key) end
      return
    end
    if M.hooks.on_section_edit then M.hooks.on_section_edit(t.section) end
  end)
  -- j / k move between sections (onto their `── Label ──` header, where `e`
  -- edits that section) instead of line by line. <Down> / <Up> and
  -- <C-d> / <C-u> still scroll through a long description.
  map("j", function() M.jump_section(1) end)
  map("k", function() M.jump_section(-1) end)
end

---Move the Info cursor to the next (dir = 1) / previous (dir = -1) section
---header. Inside a tall section `k` first returns to its own header.
---@param dir integer
function M.jump_section(dir)
  local p = panel_state()
  if not p.win or not vim.api.nvim_win_is_valid(p.win) then return end
  local headers = {}
  for lnum = 1, vim.api.nvim_buf_line_count(p.buf) do
    local t = p.line_targets[lnum]
    if t and t.kind == "section_header" then table.insert(headers, lnum) end
  end
  if #headers == 0 then return end
  local row = vim.api.nvim_win_get_cursor(p.win)[1]
  local target
  if dir > 0 then
    for _, h in ipairs(headers) do
      if h > row then target = h break end
    end
    target = target or headers[#headers]
  else
    for i = #headers, 1, -1 do
      if headers[i] < row then target = headers[i] break end
    end
    target = target or headers[1]
  end
  vim.api.nvim_win_set_cursor(p.win, { target, 0 })
  -- Centre it: otherwise a section near the bottom shows only its header,
  -- its content hidden below the window edge.
  vim.api.nvim_win_call(p.win, function() vim.cmd("normal! zz") end)
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
      -- `pending` on a row = the note it shows is not submitted yet. A thread
      -- head can be published while one of its replies is pending, so the
      -- flag is per note, not per thread.
      local first_pending = first and first.pending == true
      local header
      if pos and pos ~= vim.NIL and (pos.new_path or pos.old_path) then
        header = string.format("%s %s:%s  @%s",
          icon,
          pos.new_path or pos.old_path,
          tostring(pos.new_line or pos.old_line or "?"),
          first.author or "?")
      elseif first and first.pending_kind == "summary" then
        header = string.format("%s (review summary)  @%s", icon, first.author or "?")
      else
        header = string.format("%s (global)  @%s", icon, (first and first.author) or "?")
      end
      if first_pending then header = header .. "  " .. panel_hl.PENDING_TAG end
      table.insert(lines, header)
      p.line_targets[#lines] = {
        kind = "discussion_head",
        discussion_id = d.id,
        note_id = first and first.id,
        position = pos,
        pending = first_pending,
      }
      local body = (first and first.body) or ""
      for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(lines, "    " .. l)
        p.line_targets[#lines] = {
          kind = "discussion_body",
          discussion_id = d.id,
          note_id = first and first.id,
          position = pos,
          pending = first_pending,
        }
      end
      for i = 2, #d.notes do
        local n = d.notes[i]
        if not n.system then
          local first_line = true
          local who = "@" .. (n.author or "?")
          if n.pending then who = who .. " " .. panel_hl.PENDING_TAG end
          for _, l in ipairs(vim.split(n.body or "", "\n", { plain = true })) do
            if first_line then
              table.insert(lines, string.format("    ↳ %s: %s", who, l))
              first_line = false
            else
              table.insert(lines, "         " .. l)
            end
            p.line_targets[#lines] = {
              kind = "reply",
              discussion_id = d.id,
              note_id = n.id,
              position = pos,
              pending = n.pending == true,
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
  -- Pending review (review.review_mode). Capitals: none of them is something
  -- to hit by accident next to d / e / s.
  map("P", function()
    if M.hooks.on_review_start then M.hooks.on_review_start() end
  end)
  map("S", function()
    if M.hooks.on_review_submit then M.hooks.on_review_submit() end
  end)
  map("X", function()
    if M.hooks.on_review_discard then M.hooks.on_review_discard() end
  end)
end

local RENDERERS = {
  commits = render_commits,
  info = render_description,
  notes = render_comments,
}

-- ---------------------------------------------------------------- public API

---Hints of the Notes mode, with the pending-review keys that apply right now:
---`P` to start one, or `S` / `X` to end the one in progress.
local function notes_hints()
  local review = state_mod.state.review
  local extra
  if review and review.supported == false then
    extra = {}
  elseif review and review.active then
    extra = { { "S", "submit review" }, { "X", "discard review" } }
  else
    extra = { { "P", "start review" } }
  end
  local out = {}
  for _, e in ipairs(HINTS.notes) do
    -- Keep the mode-switch / quit hints last, as in the other modes.
    if e[1] == "h/[" then
      for _, x in ipairs(extra) do table.insert(out, x) end
    end
    table.insert(out, e)
  end
  return out
end

---"REVIEW · N pending" (winbar markup) while a review is in progress, nil
---otherwise. Shown in every mode: what `c` / `s` / `a` do depends on it,
---wherever the user happens to look.
local function review_badge()
  local review = state_mod.state.review
  if not (review and review.active) then return nil end
  return string.format("%%#ReviewPending#REVIEW · %d pending%%*", review.count or 0)
end

local function build_winbar(mode)
  local title = TITLE[mode] or "Panel"
  local hints = format_hints(mode == "notes" and notes_hints() or HINTS[mode])
  local badge = review_badge()
  if badge then title = title .. "  " .. badge end
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
---
---A window opened while the panel is current (a `vim.ui.select` picker, a
---prompt, any float) inherits the panel's fold options, this expression
---included, and would fold its own lines by the panel's rows. Neovim
---evaluates a foldexpr with the folded window's buffer as the current one,
---so anything that is not the panel buffer gets no folds at all.
function M.fold_expr(lnum)
  -- Such a window can also outlive the session or sit in another tab, where
  -- there is no session state to index.
  local session = state_mod.state
  local p = session and session.panel
  if not p or vim.api.nvim_get_current_buf() ~= p.buf then return "0" end
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
  -- A commit float belongs to the rows it was opened from: a re-render or a
  -- mode switch leaves it pointing at nothing.
  commit_preview.close()
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
  --   l / h   info -> commits -> notes -> info ... (h / l: the panel lines
  --           don't need horizontal motion, the modes read as columns)
  local opts = { buffer = p.buf, silent = true, noremap = true, nowait = true }
  vim.keymap.set("n", "q", function()
    if M.hooks.on_close then M.hooks.on_close() end
  end, opts)
  vim.keymap.set("n", "]", function() M.cycle_mode(1) end, opts)
  vim.keymap.set("n", "[", function() M.cycle_mode(-1) end, opts)
  vim.keymap.set("n", "l", function() M.cycle_mode(1) end, opts)
  vim.keymap.set("n", "h", function() M.cycle_mode(-1) end, opts)

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
