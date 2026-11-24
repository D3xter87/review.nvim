-- CI/CD of a review session: the pipeline of the MR/PR, fetched through an
-- adapter (config `ci.adapter`, else `review.ci.builtin`), cached on the
-- session, polled while it runs, and acted on from the Pipeline panel.
--
-- The feature needs no CI/CD plugin: an adapter is a table of functions
-- the user's config hands in (see |review-ci|). Everything it is given is a
-- `ReviewTarget` (also what `require("review").current()` returns).

local M = {}

local state_mod = require("review.state")
local config_mod = require("review.config")
local notify_util = require("review.util.notify")

-- ------------------------------------------------------------ statuses

-- A pipeline / job in one of these is still going: worth polling.
M.ACTIVE = { running = true, pending = true, created = true }

local KNOWN = {
  success = true, failed = true, running = true, pending = true, created = true,
  manual = true, canceled = true, skipped = true, none = true,
}

local ICONS = {
  success = "✓", failed = "✗", running = "●", pending = "○", created = "○",
  manual = "▶", canceled = "⊘", skipped = "↷", none = "–",
}

local HL = {
  success = "ReviewCiSuccess", failed = "ReviewCiFailed",
  running = "ReviewCiRunning", pending = "ReviewCiRunning", created = "ReviewCiRunning",
  manual = "ReviewCiManual",
  canceled = "ReviewCiMuted", skipped = "ReviewCiMuted", none = "ReviewCiMuted",
}

---@param status string|nil
---@return string
function M.icon(status) return ICONS[status] or "?" end

---@param status string|nil
---@return string
function M.hl(status) return HL[status] or "ReviewCiMuted" end

-- Adapters may hand in their own spelling; map the common ones.
local ALIASES = {
  passed = "success", succeeded = "success", ok = "success",
  failure = "failed", error = "failed",
  cancelled = "canceled",
  queued = "pending", waiting = "pending", scheduled = "pending",
  in_progress = "running",
}

local function norm_status(s)
  if type(s) ~= "string" then return nil end
  s = s:lower()
  s = ALIASES[s] or s
  return KNOWN[s] and s or nil
end

