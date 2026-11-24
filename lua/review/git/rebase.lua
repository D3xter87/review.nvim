-- Git plumbing for :ReviewRebase. All operations run async via vim.system so
-- they don't block the editor; callbacks are scheduled back onto the main
-- loop so they can safely touch UI / state.
--
-- Conventions:
--   * `cb({ ok = bool, code = int, stdout = str, stderr = str, ... })`
--   * Only origin's branches take part: the rebase starts from
--     `origin/<source>`, goes onto `origin/<target>` and is pushed back to
--     `origin/<source>`. Local branches are never read nor moved.
--   * Worktrees live at `<repo>/.git/review-rebase/<sanitized_branch>` so
--     parallel rebases of different branches coexist; the path is fixed
--     per source branch (so a re-run after a crash finds the previous one).

local M = {}

---@param args string[]
---@param cwd string|nil
---@param env table|nil  Extra env vars merged with current environment
---@param cb fun(res: { ok: boolean, code: integer, stdout: string, stderr: string })
function M._run(args, cwd, env, cb)
  local ok, err = pcall(vim.system, args, {
    text = true,
    cwd = cwd,
    env = env,
  }, function(out)
    vim.schedule(function()
      cb({
        ok = out.code == 0,
        code = out.code or -1,
        stdout = out.stdout or "",
        stderr = out.stderr or "",
      })
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ ok = false, code = -1, stdout = "", stderr = "system spawn failed: " .. tostring(err) })
    end)
  end
end

---Resolves the absolute path of the repository root. Synchronous (cheap call,
---needed before we can schedule any worktree work). Returns nil on failure.
function M.repo_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return nil end
  return (out[1] or ""):gsub("%s+$", "")
end

---Branch name sanitized for use as a directory component.
local function sanitize(branch)
  return (branch:gsub("[/:%s]", "_"))
end

---Path of the worktree we'd use for `source_branch`.
function M.worktree_path(repo_root, source_branch)
  return repo_root .. "/.git/review-rebase/" .. sanitize(source_branch)
end

---Returns the currently-checked-out branch in the main repo (HEAD), or nil
---if HEAD is detached.
function M.current_branch()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return nil end
  local b = (out[1] or ""):gsub("%s+$", "")
  if b == "" or b == "HEAD" then return nil end
  return b
end

---Inspects the state of a (possibly) in-progress rebase in `worktree`.
---Returns `{ unmerged = boolean, in_progress = boolean }`:
---  * `unmerged`   = there are paths with conflict markers (UU/AA/...).
---  * `in_progress` = git thinks a rebase is mid-way (presence of the
---    rebase-merge / rebase-apply state directory).
---@param worktree string
---@param cb fun(state: { unmerged: boolean, in_progress: boolean })
function M.check_state(worktree, cb)
  M._run({ "git", "-C", worktree, "status", "--porcelain" }, nil, nil, function(res)
    local unmerged = false
    if res.ok then
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local xy = line:sub(1, 2)
        -- "UU", "AA", "DD", "AU", "UA", "DU", "UD" all indicate unmerged.
        if xy:find("U") or xy == "AA" or xy == "DD" then
          unmerged = true; break
        end
      end
    end
    -- The rebase state lives in the worktree's own git dir, which for a
    -- linked worktree is `<repo>/.git/worktrees/<name>` — its `.git` is a
    -- file pointing there, not a directory.
    M._run({ "git", "-C", worktree, "rev-parse", "--absolute-git-dir" }, nil, nil, function(gres)
      local git_dir = gres.ok and (gres.stdout or ""):gsub("%s+$", "") or ""
      local in_progress = git_dir ~= ""
          and (vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1
            or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1)
      cb({ unmerged = unmerged, in_progress = in_progress })
    end)
  end)
end

