-- Controller: orchestrates Review sessions.
--
-- review.nvim supports multiple concurrent sessions, one per diffview tab.
-- The "active" session is the one whose tab is currently focused —
-- subcommands without an argument operate on it. Sessions are independent:
-- closing one does not affect the others.
--
-- Public surface:
--   M.open(opts)               start a new session (HEAD branch / explicit
--                              branch / iid / initial_mode)
--   M.open_or_focus(opts, mode)
--                              if a session for the resolved MR already
--                              exists, focus its tab and switch its panel
--                              mode; else start a new session in `mode`.
--   M.reopen_mr_session(opts)  reopen a closed MR + start session
--   M.close(tabnr?)            tear down a session; defaults to active
--   M.has_session()            does the current tab host a session?
--   M.get_active_ctx()         { provider, remote, branch, mr, tabnr } | nil
--   M.with_target(opts, cb)    resolve action target (active session,
--                              ephemeral by iid/branch, or current-branch
--                              picker when no session exists)
--   M.refresh_mr_details() / refresh_discussions() / refresh_participants()
--                              act on the active session's MR

local M = {}

local state_mod = require("review.state")
local config_mod = require("review.config")
local providers = require("review.providers")
local git_remote = require("review.http.git_remote")
local diffview_int = require("review.diffview.integration")
local readonly = require("review.diffview.readonly")
local bottom_panel = require("review.ui.bottom_panel")
local highlights = require("review.ui.highlights")
local notify_util = require("review.util.notify")

-- Augroups are shared across sessions — callbacks branch on the active
-- tab's session at fire time. Only one set of autocmds is needed because
-- they all condition on "is the current buffer / tab in some live session".
local VISUAL_AUGROUP = "ReviewVisualKeymaps"
local LIFECYCLE_AUGROUP = "ReviewLifecycle"

---@class ReviewCtx
---@field provider table
---@field remote table
---@field branch string
---@field mr table
---@field tabnr integer  diffview tabpage handle (the session's anchor)

---@type table<integer, ReviewCtx>
local ctx_by_tab = {}

-- Per-session re-entrancy guard for close().
---@type table<integer, boolean>
local closing_by_tab = {}

-- INFO-level calls here are confirmations (events) by default; use
-- notify_util.progress() directly for low-value chatter ("looking up...").
local function notify(msg, level)
  notify_util.legacy(msg, level)
end

local function current_branch()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 or not out or #out == 0 then return "" end
  return (out[1] or ""):gsub("%s+$", "")
end

---Returns the ctx for the currently-focused tab, or nil.
function M.get_active_ctx()
  local ok, tabnr = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then return nil end
  return ctx_by_tab[tabnr]
end

-- Back-compat alias used by older action modules.
function M.get_ctx() return M.get_active_ctx() end

function M.has_session()
  return M.get_active_ctx() ~= nil
end

---Searches every live session for one whose MR matches `iid` (and host).
---@param remote_host string
---@param project_path string
---@param iid integer|string
---@return integer|nil tabnr, ReviewCtx|nil
function M.find_session_by_mr(remote_host, project_path, iid)
  for tabnr, c in pairs(ctx_by_tab) do
    if c.remote and c.remote.host == remote_host
        and (c.remote.path == project_path or c.remote.owner_repo == project_path)
        and c.mr and tostring(c.mr.iid) == tostring(iid) then
      return tabnr, c
    end
  end
  return nil, nil
end

local function setup_visual_keymaps()
  -- Idempotent — runs once per Neovim session, not per Review session.
  if vim.fn.exists("#" .. VISUAL_AUGROUP) == 1 then return end

  local actions_add_comment = function()
    require("review.actions.add_comment").run()
  end
  local actions_add_suggestion = function()
    require("review.actions.add_suggestion").run()
  end

  local group = vim.api.nvim_create_augroup(VISUAL_AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if not diffview_int.is_diffview_buf(args.buf) then return end
      local opts = { buffer = args.buf, silent = true, noremap = true }
      vim.keymap.set("x", "c", actions_add_comment, opts)
      vim.keymap.set("x", "s", actions_add_suggestion, opts)
    end,
  })

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if diffview_int.is_diffview_buf(b) then
      local opts = { buffer = b, silent = true, noremap = true }
      vim.keymap.set("x", "c", actions_add_comment, opts)
      vim.keymap.set("x", "s", actions_add_suggestion, opts)
    end
  end
