-- Centralized notify helper.
--
-- Categories:
--   * event(msg)    hard confirmation, always shown (e.g. "!42 merged")
--   * progress(msg) low-value chatter (e.g. "looking up MRs..."), shown only
--                   when cfg.notify == "verbose"
--   * warn(msg)     always shown
--   * err(msg)      always shown
--
-- The default `cfg.notify = "quiet"` makes the plugin emit only events,
-- warnings and errors — typical "what just happened" feedback without the
-- progress chatter that floods notification queues during action sequences.

local M = {}

local function notify_cfg()
  -- Inline require to avoid a load-time cycle if config pulls anything from
  -- this module in the future.
  return require("review.config").get()
end

local function send(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Review" })
end

---Hard confirmation — always shown.
---@param msg string
function M.event(msg) send(msg, vim.log.levels.INFO) end

---Progress / chatter — shown only in verbose mode.
---@param msg string
function M.progress(msg)
  if (notify_cfg().notify or "quiet") ~= "verbose" then return end
  send(msg, vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg) send(msg, vim.log.levels.WARN) end

---@param msg string
function M.err(msg) send(msg, vim.log.levels.ERROR) end

---Convenience: routes legacy `notify(msg, level)` calls through the right
---channel. INFO defaults to `event` (always shown). For progress messages
---callers should use M.progress directly.
---@param msg string
---@param level integer|nil
function M.legacy(msg, level)
  if level == vim.log.levels.WARN then return M.warn(msg) end
  if level == vim.log.levels.ERROR then return M.err(msg) end
  return M.event(msg)
end

return M
