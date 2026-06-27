local M = {}

M.name = "gitlab"

local client = require("review.http.client")
local auth = require("review.http.auth")
local state_mod = require("review.state")

local function nullable(v)
  if v == vim.NIL then return nil end
  return v
end

function M.auth_host_for(remote_host)
  return remote_host
end

function M.build_remote(remote_info, cfg)
  local auth_host = M.auth_host_for(remote_info.host)
  local token, err = auth.get_token(auth_host, "gitlab", cfg)
  if not token then return nil, err end

  local base_url
  if cfg.host_bases and cfg.host_bases[remote_info.host] then
    base_url = cfg.host_bases[remote_info.host]
  else
    local scheme = (cfg.host_schemes and cfg.host_schemes[remote_info.host])
        or remote_info.scheme
        or "https"
    base_url = string.format("%s://%s/api/v4", scheme, remote_info.host)
  end

  return {
    host = remote_info.host,
    auth_host = auth_host,
    path = remote_info.path,
    base_url = base_url,
    project_id = client.uri_encode(remote_info.path),
    headers = auth.headers_for("gitlab", token),
  }
end

local function mr_url(remote, iid, suffix)
  return string.format(
    "%s/projects/%s/merge_requests/%s%s",
    remote.base_url, remote.project_id, tostring(iid), suffix or ""
  )
end

local function normalize_user(raw)
  if not raw or raw == vim.NIL then return nil end
  return {
    id = nullable(raw.id),
    username = nullable(raw.username) or "?",
    name = nullable(raw.name) or "?",
  }
end

local function normalize_user_list(list)
  list = nullable(list)
  if type(list) ~= "table" then return {} end
  local out = {}
  for _, u in ipairs(list) do
    local nu = normalize_user(u)
    if nu then table.insert(out, nu) end
  end
  return out
end

local function normalize_milestone(raw)
  if not raw or raw == vim.NIL then return nil end
  return {
    id = nullable(raw.id),
    iid = nullable(raw.iid),
    title = nullable(raw.title) or "",
    state = nullable(raw.state) or "?",
  }
end

local function normalize_time_stats(raw)
  raw = nullable(raw) or {}
  return {
    time_estimate = nullable(raw.time_estimate) or 0,
    total_time_spent = nullable(raw.total_time_spent) or 0,
    human_time_estimate = nullable(raw.human_time_estimate),
    human_total_time_spent = nullable(raw.human_total_time_spent),
  }
end

local function normalize_labels(raw)
  raw = nullable(raw)
  if type(raw) ~= "table" then return {} end
  local out = {}
  for _, l in ipairs(raw) do table.insert(out, tostring(l)) end
  return out
end

local function normalize_mr(raw)
  -- GitLab keeps draft state encoded as a "Draft:" prefix in the title plus
  -- a derived `draft` boolean on the response. We strip the prefix from the
  -- displayed title and surface is_draft separately so the panel renders a
  -- dedicated Draft section instead of duplicating the marker in the title.
  local raw_title = nullable(raw.title) or ""
  local is_draft = nullable(raw.draft) == true
      or nullable(raw.work_in_progress) == true
      or raw_title:match("^[Dd]raft:%s") ~= nil
  local clean_title = raw_title:gsub("^[Dd]raft:%s+", "")

  return {
    iid = nullable(raw.iid),
    title = clean_title,
    is_draft = is_draft,
    description = nullable(raw.description) or "",
    base_sha = nullable(raw.diff_refs) and nullable(raw.diff_refs.base_sha) or nullable(raw.sha),
    head_sha = nullable(raw.diff_refs) and nullable(raw.diff_refs.head_sha) or nullable(raw.sha),
    start_sha = nullable(raw.diff_refs) and nullable(raw.diff_refs.start_sha) or nullable(raw.sha),
    source_branch = nullable(raw.source_branch),
    target_branch = nullable(raw.target_branch),
    web_url = nullable(raw.web_url),
    author_name = raw.author and nullable(raw.author.username) or "?",
    author_full = raw.author and nullable(raw.author.name) or "?",
    state = nullable(raw.state) or "?",
    merge_status = nullable(raw.merge_status) or "?",
    detailed_merge_status = nullable(raw.detailed_merge_status),
    has_conflicts = nullable(raw.has_conflicts) == true,
    sha = nullable(raw.sha),
    squash = nullable(raw.squash) == true,
    merge_when_pipeline_succeeds = nullable(raw.merge_when_pipeline_succeeds) == true,
    assignees = normalize_user_list(raw.assignees),
    reviewers = normalize_user_list(raw.reviewers),
    labels = normalize_labels(raw.labels),
    milestone = normalize_milestone(raw.milestone),
    time_stats = normalize_time_stats(raw.time_stats),
    raw = raw,
  }