end

---Look up a discussion in the ACTIVE session that anchors to (path, line, side).
---@param path string
---@param line integer
---@param side "old"|"new"
---@return any|nil
local function find_discussion_for(path, line, side)
  local active = state_mod.get_active()
  if not active then return nil end
  for _, d in ipairs(active.discussions or {}) do
    local first = d.notes and d.notes[1]
    local pos = first and first.position
    if type(pos) == "table" and pos ~= vim.NIL then
      local p_path = pos.new_path or pos.old_path
      local p_line = tonumber(side == "new" and pos.new_line or pos.old_line)
      if p_path and p_line and p_path == path and p_line == line then
        return d.id
      end
    end
  end
  return nil
end

local function setup_lifecycle_autocmds()
  if vim.fn.exists("#" .. LIFECYCLE_AUGROUP) == 1 then return end

  local group = vim.api.nvim_create_augroup(LIFECYCLE_AUGROUP, { clear = true })

  -- Auto-close any session whose diffview tab handle is no longer valid
  -- (user did :tabclose, :DiffviewClose, etc). Iterates all sessions
  -- because the tabnr from <amatch> is a position, not a handle.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tabnr, _ in pairs(ctx_by_tab) do
        if not vim.api.nvim_tabpage_is_valid(tabnr) then
          M.close(tabnr)
        end
      end
    end,
  })

  -- Cursor-driven Notes panel sync. Operates on the ACTIVE session only —
  -- when user moves around in the diffview tab, the notes panel for THAT
  -- session expands EXCLUSIVELY the thread anchored to the cursor's line.
  -- Without a match, all folds collapse — keeping the panel as a passive
  -- "what's commented at my cursor" indicator.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      local active = M.get_active_ctx()
      if not active then return end
      local session = state_mod.get_active()
      if not session or session.panel.mode ~= "notes" then return end
      if not diffview_int.is_diffview_buf(args.buf) then return end
      local target = diffview_int.current_diff_target()
      if not target then
        bottom_panel.collapse_all()
        return
      end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local discussion_id = find_discussion_for(target.path, line, target.side)
      if discussion_id then
        bottom_panel.scroll_to_discussion(discussion_id)
      else
        bottom_panel.collapse_all()
      end
    end,
  })
end

local function clear_visual_keymaps_if_empty()
  if next(ctx_by_tab) == nil then
    pcall(vim.api.nvim_del_augroup_by_name, VISUAL_AUGROUP)
  end
end

local function clear_lifecycle_autocmds_if_empty()
  if next(ctx_by_tab) == nil then
    pcall(vim.api.nvim_del_augroup_by_name, LIFECYCLE_AUGROUP)
  end
end

---Re-fetch discussions for the ACTIVE session and refresh its panel + signs.
function M.refresh_discussions()
  local ctx = M.get_active_ctx()
  if not ctx then return end
  local session = state_mod.get_for_tab(ctx.tabnr)
  ctx.provider.fetch_mr_discussions(ctx.remote, ctx.mr.iid, function(discussions, err)
    if not discussions then
      notify((err or "failed to refresh discussions"), vim.log.levels.WARN)
      return
    end
    if session then session.discussions = discussions end
    if bottom_panel.is_open() then bottom_panel.refresh() end
    highlights.refresh(discussions)
  end)
end

function M.refresh_mr_details()
  local ctx = M.get_active_ctx()
  if not ctx then return end
  local session = state_mod.get_for_tab(ctx.tabnr)
  ctx.provider.fetch_mr_details(ctx.remote, ctx.mr.iid, function(mr, err)
    if not mr then
      notify((err or "failed to refresh MR"), vim.log.levels.WARN)
      return
    end
    ctx.mr = mr
    if session then session.mr = mr end
    if type(ctx.provider.fetch_approvals) == "function" then
      ctx.provider.fetch_approvals(ctx.remote, mr.iid, function(approval)
        if approval then
          mr.approval = approval
          if session then session.mr = mr end
        end
        if bottom_panel.is_open() then bottom_panel.refresh() end
      end)
    else
      if bottom_panel.is_open() then bottom_panel.refresh() end
    end
  end)