---Counts over the jobs that take part in the run (manual and skipped jobs
---don't), so `succeeded/total` reads as progress.
---@param jobs table[]
---@return { total: integer, succeeded: integer, failed: integer, running: integer, failed_names: string[] }
function M.counts(jobs)
  local c = { total = 0, succeeded = 0, failed = 0, running = 0, failed_names = {} }
  for _, job in ipairs(jobs or {}) do
    local s = job.status
    if s ~= "manual" and s ~= "skipped" then
      c.total = c.total + 1
      if s == "success" then
        c.succeeded = c.succeeded + 1
      elseif s == "failed" then
        c.failed = c.failed + 1
        table.insert(c.failed_names, job.name or "?")
      elseif M.ACTIVE[s] then
        c.running = c.running + 1
      end
    end
  end
  return c
end

---Aggregate status from the jobs, for an adapter that reports none.
---@param jobs table[]
---@return string
local function aggregate(jobs)
  if #jobs == 0 then return "none" end
  local seen = {}
  for _, job in ipairs(jobs) do seen[job.status] = true end
  if seen.running or seen.pending or seen.created then return "running" end
  if seen.failed then return "failed" end
  if seen.canceled then return "canceled" end
  if seen.success then return "success" end
  if seen.manual then return "manual" end
  return "skipped"
end

---Makes an adapter's pipeline safe to render: known statuses, a jobs list,
---counts.
---@param p table
---@return table
function M.normalize(p)
  p.jobs = type(p.jobs) == "table" and p.jobs or {}
  for _, job in ipairs(p.jobs) do
    job.status = norm_status(job.status) or "created"
    job.stage = (job.stage ~= nil and job.stage ~= "") and tostring(job.stage) or nil
  end
  p.status = norm_status(p.status) or aggregate(p.jobs)
  p.counts = M.counts(p.jobs)
  return p
end

-- ------------------------------------------------------------- target

---@class ReviewTarget
---@field tabnr integer
---@field provider "gitlab"|"github"|string
---@field host string|nil
---@field path string|nil          project path / owner/repo
---@field repo_root string|nil     local repository the session is pinned to
---@field iid integer|nil          MR / PR number
---@field web_url string|nil
---@field source_branch string|nil
---@field target_branch string|nil
---@field head_sha string|nil
---@field mr table                 the normalized MR/PR

---The review in `tabnr` (default: the current tab) as a `ReviewTarget`, or
---nil when there is none. Carries no credentials.
---@param tabnr integer|nil
---@return ReviewTarget|nil
function M.target(tabnr)
  local controller = package.loaded["review.controller"]
  if not controller then return nil end
  local ctx = controller.get_ctx(tabnr)
  if not ctx or not ctx.mr then return nil end
  local session = state_mod.get_for_tab(ctx.tabnr)
  local mr = ctx.mr
  local remote = ctx.remote or {}
  return {
    tabnr = ctx.tabnr,
    provider = ctx.provider and ctx.provider.name,
    host = remote.host,
    path = remote.path or remote.owner_repo,
    repo_root = session and session.repo,
    iid = mr.iid,
    web_url = mr.web_url,
    source_branch = mr.source_branch or ctx.branch,
    target_branch = mr.target_branch,
    head_sha = mr.sha or mr.head_sha,
    mr = mr,
  }
end

-- ------------------------------------------------------------ adapter

function M.enabled()
  local cfg = config_mod.get().ci
  return cfg ~= nil and cfg.enabled ~= false
end

local warned_bad_adapter = false

---The configured adapter, or the built-in one.
---@return table
function M.adapter()
  local a = (config_mod.get().ci or {}).adapter
  if type(a) == "table" and type(a.fetch) == "function" then return a end
  if a ~= nil and not warned_bad_adapter then
    warned_bad_adapter = true
    notify_util.warn("ci.adapter needs a fetch(target, cb) function - using the built-in one")
  end
  return require("review.ci.builtin")
end

-- ------------------------------------------------------- fetch / polling

---@param session table
---@return { pipeline: table|nil, err: string|nil, loading: boolean|nil, fetched_at: number|nil, refetch: boolean|nil }
local function ci_state(session)
  session.ci = session.ci or {}
  return session.ci
end

---The cached CI state of a session (nil fields until the first fetch).
---@param tabnr integer|nil  default: current tab
function M.get(tabnr)
  local session = tabnr and state_mod.get_for_tab(tabnr) or state_mod.get_active()
  return session and ci_state(session) or nil
end

local SHOWN = { info = true, pipeline = true }

---Is the session's Info or Pipeline panel on screen right now?
local function shown(tabnr)
  if vim.api.nvim_get_current_tabpage() ~= tabnr then return false end
  local session = state_mod.get_for_tab(tabnr)
  local panel = session and session.panel
  return panel ~= nil and SHOWN[panel.mode] == true
      and panel.win ~= nil and vim.api.nvim_win_is_valid(panel.win)
end

---@type table<integer, userdata>
local timers = {}

---Stop the session's poll timer.
---@param tabnr integer
function M.stop(tabnr)
  local t = timers[tabnr]
  timers[tabnr] = nil
  if t then
    pcall(t.stop, t)
    pcall(t.close, t)
  end
end

local function poll_interval()
  local ms = (config_mod.get().ci or {}).poll_interval_ms
  return type(ms) == "number" and ms or 15000
end

---Arm the next poll if the pipeline is still going. Runs while the panel is
---off screen too, but only fetches when it is on screen.
---@param tabnr integer
local function schedule_poll(tabnr)
  M.stop(tabnr)
  local session = state_mod.get_for_tab(tabnr)
  local p = session and session.ci and session.ci.pipeline
  local interval = poll_interval()
  if not p or not M.ACTIVE[p.status] or interval <= 0 then return end
  local timer = vim.uv.new_timer()
  if not timer then return end
  timers[tabnr] = timer
  timer:start(interval, 0, vim.schedule_wrap(function()
    if timers[tabnr] ~= timer then return end
    M.stop(tabnr)
    if not state_mod.get_for_tab(tabnr) then return end
    if shown(tabnr) then
      M.fetch(tabnr)
    else
      schedule_poll(tabnr)
    end
  end))
end

local function redraw(tabnr)
  if shown(tabnr) then
    require("review.controller").refresh_panel(tabnr)
  end
end

---Fetch the pipeline of the session in `tabnr` (default: current tab) through
---the adapter; the Info / Pipeline panel redraws when it arrives.
---@param tabnr integer|nil
function M.fetch(tabnr)
  if not M.enabled() then return end
  local target = M.target(tabnr)
  if not target then return end
  tabnr = target.tabnr
  local session = state_mod.get_for_tab(tabnr)
  if not session then return end
  local ci = ci_state(session)
  if ci.loading then
    ci.refetch = true
    return
  end
  ci.loading = true

  local adapter = M.adapter()
  local answered = false
  local function done(pipeline, err)
    if answered then return end
    answered = true
    vim.schedule(function()
      if state_mod.get_for_tab(tabnr) ~= session then return end -- session closed meanwhile
      ci.loading = false
      if type(pipeline) == "table" then
        ci.pipeline = M.normalize(pipeline)
        ci.err = nil
      else
        ci.err = tostring(err or "no pipeline data")
      end
      ci.fetched_at = vim.uv.now()
      redraw(tabnr)
      if ci.refetch then
        ci.refetch = false
        return M.fetch(tabnr)
      end
      schedule_poll(tabnr)
    end)
  end

  local ok, err = pcall(adapter.fetch, target, done)
  if not ok then done(nil, "ci adapter: " .. tostring(err)) end
  -- First fetch: show "(loading…)" right away. Later ones keep the last
  -- data on screen until the new one arrives.
  if not ci.pipeline then redraw(tabnr) end
end

---Fetch unless the data is fresh. For a panel coming on screen and for
---focus returning to Neovim.
---@param tabnr integer|nil
function M.ensure_fresh(tabnr)
  local ci = M.get(tabnr)
  if not ci or ci.loading then return end
  local age = ci.fetched_at and (vim.uv.now() - ci.fetched_at) or math.huge
  local p = ci.pipeline
  -- A settled pipeline only changes when someone acts on it; recheck it less.
  local max_age = (p and not M.ACTIVE[p.status]) and 60000 or math.max(poll_interval(), 5000)
  if age >= max_age then M.fetch(tabnr) end
end

-- ------------------------------------------------------------- actions

---@param url string|nil
---@param what string
function M.open_url(url, what)
  if not url or url == "" then
    notify_util.warn("no web URL for " .. what)
    return
  end
  if require("review.actions.web").open_external(url) then
    notify_util.progress("opened " .. url)
  else
    notify_util.warn("could not open browser - copy URL manually: " .. url)
  end
end

---Run the adapter's action for `job` (its `job.action`: play / retry /
---cancel). Cancelling asks first.
---@param tabnr integer|nil
---@param job table
function M.run(tabnr, job)
  local adapter = M.adapter()
  if type(adapter.run) ~= "function" then
    notify_util.warn("the CI adapter has no job actions (see :h review-ci)")
    return
  end
  if not job.action then
    notify_util.warn(string.format("%s: nothing to do while it is %s", job.name or "job", job.status or "?"))
    return
  end
  local target = M.target(tabnr)
  if not target then return end
  local label = job.action_label or job.action

  local function go()
    local ok, err = pcall(adapter.run, target, job, function(success, run_err)
      vim.schedule(function()
        if success then
          notify_util.event(string.format("%s: %s", label, job.name or "job"))
          -- Give the forge a moment to register the new state.
          vim.defer_fn(function() M.fetch(target.tabnr) end, 1500)
        else
          notify_util.err(string.format("%s %s failed: %s", label, job.name or "job", tostring(run_err or "?")))
        end
      end)
    end)
    if not ok then notify_util.err("ci adapter run: " .. tostring(err)) end
  end

  if job.action == "cancel" then
    vim.ui.select({ "No", "Yes" }, {
      prompt = string.format("%s (%s)?", label, job.name or "job"),
    }, function(choice)
      if choice == "Yes" then go() end
    end)
  else
    go()
  end