end

local function normalize_commit(raw)
  return {
    id = nullable(raw.id),
    short_id = nullable(raw.short_id),
    title = nullable(raw.title) or "",
    author_name = nullable(raw.author_name) or "?",
    created_at = nullable(raw.created_at),
  }
end

local function normalize_discussion(raw)
  local notes = {}
  for _, n in ipairs(raw.notes or {}) do
    table.insert(notes, {
      id = nullable(n.id),
      body = nullable(n.body) or "",
      author = n.author and (nullable(n.author.username) or "?") or "?",
      created_at = nullable(n.created_at),
      system = nullable(n.system) == true,
      resolvable = nullable(n.resolvable) == true,
      resolved = nullable(n.resolved) == true,
      position = nullable(n.position),
      raw = n,
    })
  end
  return {
    id = nullable(raw.id),
    individual_note = nullable(raw.individual_note) == true,
    notes = notes,
  }
end

local function fetch_mrs_with_state(remote, branch, state, cb)
  local url = string.format("%s/projects/%s/merge_requests", remote.base_url, remote.project_id)
  client.request({
    url = url,
    method = "get",
    headers = remote.headers,
    query = {
      source_branch = branch,
      state = state,
      per_page = 20,
      order_by = "updated_at",
      sort = "desc",
    },
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to list MRs") end
    local list, derr = client.decode_json(res.body)
    if not list then return cb(nil, derr) end
    local out = {}
    for _, m in ipairs(list) do table.insert(out, normalize_mr(m)) end
    cb(out)
  end)
end

function M.fetch_open_mrs(remote, branch, cb)
  fetch_mrs_with_state(remote, branch, "opened", cb)
end

function M.fetch_closed_mrs(remote, branch, cb)
  fetch_mrs_with_state(remote, branch, "closed", cb)
end

---Lists MRs for `branch` regardless of state (opened / closed / merged /
---locked). Used by :Review and :ReviewWeb to let the user browse / open
---historical MRs that the write-op commands wouldn't touch.
function M.fetch_all_mrs(remote, branch, cb)
  fetch_mrs_with_state(remote, branch, "all", cb)
end

-- Current-user cache keyed by API host. Module-level (not session-scoped)
-- because :ReviewRequest / :ReviewMine run BEFORE any review session exists,
-- so there's no active session/provider_cache to hang it on. The logged-in
-- user doesn't change within an nvim process, so a process-lifetime cache
-- per host is correct.
local current_user_by_host = {}

---Lazy-load GET /user (id + username) for "mine" / "review-requested" filters.
local function get_current_user(remote, cb)
  local key = remote.base_url or remote.host or "?"
  if current_user_by_host[key] then return cb(current_user_by_host[key]) end
  client.request({
    url = remote.base_url .. "/user",
    method = "get",
    headers = remote.headers,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch /user") end
    local u = client.decode_json(res.body)
    if not u then return cb(nil, "decode failed") end
    local user = { id = nullable(u.id), username = nullable(u.username) }
    current_user_by_host[key] = user
    cb(user)
  end)
end

---Lists open MRs where the current user is a requested reviewer.
function M.fetch_review_requested(remote, cb)
  get_current_user(remote, function(user, uerr)
    if not user then return cb(nil, uerr) end
    local url = string.format("%s/projects/%s/merge_requests", remote.base_url, remote.project_id)
    client.request({
      url = url,
      method = "get",
      headers = remote.headers,
      query = {
        reviewer_username = user.username,
        state = "opened",
        per_page = 50,
        order_by = "updated_at",
        sort = "desc",
      },
    }, function(res)
      if not res.ok then return cb(nil, res.err or "failed to list MRs") end
      local list = client.decode_json(res.body)
      if not list then return cb(nil, "decode failed") end
      local out = {}
      for _, m in ipairs(list) do table.insert(out, normalize_mr(m)) end
      cb(out)
    end)
  end)
end

---Lists open MRs that are "mine": assignee OR author. GitLab has no OR in a
---single query, so we run both and dedup by iid.
function M.fetch_review_mine(remote, cb)
  get_current_user(remote, function(user, uerr)
    if not user then return cb(nil, uerr) end
    local url = string.format("%s/projects/%s/merge_requests", remote.base_url, remote.project_id)
    local common = { state = "opened", per_page = 50, order_by = "updated_at", sort = "desc" }
    local pending, seen, out = 2, {}, {}
    local function done(list)
      for _, m in ipairs(list or {}) do
        local nm = normalize_mr(m)
        if nm.iid and not seen[nm.iid] then
          seen[nm.iid] = true
          table.insert(out, nm)
        end
      end
      pending = pending - 1
      if pending == 0 then cb(out) end
    end
    for _, key in ipairs({ "assignee_username", "author_username" }) do
      local q = vim.tbl_extend("force", common, { [key] = user.username })
      client.request({ url = url, method = "get", headers = remote.headers, query = q },
        function(res)
          if not res.ok then return done({}) end
          done(client.decode_json(res.body) or {})
        end)
    end
  end)
end

function M.fetch_mr_details(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid),
    method = "get",
    headers = remote.headers,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch MR") end
    local raw, derr = client.decode_json(res.body)
    if not raw then return cb(nil, derr) end
    cb(normalize_mr(raw))
  end)
end

function M.fetch_mr_commits(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid, "/commits"),
    method = "get",
    headers = remote.headers,
    query = { per_page = 100 },
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch commits") end
    local list, derr = client.decode_json(res.body)
    if not list then return cb(nil, derr) end
    local out = {}
    for _, c in ipairs(list) do table.insert(out, normalize_commit(c)) end
    cb(out)
  end)