---Starts the rebase, working only on origin's branches: the worktree is a
---detached checkout of the freshly fetched `origin/<source>`, rebased onto
---`origin/<target>`. Local branches — stale or checked out — never take part.
---Four steps; cb fires once on completion.
---Successful path: cb({ ok = true, worktree = ..., lease = ... }).
---Conflict path:    cb({ ok = false, conflict = true, worktree = ..., lease = ... }).
---Other failures:   cb({ ok = false, error = "..." })  (worktree may or may
---                  not exist depending on which step failed; caller handles).
---`lease` is the sha `origin/<source>` had when the rebase started; M.push
---only overwrites the branch if it still points there.
---@param repo_root string
---@param source_branch string
---@param target_branch string
---@param cb fun(res: { ok: boolean, conflict: boolean|nil, worktree: string|nil, lease: string|nil, error: string|nil })
function M.start(repo_root, source_branch, target_branch, cb)
  local worktree = M.worktree_path(repo_root, source_branch)
  local lease

  local function do_rebase()
    M._run({ "git", "-C", worktree, "rebase", "origin/" .. target_branch }, nil, nil, function(res)
      if res.ok then return cb({ ok = true, worktree = worktree, lease = lease }) end
      -- Distinguish conflict vs other failure by checking state.
      M.check_state(worktree, function(state)
        if state.in_progress and state.unmerged then
          return cb({ ok = false, conflict = true, worktree = worktree, lease = lease })
        end
        cb({
          ok = false,
          worktree = worktree,
          error = "rebase failed: " .. ((res.stderr or ""):gsub("%s+$", "")),
        })
      end)
    end)
  end

  local function do_read_lease()
    M.head_sha(worktree, function(sha)
      if not sha then
        return cb({ ok = false, worktree = worktree,
          error = "cannot read origin/" .. source_branch .. " in the worktree" })
      end
      lease = sha
      do_rebase()
    end)
  end

  local function do_worktree_add()
    -- --detach: a branch can be checked out in only one worktree, and we
    -- don't want a local branch anyway — the result is pushed straight to
    -- origin.
    M._run({ "git", "-C", repo_root, "worktree", "add", "--detach", worktree,
      "origin/" .. source_branch }, nil, nil, function(res)
      if res.ok then return do_read_lease() end
      cb({ ok = false, error = "worktree add failed: " .. (res.stderr or ""):gsub("%s+$", "") })
    end)
  end

  local function do_fetch()
    -- Explicit refspecs: the remote-tracking refs are what the rebase starts
    -- from and lands on, so they must be updated whatever the remote's fetch
    -- config says.
    local function spec(b) return "+refs/heads/" .. b .. ":refs/remotes/origin/" .. b end
    M._run({ "git", "-C", repo_root, "fetch", "origin", spec(source_branch), spec(target_branch) },
      nil, nil, function(res)
      -- Fetch must succeed: the whole point of rebase is to put the branch
      -- on top of the LATEST origin/<target>. If we couldn't refresh remote
      -- refs we'd silently rebase against a stale cache and produce a wrong
      -- result (e.g. miss a freshly-merged MR on main). Fail loudly.
      if not res.ok then
        return cb({
          ok = false,
          error = "git fetch failed: " .. ((res.stderr or "(no stderr)"):gsub("%s+$", ""))
              .. " - check your network / VPN and retry",
        })
      end
      do_worktree_add()
    end)
  end

  do_fetch()
end

---Resume a rebase after the user has staged their conflict resolution. Runs
---with `GIT_EDITOR=true` so any commit-message editor pops are auto-accepted.
---@param worktree string
---@param cb fun(res: { ok: boolean, conflict: boolean|nil, error: string|nil })
function M.continue_rebase(worktree, cb)
  M._run({ "git", "-C", worktree, "rebase", "--continue" }, nil,
    { GIT_EDITOR = "true" }, function(res)
    if res.ok then return cb({ ok = true }) end
    M.check_state(worktree, function(state)
      if state.in_progress and state.unmerged then
        return cb({ ok = false, conflict = true })
      end
      cb({ ok = false, error = "rebase --continue failed: " .. ((res.stderr or ""):gsub("%s+$", "")) })
    end)
  end)
end

---Best-effort abort. Doesn't surface errors — if the rebase wasn't in
---progress, we don't care.
function M.abort(worktree, cb)
  M._run({ "git", "-C", worktree, "rebase", "--abort" }, nil, nil, function(_)
    if cb then cb() end
  end)
end

---Pushes the worktree's HEAD to `origin/<branch>`, replacing it only if it
---still points at `lease` (where the rebase started) — commits someone pushed
---in the meantime make the push fail instead of being dropped.
---@param worktree string
---@param branch string
---@param lease string
---@param cb fun(res: { ok: boolean, error: string|nil })
function M.push(worktree, branch, lease, cb)
  local ref = "refs/heads/" .. branch
  M._run({ "git", "-C", worktree, "push",
    "--force-with-lease=" .. ref .. ":" .. lease, "origin", "HEAD:" .. ref },
    nil, nil, function(res)
    if res.ok then return cb({ ok = true }) end
    cb({ ok = false, error = (res.stderr or ""):gsub("%s+$", "") })
  end)
end

---The commit HEAD points at in `cwd` (a worktree or the main repo).
---@param cwd string
---@param cb fun(sha: string|nil)
function M.head_sha(cwd, cb)
  M._run({ "git", "-C", cwd, "rev-parse", "HEAD" }, nil, nil, function(res)
    local sha = res.ok and (res.stdout or ""):gsub("%s+$", "") or ""
    cb(sha ~= "" and sha or nil)
  end)
end

---Removes the worktree directory; pcall'd because Windows occasionally
---holds locks on freshly-closed buffers' files.
function M.cleanup(worktree, cb)
  if not worktree or worktree == "" then
    if cb then cb() end
    return
  end
  M._run({ "git", "worktree", "remove", "--force", worktree }, nil, nil, function(_)
    if cb then cb() end
  end)
end

---Returns true iff a worktree dir for this source branch already exists.
function M.worktree_exists(worktree)
  return vim.fn.isdirectory(worktree) == 1
end

return M
