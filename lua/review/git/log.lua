-- Local git facts about an MR's commits that the provider APIs don't return
-- with the commit list: per-commit diff stats, ref decorations, relative
-- dates — plus the stats of the whole MR diff. Feeds the Commits panel
-- (|review-panel-commits|); everything here is best-effort, the panel renders
-- without it (the commits may simply not be in the local object store).

local M = {}

local git = require("review.git.rebase")

---"4 files changed, 20 insertions(+), 5 deletions(-)" -> { files, adds, dels }
---@param text string|nil
---@return { files: integer, adds: integer, dels: integer }|nil
local function parse_shortstat(text)
  local files = text and text:match("(%d+) files? changed")
  if not files then return nil end
  return {
    files = tonumber(files),
    adds = tonumber(text:match("(%d+) insertions?") or 0),
    dels = tonumber(text:match("(%d+) deletions?") or 0),
  }
end

---@class ReviewCommitInfo
---@field all { files: integer, adds: integer, dels: integer }|nil  whole MR diff
---@field by_sha table<string, { stats: table|nil, date: string|nil, refs: string|nil }>

---Collects the stats of `base..head` (per commit) and of the MR diff as a
---whole. `base` is the MR's merge-base, so a plain two-rev diff equals the
---three-dot diff the session shows.
---@param repo string  repo root (for -C)
---@param base string  mr.base_sha
---@param head string  mr.head_sha
---@param cb fun(info: ReviewCommitInfo)
function M.load(repo, base, head, cb)
  local info = { all = nil, by_sha = {} }
  local prefix = { "git", "-C", repo, "-c", "core.quotePath=false" }

  local log = vim.list_extend(vim.list_slice(prefix), {
    "log", "--shortstat", "--format=%x1e%H%x1f%ar%x1f%D", base .. ".." .. head,
  })
  git._run(log, nil, nil, function(lres)
    if lres.ok then
      for _, record in ipairs(vim.split(lres.stdout, "\30", { plain = true, trimempty = true })) do
        local head_line, rest = record:match("^([^\n]*)\n?(.*)$")
        local field = vim.split(head_line or "", "\31", { plain = true })
        local sha = field[1]
        if sha and sha:match("^%x+$") then
          info.by_sha[sha] = {
            stats = parse_shortstat(rest),
            date = field[2] ~= "" and field[2] or nil,
            refs = (field[3] and field[3] ~= "") and field[3] or nil,
          }
        end
      end
    end

    local diff = vim.list_extend(vim.list_slice(prefix), { "diff", "--shortstat", base, head })
    git._run(diff, nil, nil, function(dres)
      if dres.ok then info.all = parse_shortstat(dres.stdout) end
      cb(info)
    end)
  end)
end

---Lines for the commit float: the full message and the stat of `sha`, or of
---the whole `base..head` diff when `sha` is nil. Synchronous — it runs on a
---keypress and `git show` of one commit is instant. nil when git can't
---answer (commit not fetched).
---@param repo string
---@param sha string|nil
---@param base string|nil
---@param head string|nil
---@return string[]|nil
function M.describe(repo, sha, base, head)
  local args = { "git", "-C", repo, "-c", "core.quotePath=false" }
  if sha then
    vim.list_extend(args, { "show", "--stat=100", "--format=medium", "--no-color", sha })
  elseif base and head then
    vim.list_extend(args, { "diff", "--stat=100", "--no-color", base, head })
  else
    return nil
  end
  local ok, job = pcall(vim.system, args, { text = true })
  if not ok then return nil end
  local res = job:wait()
  if res.code ~= 0 then return nil end
  return vim.split(res.stdout or "", "\n", { trimempty = true })
end

return M