end

function M.fetch_mr_discussions(remote, iid, cb)
  local url = mr_url(remote, iid, "/discussions")
  local page, max_pages, all = 1, 10, {}
  local function fetch_page()
    client.request({
      url = url,
      method = "get",
      headers = remote.headers,
      query = { per_page = 100, page = page },
    }, function(res)
      if not res.ok then return cb(nil, res.err or "failed to fetch discussions") end
      local list, derr = client.decode_json(res.body)
      if not list then return cb(nil, derr) end
      for _, d in ipairs(list) do table.insert(all, d) end
      local next_page = client.get_header(res.headers, "x-next-page")
      if next_page and next_page ~= "" and page < max_pages then
        page = page + 1
        fetch_page()
      else
        local out = {}
        for _, d in ipairs(all) do table.insert(out, normalize_discussion(d)) end
        cb(out)
      end
    end)
  end
  fetch_page()
end

---Fetches approval state for an MR. Returns `{ given, required, approved_by }`
---or nil on failure. Non-fatal in fetch_mr_full.
---@param remote table
---@param iid string|number
---@param cb fun(approval: table|nil, err: string|nil)
function M.fetch_approvals(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid, "/approvals"),
    method = "get",
    headers = remote.headers,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch approvals") end
    local raw = client.decode_json(res.body)
    if not raw then return cb(nil, "decode failed") end
    local approved_by = {}
    for _, a in ipairs(raw.approved_by or {}) do
      if a.user and a.user.username then
        table.insert(approved_by, a.user.username)
      end
    end
    cb({
      given = #approved_by,
      required = nullable(raw.approvals_required),
      approved_by = approved_by,
    })
  end)
end

function M.fetch_mr_full(remote, iid, cb)
  M.fetch_mr_details(remote, iid, function(mr, err)
    if not mr then return cb(nil, err) end
    M.fetch_mr_commits(remote, iid, function(commits, cerr)
      if not commits then return cb(nil, cerr) end
      M.fetch_mr_discussions(remote, iid, function(discussions, derr)
        if not discussions then return cb(nil, derr) end
        M.fetch_participants(remote, iid, function(participants, perr)
          -- Approval state attached to mr.approval; non-fatal — chain
          -- sequentially so cb only fires once approvals have arrived (or
          -- failed). Participants is also non-critical and falls back to {}.
          M.fetch_approvals(remote, iid, function(approval)
            if approval then mr.approval = approval end
            cb({
              mr = mr,
              commits = commits,
              discussions = discussions,
              participants = participants or {},
              participants_err = perr,
            })
          end)
        end)
      end)
    end)
  end)
end

function M.approve(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid, "/approve"),
    method = "post",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to approve")
  end)
