local M = {}

local defaults = {
  -- Per-provider explicit token override (rarely useful — see |review-auth|).
  providers = {
    -- gitlab = { token = "glpat-..." },
    -- github = { token = "ghp-..." },
  },

  -- Force a provider for hostnames the heuristics miss.
  host_providers = {
    -- ["ghes.example.com"] = "github",
    -- ["ci.intranet"]      = "gitlab",
  },

  -- Override the API URL scheme per host.
  host_schemes = {
    -- ["gitlab.intranet"] = "http",
  },

  -- Full base URL override (GitHub Enterprise).
  host_bases = {
    -- ["ghes.example.com"] = "https://ghes.example.com/api/v3",
  },

  -- Bottom panel layout.
  panel = {
    height = 12,
  },

  -- Read-only float showing the discussion thread anchored to the cursor's
  -- line — available wherever a gutter icon is (diff buffers and working-tree
  -- files of the session). Press the key again to move the cursor INTO the
  -- float; `q` / <Esc> closes it, as does moving the cursor in the origin
  -- window. The mapping is buffer-local and only lives for the duration of a
  -- review session, so it never shadows your own key outside one.
  note_preview = {
    key        = "<leader>rp",  -- false = don't map anything
    border     = "rounded",
    max_width  = 80,
    max_height = 20,
    -- Acted on the thread under the cursor INSIDE the float (so they only
    -- exist once you've pressed `key` a second time to step into it). Named
    -- after their Notes-panel equivalents on purpose. false = don't map.
    resolve_key = "r",   -- toggle resolve on the thread under the cursor
    reply_key   = "a",   -- reply to it
  },

  -- Jump between UNRESOLVED threads (the ❌ ones) without leaving the code.
  -- Walks the current file first, then the next file of the MR that still has
  -- unresolved threads, wrapping at the end. See |review-notes-nav|.
  notes_nav = {
    next = "]r",  -- false = don't map
    prev = "[r",
  },

  -- Notification verbosity:
  --   "quiet"   (default) — only event confirmations ("!42 merged"),
  --                         warnings, and errors. Progress chatter
  --                         ("looking up MRs...", "merging...") is hidden.
  --   "verbose"           — also show progress messages.
  notify = "quiet",

  -- Background watcher started after :ReviewMerge → "Set auto-merge".
  -- Polls the MR until it merges, gets cancelled (pipeline failure / manual
  -- cancel), or the timeout elapses. Survives review-session teardown so
  -- the user gets the verdict regardless of editor state.
  auto_merge_watcher = {
    enabled         = true,         -- master switch — false disables polling
    poll_interval_ms = 30 * 1000,   -- delay between MR refresh polls
    timeout_ms       = 60 * 60 * 1000,  -- give up after 1 h
  },

  -- :ReviewMerge, once the merge lands ("Merge now", or auto-merge completing
  -- while the watcher runs). When the merged MR/PR's source branch is still
  -- the one checked out locally, `checkout_target` switches to its target
  -- branch and fast-forwards it to origin, so you aren't left on a finished
  -- branch. false = stay where you are.
  merge = {
    checkout_target = true,
  },

  -- Mirror the MR's total spent time into a trailer line at the very bottom of
  -- the description: "refs PROJ-123-FEAT #time 1h 30m" — the source branch
  -- uppercased, plus the current total. Rewritten after every :ReviewTime /
  -- panel "Spent time" edit, removed when the total hits zero. Off by default
  -- — `refs ... #time ...` is an issue-tracker convention, not a GitLab one.
  spent_time_refs_line = {
    enabled = false,
  },

  -- "Close issue on merge" in the :ReviewMerge dialog adds one line per issue
  -- to the MR/PR description before merging. `template` is that line, with
  -- %s standing for the issue reference (PROJ-123, #12). The default is the
  -- closing keyword GitLab and GitHub both understand; change it when your
  -- tracker integration expects something else. See |review-close-issue|.
  --
  -- The two hooks are how another plugin (an issue tracker, say) or your own
  -- function takes part; the plugin depends on neither:
  --   detect(info)     -> what to prefill the list with: a list of references
  --                       or a string, {} for "nothing", nil for the built-in
  --                       guess (an issue number in the branch name).
  --                       info = { branch, mr, provider }
  --   on_merged(info)  -> called once the MR/PR has actually merged with the
  --                       box ticked. info = { refs, mr, provider }
  close_issue = {
    template  = "Closes %s",
    detect    = nil,
    on_merged = nil,
  },

  -- CI/CD of the MR/PR: a "Pipeline" section in the Info panel and a
  -- Pipeline panel mode with the jobs. See |review-ci|.
  --
  -- `adapter` is how a CI/CD plugin (or your own function) takes part; the
  -- CI feature needs none. nil = built-in: the pipeline's status, read
  -- through the MR/PR API (GitHub: its checks as rows), and the browser.
  -- A table with:
  --   name                  shown in the Pipeline panel's title
  --   fetch(target, cb)     required. cb(pipeline|nil, err)
  --   run(target, job, cb)  <CR> on a job: its `job.action`. cb(ok, err)
  --   log(target, job)      L on a job
  --   open(target)          B: the plugin's own pipeline UI
  -- target = require("review").current() of the session; pipeline =
  --   { status, web_url, jobs = { { name, stage, status, duration,
  --     web_url, action, action_label }, ... } }
  ci = {
    enabled = true,
    adapter = nil,
    -- Poll while the pipeline is running and the Info / Pipeline panel is on
    -- screen. 0 = never (refresh with `r` in the Pipeline panel).
    poll_interval_ms = 15 * 1000,
  },

  debug = false,
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return options
end

return M
