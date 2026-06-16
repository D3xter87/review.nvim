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

local function nullable(v)
  if v == vim.NIL then return nil end
  return v
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

---Maps a GitHub PR object to our generic MR shape. time_stats=nil tells the
---panel to skip the Time tracking section (no GitHub equivalent).
local function normalize_pr(raw)
  local head = raw.head or {}
  local base = raw.base or {}
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
    merge_when_pipeline_succeeds = nullable(raw.auto_merge) ~= nil,
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
local function pr_comment_position(c)
  local line = nullable(c.line) or nullable(c.original_line)
  if not line then return nil end
  local side = nullable(c.side) or "RIGHT"
  local path = nullable(c.path)
  if side == "RIGHT" then
    return { new_path = path, old_path = path, new_line = line, old_line = nil }
  else
    return { new_path = path, old_path = path, new_line = nil, old_line = line }
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

function M.fetch_mr_commits(remote, n, cb)
  fetch_paginated(pr_url(remote, n, "/commits"), nil, remote.headers, function(list, err)
    if not list then return cb(nil, err) end
    local out = {}
    for _, c in ipairs(list) do table.insert(out, normalize_commit(c)) end
    cb(out)
  end)
end

---Fetches review-thread metadata via GraphQL. Returns:
---  { thread_id_map = { [comment_db_id] = thread.id, ... },
---    resolved_for_thread = { [thread.id] = boolean, ... } }
local function fetch_review_threads(remote, n, cb)
  M._graphql(remote, [[
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
  ]], { owner = remote.owner, repo = remote.owner_repo:match("/(.+)$"), n = n },
  function(data, err)
    if not data then return cb(nil, err) end
    local pr = data.repository and data.repository.pullRequest
    if not pr or not pr.reviewThreads then return cb({ thread_id_map = {}, resolved_for_thread = {} }) end
    local map, resolved = {}, {}
    for _, t in ipairs(pr.reviewThreads.nodes or {}) do
      resolved[t.id] = t.isResolved == true
      for _, c in ipairs(t.comments.nodes or {}) do
        if c.databaseId then map[c.databaseId] = t.id end
      end
    end
    cb({ thread_id_map = map, resolved_for_thread = resolved })
  end)
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
    local thread_data = results.threads or { thread_id_map = {}, resolved_for_thread = {} }

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
      if body and body ~= "" then
        table.insert(discussions, normalize_review(r))
      end
    end

    -- 3. Inline comments — group into threads by walking in_reply_to_id.
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

    cb(discussions)
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

---Derives approval state from the PR's review timeline. For each user we
---keep the latest non-COMMENTED state — APPROVED counts toward `given`,
---CHANGES_REQUESTED / DISMISSED do not. GitHub doesn't expose a "required"
---reviewer count in the PR object, so `required` is left nil.
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
      local approved_by = {}
      for user, state in pairs(latest_state_by_user) do
        if state == "APPROVED" then table.insert(approved_by, user) end
      end
      cb({
        given = #approved_by,
        required = nil,
        approved_by = approved_by,
      })
    end)
end

function M.fetch_mr_full(remote, n, cb)
  M.fetch_mr_details(remote, n, function(mr, err)
    if not mr then return cb(nil, err) end
    M.fetch_mr_commits(remote, n, function(commits, cerr)
      if not commits then return cb(nil, cerr) end
      M.fetch_mr_discussions(remote, n, function(discussions, derr)
        if not discussions then return cb(nil, derr) end
        M.fetch_participants(remote, n, function(participants)
          M.fetch_approvals(remote, n, function(approval)
            if approval then mr.approval = approval end
            cb({
              mr = mr,
              commits = commits,
              discussions = discussions,
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
    cb(false, gh_error(res))
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
    local out = {}
    for _, b in ipairs(list) do
      local name = nullable(b.name)
      if name then table.insert(out, { name = name }) end
    end
    cb(out)
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
      if not res.ok then return cb(false, gh_error(res)) end
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
      cb(false, res.err or "failed to reply")
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

-- ------------------------------------------------------- merge / close

local function delete_branch(remote, branch, cb)
  client.request({
    url = repo_url(remote, "/git/refs/heads/" .. branch),
    method = "delete",
    headers = remote.headers,
  }, function(res)
    if res.ok then return cb(true) end
    cb(false, res.err or "failed to delete branch")
  end)
end

function M.merge_mr(remote, n, opts, cb)
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
        headline = opts.squash and opts.squash_commit_message or opts.merge_commit_message,
        body = nil,
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
  if opts.squash and opts.squash_commit_message and opts.squash_commit_message ~= "" then
    payload.commit_title = opts.squash_commit_message
  elseif opts.merge_commit_message and opts.merge_commit_message ~= "" then
    payload.commit_title = opts.merge_commit_message
  end

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

-- ------------------------------------------------ position + suggestion

---Builds the inline-comment payload for POST /pulls/:n/comments. Multi-line
---ranges encode start_line/start_side; single line just sets line/side.
function M.build_position(mr, opts)
  local side
  if opts.new_line then side = "RIGHT"
  elseif opts.old_line then side = "LEFT"
  else side = "RIGHT" end
  local line = opts.new_line or opts.old_line

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
