-- Maintains the "refs <BRANCH> #time <total>" trailer that mirrors an MR's
-- spent time into the bottom of its description.
--
-- The trailer is smart-commit syntax an external issue tracker picks up, not
-- something GitLab keeps in sync, so the plugin rewrites it after every
-- spent-time change. There is exactly one trailer per description and it
-- always sits at the very bottom: every matching line is stripped first and a
-- fresh one appended, which also cleans up duplicates and leftovers naming a
-- branch the MR no longer uses.
--
-- Everything here is pure string work — the network side lives in
-- actions/spent_time.lua.

local M = {}

---Matches a trailer regardless of case and of which branch it names, so
---hand-pasted and stale ones are collected too.
---@param line string
---@return boolean
local function is_trailer(line)
  return line:lower():match("^%s*refs%s+%S+%s+#time%s") ~= nil
end

---Rebuilds `description` so it ends with exactly one trailer — or with none
---when there is no time left to report.
---@param description string
---@param branch string          MR source branch, uppercased verbatim
---@param human_time string|nil  nil / "" removes the trailer
---@return string|nil  nil when nothing would change, so the caller skips the PUT
function M.apply(description, branch, human_time)
  description = description or ""
  local adding = human_time ~= nil and human_time ~= ""

  local kept, removed = {}, false
  for _, line in ipairs(vim.split(description, "\r?\n")) do
    if is_trailer(line) then
      removed = true
    else
      table.insert(kept, line)
    end
  end

  -- Nothing to add and nothing to drop: leave the description alone rather
  -- than PUT a whitespace-only reflow that shows up as an MR activity entry.
  if not adding and not removed then return nil end

  while #kept > 0 and kept[#kept]:match("^%s*$") do
    table.remove(kept)
  end

  if adding then
    -- Blank separator line, unless the trailer ends up being the whole body.
    if #kept > 0 then table.insert(kept, "") end
    table.insert(kept, string.format("refs %s #time %s", branch:upper(), human_time))
  end

  -- GitLab's web editor stores CRLF. Rejoining with "\n" would rewrite every
  -- line of the description, so keep whichever ending the MR already uses.
  local eol = description:find("\r\n", 1, true) and "\r\n" or "\n"
  local out = table.concat(kept, eol)
  if out == description then return nil end
  return out
end

return M
