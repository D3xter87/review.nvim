-- GitHub PR provider.
--
-- Parity goals with the GitLab provider, with three notable adaptations:
--   * Comments come from THREE REST endpoints (issue / pull review / reviews
--     with body), unified into the same { discussions = [...] } shape that the
--     UI consumes. Each discussion carries `kind` so update/delete/reply can
--     dispatch to the right endpoint.
--   * Resolve / unresolve threads + auto-merge + dismiss-review use GraphQL
--     (via _graphql helper). The thread-id-map is cached per session and
--     populated alongside fetch_mr_discussions.
--   * Time tracking has no GitHub equivalent — normalize_pr returns
--     time_stats=nil so the panel hides that section.

local M = {}

M.name = "github"

local client = require("review.http.client")
local auth = require("review.http.auth")
local state_mod = require("review.state")
local pending_util = require("review.util.pending")

local function nullable(v)
  if v == vim.NIL then return nil end
  return v
end

---nil for nil and "", the string otherwise.
local function nonempty(s)
  if s == nil or s == "" then return nil end
  return s
end

local notify_util = require("review.util.notify")
local function notify(msg, level) notify_util.legacy(msg, level) end

---GitHub returns descriptive error JSON on 4xx (e.g.
---{"message":"Validation Failed","errors":[{"message":"Can not approve your own pull request"}]}).
---This pulls the most useful string out of the response body.
---@param res table  client.request result
---@return string
local function gh_error(res)
  if res.body and res.body ~= "" then
    local parsed = client.decode_json(res.body)
    if parsed then
      if parsed.errors and parsed.errors[1] then
        local e = parsed.errors[1]
        if type(e) == "table" and e.message then
          return parsed.message and (parsed.message .. ": " .. e.message) or e.message
        end
        if type(e) == "string" then return e end
      end
      if parsed.message then return parsed.message end
    end
  end
  return res.err or "request failed"
end

---GitHub allows one pending review per user and PR, and while it exists a
---standalone review comment or a second review is refused. The raw message
---("user_id can only have one pending review per pull request") says nothing
---about the way out, so spell it.
---@param msg string|nil
---@return string|nil
local function pending_hint(msg)
  if type(msg) == "string" and msg:lower():find("pending review", 1, true) then
    return msg .. " (you have a review in progress: submit it, with verdict Approve to approve, or discard it)"
  end
  return msg
end

-- --------------------------------------------------------------- url helpers

local function repo_url(remote, suffix)
  return string.format("%s/repos/%s%s", remote.base_url, remote.owner_repo, suffix or "")
end

local function pr_url(remote, n, suffix)
  return string.format("%s/repos/%s/pulls/%s%s",
    remote.base_url, remote.owner_repo, tostring(n), suffix or "")
end

local function pr_no_n_url(remote, suffix)
  return string.format("%s/repos/%s/pulls%s",
    remote.base_url, remote.owner_repo, suffix or "")
end

local function issue_url(remote, n, suffix)
  return string.format("%s/repos/%s/issues/%s%s",
    remote.base_url, remote.owner_repo, tostring(n), suffix or "")
end


-- ------------------------------------------------------------------- auth

function M.auth_host_for(remote_host)
  if remote_host == "github.com" then return "api.github.com" end
  return remote_host
end

function M.build_remote(remote_info, cfg)
  local auth_host = M.auth_host_for(remote_info.host)
  local token, err = auth.get_token(auth_host, "github", cfg)
  if not token then return nil, err end

  local base_url, graphql_url
  if cfg.host_bases and cfg.host_bases[remote_info.host] then
    base_url = cfg.host_bases[remote_info.host]
    -- Best-effort GraphQL URL: caller can override via cfg if non-standard.
    graphql_url = base_url:gsub("/api/v3$", "/api/graphql")
    if graphql_url == base_url then graphql_url = base_url .. "/graphql" end
  elseif remote_info.host == "github.com" then
    base_url = "https://api.github.com"
    graphql_url = "https://api.github.com/graphql"
  else
    local scheme = (cfg.host_schemes and cfg.host_schemes[remote_info.host])
        or remote_info.scheme or "https"
    base_url = string.format("%s://%s/api/v3", scheme, remote_info.host)
    graphql_url = string.format("%s://%s/api/graphql", scheme, remote_info.host)
  end

  -- path comes parsed as "owner/repo"; first segment is the owner.
  local owner = remote_info.path:match("^([^/]+)/")

  return {
    host = remote_info.host,
    auth_host = auth_host,
    path = remote_info.path,
    base_url = base_url,
    graphql_url = graphql_url,
    owner = owner,
    owner_repo = remote_info.path,
    headers = auth.headers_for("github", token),
  }
end

-- ----------------------------------------------------------- graphql helper

function M._graphql(remote, query, variables, cb)
  client.request({
    url = remote.graphql_url,
    method = "post",
    headers = remote.headers,
    body = vim.json.encode({ query = query, variables = variables or vim.empty_dict() }),
  }, function(res)
    if not res.ok then return cb(nil, res.err or "graphql request failed") end
    local data = client.decode_json(res.body)
    if not data then return cb(nil, "graphql: malformed response") end
    if data.errors and #data.errors > 0 then
      local first = data.errors[1]
      return cb(nil, "graphql: " .. (first.message or "unknown error"))
    end
    cb(data.data)
  end)
end

-- ----------------------------------------------------- cached helpers
--
-- These caches are module-level (keyed by host / host+PR) rather than
-- session-scoped. The out-of-band action commands (:ReviewRevoke !iid,
-- :ReviewMerge !iid) run BEFORE any review session exists, so there's no
-- active session/provider_cache to hang them on. Identity and a PR's node
-- ID are stable for the nvim process lifetime, so this is correct.
local current_user_by_host = {}
local pr_node_id_by_key = {}

---Lazy-load GET /user (login + id) for unapprove dismiss.
local function get_current_user(remote, cb)
  local key = remote.base_url or remote.host or "?"
  if current_user_by_host[key] then return cb(current_user_by_host[key]) end
  client.request({
    url = remote.base_url .. "/user",
    method = "get",
    headers = remote.headers,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch /user") end
    local user = client.decode_json(res.body)
    if not user then return cb(nil, "decode failed") end
    local u = { login = user.login, id = user.id }
    current_user_by_host[key] = u
    cb(u)
  end)
end

---Lazy-load PR's GraphQL node ID — needed for enablePullRequestAutoMerge.
local function get_pr_node_id(remote, n, cb)
  local key = (remote.base_url or "?") .. "#" .. (remote.owner_repo or "?") .. "#" .. tostring(n)
  if pr_node_id_by_key[key] then return cb(pr_node_id_by_key[key]) end
  M._graphql(remote, [[
    query($owner: String!, $repo: String!, $n: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $n) { id }
      }
    }
  ]], { owner = remote.owner, repo = remote.owner_repo:match("/(.+)$"), n = n },
  function(data, err)
    if not data then return cb(nil, err) end
    local id = data.repository and data.repository.pullRequest and data.repository.pullRequest.id
    if not id then return cb(nil, "graphql: no PR id") end
    pr_node_id_by_key[key] = id
    cb(id)
  end)
end

-- ---------------------------------------------------------- normalize

