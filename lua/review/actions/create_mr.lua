-- :ReviewCreate [target]
--
-- Opens an MR/PR from the checked-out branch. The branch must already be on
-- origin with nothing left to push -- the plugin never pushes; it says what
-- to run instead.
--
-- The target defaults to the branch the current one came from (see
-- review.git.base); an argument names it explicitly. A dialog then shows
-- target, title, description and the options the forge takes on creation
-- (provider.create_fields). <CR> on Target opens a picker of the remote
-- branches. On success: a notification with the link, and the link in the
-- unnamed and `+` registers. No review session is started.

local M = {}

local controller = require("review.controller")
local git = require("review.git.rebase")
local base = require("review.git.base")
local form_dialog = require("review.ui.form_dialog")
local notify_util = require("review.util.notify")

local function push_hint(source)
  return ("'%s' is not on origin - push it first: git push -u origin %s"):format(source, source)
end

---"feature/add-foo_bar" -> "Add foo bar", the way the forges title an MR of
---several commits.
---@param branch string
---@return string
function M._title_from_branch(branch)
  local last = branch:match("([^/]+)$") or branch
  local words = vim.trim((last:gsub("[-_]+", " ")))
  return (words:gsub("^%l", string.upper))
end

---Title and description from the commits the MR would bring: one commit
---gives its subject and body, more give the branch name. Exposed for tests.
---@param stdout string  `git log --format=%s%x1f%b%x1e` output
---@param source string
---@return string title, string description
function M._prefill(stdout, source)
  local commits = {}
  for record in (stdout or ""):gmatch("[^\30]+") do
    local subject, body = record:match("^%s*(.-)\31(.*)$")
    if subject and subject ~= "" then
      table.insert(commits, { subject = subject, body = vim.trim(body or "") })
    end
  end
  if #commits == 1 then return commits[1].subject, commits[1].body end
  return M._title_from_branch(source), ""
end

---@param value string
local function copy_url(value)
  vim.fn.setreg('"', value)
  if vim.fn.has("clipboard") == 1 then pcall(vim.fn.setreg, "+", value) end
end

---Target, title and description chosen -- show the dialog and create.
local function open_dialog(ctx)
  local provider, source, kind = ctx.provider, ctx.source, ctx.kind
  local fields_ok = provider.create_fields or {}

  local function hint_for(name)
    local tags = {}
    if name == ctx.detected then table.insert(tags, "base") end
    if ctx.by_name[name] and ctx.by_name[name].default then table.insert(tags, "default") end
    return #tags > 0 and ("(" .. table.concat(tags, ", ") .. ")") or nil
  end

  -- Picker order: the detected base, the default branch, then the rest.
  local ordered = {}
  for _, b in ipairs(ctx.candidates) do table.insert(ordered, b.name) end
  local function rank(name)
    if name == ctx.detected then return 0 end
    if ctx.by_name[name].default then return 1 end
    return 2
  end
  table.sort(ordered, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)

  form_dialog.open({
    title = "Create " .. kind,
    header = "Source: " .. source,
    fields = {
      {
        id = "target", kind = "choice", label = "Target",
        value = ctx.target, hint = hint_for(ctx.target),
        pick = function(_, set)
          vim.ui.select(ordered, {
            prompt = "Target branch",
            format_item = function(name)
              local h = hint_for(name)
              return h and (name .. "  " .. h) or name
            end,
          }, function(name)
            set(name, name and hint_for(name) or nil)
          end)
        end,
      },
      { id = "title", kind = "text", label = "Title", value = ctx.title,
        single_line = true, prompt = kind .. " title" },
      { id = "description", kind = "text", label = "Description", value = ctx.description,
        prompt = kind .. " description" },
      { id = "draft", kind = "checkbox", label = "Draft", value = false },
      { id = "delete_source", kind = "checkbox", label = "Delete source branch after merge",
        value = true, hidden = not fields_ok.delete_source },
      { id = "squash", kind = "checkbox", label = "Squash commits on merge",
        value = false, hidden = not fields_ok.squash },
    },
    actions = { { id = "create", label = "Create " .. kind } },
    -- Runs with the dialog still open, so nothing typed is lost.
    validate = function(v)
      if not v.title or vim.trim(v.title) == "" then return "the title is required" end
      for _, mr in ipairs(ctx.open_mrs) do
        if mr.target_branch == v.target then
          return ("!%s is already open for %s -> %s"):format(tostring(mr.iid), source, v.target)
        end
      end
    end,
    on_submit = function(_, v)
      notify_util.progress(("creating %s %s -> %s..."):format(kind, source, v.target))
      provider.create_mr(ctx.remote, {
        source_branch = source,
        target_branch = v.target,
        title = vim.trim(v.title),
        description = v.description,
        draft = v.draft,
        delete_source = v.delete_source,
        squash = v.squash,
      }, function(ok, err, mr)
        vim.schedule(function()
          if not ok then
            return notify_util.err(("failed to create %s: %s"):format(kind, err or "?"))
          end
          local url = mr and mr.web_url or ""
          if url ~= "" then copy_url(url) end
          notify_util.event(("!%s created (%s -> %s) %s"):format(
            tostring(mr and mr.iid or "?"), source, v.target, url))
        end)
      end)
    end,
  })
