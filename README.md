# review.nvim

End-to-end Merge Request / Pull Request review inside Neovim. Opens the
MR/PR diff under [diffview.nvim](https://github.com/sindrets/diffview.nvim),
adds a sliding bottom panel for commits / metadata / discussion threads,
and lets you approve, comment, suggest, resolve, merge — without leaving
the editor.

Supports **GitLab** (REST API v4) and **GitHub** (REST + minimal GraphQL)
with feature parity.

## What it does

- `:Review [branch|!iid]` opens diffview for the MR's `base...head` range
  in a new tab; bottom split shows commits / info / notes (rotating).
- Visual selection in the diff + `c` / `s` posts an inline comment or a
  suggestion (the suggestion's input is **prefilled with the selected
  code** so you just edit it).
- `:ReviewNotes` lists every comment / suggestion / review summary
  (GitHub merges issue + review comments + reviews into one stream).
  Resolve threads (`r` / `R`), reply (`a`), edit / delete, cursor-tracked
  auto-scroll as you move through the diff.
- `<leader>rp` on any line with a gutter icon opens a **float with the whole
  thread** — in the diff, *and* on your normal working-tree files in **any
  tab** while the review sits in a background tab (matched by the checked-out
  branch). Press again to move the cursor into it, then `r` toggles resolve
  and `a` replies; `q`/`<Esc>` closes. Suggestions render as a real `-`/`+`
  diff instead of a raw ` ```suggestion ` fence.
- `]r` / `[r` walk the **unresolved (❌) threads** straight from the code —
  current file first, then on into the next file that still has some,
  wrapping at the end. Works in the diff and while browsing the branch
  locally.
- `:ReviewInfo` shows title, description, assignees, reviewers, labels,
  milestone, estimate + spent time (GitLab only), participants, draft
  toggle. Each section is editable (`e`) — text input or checkbox picker.
- The Info panel header carries an `auto-merge` marker while the MR is
  **armed for auto-merge** (merge once the pipeline / required checks pass).
  Arm or cancel it from `:ReviewMerge`. Works for auto-merges scheduled by
  anyone, not just from this plugin.
- Spent time is one input field prefilled with the current total, where the
  **sign picks the operation**: `1h30m` sets it, `+30m` adds, `-30m`
  subtracts, `0` clears. Reachable with `e` on the **Spent time** section
  or directly via `:ReviewTime [branch|!iid] [duration]` —
  `:ReviewTime +1h` logs an hour without opening the panel.
- Opt-in `spent_time_refs_line` keeps a smart-commit trailer at the bottom
  of the MR description in sync with the total: `refs CVNT-3456-FEAT #time
  1h 30m` (source branch uppercased). Edited in place, never duplicated,
  and removed when the total hits zero.
- `:ReviewMerge` opens a merge dialog with **Delete source branch /
  Squash / Edit commit message** checkboxes and **Merge now / Set
  auto-merge** actions.
- `:ReviewApprove`, `:ReviewRevoke`, `:ReviewMerge`, `:ReviewClose`,
  `:ReviewOpen` all accept an optional `[branch|!iid]` argument so you
  can act on any MR/PR without losing the active review session.

## Quick example

```vim
git checkout feature/login

:Review                    " start a review session for the current branch

" bottom panel
:ReviewInfo                " switch panel to MR info — press 'e' on a section
:ReviewCommits             " switch to commits — <CR> opens commit diff
:ReviewNotes               " switch to discussion threads

" inside the diff window, in visual mode:
c                          " add a line/range comment
s                          " add a suggestion (input pre-filled with code)

" actions on the active MR
:ReviewApprove             " approve
:ReviewMerge               " open merge dialog
:ReviewClose               " close MR (with optional farewell comment)

" out-of-band actions on a different MR — session stays open
:ReviewApprove !319
:ReviewMerge feature/foo
```

End the session with `q` in the bottom panel or by closing the diffview
tab.

## Installation

`lazy.nvim`:

```lua
{
  "D3xter87/review.nvim",
  dependencies = { "sindrets/diffview.nvim" },
  cmd = {
    "Review", "ReviewOpen",
    "ReviewApprove", "ReviewRevoke",
    "ReviewInfo", "ReviewCommits", "ReviewNotes",
    "ReviewMerge", "ReviewClose", "ReviewTime",
  },
  opts = {},
}
```

Requirements:

- Neovim 0.10+
- system `curl` on PATH
- a personal access token for the forge (see Authentication)

## Authentication

Token lookup, first hit wins:

1. `opts.providers.<name>.token` from `setup()`.
2. `~/.netrc` (or `%USERPROFILE%\_netrc` on Windows). For `github.com`
   the host is `api.github.com`:
   ```
   machine api.github.com
     login   <ignored>
     password ghp_XXXXXXXXXXXXXXXX
   ```
3. Environment variables `$GITLAB_TOKEN` / `$GITHUB_TOKEN`.

Required scopes:

- **GitLab**: `api` (write access for approve / merge / comment).
- **GitHub**: `repo` for private, `public_repo` for public. The same
  token is used for REST and GraphQL.

## Example configuration

```lua
require("review").setup({
  providers = {
    -- explicit per-provider override; rarely needed
    -- gitlab = { token = vim.env.WORK_GITLAB_TOKEN },
  },

  host_providers = {
    -- force a provider for hostnames the heuristics miss
    -- ["ghes.example.com"] = "github",
    -- ["ci.intranet"]      = "gitlab",
  },

  host_schemes = {
    -- override the API URL scheme (e.g. self-hosted GitLab on plain HTTP)
    -- ["gitlab.intranet"] = "http",
  },

  host_bases = {
    -- full API base URL override (useful for GitHub Enterprise);
    -- the GraphQL endpoint is derived automatically as <base>/graphql
    -- ["ghes.example.com"] = "https://ghes.example.com/api/v3",
  },

  panel = {
    height = 12,  -- bottom panel height in lines
  },

  -- Float with the thread anchored to the cursor's line.
  note_preview = {
    key         = "<leader>rp",  -- false = don't map anything
    border      = "rounded",
    max_width   = 80,
    max_height  = 20,
    resolve_key = "r",  -- inside the float: toggle resolve
    reply_key   = "a",  -- inside the float: reply
  },

  -- Jump between unresolved (❌) threads from the code.
  notes_nav = {
    next = "]r",
    prev = "[r",
  },

  -- Notification verbosity. "quiet" (default) only shows event
  -- confirmations ("!42 merged"), warnings and errors. "verbose" also
  -- shows progress chatter ("looking up MRs...", "merging...").
  notify = "quiet",

  -- Background watcher for scheduled auto-merges.
  auto_merge_watcher = {
    enabled          = true,
    poll_interval_ms = 30 * 1000,         -- 30 seconds
    timeout_ms       = 60 * 60 * 1000,    -- 1 hour
  },

  -- Mirror the total spent time into a "refs <BRANCH> #time <total>"
  -- trailer at the bottom of the MR description. Off by default.
  spent_time_refs_line = {
    enabled = false,
  },
})
```

## Multi-session

Each `:Review` opens an independent session in its own tab — you can have
many running at once (one per MR/PR). Subcommands without arguments
operate on the session in the focused tab. Subcommands with an argument
(`!iid` or `branch`) act "out-of-band" on the targeted MR without
touching whatever session is already open.

UI commands (`:ReviewInfo` / `:ReviewCommits` / `:ReviewNotes`) double as
shortcuts for "open this MR with that panel up front":

```vim
:ReviewNotes !100   " if !100 has a session, focus its tab + switch panel;
                    " otherwise start a new session pre-set to Notes mode.
```

## Commands at a glance

| Command          | What it does                                             |
|------------------|----------------------------------------------------------|
| `:Review [arg]`  | Start a review session for ANY MR state (opened/closed/merged); HEAD / branch / `!<iid>`. |
| `:ReviewOpen`    | Reopen a closed MR/PR and start a session.               |
| `:ReviewApprove` | Approve. Without arg targets the active session or picks from current branch. |
| `:ReviewRevoke`  | Revoke approval (GitHub: dismiss your latest APPROVED review). |
| `:ReviewMerge`   | Open merge dialog (squash / delete src / auto-merge).    |
| `:ReviewRebase`  | Rebase source onto target + auto-push (worktree, no local branch change). |
| `:ReviewWeb`     | Open MR/PR in the default browser (works for any state). |
| `:ReviewRequest` | List open MRs/PRs where you're a requested reviewer, then open one. |
| `:ReviewMine`    | List your own open MRs/PRs (assignee or author), then open one. |
| `:ReviewClose`   | Close MR with an optional farewell comment.              |
| `:ReviewTime`    | Spent time. Sign picks the op: `1h` sets, `+1h` adds, `-1h` subtracts, `0` clears. No arg → prompt prefilled with the current total. GitLab only. |
| `:ReviewInfo`    | Bottom panel — MR metadata, editable sections.           |
| `:ReviewCommits` | Bottom panel — commits, `<CR>` opens commit diff.        |
| `:ReviewNotes`   | Bottom panel — every thread / note / suggestion.         |

Notes panel keys: `<CR>` jump · `a` reply · `c` global · `d` delete ·
`e` edit · `r` toggle resolve · `R` toggle resolve all · `s` cycle sort ·
`q` end review.

Always-on panel keys (any mode): `]` next mode · `[` prev mode · `q` end
review. Mode order: info → commits → notes (wraps).

Notes use native vim folds (`za`/`zo`/`zc`/`zM`/`zR`). Default is "all
collapsed"; cursor movement in the diffview windows auto-expands the
single thread anchored to the current line and collapses everything else.
Sort modes cycled with `s`: status (unresolved first, default) → file →
date → author.

Diff visual-mode keys: `c` line comment · `s` suggestion (prefilled with
selected code).

Note preview (`<leader>rp`, configurable via `note_preview.key`): float with
the full thread, available wherever a gutter icon is — diff buffers, and your
working-tree files in any tab while the review runs in a background tab
(which review applies is decided by the checked-out branch, so a second
unrelated session can't bleed into it). First press opens it without stealing
the cursor, second press moves into it, `q`/`<Esc>` closes; moving the cursor
in the origin window dismisses it. Suggestions are shown as a `-`/`+` diff,
with the replaced lines read from the MR's head commit (never from a
possibly-dirty working-tree buffer).

Inside the float: `r` toggles resolve on the thread under the cursor (it
re-renders in place, so ❌ → ✅ happens in front of you), `a` replies. Edit
and delete stay panel-only.

Unresolved-thread navigation: `]r` / `[r` (`notes_nav.next` / `.prev`) stop
only on ❌ threads, ordered by file then line, continuing into the next file
that still has some and wrapping at the end.

Icons in panel + gutter:
- 💬 non-resolvable note (issue / review / global) — informational
- ❌ resolvable thread, unresolved
- ✅ resolvable thread, fully resolved

## Help

After installation:

```vim
:help review
```

## License

MIT — see [LICENSE](./LICENSE).
