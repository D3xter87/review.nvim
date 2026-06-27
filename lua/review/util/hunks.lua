-- Diff hunk line ranges + per-line position info + selection clamping.
--
-- GitHub/GitLab reject inline comments whose line numbers fall outside a diff
-- hunk. GitLab additionally needs BOTH old_line and new_line to build a valid
-- "line_code" for an UNCHANGED (context) line — sending only new_line for a
-- context line yields `line_code can't be blank`. So we parse the diff into a
-- per-line map that records, for every commentable line on each side, the
-- (new_line, old_line) pair to send.
--
-- We diff base...head (3-dot, merge-base) to match what diffview opens (see
-- diffview/integration.lua), so the parsed line numbers line up with the
-- buffer line numbers the user is selecting on each side.

local M = {}

local rebase = require("review.git.rebase")

-- Parsed data cached per (base, head, path). SHAs are fixed per MR, so the
-- diff for a given file never changes within a session — no invalidation needed.
local cache = {}

---Per side:
---  ranges = { {start, end}, ... }            -- hunk spans, for overlap/abort
---  pos    = { [line] = {new_line=, old_line=} } -- position opts to send for a
---           comment anchored on that line (old_line absent for added lines,
---           new_line absent for removed lines, both present for context).
local function parse(base_sha, head_sha, path)
  local root = rebase.repo_root()
  if not root then return nil end

  local out = vim.fn.systemlist({
    "git", "-C", root, "diff", base_sha .. "..." .. head_sha, "--", path,
  })
  if vim.v.shell_error ~= 0 or not out then return nil end

  local res = {
    old = { ranges = {}, pos = {} },
    new = { ranges = {}, pos = {} },
  }
  local in_hunk = false
  local old_ln, new_ln = 0, 0

  for _, line in ipairs(out) do
    local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os_ then
      in_hunk = true
      local old_start, old_count = tonumber(os_), (oc == "" and 1 or tonumber(oc))
      local new_start, new_count = tonumber(ns), (nc == "" and 1 or tonumber(nc))
      old_ln, new_ln = old_start, new_start
      if old_count > 0 then
        res.old.ranges[#res.old.ranges + 1] = { start = old_start, ["end"] = old_start + old_count - 1 }
      end
      if new_count > 0 then
        res.new.ranges[#res.new.ranges + 1] = { start = new_start, ["end"] = new_start + new_count - 1 }
      end
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        res.new.pos[new_ln] = { new_line = new_ln }
        new_ln = new_ln + 1
      elseif c == "-" then
        res.old.pos[old_ln] = { old_line = old_ln }
        old_ln = old_ln + 1
      elseif c == " " then
        res.new.pos[new_ln] = { new_line = new_ln, old_line = old_ln }
        res.old.pos[old_ln] = { old_line = old_ln, new_line = new_ln }
        new_ln = new_ln + 1
        old_ln = old_ln + 1
      elseif c ~= "\\" then
        -- Anything other than +/-/space/"\ No newline" ends the hunk body.
        in_hunk = false
      end
    end
  end
  return res
end

local function get(base_sha, head_sha, path)
  local key = (base_sha or "") .. (head_sha or "") .. (path or "")
  local entry = cache[key]
  if not entry then
    entry = parse(base_sha, head_sha, path) or { old = { ranges = {}, pos = {} }, new = { ranges = {}, pos = {} } }
    cache[key] = entry
  end
  return entry
end

---List of {start, end} hunk ranges for `side` ("old"|"new"), or {}.
---@param side "old"|"new"
---@return { start:integer, ["end"]:integer }[]
function M.ranges(base_sha, head_sha, path, side)
  local e = get(base_sha, head_sha, path)
  return (side == "old" and e.old or e.new).ranges
end

---Position opts {new_line=?, old_line=?} for `line` on `side`, or nil if the
---line is not part of the diff on that side.
---@param side "old"|"new"
---@return { new_line:integer|nil, old_line:integer|nil }|nil
function M.pos(base_sha, head_sha, path, side, line)
  local e = get(base_sha, head_sha, path)
  return (side == "old" and e.old or e.new).pos[line]
end

---Clamps the selection [s, e] into a single diff hunk.
---Returns clamped_start, clamped_end, adjusted — or nil if the selection does
---not overlap any hunk at all. Picks the last (highest-line) overlapping hunk,
---which is the one nearest the selection's end.
---@param ranges { start:integer, ["end"]:integer }[]
---@param s integer
---@param e integer
---@return integer|nil clamped_start
---@return integer|nil clamped_end
---@return boolean|nil adjusted
function M.clamp(ranges, s, e)
  local hunk
  for _, h in ipairs(ranges) do
    if h.start <= e and h["end"] >= s then hunk = h end
  end
  if not hunk then return nil end

  local cs = math.max(s, hunk.start)
  local ce = math.min(e, hunk["end"])
  return cs, ce, (cs ~= s or ce ~= e)
end

return M
