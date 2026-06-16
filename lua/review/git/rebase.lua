-- Git plumbing for :ReviewRebase. All operations run async via vim.system so
-- they don't block the editor; callbacks are scheduled back onto the main
-- loop so they can safely touch UI / state.
--
-- Conventions:
--   * `cb({ ok = bool, code = int, stdout = str, stderr = str, ... })`
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
    local in_progress = vim.fn.isdirectory(worktree .. "/.git/rebase-merge") == 1
        or vim.fn.isdirectory(worktree .. "/.git/rebase-apply") == 1
    cb({ unmerged = unmerged, in_progress = in_progress })
  end)
end

---Starts the rebase. Three-step sequence; cb fires once on completion.
---Successful path: cb({ ok = true, worktree = ... }).
---Conflict path:    cb({ ok = false, conflict = true, worktree = ... }).
---Other failures:   cb({ ok = false, error = "..." })  (worktree may or may
---                  not exist depending on which step failed; caller handles).
---@param repo_root string
---@param source_branch string
---@param target_branch string
---@param cb fun(res: { ok: boolean, conflict: boolean|nil, worktree: string|nil, error: string|nil, branch_busy: boolean|nil })
function M.start(repo_root, source_branch, target_branch, cb)
  local worktree = M.worktree_path(repo_root, source_branch)

  local function do_rebase()
    -- `origin/<target>` to use the freshest fetched ref; falls back implicitly
    -- to the local target if origin/<target> doesn't exist (rare, e.g. when
    -- target branch hasn't been pushed). For simplicity we always fetch first.
    M._run({ "git", "-C", worktree, "rebase", "origin/" .. target_branch }, nil, nil, function(res)
      if res.ok then return cb({ ok = true, worktree = worktree }) end
      -- Distinguish conflict vs other failure by checking state.
      M.check_state(worktree, function(state)
        if state.in_progress and state.unmerged then
          return cb({ ok = false, conflict = true, worktree = worktree })
        end
        cb({
          ok = false,
          worktree = worktree,
          error = "rebase failed: " .. ((res.stderr or ""):gsub("%s+$", "")),
        })
      end)
    end)
  end

  local function do_worktree_add()
    M._run({ "git", "-C", repo_root, "worktree", "add", worktree, source_branch },
      nil, nil, function(res)
      if res.ok then return do_rebase() end
      -- "is already checked out" or "is already used by worktree" -> branch_busy
      local stderr = res.stderr or ""
      if stderr:find("already checked out") or stderr:find("already used by") then
        return cb({
          ok = false,
          branch_busy = true,
          error = "branch '" .. source_branch .. "' is already checked out",
        })
      end
      cb({ ok = false, error = "worktree add failed: " .. stderr:gsub("%s+$", "") })
    end)
  end

  local function do_fetch()
    M._run({ "git", "-C", repo_root, "fetch", "origin", source_branch, target_branch },
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

---In-place rebase variant: runs in `cwd` (the user's main repo) rather than
---a worktree. Used when source_branch == current branch — the user is
---already on it and a worktree would just be redundant indirection.
---@param cwd string
---@param target_branch string
---@param cb fun(res: { ok: boolean, conflict: boolean|nil, error: string|nil })
function M.start_in_place(cwd, target_branch, cb)
  M._run({ "git", "-C", cwd, "fetch", "origin", target_branch }, nil, nil, function(fres)
    if not fres.ok then
      return cb({
        ok = false,
        error = "git fetch failed: " .. ((fres.stderr or "(no stderr)"):gsub("%s+$", ""))
            .. " - check your network / VPN and retry",
      })
    end
    M._run({ "git", "-C", cwd, "rebase", "origin/" .. target_branch }, nil, nil, function(res)
      if res.ok then return cb({ ok = true }) end
      M.check_state(cwd, function(state)
        if state.in_progress and state.unmerged then
          return cb({ ok = false, conflict = true })
        end
        cb({ ok = false, error = "rebase failed: " .. ((res.stderr or ""):gsub("%s+$", "")) })
      end)
    end)
  end)
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

---Force-with-lease push of the rebased branch.
---@param worktree string
---@param branch string
---@param cb fun(res: { ok: boolean, error: string|nil })
function M.push(worktree, branch, cb)
  M._run({ "git", "-C", worktree, "push", "--force-with-lease", "origin", branch },
    nil, nil, function(res)
    if res.ok then return cb({ ok = true }) end
    cb({ ok = false, error = (res.stderr or ""):gsub("%s+$", "") })
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