end

---Closes an MR by setting state_event=close. Goes through update_mr so we
---get the normalized MR back and panel re-renders see the new state.
---@param remote table
---@param iid string|number
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.close_mr(remote, iid, cb)
  M.update_mr(remote, iid, { state_event = "close" }, cb)
end

---Reopens a closed MR by setting state_event=reopen.
---@param remote table
---@param iid string|number
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.reopen_mr(remote, iid, cb)
  M.update_mr(remote, iid, { state_event = "reopen" }, cb)
end

---Merge an MR (or schedule auto-merge).
---@param remote table
---@param iid string|number
---@param opts {
---  squash: boolean|nil,
---  should_remove_source_branch: boolean|nil,
---  merge_when_pipeline_succeeds: boolean|nil,
---  merge_commit_message: string|nil,
---  squash_commit_message: string|nil,
---  sha: string|nil,
---}
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.merge_mr(remote, iid, opts, cb)
  local payload = {}
  if opts.squash ~= nil then payload.squash = opts.squash end
  if opts.should_remove_source_branch ~= nil then
    payload.should_remove_source_branch = opts.should_remove_source_branch
  end
  if opts.merge_when_pipeline_succeeds then
    payload.merge_when_pipeline_succeeds = true
  end
  if opts.merge_commit_message and opts.merge_commit_message ~= "" then
    payload.merge_commit_message = opts.merge_commit_message
  end
  if opts.squash_commit_message and opts.squash_commit_message ~= "" then
    payload.squash_commit_message = opts.squash_commit_message
  end
  if opts.sha and opts.sha ~= "" then payload.sha = opts.sha end

  client.request({
    url = mr_url(remote, iid, "/merge"),
    method = "put",
    headers = remote.headers,
    body = vim.json.encode(payload),
  }, function(res)
    if not res.ok then
      -- GitLab returns the error reason in the body for 405/406. Surface it.
      local detail
      if res.body and res.body ~= "" then
        local parsed = client.decode_json(res.body)
        if parsed and (parsed.message or parsed.error) then
          detail = parsed.message or parsed.error
        end
      end
      return cb(false, detail or res.err or "merge failed")
    end
    local raw = client.decode_json(res.body)
    if not raw then return cb(true) end
    cb(true, nil, normalize_mr(raw))
  end)
end

function M.unapprove(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid, "/unapprove"),
    method = "post",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to unapprove")
  end)
end

function M.update_description(remote, iid, description, cb)
  M.update_mr(remote, iid, { description = description }, cb)
end

---Generic MR update. Accepts any of:
---  title (string), description (string),
---  assignee_ids (int[]), reviewer_ids (int[]),
---  labels (string|string[]) — joined with comma,
---  milestone_id (int) — 0 to remove
---@param remote table
---@param iid string|number
---@param fields table
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.update_mr(remote, iid, fields, cb)
  local payload = {}
  for k, v in pairs(fields) do
    if k == "labels" and type(v) == "table" then
      payload[k] = table.concat(v, ",")
    else
      payload[k] = v
    end
  end
  -- Preserve draft state across title edits: GitLab encodes draft as a
  -- "Draft: " prefix in the title, but our normalized title strips it. If
  -- the active MR is a draft and the caller is updating the title, re-add
  -- the prefix so the API keeps the draft flag set.
  if payload.title and state_mod.state.mr and state_mod.state.mr.is_draft then
    if not payload.title:match("^[Dd]raft:%s") then
      payload.title = "Draft: " .. payload.title
    end
  end
  client.request({
    url = mr_url(remote, iid),
    method = "put",
    headers = remote.headers,
    body = vim.json.encode(payload),
  }, function(res)
    if not res.ok then return cb(false, res.err or "failed to update MR") end
    local raw = client.decode_json(res.body)
    if not raw then return cb(true) end
    cb(true, nil, normalize_mr(raw))
  end)
end

