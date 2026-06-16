-- Highlight rendering for the bottom panel.
--
-- We use buffer extmarks (`nvim_buf_set_extmark`) bound to a dedicated
-- namespace per buffer. Highlights are reapplied after every render
-- because re-render rewrites the buffer contents from scratch.
--
-- Group names are linked to standard semantic groups with `default = true`
-- so user colorschemes / overrides win.

local M = {}

local NS_NAME = "review_panel_hl"

---@type table<string, string>  group -> link target
local GROUPS = {
  ReviewIid             = "Number",
  ReviewAuthor          = "Identifier",
  ReviewBranch          = "Type",
  ReviewSha             = "Number",
  ReviewState           = "Constant",
  ReviewSectionHeader   = "Title",
  ReviewApprovalOk      = "DiagnosticOk",
  ReviewApprovalMissing = "DiagnosticWarn",
  ReviewReady           = "DiagnosticOk",
  ReviewBlocker         = "DiagnosticWarn",
  ReviewDraft           = "Special",
  ReviewIconComment     = "DiagnosticInfo",
  ReviewIconUnresolved  = "DiagnosticError",
  ReviewIconResolved    = "DiagnosticOk",
  ReviewPath            = "Directory",
  ReviewLine            = "Number",
  ReviewSystemNote      = "Comment",
  ReviewMuted           = "Comment",
}

-- "ready"-state lexicon: which strings map to OK vs blocker styling. The
-- bottom-panel header builds these via util/notify-style format helpers, so
-- we just match exact substrings.
local READY_OK     = { ["ready to merge"] = true }
local READY_BLOCK  = {
  ["needs pipeline"]      = true,
  ["unresolved threads"]  = true,
  ["draft"]               = true,
  ["needs approval"]      = true,
  ["conflicts"]           = true,
  ["not mergeable"]       = true,
  ["checking..."]         = true,
}

local groups_set_up = false

---Idempotent. Define / link highlight groups. Called from bottom_panel.open.
function M.setup_groups()
  if groups_set_up then return end
  groups_set_up = true
  for group, link in pairs(GROUPS) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
end

---Get (or create) the namespace for this buffer's panel.
---@param buf integer
---@return integer
function M.ns()
  return vim.api.nvim_create_namespace(NS_NAME)
end

---Clear all extmarks owned by this module from the buffer.
---@param buf integer
function M.clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns(), 0, -1)
  end
end

---Add a highlight extmark for `[start_col, end_col)` on `row` (0-indexed).
---@param buf integer
---@param row integer  0-indexed
---@param start_col integer  byte column, 0-indexed
---@param end_col integer  exclusive
---@param hl_group string
local function hl(buf, row, start_col, end_col, hl_group)
  if start_col >= end_col or start_col < 0 then return end
  pcall(vim.api.nvim_buf_set_extmark, buf, M.ns(), row, start_col, {
    end_col = end_col,
    hl_group = hl_group,
  })
end

---Searches `line` for `pattern` (Lua pattern) and applies `hl_group` to all
---matches. Useful for one-off region highlighting after rendering.
---@param buf integer
---@param row integer
---@param line string
---@param pattern string  Lua pattern with optional captures; whole match used
---@param hl_group string
local function hl_pattern(buf, row, line, pattern, hl_group)
  local s, e = 1, nil
  while true do
    local ms, me = line:find(pattern, s)
    if not ms then break end
    hl(buf, row, ms - 1, me, hl_group)
    s = me + 1
    e = me
    if e == nil then break end
  end
end

-- ----------------------------------------------------------- Info / header

