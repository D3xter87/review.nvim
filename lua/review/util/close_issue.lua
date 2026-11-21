-- Closing references ("Closes PROJ-123", "Closes #12") in an MR/PR
-- description, written when "Close issue on merge" is ticked in the merge
-- dialog.
--
-- The forge (or its issue-tracker integration) is what actually closes the
-- issue once the MR merges; the plugin only makes sure the description says
-- so. One line per issue, each built from `close_issue.template`, kept
-- together as a block at the bottom of the description — above the
-- "refs ... #time ..." trailer when there is one, since that trailer owns the
-- very last line (see util/refs_line.lua).
--
-- The plugin itself only knows issue numbers spelled in a branch name. Any
-- other source — an issue tracker plugin, your own function — plugs in
-- through `close_issue.detect`, and whatever has to happen outside the forge
-- once the merge lands goes into `close_issue.on_merged`; nothing here
-- depends on a particular plugin.
--
-- Pure string work apart from prefill(), which calls that user hook. The
-- network side lives in actions/merge_mr.lua.

local M = {}

local refs_line = require("review.util.refs_line")

local DEFAULT_TEMPLATE = "Closes %s"

-- Templates already reported as invalid, so a bad config warns once rather
-- than on every dialog.
local warned = {}

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

---The configured line template, or the default when it is unusable.
---@return string
function M.template()
  local template = (require("review.config").get().close_issue or {}).template
  if template == nil then return DEFAULT_TEMPLATE end
  if type(template) == "string" then
    template = vim.trim(template)
    local _, count = template:gsub("%%s", "")
    if count == 1 then return template end
  end
  local key = tostring(template)
  if not warned[key] then
    warned[key] = true
    require("review.util.notify").warn(
      ("close_issue.template must contain exactly one %%s — using %q"):format(DEFAULT_TEMPLATE))
  end
  return DEFAULT_TEMPLATE
end

---Splits a template around its %s placeholder.
---@param template string
---@return string prefix, string suffix
local function split_template(template)
  local s, e = template:find("%s", 1, true)
  return template:sub(1, s - 1), template:sub(e + 1)
end

---Plain substitution rather than string.format, so any other "%" a template
---carries is written out literally instead of raising mid-merge.
---@param template string
---@param ref string
---@return string
local function render(template, ref)
  local prefix, suffix = split_template(template)
  return prefix .. ref .. suffix
end

---Literal text as a Lua pattern that tolerates any amount of whitespace
---wherever the text has some.
---@param text string
---@return string
local function to_pattern(text)
  return (vim.pesc(text:lower()):gsub("%s+", "%%s+"))
end

---The reference a line closes, or nil when the line isn't a closing line.
---Matched case-insensitively ("closes #1" counts), but the reference itself is
---cut out of the original line so "Group/Project#5" keeps its case.
---@param line string
---@param template string
---@return string|nil
local function match(line, template)
  local prefix, suffix = split_template(template)
  local pattern = "^%s*" .. to_pattern(prefix) .. "()%S+()" .. to_pattern(suffix) .. "%s*$"
  local from, to = line:lower():match(pattern)
  if not from then return nil end
  return line:sub(from, to - 1)
end

---@param list string[]
---@return string[]
local function dedupe(list)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    if not seen[item] then
      seen[item] = true
      table.insert(out, item)
    end
  end
  return out
end

---Built-in guess at the issue a branch belongs to: a forge issue number
---spelled in the branch name ("issue-12", "12-fix-login", "feature/12-foo").
---Deliberately nothing smarter — a branch named after a tracker key
---("proj-123") says nothing about a forge issue, so it yields no guess.
---@param branch string|nil
---@return string[]  zero or one reference
function M.detect(branch)
  if not branch or branch == "" then return {} end

  local lower = branch:lower()
  local number = lower:match("%f[%w]issues?[-_/]?(%d+)")
      or lower:match("^(%d+)[-_]")
      or lower:match("/(%d+)[-_]")
      or lower:match("^(%d+)$")
  if number then return { "#" .. number } end
  return {}