---Toggles the MR's draft state. GitLab has no dedicated endpoint — the API
---derives `draft` from a "Draft: " prefix in the title. We strip / prepend
---the prefix on the cached clean title and PUT the new value.
---@param remote table
---@param iid string|number
---@param is_draft boolean
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.set_draft(remote, iid, is_draft, cb)
  local current_title = (state_mod.state.mr and state_mod.state.mr.title) or ""
  -- state.mr.title was already cleaned by normalize_mr; safe to prepend.
  local new_title = is_draft
      and ("Draft: " .. (current_title:gsub("^[Dd]raft:%s+", "")))
      or  current_title:gsub("^[Dd]raft:%s+", "")
  client.request({
    url = mr_url(remote, iid),
    method = "put",
    headers = remote.headers,
    body = vim.json.encode({ title = new_title }),
  }, function(res)
    if not res.ok then return cb(false, res.err or "failed to set draft") end
    local raw = client.decode_json(res.body)
    if not raw then return cb(true) end
    cb(true, nil, normalize_mr(raw))
  end)
end

---Sets the time estimate (e.g. "3h30m"). Pass empty string / nil to reset.
---@param remote table
---@param iid string|number
---@param duration string|nil  e.g. "3h", "1d 2h", "" or nil to reset
---@param cb fun(ok: boolean, err: string|nil)
function M.set_time_estimate(remote, iid, duration, cb)
  local suffix = (duration == nil or duration == "")
      and "/reset_time_estimate"
      or "/time_estimate"
  local query = (duration ~= nil and duration ~= "") and { duration = duration } or nil
  client.request({
    url = mr_url(remote, iid, suffix),
    method = "post",
    headers = remote.headers,
    query = query,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to set time estimate")
  end)
end

function M.fetch_participants(remote, iid, cb)
  client.request({
    url = mr_url(remote, iid, "/participants"),
    method = "get",
    headers = remote.headers,
    query = { per_page = 100 },
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch participants") end
    local list, derr = client.decode_json(res.body)
    if not list then return cb(nil, derr) end
    cb(normalize_user_list(list))
  end)
end

local function fetch_paginated(remote, suffix, query, cb)
  local url = string.format("%s/projects/%s%s", remote.base_url, remote.project_id, suffix)
  local page, max_pages, all = 1, 5, {}
  local function fetch_page()
    local q = vim.tbl_extend("force", query or {}, { per_page = 100, page = page })
    client.request({
      url = url,
      method = "get",
      headers = remote.headers,
      query = q,
    }, function(res)
      if not res.ok then return cb(nil, res.err or "request failed") end
      local list, derr = client.decode_json(res.body)
      if not list then return cb(nil, derr) end
      for _, item in ipairs(list) do table.insert(all, item) end
      local next_page = client.get_header(res.headers, "x-next-page")
      if next_page and next_page ~= "" and page < max_pages then
        page = page + 1
        fetch_page()
      else
        cb(all)
      end
    end)
  end
  fetch_page()
end

---Project members (including inherited). Used as the option list for
---assignee/reviewer pickers.
function M.fetch_members(remote, cb)
  fetch_paginated(remote, "/members/all", nil, function(list, err)
    if not list then return cb(nil, err) end
    cb(normalize_user_list(list))
  end)
end

function M.fetch_labels(remote, cb)
  fetch_paginated(remote, "/labels", nil, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, l in ipairs(list) do
      table.insert(out, {
        id = nullable(l.id),
        name = nullable(l.name) or "?",
        color = nullable(l.color),
      })
    end
    cb(out)
  end)
end

function M.fetch_milestones(remote, cb)
  fetch_paginated(remote, "/milestones", { state = "active" }, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, m in ipairs(list) do
      local nm = normalize_milestone(m)
      if nm then table.insert(out, nm) end
    end
    cb(out)
  end)
end

---Lists repository branches (just names). Used as the option list for the
---Target branch picker in :ReviewInfo so the user can re-point an MR.
function M.fetch_branches(remote, cb)
  fetch_paginated(remote, "/repository/branches", nil, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, b in ipairs(list) do
      local name = nullable(b.name)
      if name then table.insert(out, { name = name, default = b.default == true }) end
    end
    cb(out)
  end)
end

---@param remote table
---@param iid string|number
---@param body string  raw markdown body for the new note
---@param position table|nil  GitLab position dict (nil = global thread)
---@param cb fun(ok: boolean, err: string|nil, discussion: table|nil)
---Extracts a human-readable detail from a GitLab error response body.
---GitLab returns `{ "message": "..." }` for many 4xx, sometimes
---`{ "error": "..." }`, and for validation errors the message itself can be
---a nested table (`{ "position": ["is invalid"] }`). This flattens to a
---usable string for the notify path.
local function gl_error_detail(res)
  if not res.body or res.body == "" then return nil end
  local parsed = client.decode_json(res.body)
  if not parsed then return nil end
  local msg = parsed.message or parsed.error
  if type(msg) == "string" then return msg end
  if type(msg) == "table" then
    -- Either { field = { "is invalid", ... } } or array of strings.
    if msg[1] then return tostring(msg[1]) end
    local key, val = next(msg)
    if key and val then
      local detail = type(val) == "table" and (val[1] or vim.inspect(val)) or tostring(val)
      return tostring(key) .. ": " .. detail
    end
  end
  return nil
end

function M.post_discussion(remote, iid, body, position, cb)
  local payload = { body = body }
  if position then payload.position = position end
  client.request({
    url = mr_url(remote, iid, "/discussions"),
    method = "post",
    headers = remote.headers,
    body = vim.json.encode(payload),
  }, function(res)
    if not res.ok then
      return cb(false, gl_error_detail(res) or res.err or "failed to post discussion")
    end
    local raw, derr = client.decode_json(res.body)
    if not raw then return cb(false, derr) end
    cb(true, nil, normalize_discussion(raw))
  end)
end

function M.update_note(remote, iid, discussion_id, note_id, body, cb)
  client.request({
    url = mr_url(remote, iid, string.format("/discussions/%s/notes/%s", discussion_id, tostring(note_id))),
    method = "put",
    headers = remote.headers,
    body = vim.json.encode({ body = body }),
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to update note")
  end)
end

---Resolve or unresolve an entire discussion thread.
---@param remote table
---@param iid string|number
---@param discussion_id any
---@param resolved boolean  true=resolve, false=unresolve
---@param cb fun(ok: boolean, err: string|nil)
function M.resolve_discussion(remote, iid, discussion_id, resolved, cb)
  client.request({
    url = mr_url(remote, iid, "/discussions/" .. tostring(discussion_id)),
    method = "put",
    headers = remote.headers,
    query = { resolved = resolved and "true" or "false" },
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to set resolved state")
  end)
end

---Adds a reply note to an existing discussion thread.
---@param remote table
---@param iid string|number
---@param discussion_id any
---@param body string
---@param cb fun(ok: boolean, err: string|nil)
function M.add_reply(remote, iid, discussion_id, body, cb)
  client.request({
    url = mr_url(remote, iid, "/discussions/" .. tostring(discussion_id) .. "/notes"),
    method = "post",
    headers = remote.headers,
    body = vim.json.encode({ body = body }),
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to add reply")
  end)
end

function M.delete_note(remote, iid, discussion_id, note_id, cb)
  client.request({
    url = mr_url(remote, iid, string.format("/discussions/%s/notes/%s", discussion_id, tostring(note_id))),
    method = "delete",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to delete note")
  end)
end

---Builds the position dict required by GitLab for inline comments.
---
---GitLab anchors a note on a single line and (for suggestions) extends N lines
---DOWN from it via the fence, so when `start_line` is present we anchor on the
---START of the range (using its old_line for the line_code). For a context
---(unchanged) line GitLab needs BOTH old_line and new_line to form a valid
---line_code, so callers pass old_line for those.
---@param mr table  normalized MR (must include base_sha/head_sha/start_sha)
---@param opts { new_path: string, old_path: string|nil, new_line: integer|nil, old_line: integer|nil, side: string|nil, start_line: integer|nil, start_old_line: integer|nil }
---@return table
function M.build_position(mr, opts)
  local new_line, old_line
  if opts.start_line then
    new_line = opts.start_line
    old_line = opts.start_old_line
  else
    new_line = opts.new_line
    old_line = opts.old_line
  end
  return {
    base_sha = mr.base_sha,
    head_sha = mr.head_sha,
    start_sha = mr.start_sha,
    position_type = "text",
    new_path = opts.new_path,
    old_path = opts.old_path or opts.new_path,
    new_line = new_line,
    old_line = old_line,
  }
end

---Wraps user-supplied lines into a GitLab suggestion fenced block.
---@param lines string[]  the (edited) replacement lines
---@param extra_lines integer  N in suggestion:-0+N (end_line - start_line)
---@return string
function M.format_suggestion(lines, extra_lines)
  local fence_open = string.format("```suggestion:-0+%d", extra_lines)
  local body_lines = { fence_open }
  for _, l in ipairs(lines) do table.insert(body_lines, l) end
  table.insert(body_lines, "```")
  return table.concat(body_lines, "\n")
end

return M