end

function M.refresh_participants()
  local ctx = M.get_active_ctx()
  if not ctx then return end
  local session = state_mod.get_for_tab(ctx.tabnr)
  ctx.provider.fetch_participants(ctx.remote, ctx.mr.iid, function(list)
    if session then session.participants = list or {} end
    if bottom_panel.is_open() then bottom_panel.refresh() end
  end)
end

---Lazy fetcher for picker option lists. Caches per session.
---@param kind "members"|"labels"|"milestones"|"branches"
---@param cb fun(list: table[]|nil, err: string|nil)
function M.get_picker_options(kind, cb)
  local ctx = M.get_active_ctx()
  if not ctx then return cb(nil, "no session") end
  local session = state_mod.get_for_tab(ctx.tabnr)
  local cached = session and session.pickers[kind]
  if cached then return cb(cached) end
  local fn = ({
    members = ctx.provider.fetch_members,
    labels = ctx.provider.fetch_labels,
    milestones = ctx.provider.fetch_milestones,
    branches = ctx.provider.fetch_branches,
  })[kind]
  if not fn then return cb(nil, "unknown picker kind: " .. tostring(kind)) end
  fn(ctx.remote, function(list, err)
    if not list then return cb(nil, err) end
    if session then session.pickers[kind] = list end
    cb(list)
  end)
end

local function wire_panel_hooks()
  bottom_panel.hooks.on_close = function() M.close() end
  bottom_panel.hooks.on_commit_open = function(sha)
    pcall(vim.cmd, "DiffviewOpen " .. sha .. "^!")
  end
  bottom_panel.hooks.on_section_edit = function(section_id)
    require("review.actions.edit_section").run(section_id)
  end
  bottom_panel.hooks.on_comment_jump = function(target)
    require("review.actions.jump_to_comment").run(target)
  end
  bottom_panel.hooks.on_comment_delete = function(target)
    require("review.actions.delete_comment").run(target)
  end
  bottom_panel.hooks.on_comment_edit = function(target)
    require("review.actions.edit_comment").run(target)
  end
  bottom_panel.hooks.on_global_comment = function()
    require("review.actions.add_global_comment").run()
  end
  bottom_panel.hooks.on_comment_reply = function(target)
    require("review.actions.reply_comment").run(target)
  end
  bottom_panel.hooks.on_comment_resolve_toggle = function(target)
    require("review.actions.resolve_thread").run(target)
  end
  bottom_panel.hooks.on_comment_resolve_all = function()
    require("review.actions.resolve_all").run()
  end
end

-- State tag shown in the picker. An opened-but-draft MR reads as "draft"
-- (more actionable signal than "opened"); other states pass through.
local function mr_state_tag(m)
  if m.is_draft and (m.state == "opened" or m.state == nil) then
    return "draft"
  end
  return m.state or "?"
end

local function pick_mr(mrs, cb)
  if #mrs == 0 then return cb(nil) end
  if #mrs == 1 then return cb(mrs[1]) end
  vim.ui.select(mrs, {
    prompt = "Select MR:",
    format_item = function(m)
      return string.format("!%s  [%s]  %s  (@%s)",
        tostring(m.iid), mr_state_tag(m), m.title or "", m.author_name or "?")
    end,
  }, function(choice) cb(choice) end)
end

---Builds a session table for the new diffview tab and populates it from the
---fetched payload. `initial_mode` defaults to "info".
---@param provider table
---@param remote table
---@param branch string
---@param full table
---@param initial_mode string|nil
local function start_session(provider, remote, branch, full, initial_mode)
  initial_mode = initial_mode or "info"

  local ok, err = diffview_int.open(full.mr)
  if not ok then
    notify((err or "failed to open diffview"), vim.log.levels.ERROR)
    return
  end
  local tabnr = vim.api.nvim_get_current_tabpage()

  local session = state_mod.create_for_tab(tabnr)
  session.mr = full.mr
  session.commits = full.commits
  session.discussions = full.discussions
  session.participants = full.participants or {}
  session.branch = branch
  session.provider_name = provider.name

  ctx_by_tab[tabnr] = {
    provider = provider,
    remote = remote,
    branch = branch,
    mr = full.mr,
    tabnr = tabnr,
  }

  readonly.apply()
  setup_visual_keymaps()
  setup_lifecycle_autocmds()
  wire_panel_hooks()
  bottom_panel.open(initial_mode)
  highlights.refresh(full.discussions)

  notify(string.format("!%s opened (%s -> %s)",
    tostring(full.mr.iid), full.mr.source_branch or "?", full.mr.target_branch or "?"))