end

---Turns what the user typed into a list of references. Separators are
---whitespace, commas and semicolons; a bare number becomes "#N" and a
---tracker key is uppercased, anything else (group/project#5, a URL) is kept
---verbatim.
---@param text string|nil
---@return string[]
function M.parse_refs(text)
  local refs = {}
  for token in (text or ""):gmatch("[^%s,;]+") do
    if token:match("^%d+$") then
      token = "#" .. token
    elseif token:match("^%a[%a%d]*%-%d+$") then
      token = token:upper()
    end
    table.insert(refs, token)
  end
  return dedupe(refs)
end

---What the merge dialog offers for an MR that closes nothing yet. The
---`close_issue.detect` hook decides when it is set and returns something
---(a list, or a string in any form parse_refs accepts; an empty list means
---"offer nothing"); nil from it, or no hook, leaves it to M.detect.
---@param mr table              normalized MR/PR
---@param provider string|nil   "gitlab" | "github"
---@return string[]
function M.prefill(mr, provider)
  local hook = (require("review.config").get().close_issue or {}).detect
  if type(hook) == "function" then
    local ok, result = pcall(hook, { branch = mr.source_branch, mr = mr, provider = provider })
    if not ok then
      require("review.util.notify").warn("close_issue.detect failed: " .. tostring(result))
    elseif type(result) == "table" then
      local parts = {}
      for _, item in ipairs(result) do table.insert(parts, tostring(item)) end
      return M.parse_refs(table.concat(parts, "\n"))
    elseif type(result) == "string" then
      return M.parse_refs(result)
    end
  end
  return M.detect(mr.source_branch)
end

---References the description already closes through template-shaped lines.
---@param description string|nil
---@param template string
---@return string[]
function M.existing(description, template)
  local refs = {}
  for _, line in ipairs(vim.split(description or "", "\r?\n")) do
    local ref = match(line, template)
    if ref then table.insert(refs, ref) end
  end
  return dedupe(refs)
end

---Rebuilds `description` so it closes exactly `refs` — or nothing, when the
---list is empty.
---@param description string|nil
---@param refs string[]
---@param template string
---@return string|nil  nil when nothing would change, so the caller skips the PUT
function M.apply(description, refs, template)
  description = description or ""
  refs = refs or {}

  local kept, found = {}, {}
  local after_removed = false
  for _, line in ipairs(vim.split(description, "\r?\n")) do
    local ref = match(line, template)
    if ref then
      table.insert(found, ref)
      after_removed = true
    else
      -- A removed line leaves its blank separators behind; drop the second
      -- one so the hole doesn't turn into a double blank line.
      local hole = after_removed and is_blank(line)
          and (#kept == 0 or is_blank(kept[#kept]))
      if not hole then table.insert(kept, line) end
      after_removed = false
    end
  end

  if #refs == 0 and #found == 0 then return nil end
  -- Already closing exactly these, wherever the lines sit: leave them alone
  -- rather than PUT a reflow that shows up as an MR activity entry.
  if #refs > 0 and vim.deep_equal(found, refs) then return nil end

  local function trim_tail()
    while #kept > 0 and is_blank(kept[#kept]) do
      table.remove(kept)
    end
  end

  trim_tail()
  local trailer
  if #kept > 0 and refs_line.is_trailer(kept[#kept]) then
    trailer = table.remove(kept)
    trim_tail()
  end

  if #refs > 0 then
    if #kept > 0 then table.insert(kept, "") end
    for _, ref in ipairs(refs) do
      table.insert(kept, render(template, ref))
    end
  end
  if trailer then
    if #kept > 0 then table.insert(kept, "") end
    table.insert(kept, trailer)
  end

  -- Same reasoning as refs_line.apply: keep the line ending the MR uses.
  local eol = description:find("\r\n", 1, true) and "\r\n" or "\n"
  local out = table.concat(kept, eol)
  if out == description then return nil end
  return out
end

return M