end

---Show the job's log through the adapter.
---@param tabnr integer|nil
---@param job table
function M.log(tabnr, job)
  local adapter = M.adapter()
  if type(adapter.log) ~= "function" then
    return M.open_url(job.web_url, job.name or "job")
  end
  local target = M.target(tabnr)
  if not target then return end
  local ok, err = pcall(adapter.log, target, job)
  if not ok then notify_util.err("ci adapter log: " .. tostring(err)) end
end

---The adapter's own pipeline UI; the pipeline page in the browser without one.
---@param tabnr integer|nil
function M.open(tabnr)
  local adapter = M.adapter()
  local target = M.target(tabnr)
  if not target then return end
  if type(adapter.open) ~= "function" then
    local ci = M.get(target.tabnr)
    return M.open_url(ci and ci.pipeline and ci.pipeline.web_url, "the pipeline")
  end
  local ok, err = pcall(adapter.open, target)
  if not ok then notify_util.err("ci adapter open: " .. tostring(err)) end
end

---Which optional keys the adapter supports (for the panel's hints).
---@return { run: boolean, log: boolean, open: boolean, name: string }
function M.capabilities()
  local a = M.adapter()
  return {
    run = type(a.run) == "function",
    log = type(a.log) == "function",
    open = type(a.open) == "function",
    name = type(a.name) == "string" and a.name or "built-in",
  }
end

-- Coming back to Neovim: a pipeline may have moved on meanwhile.
pcall(vim.api.nvim_create_autocmd, "FocusGained", {
  group = vim.api.nvim_create_augroup("ReviewCi", { clear = true }),
  callback = function()
    local tabnr = vim.api.nvim_get_current_tabpage()
    if shown(tabnr) then M.ensure_fresh(tabnr) end
  end,
})

return M