end

---@param cb fun(provider: table|nil, remote: table|nil, err: string|nil)
local function build_provider_context(cb)
  local cfg = config_mod.get()

  local remote_info, err = git_remote.detect()
  if not remote_info then return cb(nil, nil, err or "no git remote") end

  local provider_name = providers.detect(remote_info.host, cfg)
  local provider = providers.get(provider_name)

  local remote, build_err = provider.build_remote(remote_info, cfg)
  if not remote then return cb(nil, nil, build_err or "failed to build remote") end

  cb(provider, remote, nil)
end

local function resolve_branch(opts)
  local branch = opts.branch
  if branch and branch ~= "" then
    return (branch:gsub("^origin/", ""))
  end
  return current_branch()
end

---Fetches an MR by iid and starts a session. `initial_mode` controls which
---bottom panel mode the session opens in.
local function open_by_iid(provider, remote, iid, initial_mode)
  notify_util.progress(string.format("loading !%s...", tostring(iid)))
  provider.fetch_mr_full(remote, iid, function(full, err)
    if not full then
      notify((err or "failed to load MR"), vim.log.levels.ERROR); return
    end
    if full.mr.state ~= "opened" then
      notify(string.format("!%s is %s - opening read-only diff",
        tostring(iid), full.mr.state), vim.log.levels.WARN)
    end
    start_session(provider, remote, full.mr.source_branch or "?", full, initial_mode)
  end)
end

---Heal stale entries (tabs gone away under us via paths that didn't fire
---TabClosed cleanly).
local function reap_stale_sessions()
  for tabnr, _ in pairs(ctx_by_tab) do
    if not vim.api.nvim_tabpage_is_valid(tabnr) then
      M.close(tabnr)
    end
  end
end

---Resolves a target MR for one-shot actions. Three paths:
---  1. target_opts.iid    -> ephemeral ctx for that iid.
---  2. target_opts.branch -> ephemeral ctx via fetch_open_mrs(branch) -> picker.
---  3. empty target_opts  -> the ACTIVE session's ctx; or, if no active
---                           session, fall back to path 2 with current branch.
---is_ephemeral=false ONLY in path 3 when there IS an active session, signalling
---to the caller that destructive teardown (controller.close) is appropriate.
---@param target_opts { iid?: integer, branch?: string }|nil
---@param cb fun(target_ctx: table|nil, err: string|nil, is_ephemeral: boolean)
---@param state_filter "opened"|"all"|nil  default "opened" (action commands
---  only operate on open MRs; pass "all" for view-only flows like :ReviewWeb).
function M.with_target(target_opts, cb, state_filter)
  target_opts = target_opts or {}
  state_filter = state_filter or "opened"

  if vim.tbl_isempty(target_opts) then
    local active = M.get_active_ctx()
    if active then return cb(active, nil, false) end
  end

  build_provider_context(function(provider, remote, err)
    if not provider or not remote then return cb(nil, err or "setup failed", true) end

    local function finalize(iid)
      provider.fetch_mr_details(remote, iid, function(mr, derr)
        if not mr then return cb(nil, derr or "failed to load MR", true) end
        cb({
          provider = provider,
          remote = remote,
          branch = mr.source_branch or "?",
          mr = mr,
        }, nil, true)
      end)
    end

    if target_opts.iid then
      return finalize(target_opts.iid)
    end

    local branch = (target_opts.branch and target_opts.branch ~= "")
        and (target_opts.branch:gsub("^origin/", ""))
        or current_branch()
    if branch == "" then return cb(nil, "cannot determine branch", true) end

    local fetch = (state_filter == "all")
        and provider.fetch_all_mrs
        or provider.fetch_open_mrs
    local empty_msg = (state_filter == "all")
        and ("no MR for '" .. branch .. "'")
        or ("no open MR for '" .. branch .. "'")
    fetch(remote, branch, function(mrs, ferr)
      if not mrs then return cb(nil, ferr or "failed to list MRs", true) end
      if #mrs == 0 then return cb(nil, empty_msg, true) end
      pick_mr(mrs, function(chosen)
        if not chosen then return cb(nil, "cancelled", true) end
        finalize(chosen.iid)
      end)
    end)
  end)
