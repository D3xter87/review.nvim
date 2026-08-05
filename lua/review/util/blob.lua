-- Reads file contents at a specific rev (`git show <sha>:<path>`), cached.
--
-- Used to recover the ORIGINAL lines a ```suggestion replaces, so the note
-- preview can render it as a real diff. The obvious alternative — reading the
-- buffer the user is standing in — is wrong for working-tree files: local
-- uncommitted edits would produce a diff that looks plausible but shows code
-- the suggestion was never written against. Going to the object store is
-- authoritative regardless of which buffer the preview was opened from.
--
-- diffview/integration.ensure_revs has already guaranteed base_sha/head_sha are
-- present locally for the whole session, so a miss here means the PATH doesn't
-- exist at that rev (renamed / added / deleted), not a missing commit.

local M = {}

local rebase = require("review.git.rebase")

-- Cached per (sha, path) forever: a blob at a fixed sha never changes. `false`
-- memoizes a known-absent path so we don't re-shell for every keypress.
local cache = {}

---Lines of `path` (repo-relative, POSIX separators — a provider path, never a
---buffer name) at `sha`. Returns nil when the blob doesn't exist there.
---@param sha string|nil
---@param path string|nil
---@return string[]|nil
function M.lines(sha, path)
  if type(sha) ~= "string" or sha == "" then return nil end
  if type(path) ~= "string" or path == "" then return nil end

  local key = sha .. ":" .. path
  local hit = cache[key]
  if hit ~= nil then
    return hit ~= false and hit or nil
  end

  local root = rebase.repo_root()
  if not root then
    cache[key] = false
    return nil
  end

  local out = vim.fn.systemlist({ "git", "-C", root, "show", sha .. ":" .. path })
  if vim.v.shell_error ~= 0 or type(out) ~= "table" then
    cache[key] = false
    return nil
  end

  cache[key] = out
  return out
end

return M