---Highlights the !iid header line shared by all modes.
---Format: `!IID  by @AUTHOR  •  SRC -> DST  •  STATE  •  approval...  •  ready...`
local function highlight_iid_header(buf, row, line)
  -- !iid
  hl_pattern(buf, row, line, "!%d+", "ReviewIid")
  -- @author
  hl_pattern(buf, row, line, "@[%w_%-%.]+", "ReviewAuthor")
  -- branches: pattern is "  <src> -> <dst>  •" or unicode arrow → -- match the pair
  -- around either ASCII -> or unicode →
  local ms, me, src, dst = line:find("  ([%w%./_-]+) %-> ([%w%./_-]+)  ")
  if not ms then
    ms, me, src, dst = line:find("  ([%w%./_-]+) → ([%w%./_-]+)  ")
  end
  if ms and src and dst then
    -- src position: after the leading "  "
    local src_start = ms + 2 - 1
    hl(buf, row, src_start, src_start + #src, "ReviewBranch")
    -- dst comes after src + " -> " (4 chars) or " → " (5 bytes for utf-8 arrow)
    local dst_start = me - 2 - #dst
    hl(buf, row, dst_start, dst_start + #dst, "ReviewBranch")
  end
  -- State token: pick a different highlight per value so the header makes
  -- the MR lifecycle stage immediately obvious.
  --   opened → ReviewState  (neutral Constant)
  --   merged → ReviewReady  (DiagnosticOk; the desirable terminal state)
  --   closed → ReviewBlocker (DiagnosticWarn; closed-without-merge)
  local STATE_GROUP = {
    opened = "ReviewState",
    merged = "ReviewReady",
    closed = "ReviewBlocker",
  }
  for st, group in pairs(STATE_GROUP) do
    local sm = line:find("•%s+" .. st)
    if sm then
      local fs, fe = line:find(st, sm)
      if fs then hl(buf, row, fs - 1, fe, group) end
    end
  end

  -- Approval segment
  local lower = line:lower()
  if lower:find("not approved") then
    local s = lower:find("not approved")
    hl(buf, row, s - 1, s - 1 + #"not approved", "ReviewApprovalMissing")
  end
  for ms2, me2 in line:gmatch("()approved %([^)]+%)()") do
    -- Decide OK vs missing by N/M parsing.
    local seg = line:sub(ms2, me2 - 1)
    local n, m = seg:match("approved %((%d+)/(%d+)%)")
    local ok = (n and m and tonumber(n) >= tonumber(m)) or (not m)
    hl(buf, row, ms2 - 1, me2 - 1, ok and "ReviewApprovalOk" or "ReviewApprovalMissing")
  end

  -- Ready-state segment.
  for label in pairs(READY_OK) do
    local s = line:find(label, 1, true)
    if s then hl(buf, row, s - 1, s - 1 + #label, "ReviewReady") end
  end
  for label in pairs(READY_BLOCK) do
    local s = line:find(label, 1, true)
    if s then hl(buf, row, s - 1, s - 1 + #label, "ReviewBlocker") end
  end
end

---Highlights a section header line `── Foo ──`.
local function highlight_section_header(buf, row, line)
  hl(buf, row, 0, #line, "ReviewSectionHeader")
end

---Apply highlights for the Info panel.
---@param buf integer
---@param lines string[]
---@param line_targets table<integer, table>
function M.apply_info(buf, lines, line_targets)
  for i, line in ipairs(lines) do
    local row = i - 1
    local target = line_targets[i]
    if target and target.kind == "header" then
      highlight_iid_header(buf, row, line)
    elseif target and target.kind == "section_header" then
      highlight_section_header(buf, row, line)
    elseif target and target.kind == "section_body" then
      -- Within section bodies, apply contextual highlights.
      if target.section == "draft" then
        hl_pattern(buf, row, line, "%[[ x]%]%s*%w+", "ReviewDraft")
      elseif target.section == "labels" or target.section == "milestone" or target.section == "assignees" or target.section == "reviewers" then
        hl_pattern(buf, row, line, "%(none%)", "ReviewMuted")
        hl_pattern(buf, row, line, "@[%w_%-%.]+", "ReviewAuthor")
      elseif target.section == "description" then
        hl_pattern(buf, row, line, "%(empty%)", "ReviewMuted")
      elseif target.section == "participants" then
        hl_pattern(buf, row, line, "@[%w_%-%.]+", "ReviewAuthor")
      end
    end
  end
end

-- --------------------------------------------------------------- Commits

---Highlights one commit line: `<short_sha>  <author> — <subject>`.
local function highlight_commit_line(buf, row, line)
  -- Short SHA at the start: 7-12 hex digits.
  local s, e = line:find("^[%da-f]+")
  if s then hl(buf, row, s - 1, e, "ReviewSha") end
  -- Author: between two spaces and " — " (em-dash) / " - "
  hl_pattern(buf, row, line, "@?[%w_%-%.]+%s+[—–-]", "ReviewAuthor")
end

---@param buf integer
---@param lines string[]
---@param line_targets table<integer, table>
function M.apply_commits(buf, lines, line_targets)
  for i, line in ipairs(lines) do
    local target = line_targets[i]
    if target and target.kind == "commit" then
      highlight_commit_line(buf, i - 1, line)
    end
  end
end

-- ----------------------------------------------------------------- Notes

local ICON_HL = {
  ["💬"] = "ReviewIconComment",
  ["❌"] = "ReviewIconUnresolved",
  ["✅"] = "ReviewIconResolved",
}

local function highlight_thread_head(buf, row, line)
  -- Icon at start (one of 💬❌✅, multibyte). Find by exact prefix match.
  for icon, group in pairs(ICON_HL) do
    if line:sub(1, #icon) == icon then
      hl(buf, row, 0, #icon, group)
      break
    end
  end

  -- File path : line  e.g. "src/foo.lua:42"
  local s, e, path, ln = line:find("([%w%./_%-]+):(%d+)")
  if s and path and ln then
    hl(buf, row, s - 1, s - 1 + #path, "ReviewPath")
    hl(buf, row, e - #ln, e, "ReviewLine")
  end

  -- (global) marker
  local gs = line:find("%(global%)")
  if gs then hl(buf, row, gs - 1, gs - 1 + #"(global)", "ReviewMuted") end

  -- @author
  hl_pattern(buf, row, line, "@[%w_%-%.]+", "ReviewAuthor")
end

---@param buf integer
---@param lines string[]
---@param line_targets table<integer, table>
function M.apply_notes(buf, lines, line_targets)
  for i, line in ipairs(lines) do
    local row = i - 1
    local target = line_targets[i]
    if target and target.kind == "discussion_head" then
      highlight_thread_head(buf, row, line)
    elseif target and (target.kind == "discussion_body" or target.kind == "reply") then
      hl_pattern(buf, row, line, "@[%w_%-%.]+", "ReviewAuthor")
    elseif line == "(no notes)" then
      hl(buf, row, 0, #line, "ReviewMuted")
    end
  end
end

return M