end

---Either focuses an existing session whose MR matches the resolved target,
---or starts a new session. Used by :Review / :ReviewInfo / :ReviewCommits /
---:ReviewNotes when called with an argument.
---@param opts { iid?: integer, branch?: string }
---@param initial_mode string|nil  "info" | "commits" | "notes" — for new sessions
function M.open_or_focus(opts, initial_mode)
  opts = opts or {}
  initial_mode = initial_mode or "info"
  reap_stale_sessions()

  build_provider_context(function(provider, remote, err)
    if not provider or not remote then
      notify((err or "setup failed"), vim.log.levels.ERROR); return
    end

    local function focus_or_start(iid)
      local existing_tab = M.find_session_by_mr(remote.host,
        remote.path or remote.owner_repo, iid)
      if existing_tab then
        pcall(vim.api.nvim_set_current_tabpage, existing_tab)
        bottom_panel.set_mode(initial_mode)
        notify(string.format("focused !%s (panel: %s)",
          tostring(iid), initial_mode))
        return
      end
      open_by_iid(provider, remote, iid, initial_mode)
    end

    if opts.iid then
      return focus_or_start(opts.iid)
    end

    local branch = resolve_branch(opts)
    if branch == "" then
      notify("cannot determine branch", vim.log.levels.ERROR); return
    end

    notify_util.progress(string.format("looking up MRs for '%s'...", branch))
    -- open_or_focus serves both :Review and the UI commands. Use
    -- fetch_all_mrs so the user can browse closed / merged MRs too.
    -- Write-op commands (Approve / Merge / Rebase / ReviewClose) go through
    -- with_target() which keeps state_filter="opened" by default.
    provider.fetch_all_mrs(remote, branch, function(mrs, list_err)
      if not mrs then
        notify((list_err or "failed to list MRs"), vim.log.levels.ERROR); return
      end
      if #mrs == 0 then
        notify(string.format("no MR for '%s'", branch), vim.log.levels.WARN); return
      end
      pick_mr(mrs, function(chosen)
        if not chosen then return end
        focus_or_start(chosen.iid)
      end)
    end)
  end)
end

---Lists MRs via a provider fetcher that takes no branch (e.g. "review
---requested for me", "mine"), lets the user pick (auto-open on a single
---result), and starts a session — focusing an existing tab if one already
---hosts the chosen MR. Used by :ReviewRequest / :ReviewMine.
---@param list_fetcher fun(provider: table, remote: table, cb: fun(mrs: table[]|nil, err: string|nil))
---@param empty_msg string  shown when the fetcher returns zero MRs
function M.pick_and_open(list_fetcher, empty_msg)
  reap_stale_sessions()
  build_provider_context(function(provider, remote, err)
    if not provider or not remote then
      notify((err or "setup failed"), vim.log.levels.ERROR); return
    end
    list_fetcher(provider, remote, function(mrs, ferr)
      if not mrs then
        notify((ferr or "failed to list MRs"), vim.log.levels.ERROR); return
      end
      if #mrs == 0 then
        notify(empty_msg, vim.log.levels.WARN); return
      end
      pick_mr(mrs, function(chosen)
        if not chosen then return end
        local existing = M.find_session_by_mr(remote.host,
          remote.path or remote.owner_repo, chosen.iid)
        if existing then
          pcall(vim.api.nvim_set_current_tabpage, existing)
          return
        end
        open_by_iid(provider, remote, chosen.iid, "info")
      end)
    end)
  end)
end

---Start a fresh session. With multi-session enabled, "session already open"
---is no longer an error — multiple sessions coexist. If the picked MR
---already has a session, we focus it instead of duplicating (via
---open_or_focus).
function M.open(opts)
  M.open_or_focus(opts, "info")
end

