-- Normal-mode keys bound in the buffers a live review can decorate: diffview
-- content buffers and working-tree files. One augroup, one buffer set, shared by
-- |review-note-preview| and |review-notes-nav| — they have the same lifetime and
-- the same eligibility rule, so they're registered together.
--
-- Deliberately NOT gated on "the current tab hosts a session": the point of both
-- features is to work while browsing the branch's files in an ordinary tab, with
-- the review sitting in a background tab. The gate is "some session is live";
-- WHICH session's notes apply is resolved per-tabpage at keypress time by
-- review.ui.highlights. With nothing under the cursor the keys just say so, so
-- binding them across the repo's buffers costs nothing.
--
-- The mappings are buffer-local and exist only for the duration of a session, so
-- they never permanently shadow the user's own keys.

local M = {}

local config_mod = require("review.config")
local state_mod = require("review.state")
local highlights = require("review.ui.highlights")

local AUGROUP = "ReviewBufferKeys"

---Key specs from config: { key, fn, desc }. A `false`/nil key is skipped, so
---each feature can be switched off individually.
---@return table[]
local function specs()
  local cfg = config_mod.get()
  local out = {}

  local preview = cfg.note_preview
  if type(preview) == "table" and preview.key and preview.key ~= "" then
    out[#out + 1] = {
      key = preview.key,
      desc = "review: preview note thread under cursor",
      fn = function() require("review.ui.note_preview").toggle() end,
    }
  end

  local nav = cfg.notes_nav
  if type(nav) == "table" then
    if nav.next and nav.next ~= "" then
      out[#out + 1] = {
        key = nav.next,
        desc = "review: next unresolved thread",
        fn = function() require("review.actions.next_note").run(1) end,
      }
    end
    if nav.prev and nav.prev ~= "" then
      out[#out + 1] = {
        key = nav.prev,
        desc = "review: previous unresolved thread",
        fn = function() require("review.actions.next_note").run(-1) end,
      }
    end
  end

  return out
end

local function any_session()
  return state_mod.sessions and next(state_mod.sessions) ~= nil
end

---@param bufnr integer
---@param list table[]
local function map_buf(bufnr, list)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  for _, spec in ipairs(list) do
    pcall(vim.keymap.set, "n", spec.key, spec.fn, {
      buffer = bufnr, silent = true, noremap = true, desc = spec.desc,
    })
  end
end

---Idempotent — one augroup serves every session.
function M.attach()
  local list = specs()
  if #list == 0 then return end
  if vim.fn.exists("#" .. AUGROUP) == 1 then return end

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function(args)
      if not any_session() then return end
      if not highlights.is_review_target(args.buf) then return end
      map_buf(args.buf, list)
    end,
  })

  -- Catch-up over every loaded buffer, not just this tab's windows: diffview
  -- laid out its own windows before we got here, AND the user very likely
  -- already had files open in the tab they were working in.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and highlights.is_review_target(b) then
      map_buf(b, list)
    end
  end
end

---Drop the hooks and the mappings. Called when the last session closes.
function M.detach()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  local list = specs()
  -- diffview's buffers go away with its view, but working-tree buffers outlive
  -- the session — their buffer-local mappings have to be removed explicitly.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    for _, spec in ipairs(list) do
      pcall(vim.keymap.del, "n", spec.key, { buffer = b })
    end
  end
end

return M