end

---Forge data in hand: resolve the target, prefill from git, open the dialog.
local function with_forge(ctx, wanted)
  ctx.by_name = {}
  ctx.candidates = {}
  for _, b in ipairs(ctx.branches) do
    ctx.by_name[b.name] = b
    if b.name ~= ctx.source then table.insert(ctx.candidates, b) end
  end
  -- No "is the source on the forge" check against this list: it is capped
  -- (GitLab 500, GitHub 1000 branches), and the forge refuses an unknown
  -- source branch by itself.
  if #ctx.candidates == 0 then
    return notify_util.err("no other branch on the remote to open the " .. ctx.kind .. " against")
  end

  local function with_target(target)
    ctx.target = target
    git._run({ "git", "log", "--format=%s%x1f%b%x1e",
      "refs/remotes/origin/" .. target .. "..HEAD" }, nil, nil, function(res)
      if res.ok then
        ctx.title, ctx.description = M._prefill(res.stdout, ctx.source)
      else
        ctx.title, ctx.description = M._title_from_branch(ctx.source), ""
      end
      open_dialog(ctx)
    end)
  end

  base.detect(ctx.source, ctx.branches, function(detected)
    ctx.detected = detected
    if wanted then
      local function unknown()
        notify_util.err(("no branch '%s' on the remote to target"):format(wanted))
      end
      if wanted == ctx.source then return unknown() end
      if ctx.by_name[wanted] then return with_target(wanted) end
      -- Past the list's cap: a local origin/<wanted> is good enough.
      return git._run({ "git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" .. wanted },
        nil, nil, function(res)
        if not res.ok then return unknown() end
        ctx.by_name[wanted] = { name = wanted }
        table.insert(ctx.candidates, ctx.by_name[wanted])
        with_target(wanted)
      end)
    end
    if not detected then return notify_util.err("cannot pick a target branch") end
    with_target(detected)
  end)
end

---@param opts { target: string|nil }|nil
function M.run(opts)
  opts = opts or {}
  local wanted = opts.target
  if wanted == "" then wanted = nil end
  if wanted then wanted = wanted:gsub("^origin/", "") end

  local source = git.current_branch()
  if not source then
    return notify_util.err("detached HEAD - check out the branch to open an MR/PR for")
  end

  git._run({ "git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" .. source },
    nil, nil, function(res)
    if not res.ok then return notify_util.err(push_hint(source)) end
    git._run({ "git", "rev-list", "--count", "refs/remotes/origin/" .. source .. "..HEAD" },
      nil, nil, function(count)
      local ahead = tonumber(vim.trim(count.stdout or "")) or 0
      if count.ok and ahead > 0 then
        return notify_util.err(("%d local commit(s) on '%s' not pushed - push first: git push")
          :format(ahead, source))
      end

      controller.provider_context(function(provider, remote, err)
        if not provider or not remote then
          return notify_util.err(err or "setup failed")
        end
        if not provider.create_mr then
          return notify_util.err(provider.name .. " provider cannot create MRs")
        end
        local ctx = {
          provider = provider,
          remote = remote,
          source = source,
          kind = provider.name == "github" and "PR" or "MR",
        }
        notify_util.progress(("loading branches for %s..."):format(source))

        -- Branches and the branch's open MRs, in parallel. A failed MR list
        -- only drops the duplicate check -- the forge refuses a duplicate anyway.
        local pending = 2
        local branches_err
        local function done()
          pending = pending - 1
          if pending > 0 then return end
          vim.schedule(function()
            if not ctx.branches then
              return notify_util.err("failed to load branches: " .. (branches_err or "?"))
            end
            with_forge(ctx, wanted)
          end)
        end
        provider.fetch_branches(remote, function(list, berr)
          ctx.branches, branches_err = list, berr
          done()
        end)
        provider.fetch_open_mrs(remote, source, function(mrs)
          ctx.open_mrs = mrs or {}
          done()
        end)
      end)
    end)
  end)
end

return M