---Helper: fetch full payload after reopen, then start the session.
local function reopen_and_start(provider, remote, iid, branch_hint)
  provider.fetch_mr_full(remote, iid, function(full, err)
    if not full then
      notify((err or "failed to load MR after reopen"), vim.log.levels.ERROR); return
    end
    start_session(provider, remote, full.mr.source_branch or branch_hint or "?", full, "info")
  end)
end

---Reopens a closed MR and starts a session for it.
function M.reopen_mr_session(opts)
  opts = opts or {}
  reap_stale_sessions()

  build_provider_context(function(provider, remote, err)
    if not provider or not remote then
      notify((err or "setup failed"), vim.log.levels.ERROR); return
    end

    if opts.iid then
      provider.fetch_mr_details(remote, opts.iid, function(mr, derr)
        if not mr then
          notify((derr or "failed to load MR"), vim.log.levels.ERROR); return
        end
        if mr.state == "merged" then
          notify(string.format("!%s is merged - cannot reopen", tostring(opts.iid)),
            vim.log.levels.WARN); return
        end
        if mr.state == "opened" then
          notify_util.progress(string.format("!%s is already open - starting session", tostring(opts.iid)))
          return reopen_and_start(provider, remote, opts.iid, mr.source_branch)
        end
        provider.reopen_mr(remote, opts.iid, function(ok, rerr)
          if not ok then
            notify((rerr or "failed to reopen"), vim.log.levels.ERROR); return
          end
          notify(string.format("!%s reopened", tostring(opts.iid)))
          reopen_and_start(provider, remote, opts.iid, mr.source_branch)
        end)
      end)
      return
    end

    local branch = resolve_branch(opts)
    if branch == "" then
      notify("cannot determine branch", vim.log.levels.ERROR); return
    end

    notify_util.progress(string.format("looking up closed MRs for '%s'...", branch))
    provider.fetch_closed_mrs(remote, branch, function(mrs, list_err)
      if not mrs then
        notify((list_err or "failed to list MRs"), vim.log.levels.ERROR); return
      end
      if #mrs == 0 then
        notify(string.format("no closed MR for '%s'", branch), vim.log.levels.WARN); return
      end
      pick_mr(mrs, function(chosen)
        if not chosen then return end
        provider.reopen_mr(remote, chosen.iid, function(ok, reopen_err)
          if not ok then
            notify((reopen_err or "failed to reopen"), vim.log.levels.ERROR); return
          end
          notify(string.format("!%s reopened", tostring(chosen.iid)))
          reopen_and_start(provider, remote, chosen.iid, branch)
        end)
      end)
    end)
  end)
end

---Tear down a session. `tabnr` defaults to the active session's tab.
---@param tabnr integer|nil
function M.close(tabnr)
  tabnr = tabnr or (M.get_active_ctx() and M.get_active_ctx().tabnr)
  if not tabnr then return end
  local ctx = ctx_by_tab[tabnr]
  if not ctx or closing_by_tab[tabnr] then return end
  closing_by_tab[tabnr] = true

  -- Switch to the session's tab so panel/highlight cleanups affect the
  -- right windows. Best effort — the tab may already be gone.
  if vim.api.nvim_tabpage_is_valid(tabnr) then
    pcall(vim.api.nvim_set_current_tabpage, tabnr)
  end

  -- Capture the iid before teardown wipes the ctx — we need it for the
  -- notification later.
  local closed_iid = ctx.mr and ctx.mr.iid or "?"

  pcall(bottom_panel.close)
  pcall(highlights.clear)
  pcall(diffview_int.close)
  state_mod.delete_for_tab(tabnr)

  ctx_by_tab[tabnr] = nil
  closing_by_tab[tabnr] = nil

  -- Tear down shared autocmds + readonly only when no sessions remain.
  if next(ctx_by_tab) == nil then
    pcall(readonly.clear)
    clear_visual_keymaps_if_empty()
    clear_lifecycle_autocmds_if_empty()
  end

  -- Defer the notify so it doesn't get coalesced/suppressed by upstream
  -- notify plugins (noice, snacks) when emitted alongside a tab switch.
  -- Caller-emitted notifications (e.g. "!iid merged") render first; this
  -- one lands cleanly on the next event-loop tick.
  vim.schedule(function()
    notify_util.event("session closed (!" .. tostring(closed_iid) .. ")")
  end)
end

return M
