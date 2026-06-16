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
