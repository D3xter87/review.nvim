-- Which branch did the current one come from? Used as the default target of
-- :ReviewCreate. Reads only local git data (no fetch); every answer must be
-- one of `candidates` -- the branches the forge knows about -- and never the
-- source branch itself.
--
-- Steps, first hit wins:
--   1. The branch's own reflog: "branch: Created from origin/develop". Only
--      says something when the start point was given explicitly.
--   2. Only when step 1 reads "Created from HEAD" (a plain
--      `git switch -c <source>`): HEAD's reflog, the oldest
--      "checkout: moving from develop to <source>".
--   3. The nearest remote branch: the one missing the fewest of HEAD's
--      commits (`%(ahead-behind:HEAD)`, git >= 2.41). Refs that contain all
--      of HEAD are descendants, not bases, and are skipped. Ties go to the
--      default branch, then protected ones, then the one with fewer commits
--      of its own, then the name.
--   4. The default branch, then the first candidate.

local M = {}

local run = require("review.git.rebase")._run

---@param ref string|nil
---@return string|nil
local function strip(ref)
  if not ref then return nil end
  ref = vim.trim(ref)
  ref = ref:gsub("^refs/remotes/", ""):gsub("^refs/heads/", ""):gsub("^origin/", "")
  return ref
end

---@param source string
---@param by_name table<string, table>
local function acceptor(source, by_name)
  return function(ref)
    local name = strip(ref)
    if not name or name == "" or name == "HEAD" or name == source then return nil end
    if name:match("^%x+$") and #name >= 7 and #name <= 40 then return nil end
    if not by_name[name] then return nil end
    return name
  end
end

---Oldest reflog entry matching `pattern` (reflog lists newest first).
---@param lines string[]
---@param pattern string  with one capture
local function oldest_match(lines, pattern)
  for i = #lines, 1, -1 do
    local hit = lines[i]:match(pattern)
    if hit then return hit end
  end
  return nil
end

---@param stdout string
local function lines_of(stdout)
  return vim.split(stdout or "", "\n", { trimempty = true })
end

-- Ranking of two nearest-branch candidates: lower wins on each key in turn.
local RANK = { "behind", "default", "protected", "ahead" }
local function before(a, b)
  for _, key in ipairs(RANK) do
    if a[key] ~= b[key] then return a[key] < b[key] end
  end
  return a.name < b.name
end

---Picks the nearest remote branch from `for-each-ref ... %(ahead-behind:HEAD)`
---output. Exposed for tests.
---@param stdout string
---@param accept fun(ref: string): string|nil
---@param by_name table<string, table>
---@return string|nil
function M._nearest(stdout, accept, by_name)
  local best
  for _, line in ipairs(lines_of(stdout)) do
    local ref, ahead, behind = line:match("^(%S+)%s+(%d+)%s+(%d+)$")
    local name = ref and accept(ref)
    behind = tonumber(behind)
    if name and behind and behind > 0 then
      local c = by_name[name]
      local cand = {
        name = name,
        behind = behind,
        ahead = tonumber(ahead) or 0,
        default = c.default and 0 or 1,
        protected = c.protected and 0 or 1,
      }
      if not best or before(cand, best) then best = cand end
    end
  end
  return best and best.name or nil
end

---@param source string
---@param candidates { name: string, default: boolean|nil, protected: boolean|nil }[]
---@param cb fun(name: string|nil, how: "reflog"|"checkout"|"nearest"|"default"|"first"|nil)
function M.detect(source, candidates, cb)
  local by_name, default_name = {}, nil
  for _, c in ipairs(candidates or {}) do
    by_name[c.name] = c
    if c.default and c.name ~= source then default_name = c.name end
  end
  local accept = acceptor(source, by_name)

  local function fallback()
    if default_name then return cb(default_name, "default") end
    for _, c in ipairs(candidates or {}) do
      if c.name ~= source then return cb(c.name, "first") end
    end
    cb(nil, nil)
  end

  local function nearest()
    run({ "git", "for-each-ref", "--format=%(refname:lstrip=3) %(ahead-behind:HEAD)",
      "refs/remotes/origin" }, nil, nil, function(res)
      if not res.ok then return fallback() end
      local name = M._nearest(res.stdout, accept, by_name)
      if name then return cb(name, "nearest") end
      fallback()
    end)
  end

  local function head_reflog()
    run({ "git", "reflog", "show", "--format=%gs", "HEAD" }, nil, nil, function(res)
      if res.ok then
        -- Escape magic characters: branch names often contain '-' and '.'.
        local target = vim.pesc(source)
        local from = oldest_match(lines_of(res.stdout),
          "^checkout: moving from (%S+) to " .. target .. "$")
        local name = accept(from)
        if name then return cb(name, "checkout") end
      end
      nearest()
    end)
  end

  run({ "git", "reflog", "show", "--format=%gs", "refs/heads/" .. source }, nil, nil, function(res)
    local from = res.ok and oldest_match(lines_of(res.stdout), "^branch: Created from (%S+)$") or nil
    local name = accept(from)
    if name then return cb(name, "reflog") end
    -- Only a branch made from HEAD makes "the branch HEAD was on" the base.
    -- One made from its own remote branch (created on the forge, then
    -- `git checkout <name>`) or with no reflog says nothing about where
    -- you were standing at the time.
    if from == "HEAD" then return head_reflog() end
    nearest()
  end)
end

return M