local function normalize_user(raw)
  if not raw or raw == vim.NIL then return nil end
  return {
    -- For GitHub the canonical identifier in our payloads is the login string
    -- (used directly in PATCH issues / requested_reviewers endpoints).
    id = nullable(raw.login) or "?",
    username = nullable(raw.login) or "?",
    name = nullable(raw.name) or nullable(raw.login) or "?",
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

local function normalize_label_names(list)
  list = nullable(list)
  if type(list) ~= "table" then return {} end
  local out = {}
  for _, l in ipairs(list) do
    if type(l) == "table" then
      table.insert(out, nullable(l.name) or "?")
    else
      table.insert(out, tostring(l))
    end
  end
  return out
end

local function normalize_milestone(raw)
  if not raw or raw == vim.NIL then return nil end
  return {
    -- PATCH /issues uses the milestone's `number`, not its global id.
    id = nullable(raw.number),
    iid = nullable(raw.number),
    title = nullable(raw.title) or "",
    state = nullable(raw.state) or "?",
  }
end

-- GitHub reports a pending auto-merge as an `auto_merge` object (null when
-- not armed) carrying the user who enabled it and the merge method that will
-- be used once the required checks pass.
local function normalize_auto_merge(raw)
  local am = nullable(raw.auto_merge)
  if type(am) ~= "table" then return { enabled = false } end
  local method = nullable(am.merge_method)
  local enabled_by = nullable(am.enabled_by)
  return {
    enabled = true,
    strategy = method and ("when checks pass (" .. method .. ")") or "when checks pass",
    set_by = enabled_by and nullable(enabled_by.login) or nil,
  }
end

---Maps a GitHub PR object to our generic MR shape. time_stats=nil tells the
---panel to skip the Time tracking section (no GitHub equivalent).
local function normalize_pr(raw)
  local head = raw.head or {}
  local base = raw.base or {}
  local auto_merge = normalize_auto_merge(raw)
  local mergeable = nullable(raw.mergeable)
  local has_conflicts = mergeable == false
  local merge_status
  if mergeable == true then merge_status = "can_be_merged"
  elseif mergeable == false then merge_status = "cannot_be_merged"
  else merge_status = "checking" end

  return {
    iid = nullable(raw.number),
    title = nullable(raw.title) or "",
    is_draft = nullable(raw.draft) == true,
    description = nullable(raw.body) or "",
    base_sha = nullable(base.sha),
    head_sha = nullable(head.sha),
    start_sha = nullable(base.sha),
    source_branch = nullable(head.ref),
    target_branch = nullable(base.ref),
    web_url = nullable(raw.html_url),
    author_name = raw.user and (nullable(raw.user.login) or "?") or "?",
    author_full = raw.user and (nullable(raw.user.login) or "?") or "?",
    -- PR state in GitHub is "open" / "closed"; map to GitLab's vocabulary so
    -- shared UI (e.g. ":merged" check, status display) reads naturally.
    state = (raw.state == "closed" and (raw.merged_at and raw.merged_at ~= vim.NIL and "merged" or "closed"))
        or (raw.state == "open" and "opened")
        or "?",
    merge_status = merge_status,
    detailed_merge_status = nil,
    has_conflicts = has_conflicts,
    sha = nullable(head.sha),
    squash = false,
    merge_when_pipeline_succeeds = auto_merge.enabled,
    auto_merge = auto_merge,
    assignees = normalize_user_list(raw.assignees),
    reviewers = normalize_user_list(raw.requested_reviewers),
    labels = normalize_label_names(raw.labels),
    milestone = normalize_milestone(raw.milestone),
    time_stats = nil,  -- GitHub has no time tracking → panel hides section
    raw = raw,
  }
end

local function normalize_commit(raw)
  return {
    id = nullable(raw.sha),
    short_id = nullable(raw.sha) and raw.sha:sub(1, 7) or nil,
    title = (raw.commit and nullable(raw.commit.message) or ""):gsub("\n.*", ""),
    author_name = (raw.commit and raw.commit.author and nullable(raw.commit.author.name)) or "?",
    created_at = raw.commit and raw.commit.author and nullable(raw.commit.author.date) or nil,
  }
end

---Issue comment → discussion with single note (kind="issue").
local function normalize_issue_comment(raw)
  return {
    id = "issue:" .. tostring(nullable(raw.id) or ""),
    individual_note = true,
    kind = "issue",
    notes = { {
      id = nullable(raw.id),
      body = nullable(raw.body) or "",
      author = raw.user and (nullable(raw.user.login) or "?") or "?",
      created_at = nullable(raw.created_at),
      system = false,
      resolvable = false,
      resolved = false,
      position = nil,
      kind = "issue",
      raw = raw,
    } },
  }
end

---Review with body → discussion with single note (kind="review").
local function normalize_review(raw)
  local state = nullable(raw.state) or ""
  local prefix = state ~= "" and ("[" .. state:lower() .. "] ") or ""
  return {
    id = "review:" .. tostring(nullable(raw.id) or ""),
    individual_note = true,
    kind = "review",
    notes = { {
      id = nullable(raw.id),
      body = prefix .. (nullable(raw.body) or ""),
      author = raw.user and (nullable(raw.user.login) or "?") or "?",
      created_at = nullable(raw.submitted_at) or nullable(raw.created_at),
      system = false,
      resolvable = false,
      resolved = false,
      position = nil,
      kind = "review",
      raw = raw,
    } },
  }
end

---Convert a GitHub review-comment line/side into our generic position dict.
---
---`start_*_line` carries the range of a MULTI-LINE comment. GitHub anchors on
---the END line and encodes the span separately (unlike GitLab, which puts it in
---the ```suggestion fence), so without it a multi-line suggestion can't be
---rendered as a diff — see review.util.suggestion. Only the *_line fields feed
---gutter placement; these extras are ignored there.
local function pr_comment_position(c)
  local line = nullable(c.line) or nullable(c.original_line)
  if not line then return nil end
  local start = nullable(c.start_line) or nullable(c.original_start_line)
  local side = nullable(c.side) or "RIGHT"
  local path = nullable(c.path)
  if side == "RIGHT" then
    return { new_path = path, old_path = path, new_line = line, old_line = nil,
      start_new_line = start }
  else
    return { new_path = path, old_path = path, new_line = nil, old_line = line,
      start_old_line = start }
  end
end

local function normalize_inline_note(raw, resolved)
  return {
    id = nullable(raw.id),
    body = nullable(raw.body) or "",
    author = raw.user and (nullable(raw.user.login) or "?") or "?",
    created_at = nullable(raw.created_at),
    system = false,
    resolvable = true,           -- inline GitHub threads ARE resolvable (GraphQL)
    resolved = resolved == true,
    position = pr_comment_position(raw),
    kind = "inline",
    raw = raw,
  }
end

-- ------------------------------------------------------ paginated fetcher

local function fetch_paginated(url, query, headers, cb)
  local page, max_pages, all = 1, 10, {}
  local function fetch_page()
    local q = vim.tbl_extend("force", query or {}, { per_page = 100, page = page })
    client.request({ url = url, method = "get", headers = headers, query = q }, function(res)
      if not res.ok then return cb(nil, res.err or "request failed") end
      local list = client.decode_json(res.body)
      if not list then return cb(nil, "decode failed") end
      for _, item in ipairs(list) do table.insert(all, item) end
      -- GitHub uses Link header for pagination; for simplicity bail out when
      -- the page returned fewer than per_page items (GitHub convention).
      if #list < 100 or page >= max_pages then return cb(all) end
      page = page + 1
      fetch_page()
    end)
  end
  fetch_page()
end

-- ------------------------------------------------------ fetch flows

local function fetch_pulls(remote, branch, state, cb)
  local q = { state = state, per_page = 20, sort = "updated", direction = "desc" }
  if branch and branch ~= "" then
    q.head = remote.owner .. ":" .. branch
  end
  client.request({
    url = pr_no_n_url(remote, ""),
    method = "get",
    headers = remote.headers,
    query = q,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to list PRs") end
    local list = client.decode_json(res.body)
    if not list then return cb(nil, "decode failed") end
    local out = {}
    for _, p in ipairs(list) do table.insert(out, normalize_pr(p)) end
    cb(out)
  end)
end

function M.fetch_open_mrs(remote, branch, cb)
  fetch_pulls(remote, branch, "open", cb)
end

function M.fetch_closed_mrs(remote, branch, cb)
  fetch_pulls(remote, branch, "closed", cb)
end

---Lists PRs for `branch` regardless of state. Used by :Review and :ReviewWeb.
function M.fetch_all_mrs(remote, branch, cb)
  fetch_pulls(remote, branch, "all", cb)
end

function M.fetch_mr_details(remote, n, cb)
  client.request({
    url = pr_url(remote, n),
    method = "get",
    headers = remote.headers,
  }, function(res)
    if not res.ok then return cb(nil, res.err or "failed to fetch PR") end
    local raw = client.decode_json(res.body)
    if not raw then return cb(nil, "decode failed") end
    cb(normalize_pr(raw))
  end)
end

-- Check run (status + conclusion) → the review.ci vocabulary.
local function check_run_status(run)
  local status = nullable(run.status)
  if status ~= "completed" then
    return status == "in_progress" and "running" or "pending"
  end
  local c = nullable(run.conclusion)
  if c == "success" then return "success" end
  if c == "failure" or c == "timed_out" or c == "startup_failure" then return "failed" end
  if c == "cancelled" then return "canceled" end
  if c == "action_required" then return "manual" end
  return "skipped" -- neutral, skipped, stale
end

-- Commit status (the legacy statuses API) → the review.ci vocabulary.
local COMMIT_STATUS = { success = "success", pending = "pending", failure = "failed", error = "failed" }

---The head commit's checks: its check runs (GitHub Actions and other apps)
---and commit statuses (external CI on the older API), one job row each, all
---in one "checks" stage. Read-only -- the built-in CI adapter has no
---actions (|review-ci|).
---@param remote table
---@param mr table  normalized PR
---@param cb fun(pipeline: table|nil, err: string|nil)
function M.fetch_pipeline_status(remote, mr, cb)
  local sha = mr.sha or mr.head_sha
  if not sha then return cb(nil, "PR has no head commit") end
  local jobs, pending, failure = {}, 2, nil
  local function finish()
    pending = pending - 1
    if pending > 0 then return end
    if failure and #jobs == 0 then return cb(nil, failure) end
    table.sort(jobs, function(a, b) return a.name < b.name end)
    cb({
      status = #jobs == 0 and "none" or nil, -- otherwise derived from the rows
      web_url = mr.web_url and (mr.web_url .. "/checks") or nil,
      sha = sha,
      jobs = jobs,
    })
  end

  client.request({
    url = repo_url(remote, "/commits/" .. sha .. "/check-runs"),
    method = "get",
    headers = remote.headers,
    query = { per_page = 100 },
  }, function(res)
    local body = res.ok and client.decode_json(res.body)
    if type(body) == "table" then
      for _, run in ipairs(nullable(body.check_runs) or {}) do
        local started, ended = nullable(run.started_at), nullable(run.completed_at)
        local duration
        if started and ended then
          local function epoch(ts)
            local y, mo, d, h, mi, s = ts:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
            if not y then return nil end
            return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
          end
          local a, b = epoch(started), epoch(ended)
          duration = a and b and (b - a) or nil
        end
        table.insert(jobs, {
          id = nullable(run.id),
          name = nullable(run.name) or "?",
          stage = "checks",
          status = check_run_status(run),
          duration = duration,
          web_url = nullable(run.html_url) or nullable(run.details_url),
        })
      end
    else
      failure = res.err or "failed to list check runs"
    end
    finish()
  end)

  client.request({
    url = repo_url(remote, "/commits/" .. sha .. "/status"),
    method = "get",
    headers = remote.headers,
  }, function(res)
    local body = res.ok and client.decode_json(res.body)
    if type(body) == "table" then
      for _, s in ipairs(nullable(body.statuses) or {}) do
        table.insert(jobs, {
          id = nullable(s.id),
          name = nullable(s.context) or "?",
          stage = "checks",
          status = COMMIT_STATUS[nullable(s.state)] or "pending",
          web_url = nullable(s.target_url),
        })
      end
    else
      failure = failure or res.err or "failed to read commit status"
    end
    finish()
  end)
end

function M.fetch_mr_commits(remote, n, cb)
  fetch_paginated(pr_url(remote, n, "/commits"), nil, remote.headers, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, c in ipairs(list) do table.insert(out, normalize_commit(c)) end
    cb(out)
  end)
end

---Pending review comment (GraphQL) → pending note (review.util.pending).
---@param c table  PullRequestReviewComment node
---@param position table|nil  anchor, for the first comment of a new thread
---@param reply_to string|nil  id of the published discussion it answers
local function normalize_pending_comment(c, position, reply_to)
  local author = nullable(c.author)
  return {
    id = pending_util.ID_PREFIX .. tostring(nullable(c.databaseId) or nullable(c.id) or ""),
    pending = true,
    pending_id = nullable(c.id),  -- GraphQL node id: what the mutations take
    pending_kind = reply_to and "reply" or "inline",
    reply_to = reply_to,
    body = nullable(c.body) or "",
    author = type(author) == "table" and nullable(author.login) or "?",
    created_at = nullable(c.createdAt),
    system = false,
    resolvable = false,
    resolved = false,
    position = position,
    raw = c,
  }
end

---Fetches review-thread metadata via GraphQL. Returns:
---  { thread_id_map = { [comment_db_id] = thread.id, ... },
---    resolved_for_thread = { [thread.id] = boolean, ... },
---    pending_review = { node_id, id, body } | nil,   -- the viewer's own
---    pending_notes = { pending note, ... },          -- its inline comments
---    pending_ids = { [comment_db_id] = true, ... } }
---Only the viewer's own pending review is ever visible to the API.
---
---`pending_unknown = true` marks a result from the fallback query: resolve
---data is there, but nothing can be said about a pending review.
local THREADS_QUERY = [[
  query($owner: String!, $repo: String!, $n: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $n) {
        reviews(states: [PENDING], first: 5) {
          nodes { id databaseId body viewerDidAuthor }
        }
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            path
            line
            startLine
            originalLine
            originalStartLine
            diffSide
            comments(first: 100) {
              nodes { id databaseId body state createdAt author { login } }
            }
          }
        }
      }
    }
  }
]]

-- What resolve / unresolve needs and nothing else. Used when the full query
-- is refused (e.g. a GitHub Enterprise Server whose schema lacks a field):
-- pending notes are then lost, but threads stay resolvable.
local THREADS_QUERY_MIN = [[
  query($owner: String!, $repo: String!, $n: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $n) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 100) { nodes { databaseId } }
          }
        }
      }
    }
  }
]]

local parse_review_threads

local function fetch_review_threads(remote, n, cb)
  local vars = { owner = remote.owner, repo = remote.owner_repo:match("/(.+)$"), n = tonumber(n) or n }
  M._graphql(remote, THREADS_QUERY, vars, function(data, err)
    if data then return cb(parse_review_threads(data)) end
    M._graphql(remote, THREADS_QUERY_MIN, vars, function(min_data, min_err)
      if not min_data then return cb(nil, min_err or err) end
      local out = parse_review_threads(min_data)
      out.pending_unknown = true
      cb(out)
    end)
  end)
end

---GraphQL payload of either threads query → the table documented above.
parse_review_threads = function(data)
  local out = { thread_id_map = {}, resolved_for_thread = {}, pending_notes = {}, pending_ids = {} }
  local pr = data.repository and nullable(data.repository.pullRequest)
  if not pr then return out end

  local reviews = nullable(pr.reviews)
  for _, r in ipairs(reviews and nullable(reviews.nodes) or {}) do
    if r.viewerDidAuthor ~= false then
      out.pending_review = {
        node_id = nullable(r.id),
        id = nullable(r.databaseId),
        body = nullable(r.body) or "",
      }
      break
    end
  end

  local threads = nullable(pr.reviewThreads)
  for _, t in ipairs(threads and nullable(threads.nodes) or {}) do
    out.resolved_for_thread[t.id] = t.isResolved == true
    local comments = nullable(t.comments)
    local nodes = comments and nullable(comments.nodes) or {}
    local root = nodes[1]
    for i, c in ipairs(nodes) do
      local db_id = nullable(c.databaseId)
      if db_id then out.thread_id_map[db_id] = t.id end
      if c.state == "PENDING" then
        if db_id then out.pending_ids[db_id] = true end
        local root_published = root and root.state ~= "PENDING" and nullable(root.databaseId)
        if i > 1 and root_published then
          table.insert(out.pending_notes,
            normalize_pending_comment(c, nil, "inline:" .. tostring(root_published)))
        elseif i == 1 then
          local position = pr_comment_position({
            path = t.path,
            line = t.line,
            original_line = t.originalLine,
            start_line = t.startLine,
            original_start_line = t.originalStartLine,
            side = t.diffSide,
          })
          table.insert(out.pending_notes, normalize_pending_comment(c, position, nil))
        else
          -- A second pending comment in a thread that is itself pending:
          -- no published thread to hang it on, so show it on its own.
          table.insert(out.pending_notes, normalize_pending_comment(c, nil, nil))
        end
      end
    end
  end
  return out
end

function M.fetch_mr_discussions(remote, n, cb)
  local results = { issue = nil, inline = nil, reviews = nil, threads = nil }
  local errors = {}
  local pending = 4

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end

    if results.issue == nil and results.inline == nil and results.reviews == nil then
      return cb(nil, "all discussion fetches failed: " .. table.concat(errors, "; "))
    end

    -- Thread map only needs to live for the duration of this build: each
    -- inline discussion gets its GraphQL thread_id attached directly (see
    -- below), which is what resolve_discussion reads. No session-scoped
    -- caching needed (and fetch_mr_discussions runs before a session exists).
    local thread_data = results.threads
        or { thread_id_map = {}, resolved_for_thread = {}, pending_notes = {}, pending_ids = {} }

    -- The viewer's own pending review (nobody else's is ever returned). It
    -- must not render as a published "[pending] ..." entry, and neither must
    -- its inline comments: they come back as pending notes instead.
    local pending_rest
    for _, r in ipairs(results.reviews or {}) do
      if nullable(r.state) == "PENDING" then pending_rest = r; break end
    end
    local pending_review = thread_data.pending_review
    if not pending_review and pending_rest then
      pending_review = {
        node_id = nullable(pending_rest.node_id),
        id = nullable(pending_rest.id),
        body = nullable(pending_rest.body) or "",
      }
    end
    local pending_review_id = pending_review and pending_review.id
    local function is_pending_comment(c)
      if thread_data.pending_ids[c.id] then return true end
      local rid = nullable(c.pull_request_review_id)
      return rid ~= nil and pending_review_id ~= nil and rid == pending_review_id
    end

    local discussions = {}

    -- 1. Issue (global) comments — each becomes its own single-note discussion.
    for _, c in ipairs(results.issue or {}) do
      table.insert(discussions, normalize_issue_comment(c))
    end

    -- 2. Reviews — include only when the reviewer wrote a body. GitHub
    --    auto-creates a review wrapper (state=COMMENTED, empty body) for
    --    every standalone inline comment POSTed via /pulls/:n/comments —
    --    those are noise that would otherwise appear as duplicate
    --    "[commented]" entries next to the actual inline comment. Pure
    --    APPROVE/REQUEST_CHANGES without a body is also redundant with the
    --    approval status itself.
    for _, r in ipairs(results.reviews or {}) do
      local body = nullable(r.body)
      if body and body ~= "" and nullable(r.state) ~= "PENDING" then
        table.insert(discussions, normalize_review(r))
      end
    end

    -- 3. Inline comments — group into threads by walking in_reply_to_id.
    local inline = {}
    for _, c in ipairs(results.inline or {}) do
      if not is_pending_comment(c) then table.insert(inline, c) end
    end
    results.inline = inline
    local by_id = {}
    for _, c in ipairs(results.inline or {}) do by_id[c.id] = c end

    local function root_of(c)
      local cur, seen = c, {}
      while true do
        local parent_id = nullable(cur.in_reply_to_id)
        if not parent_id or seen[parent_id] then return cur end
        local parent = by_id[parent_id]
        if not parent then return cur end
        seen[parent_id] = true
        cur = parent
      end
    end

    local replies_by_root = {}
    local roots = {}
    local seen_root = {}
    for _, c in ipairs(results.inline or {}) do
      local root = root_of(c)
      if c.id == root.id then
        if not seen_root[root.id] then
          seen_root[root.id] = true
          table.insert(roots, root)
        end
      else
        replies_by_root[root.id] = replies_by_root[root.id] or {}
        table.insert(replies_by_root[root.id], c)
      end
    end

    for _, root in ipairs(roots) do
      local thread_id = thread_data.thread_id_map[root.id]
      local resolved = thread_id and thread_data.resolved_for_thread[thread_id] or false
      local notes = { normalize_inline_note(root, resolved) }
      for _, reply in ipairs(replies_by_root[root.id] or {}) do
        local rnote = normalize_inline_note(reply, resolved)
        rnote.position = nil  -- replies inherit anchor of root in our UI
        table.insert(notes, rnote)
      end
      table.insert(discussions, {
        id = "inline:" .. tostring(root.id),
        individual_note = false,
        kind = "inline",
        thread_id = thread_id,  -- GraphQL id, used by resolve_discussion
        notes = notes,
      })
    end

    -- 4. Pending review: its inline comments, plus its body as one "summary"
    --    note (GitHub has no separate global comments inside a review).
    local pending_notes = {}
    for _, note in ipairs(thread_data.pending_notes or {}) do
      table.insert(pending_notes, note)
    end
    if pending_review and pending_review.body ~= "" then
      table.insert(pending_notes, {
        id = pending_util.ID_PREFIX .. "summary",
        pending = true,
        pending_id = pending_review.node_id,
        pending_kind = "summary",
        body = pending_review.body,
        author = (pending_rest and type(pending_rest.user) == "table"
          and nullable(pending_rest.user.login)) or "?",
        system = false,
        resolvable = false,
        resolved = false,
        position = nil,
        raw = pending_review,
      })
    end
    pending_util.merge(discussions, pending_notes)

    -- Without GraphQL and without a PENDING entry in the REST list nothing is
    -- known about a pending review: say so (nil) rather than "there is none".
    local review
    if (results.threads and not results.threads.pending_unknown) or pending_review then
      review = {
        supported = true,
        exists = pending_review ~= nil,
        count = #pending_notes,
        summary = pending_review and nonempty(pending_review.body) or nil,
      }
    end
    cb(discussions, nil, review)
  end

  fetch_paginated(issue_url(remote, n, "/comments"), nil, remote.headers, function(list, err)
    results.issue = list or {}
    if err then table.insert(errors, "issue: " .. err) end
    on_done()
  end)
  fetch_paginated(pr_url(remote, n, "/comments"), nil, remote.headers, function(list, err)
    results.inline = list or {}
    if err then table.insert(errors, "inline: " .. err) end
    on_done()
  end)
  fetch_paginated(pr_url(remote, n, "/reviews"), nil, remote.headers, function(list, err)
    results.reviews = list or {}
    if err then table.insert(errors, "reviews: " .. err) end
    on_done()
  end)
  fetch_review_threads(remote, n, function(data, err)
    results.threads = data
    if err then
      -- Non-fatal: without GraphQL we just lose resolve info.
      notify_util.warn("graphql review threads failed (" .. err .. "), resolve disabled")
    end
    on_done()
  end)
end

---Synthesize participants from PR fields (GitHub has no /participants endpoint).
function M.fetch_participants(remote, n, cb)
  M.fetch_mr_details(remote, n, function(mr, err)
    if not mr then return cb(nil, err) end
    local seen, out = {}, {}
    local function add(u)
      if u and u.username and not seen[u.username] then
        seen[u.username] = true
        table.insert(out, u)
      end
    end
    add({ username = mr.author_name, name = mr.author_full })
    for _, u in ipairs(mr.assignees or {}) do add(u) end
    for _, u in ipairs(mr.reviewers or {}) do add(u) end
    cb(out)
  end)
end

---GitHub's own verdict on the PR's reviews: "APPROVED", "CHANGES_REQUESTED"
---or "REVIEW_REQUIRED". nil when the base branch requires no reviews (the
---field is null then) or the query fails.
---@param cb fun(decision: string|nil)
local function fetch_review_decision(remote, n, cb)
  M._graphql(remote, [[
    query($owner: String!, $repo: String!, $n: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $n) { reviewDecision }
      }
    }
  ]], { owner = remote.owner, repo = remote.owner_repo:match("/(.+)$"), n = tonumber(n) or n },
  function(data)
    local repo = type(data) == "table" and data.repository
    local pr = type(repo) == "table" and repo.pullRequest
    local decision = type(pr) == "table" and pr.reviewDecision
    cb(type(decision) == "string" and decision or nil)
  end)
end

---Derives approval state from the PR's review timeline. For each user we
---keep the latest non-COMMENTED state — APPROVED counts toward `given`,
---CHANGES_REQUESTED / DISMISSED do not. GitHub doesn't expose a "required"
---reviewer count in the PR object, so `required` is left nil; whether the
---reviews are enough is GitHub's `reviewDecision`. Returns
---  { given, required, approved_by,   -- logins with a standing approval
---    changes_requested_by,           -- logins whose latest review blocks
---    decision }                      -- see fetch_review_decision, may be nil
---@param remote table
---@param n integer
---@param cb fun(approval: table|nil)
function M.fetch_approvals(remote, n, cb)
  fetch_paginated(pr_url(remote, n, "/reviews"), nil, remote.headers,
    function(reviews)
      if not reviews then return cb(nil) end
      -- GitHub returns reviews in submission order — last write wins per user.
      local latest_state_by_user = {}
      for _, r in ipairs(reviews) do
        local user = r.user and r.user.login
        local state = r.state
        if user and state and state ~= "PENDING" and state ~= "COMMENTED" then
          latest_state_by_user[user] = state
        end
      end
      local approved_by, changes_requested_by = {}, {}
      for user, state in pairs(latest_state_by_user) do
        if state == "APPROVED" then
          table.insert(approved_by, user)
        elseif state == "CHANGES_REQUESTED" then
          table.insert(changes_requested_by, user)
        end
      end
      -- pairs() order is arbitrary; the names are displayed, so keep them
      -- from reshuffling between refreshes.
      table.sort(approved_by)
      table.sort(changes_requested_by)
      fetch_review_decision(remote, n, function(decision)
        cb({
          given = #approved_by,
          required = nil,
          approved_by = approved_by,
          changes_requested_by = changes_requested_by,
          decision = decision,
        })
      end)
    end)
end

function M.fetch_mr_full(remote, n, cb)
  M.fetch_mr_details(remote, n, function(mr, err)
    if not mr then return cb(nil, err) end
    M.fetch_mr_commits(remote, n, function(commits, cerr)
      if not commits then return cb(nil, cerr) end
      M.fetch_mr_discussions(remote, n, function(discussions, derr, review)
        if not discussions then return cb(nil, derr) end
        M.fetch_participants(remote, n, function(participants)
          M.fetch_approvals(remote, n, function(approval)
            if approval then mr.approval = approval end
            cb({
              mr = mr,
              commits = commits,
              discussions = discussions,
              review = review,
              participants = participants or {},
            })
          end)
        end)
      end)
    end)
  end)
end

-- ----------------------------------------------------- approve / unapprove

function M.approve(remote, n, cb)
  -- Don't send body=""; some GitHub validation paths reject the empty string.
  -- APPROVE accepts a payload with just `event`.
  client.request({
    url = pr_url(remote, n, "/reviews"),
    method = "post",
    headers = remote.headers,
    body = vim.json.encode({ event = "APPROVE" }),
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, pending_hint(gh_error(res)))
  end)
end

---Dismisses the latest APPROVED review by the current user.
function M.unapprove(remote, n, cb)
  get_current_user(remote, function(user, uerr)
    if not user then return cb(false, uerr or "no current user") end
    fetch_paginated(pr_url(remote, n, "/reviews"), nil, remote.headers, function(reviews, rerr)
      if not reviews then return cb(false, rerr) end
      local target
      for i = #reviews, 1, -1 do
        local r = reviews[i]
        if r.user and r.user.login == user.login and r.state == "APPROVED" then
          target = r; break
        end
      end
      if not target then
        return cb(false, "no APPROVED review by current user to dismiss")
      end
      client.request({
        url = pr_url(remote, n, "/reviews/" .. tostring(target.id) .. "/dismissals"),
        method = "put",
        headers = remote.headers,
        body = vim.json.encode({ message = "Dismissed via Review plugin" }),
      }, function(res)
        if res.ok then return cb(true) end
        cb(false, res.err or "failed to dismiss")
      end)
    end)
  end)
end

-- ------------------------------------------------------ update_mr (multi)

local function set_diff(current_logins, desired_logins)
  local cur, desired = {}, {}
  for _, l in ipairs(current_logins) do cur[l] = true end
  for _, l in ipairs(desired_logins) do desired[l] = true end
  local to_remove, to_add = {}, {}
  for l in pairs(cur) do if not desired[l] then table.insert(to_remove, l) end end
  for l in pairs(desired) do if not cur[l] then table.insert(to_add, l) end end
  return to_remove, to_add
end

function M.update_mr(remote, n, fields, cb)
  -- Build list of HTTP calls based on which fields were provided.
  local calls = {}

  -- PATCH /pulls/:n — title / description / state
  do
    local patch_pr = {}
    if fields.title ~= nil then patch_pr.title = fields.title end
    if fields.description ~= nil then patch_pr.body = fields.description end
    if fields.target_branch ~= nil then patch_pr.base = fields.target_branch end
    if fields.state_event then
      patch_pr.state = (fields.state_event == "close") and "closed" or "open"
    end
    if next(patch_pr) then
      table.insert(calls, function(done)
        client.request({
          url = pr_url(remote, n),
          method = "patch",
          headers = remote.headers,
          body = vim.json.encode(patch_pr),
        }, function(res) done(res.ok, res.err) end)
      end)
    end
  end

  -- PUT /issues/:n/labels
  if fields.labels ~= nil then
    table.insert(calls, function(done)
      client.request({
        url = issue_url(remote, n, "/labels"),
        method = "put",
        headers = remote.headers,
        body = vim.json.encode({ labels = fields.labels }),
      }, function(res) done(res.ok, res.err) end)
    end)
  end

  -- PATCH /issues/:n  — assignees + milestone
  do
    local patch_issue = {}
    if fields.assignee_ids ~= nil then patch_issue.assignees = fields.assignee_ids end
    if fields.milestone_id ~= nil then
      patch_issue.milestone = (fields.milestone_id == 0) and vim.NIL or fields.milestone_id
    end
    if next(patch_issue) then
      table.insert(calls, function(done)
        client.request({
          url = issue_url(remote, n),
          method = "patch",
          headers = remote.headers,
          body = vim.json.encode(patch_issue),
        }, function(res) done(res.ok, res.err) end)
      end)
    end
  end

  -- requested_reviewers: compute add/remove diff vs current ctx.mr.reviewers.
  if fields.reviewer_ids ~= nil then
    local current_logins = {}
    if state_mod.state.mr and state_mod.state.mr.reviewers then
      for _, u in ipairs(state_mod.state.mr.reviewers) do
        table.insert(current_logins, u.username or u.id)
      end
    end
    local to_remove, to_add = set_diff(current_logins, fields.reviewer_ids)
    if #to_remove > 0 then
      table.insert(calls, function(done)
        client.request({
          url = pr_url(remote, n, "/requested_reviewers"),
          method = "delete",
          headers = remote.headers,
          body = vim.json.encode({ reviewers = to_remove }),
        }, function(res) done(res.ok, res.err) end)
      end)
    end
    if #to_add > 0 then
      table.insert(calls, function(done)
        client.request({
          url = pr_url(remote, n, "/requested_reviewers"),
          method = "post",
          headers = remote.headers,
          body = vim.json.encode({ reviewers = to_add }),
        }, function(res) done(res.ok, res.err) end)
      end)
    end
  end

  if #calls == 0 then return cb(true) end

  local pending, errors = #calls, {}
  for _, fn in ipairs(calls) do
    fn(function(ok, err)
      if not ok and err then table.insert(errors, err) end
      pending = pending - 1
      if pending == 0 then
        if #errors > 0 then return cb(false, table.concat(errors, "; ")) end
        -- Re-fetch to surface freshest values to the panel.
        M.fetch_mr_details(remote, n, function(mr) cb(true, nil, mr) end)
      end
    end)
  end
end

function M.update_description(remote, n, description, cb)
  M.update_mr(remote, n, { description = description }, cb)
end

function M.set_time_estimate(_, _, _, cb)
  vim.schedule(function()
    cb(false, "GitHub has no time tracking — section is hidden")
  end)
end

function M.add_spent_time(_, _, _, cb)
  vim.schedule(function()
    cb(false, "GitHub has no time tracking — section is hidden")
  end)
end

function M.reset_spent_time(_, _, cb)
  vim.schedule(function()
    cb(false, "GitHub has no time tracking — section is hidden")
  end)
end

---Toggles draft state via GraphQL. REST PATCH /pulls accepts `draft` only on
---creation; switching after the fact requires markPullRequestReadyForReview /
---convertPullRequestToDraft mutations.
---@param remote table
---@param n integer
---@param is_draft boolean
---@param cb fun(ok: boolean, err: string|nil)
function M.set_draft(remote, n, is_draft, cb)
  get_pr_node_id(remote, n, function(node_id, err)
    if not node_id then return cb(false, err or "no PR node id") end
    local mutation = is_draft and [[
      mutation($id: ID!) {
        convertPullRequestToDraft(input: { pullRequestId: $id }) {
          pullRequest { isDraft }
        }
      }
    ]] or [[
      mutation($id: ID!) {
        markPullRequestReadyForReview(input: { pullRequestId: $id }) {
          pullRequest { isDraft }
        }
      }
    ]]
    M._graphql(remote, mutation, { id = node_id }, function(data, gerr)
      if not data then return cb(false, gerr) end
      cb(true)
    end)
  end)
end

-- ----------------------------------------------------------- pickers

function M.fetch_members(remote, cb)
  fetch_paginated(repo_url(remote, "/collaborators"), { affiliation = "all" }, remote.headers,
    function(list, err)
      if not list then return cb(nil, err) end
      cb(normalize_user_list(list))
    end)
end

function M.fetch_labels(remote, cb)
  fetch_paginated(repo_url(remote, "/labels"), nil, remote.headers, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, l in ipairs(list) do
      table.insert(out, {
        id = nullable(l.name) or "?",
        name = nullable(l.name) or "?",
        color = nullable(l.color),
      })
    end
    cb(out)
  end)
end

function M.fetch_milestones(remote, cb)
  fetch_paginated(repo_url(remote, "/milestones"), { state = "open" }, remote.headers,
    function(list, err)
      if not list then return cb(nil, err) end
      local out = {}
      for _, m in ipairs(list) do
        local nm = normalize_milestone(m)
        if nm then table.insert(out, nm) end
      end
      cb(out)
    end)
end

---Runs a GitHub issue-search scoped to this repo + open PRs, with an extra
---qualifier (e.g. "review-requested:@me"). Returns a lightweight normalized
---list (iid/title/author_name/state/web_url) — enough for the picker; the
---full payload is fetched via fetch_mr_full(iid) when a session opens.
local function search_prs(remote, qualifier, cb)
  local q = string.format("is:pr is:open repo:%s %s", remote.owner_repo, qualifier)
  client.request({
    url = remote.base_url .. "/search/issues",
    method = "get",
    headers = remote.headers,
    query = { q = q, sort = "updated", order = "desc", per_page = 50 },
  }, function(res)
    if not res.ok then return cb(nil, gh_error(res)) end
    local data = client.decode_json(res.body)
    if not data or not data.items then return cb(nil, "decode failed") end
    local out = {}
    for _, it in ipairs(data.items) do
      table.insert(out, {
        iid = nullable(it.number),
        title = nullable(it.title) or "",
        author_name = it.user and (nullable(it.user.login) or "?") or "?",
        state = (nullable(it.state) == "open") and "opened" or (nullable(it.state) or "?"),
        is_draft = nullable(it.draft) == true,
        web_url = nullable(it.html_url),
      })
    end
    cb(out)
  end)
end

function M.fetch_review_requested(remote, cb)
  search_prs(remote, "review-requested:@me", cb)
end

---"Mine" = assignee OR author. Two searches, dedup by number.
function M.fetch_review_mine(remote, cb)
  local seen, out, pending, errs = {}, {}, 2, {}
  local function merge(list, err)
    if err then table.insert(errs, err) end
    for _, m in ipairs(list or {}) do
      if m.iid and not seen[m.iid] then
        seen[m.iid] = true
        table.insert(out, m)
      end
    end
    pending = pending - 1
    if pending == 0 then
      -- Surface an error only if BOTH searches failed (and nothing returned).
      if #out == 0 and #errs > 0 then return cb(nil, errs[1]) end
      cb(out)
    end
  end
  search_prs(remote, "assignee:@me", merge)
  search_prs(remote, "author:@me", merge)
end

---Lists repository branches. Used as the option list for the Target branch
---picker in :ReviewInfo so the user can re-point a PR.
function M.fetch_branches(remote, cb)
  fetch_paginated(repo_url(remote, "/branches"), nil, remote.headers, function(list, err)
    if not list then return cb(nil, err) end
    -- /branches does not say which one is the default; the repository does.
    -- Without it the list is still usable, just with no branch marked.
    client.request({ url = repo_url(remote), method = "get", headers = remote.headers }, function(res)
      local repo = res.ok and client.decode_json(res.body) or nil
      local default = repo and nullable(repo.default_branch)
      local out = {}
      for _, b in ipairs(list) do
        local name = nullable(b.name)
        if name then
          table.insert(out, { name = name, default = name == default, protected = b.protected == true })
        end
      end
      cb(out)
    end)
  end)
end

-- -------------------------------------------------- discussion writes

function M.post_discussion(remote, n, body, position, cb)
  if position then
    -- position here was built by M.build_position → GitHub-internal payload.
    local payload = vim.tbl_extend("force", { body = body }, position)
    client.request({
      url = pr_url(remote, n, "/comments"),
      method = "post",
      headers = remote.headers,
      body = vim.json.encode(payload),
    }, function(res)
      if not res.ok then return cb(false, pending_hint(gh_error(res))) end
      cb(true)
    end)
  else
    client.request({
      url = issue_url(remote, n, "/comments"),
      method = "post",
      headers = remote.headers,
      body = vim.json.encode({ body = body }),
    }, function(res)
      if not res.ok then return cb(false, gh_error(res)) end
      cb(true)
    end)
  end
end

---Find the cached note kind by note_id (we may receive only ids in line_targets).
---Falls back to "issue" if not found (safe-ish default for global comments).
local function lookup_note_kind(note_id)
  for _, d in ipairs(state_mod.state.discussions or {}) do
    for _, n in ipairs(d.notes or {}) do
      if n.id == note_id then return n.kind or d.kind end
    end
  end
  return "issue"
end

function M.update_note(remote, _, _, note_id, body, cb)
  local kind = lookup_note_kind(note_id)
  if kind == "review" then
    return cb(false, "GitHub: editing review summary is not supported via REST")
  end
  local url
  if kind == "inline" then
    url = repo_url(remote, "/pulls/comments/" .. tostring(note_id))
  else
    url = repo_url(remote, "/issues/comments/" .. tostring(note_id))
  end
  client.request({
    url = url,
    method = "patch",
    headers = remote.headers,
    body = vim.json.encode({ body = body }),
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to update note")
  end)
end

function M.delete_note(remote, _, _, note_id, cb)
  local kind = lookup_note_kind(note_id)
  if kind == "review" then
    return cb(false, "GitHub: deleting submitted reviews is not supported via REST")
  end
  local url
  if kind == "inline" then
    url = repo_url(remote, "/pulls/comments/" .. tostring(note_id))
  else
    url = repo_url(remote, "/issues/comments/" .. tostring(note_id))
  end
  client.request({
    url = url,
    method = "delete",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to delete note")
  end)
end

---Reply behaviour by discussion kind:
---  inline → POST /pulls/:n/comments/:cid/replies (proper threaded reply)
---  issue / review → POST /issues/:n/comments  (GitHub has no global threads)
function M.add_reply(remote, n, discussion_id, body, cb)
  local kind, root_note_id
  for _, d in ipairs(state_mod.state.discussions or {}) do
    if d.id == discussion_id then
      kind = d.kind
      root_note_id = d.notes[1] and d.notes[1].id
      break
    end
  end
  if kind == "inline" and root_note_id then
    client.request({
      url = pr_url(remote, n, "/comments/" .. tostring(root_note_id) .. "/replies"),
      method = "post",
      headers = remote.headers,
      body = vim.json.encode({ body = body }),
    }, function(res)
      if res.ok then return cb(true) end
      cb(false, pending_hint(gh_error(res)))
    end)
  else
    client.request({
      url = issue_url(remote, n, "/comments"),
      method = "post",
      headers = remote.headers,
      body = vim.json.encode({ body = body }),
    }, function(res)
      if res.ok then return cb(true) end
      cb(false, res.err or "failed to reply")
    end)
  end
end

-- ------------------------------------------------- resolve (GraphQL only)

local function find_thread_id(discussion_id)
  for _, d in ipairs(state_mod.state.discussions or {}) do
    if d.id == discussion_id then return d.thread_id end
  end
end

function M.resolve_discussion(remote, _, discussion_id, resolved, cb)
  local thread_id = find_thread_id(discussion_id)
  if not thread_id then
    return cb(false, "GitHub: this thread isn't resolvable (issue/review or no GraphQL data)")
  end
  local mutation = resolved and [[
    mutation($id: ID!) { resolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }
  ]] or [[
    mutation($id: ID!) { unresolveReviewThread(input: { threadId: $id }) { thread { id isResolved } } }
  ]]
  M._graphql(remote, mutation, { id = thread_id }, function(data, err)
    if not data then return cb(false, err) end
    cb(true)
  end)
end

-- ------------------------------------------- pending review (GraphQL only)
--
-- GitHub keeps the comments of a started review in ONE pending review per
-- user and PR, visible only to its author until submitted. REST can create a
-- pending review but cannot add to an existing one, so everything here is
-- GraphQL. The functions take the note / discussion objects themselves: the
-- session-state lookups used further up are nil outside the session's tab.

---Verdicts M.submit_review accepts, in the order the submit prompt lists them.
M.review_verdicts = { "comment", "approve", "request_changes" }

local REVIEW_EVENTS = {
  comment = "COMMENT",
  approve = "APPROVE",
  request_changes = "REQUEST_CHANGES",
}

---Runs `mutation { <name>(input: $input) { <selection> } }`.
---@param cb fun(payload: table|nil, err: string|nil)
local function mutate(remote, name, input_type, selection, input, cb)
  local query = string.format("mutation($input: %s!) { %s(input: $input) { %s } }",
    input_type, name, selection)
  M._graphql(remote, query, { input = input }, function(data, err)
    if not data then return cb(nil, err) end
    local payload = nullable(data[name])
    cb(type(payload) == "table" and payload or {})
  end)
end

---The PR's node id and the viewer's pending review on it, if any.
---@param cb fun(found: { pr_id: string, review_id: string|nil, body: string }|nil, err: string|nil)
local function find_pending_review(remote, n, cb)
  M._graphql(remote, [[
    query($owner: String!, $repo: String!, $n: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $n) {
          id
          reviews(states: [PENDING], first: 5) { nodes { id body viewerDidAuthor } }
        }
      }
    }
  ]], { owner = remote.owner, repo = remote.owner_repo:match("/(.+)$"), n = tonumber(n) or n },
  function(data, err)
    if not data then return cb(nil, err) end
    local pr = data.repository and nullable(data.repository.pullRequest)
    if not pr or not nullable(pr.id) then return cb(nil, "graphql: no PR id") end
    local found = { pr_id = pr.id, review_id = nil, body = "" }
    local reviews = nullable(pr.reviews)
    for _, r in ipairs(reviews and nullable(reviews.nodes) or {}) do
      if r.viewerDidAuthor ~= false then
        found.review_id = nullable(r.id)
        found.body = nullable(r.body) or ""
        break
      end
    end
    cb(found)
  end)
end

---Like find_pending_review, but starts a pending review when there is none.
---Looked up on every call rather than cached: the review can be submitted or
---deleted in the browser at any time, and a stale id would fail the write.
---@param cb fun(found: { pr_id: string, review_id: string, body: string }|nil, err: string|nil)
local function ensure_pending_review(remote, n, cb)
  find_pending_review(remote, n, function(found, err)
    if not found then return cb(nil, err) end
    if found.review_id then return cb(found) end
    mutate(remote, "addPullRequestReview", "AddPullRequestReviewInput",
      "pullRequestReview { id }", { pullRequestId = found.pr_id },
      function(payload, cerr)
        local review = payload and nullable(payload.pullRequestReview)
        if type(review) == "table" and nullable(review.id) then
          found.review_id = review.id
          return cb(found)
        end
        -- Two notes saved back to back race for the creation; the loser finds
        -- the winner's review on a second look.
        find_pending_review(remote, n, function(again)
          if again and again.review_id then return cb(again) end
          cb(nil, cerr or "failed to start a pending review")
        end)
      end)
  end)
end

local function update_review_body(remote, review_id, body, cb)
  mutate(remote, "updatePullRequestReview", "UpdatePullRequestReviewInput",
    "pullRequestReview { id }", { pullRequestReviewId = review_id, body = body },
    function(payload, err)
      if not payload then return cb(false, err) end
      cb(true)
    end)
end

---Holds a comment back in the pending review instead of publishing it.
---
---  inline (position)          → a new pending thread
---  reply to an inline thread  → a pending reply in that thread
---  anything else              → appended to the review's body: a GitHub
---                               review has ONE summary, no separate global
---                               comments, and issue comments cannot be held
---                               back at all.
---@param remote table
---@param n string|number
---@param body string
---@param position table|nil  M.build_position result (nil = global note)
---@param opts { reply_to: table|nil }|nil  reply_to = the discussion answered
---@param cb fun(ok: boolean, err: string|nil)
function M.create_pending(remote, n, body, position, opts, cb)
  local reply_to = opts and opts.reply_to
  local threaded = reply_to ~= nil and reply_to.kind == "inline"
  if threaded and not reply_to.thread_id then
    return cb(false, "GitHub: this thread has no GraphQL id (refresh the review), cannot reply in a pending review")
  end
  ensure_pending_review(remote, n, function(found, err)
    if not found then return cb(false, err) end
    if position then
      local input = {
        pullRequestReviewId = found.review_id,
        path = position.path,
        line = position.line,
        side = position.side,
        body = body,
      }
      if position.start_line then
        input.startLine = position.start_line
        input.startSide = position.start_side or position.side
      end
      mutate(remote, "addPullRequestReviewThread", "AddPullRequestReviewThreadInput",
        "thread { id }", input, function(payload, merr)
          if not payload then return cb(false, merr) end
          -- GitHub answers 200 with `thread: null` for a line it cannot anchor.
          if type(nullable(payload.thread)) ~= "table" then
            return cb(false, "GitHub did not accept this position (line not part of the diff?)")
          end
          cb(true)
        end)
    elseif threaded then
      mutate(remote, "addPullRequestReviewThreadReply", "AddPullRequestReviewThreadReplyInput",
        "comment { id }", {
          pullRequestReviewId = found.review_id,
          pullRequestReviewThreadId = reply_to.thread_id,
          body = body,
        }, function(payload, merr)
          if not payload then return cb(false, merr) end
          cb(true)
        end)
    else
      local merged = found.body ~= "" and (found.body .. "\n\n" .. body) or body
      update_review_body(remote, found.review_id, merged, cb)
    end
  end)
end

---@param note table  pending note (review.util.pending)
---@param cb fun(ok: boolean, err: string|nil)
function M.update_pending(remote, _, note, body, cb)
  if note.pending_kind == "summary" then
    return update_review_body(remote, note.pending_id, body, cb)
  end
  mutate(remote, "updatePullRequestReviewComment", "UpdatePullRequestReviewCommentInput",
    "pullRequestReviewComment { id }",
    { pullRequestReviewCommentId = note.pending_id, body = body },
    function(payload, err)
      if not payload then return cb(false, err) end
      cb(true)
    end)
end

---@param note table  pending note (review.util.pending)
---@param cb fun(ok: boolean, err: string|nil)
function M.delete_pending(remote, _, note, cb)
  if note.pending_kind == "summary" then
    return update_review_body(remote, note.pending_id, "", cb)
  end
  mutate(remote, "deletePullRequestReviewComment", "DeletePullRequestReviewCommentInput",
    "clientMutationId", { id = note.pending_id },
    function(payload, err)
      if not payload then return cb(false, err) end
      cb(true)
    end)
end

---Submits the pending review with a verdict; with no pending review it
---creates and submits one in a single step (a bare verdict / summary).
---`opts.body` REPLACES the review's summary: the submit prompt is prefilled
---with it, so what comes back is what the user wants published.
---@param opts { body: string|nil, verdict: string }
---@param cb fun(ok: boolean, err: string|nil, warning: string|nil)
function M.submit_review(remote, n, opts, cb)
  local event = REVIEW_EVENTS[opts.verdict or "comment"]
  if not event then return cb(false, "unknown verdict: " .. tostring(opts.verdict)) end
  local body = nonempty(opts.body)
  find_pending_review(remote, n, function(found, err)
    if not found then return cb(false, err) end
    if found.review_id then
      local input = { pullRequestReviewId = found.review_id, event = event }
      if body then
        input.body = body
      elseif found.body ~= "" then
        input.body = ""
      end
      mutate(remote, "submitPullRequestReview", "SubmitPullRequestReviewInput",
        "pullRequestReview { id }", input, function(payload, merr)
          if not payload then return cb(false, merr) end
          cb(true)
        end)
    else
      local input = { pullRequestId = found.pr_id, event = event }
      if body then input.body = body end
      mutate(remote, "addPullRequestReview", "AddPullRequestReviewInput",
        "pullRequestReview { id }", input, function(payload, merr)
          if not payload then return cb(false, merr) end
          cb(true)
        end)
    end
  end)
end

---Deletes the pending review together with every comment in it.
---@param cb fun(ok: boolean, err: string|nil)
function M.discard_review(remote, n, cb)
  find_pending_review(remote, n, function(found, err)
    if not found then return cb(false, err) end
    if not found.review_id then return cb(true) end
    mutate(remote, "deletePullRequestReview", "DeletePullRequestReviewInput",
      "clientMutationId", { pullRequestReviewId = found.review_id },
      function(payload, merr)
        if not payload then return cb(false, merr) end
        cb(true)
      end)
  end)
end

-- ------------------------------------------------------- merge / close

---Deletes a branch of the repository (the remote one, not a local branch).
---@param remote table
---@param branch string
---@param cb fun(ok: boolean, err: string|nil)
local function delete_branch(remote, branch, cb)
  client.request({
    url = repo_url(remote, "/git/refs/heads/" .. branch),
    method = "delete",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, gh_error(res))
  end)
end
M.delete_branch = delete_branch

---Merge a PR (or schedule auto-merge). `opts` is the same table the GitLab
---provider takes; GitHub accepts the commit title and description
---separately, so each is sent only when given and the other keeps GitHub's
---default — `default_commit_title` is not needed here.
function M.merge_mr(remote, n, opts, cb)
  local commit_title = nonempty(opts.commit_title)
  local commit_body = nonempty(opts.commit_body)

  if opts.merge_when_pipeline_succeeds then
    -- Auto-merge — GraphQL only.
    get_pr_node_id(remote, n, function(node_id, err)
      if not node_id then return cb(false, err or "no PR node id") end
      local merge_method = opts.squash and "SQUASH" or "MERGE"
      M._graphql(remote, [[
        mutation($id: ID!, $method: PullRequestMergeMethod!, $headline: String, $body: String) {
          enablePullRequestAutoMerge(input: {
            pullRequestId: $id, mergeMethod: $method,
            commitHeadline: $headline, commitBody: $body
          }) { pullRequest { autoMergeRequest { enabledAt } } }
        }
      ]], {
        id = node_id, method = merge_method,
        headline = commit_title,
        body = commit_body,
      }, function(data, gerr)
        if not data then return cb(false, gerr) end
        cb(true)
      end)
    end)
    return
  end

  local payload = {
    sha = opts.sha,
    merge_method = opts.squash and "squash" or "merge",
  }
  payload.commit_title = commit_title
  payload.commit_message = commit_body

  client.request({
    url = pr_url(remote, n, "/merge"),
    method = "put",
    headers = remote.headers,
    body = vim.json.encode(payload),
  }, function(res)
    if not res.ok then
      local detail
      if res.body and res.body ~= "" then
        local parsed = client.decode_json(res.body)
        if parsed and parsed.message then detail = parsed.message end
      end
      return cb(false, detail or res.err or "merge failed")
    end
    -- Optionally delete the source branch after merge.
    if opts.should_remove_source_branch and state_mod.state.mr
        and state_mod.state.mr.source_branch then
      delete_branch(remote, state_mod.state.mr.source_branch, function(ok, dberr)
        if not ok then
          notify("merge OK but branch delete failed: " .. (dberr or "?"),
            vim.log.levels.WARN)
        end
        cb(true)
      end)
    else
      cb(true)
    end
  end)
end

function M.close_mr(remote, n, cb)
  M.update_mr(remote, n, { state_event = "close" }, cb)
end

function M.reopen_mr(remote, n, cb)
  M.update_mr(remote, n, { state_event = "reopen" }, cb)
end

---Options the :ReviewCreate dialog may offer on this forge. GitHub sets
---"delete branch on merge" and the squash method per repository or at merge
---time, not on a new PR, so the dialog leaves both out.
M.create_fields = {}

---Opens a new PR. `f` is the same table the GitLab provider takes; the
---GitLab-only fields are ignored.
---@param remote table
---@param f { source_branch: string, target_branch: string, title: string,
---  description: string|nil, draft: boolean|nil }
---@param cb fun(ok: boolean, err: string|nil, mr: table|nil)
function M.create_mr(remote, f, cb)
  client.request({
    url = pr_no_n_url(remote),
    method = "post",
    headers = remote.headers,
    body = vim.json.encode({
      title = f.title,
      head = f.source_branch,
      base = f.target_branch,
      body = f.description or "",
      draft = f.draft == true,
    }),
  }, function(res)
    if not res.ok then return cb(false, gh_error(res)) end
    local raw = client.decode_json(res.body)
    if not raw then return cb(false, "failed to decode the new PR") end
    cb(true, nil, normalize_pr(raw))
  end)
end

-- ------------------------------------------------ position + suggestion

---Builds the inline-comment payload for POST /pulls/:n/comments. Multi-line
---ranges encode start_line/start_side; single line just sets line/side.
function M.build_position(mr, opts)
  -- Prefer the explicit side hint; fall back to inferring from which line is
  -- set (callers may now pass BOTH lines for context lines, so the hint avoids
  -- mis-detecting the side).
  local side
  if opts.side == "new" then side = "RIGHT"
  elseif opts.side == "old" then side = "LEFT"
  elseif opts.new_line then side = "RIGHT"
  elseif opts.old_line then side = "LEFT"
  else side = "RIGHT" end
  local line = (side == "RIGHT") and (opts.new_line or opts.old_line)
      or (opts.old_line or opts.new_line)

  local pos = {
    commit_id = mr.head_sha,
    path = opts.new_path or opts.old_path,
    line = line,
    side = side,
  }
  if opts.start_line and opts.start_line ~= line then
    pos.start_line = opts.start_line
    pos.start_side = side
  end
  return pos
end

function M.format_suggestion(lines, _)
  local body_lines = { "```suggestion" }
  for _, l in ipairs(lines) do table.insert(body_lines, l) end
  table.insert(body_lines, "```")
  return table.concat(body_lines, "\n")
end

return M
