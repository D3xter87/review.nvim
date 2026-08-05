-- Parses ```suggestion fences out of a note body and renders them as a diff.
--
-- Both forges express "replace these lines with those" differently:
--
--   GitLab   ```suggestion:-A+B   A lines ABOVE the anchor, B BELOW it, so the
--                                 replaced span is [anchor - A, anchor + B].
--                                 (review.providers.gitlab.format_suggestion
--                                 writes -0+N; the web UI can emit A > 0.)
--                                 Multi-line notes may also carry the span in
--                                 position.line_range, which wins when present.
--   GitHub   ```suggestion        Bare fence — the span lives on the COMMENT
--                                 (start_line..line), which
--                                 providers.github.pr_comment_position keeps as
--                                 position.start_new_line.
--
-- A suggestion always replaces NEW-side lines, whichever side's buffer the
-- reader happens to be in. That's why `origin` is resolved from new_path at the
-- head sha and never from the current buffer.
--
-- This module is pure: hand it a body plus a line-fetcher and it returns lines
-- and a parallel `kinds` array for the highlighter. No windows, no session.

local M = {}

---Matches a fence opener. Returns the fence length (so a longer ``` inside the
---block doesn't close it early) plus the GitLab above/below offsets.
---@param line string
---@return integer|nil fence_len
---@return integer|nil above
---@return integer|nil below
function M.parse_open(line)
  local fence, rest = line:match("^%s*(```+)%s*suggestion(.*)$")
  if not fence then return nil end
  local above, below = rest:match("^:%-(%d+)%+(%d+)%s*$")
  if above then return #fence, tonumber(above) or 0, tonumber(below) or 0 end
  if rest:match("^%s*$") then return #fence, 0, 0 end  -- GitHub / plain GitLab
  return nil  -- ```suggestionfoo — not a suggestion fence
end

---@param line string
---@param fence_len integer
---@return boolean
function M.is_close(line, fence_len)
  local f = line:match("^%s*(```+)%s*$")
  return f ~= nil and #f >= fence_len
end

---Normalizes a note body into lines. GitLab returns CRLF routinely; leaving the
---\r on would render as ^M and throw off every display-width calculation.
---Trailing blank lines are dropped so an N-note thread doesn't accumulate N
---stray rows (which would also inflate the float's height).
---@param body string|nil
---@return string[]
function M.body_lines(body)
  local s = (body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = vim.split(s, "\n", { plain = true })
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines
end

---The NEW-side span a suggestion replaces.
---@param pos table  normalized position dict
---@param above integer  A from the GitLab fence
---@param below integer  B from the GitLab fence
---@return integer|nil from, integer|nil to
local function replaced_span(pos, above, below)
  -- GitLab multi-line notes carry the authoritative span; the fence is only a
  -- rendering hint, so prefer line_range when the provider passed it through.
  local lr = pos.line_range
  if type(lr) == "table" then
    local from = tonumber(lr.start and lr.start.new_line)
    local to = tonumber(lr["end"] and lr["end"].new_line)
    if from and to and to >= from then return from, to end
  end

  local anchor = tonumber(pos.new_line)
  if not anchor then return nil end  -- note on a removed line: nothing to replace

  local start_new = tonumber(pos.start_new_line)
  if start_new and start_new <= anchor then
    return start_new, anchor  -- GitHub: anchored on the END of the range
  end
  return anchor - above, anchor + below  -- GitLab: anchored on the START
end

---Slices `origin` for the span, reporting how well it fit.
---@param origin string[]|nil
---@param from integer
---@param to integer
---@return string[]|nil lines, string status  "ok"|"clipped"|"out_of_range"|"unavailable"
local function original_lines(origin, from, to)
  if not origin then return nil, "unavailable" end
  local n = #origin
  from = math.max(1, from)
  if from > n then return nil, "out_of_range" end
  local clipped = to > n
  to = math.min(to, n)
  local out = {}
  for i = from, to do out[#out + 1] = origin[i] end
  return out, clipped and "clipped" or "ok"
end

---Renders a note body: prose passes through, suggestion fences become a
---`-`/`+` diff. Degrades to a labelled `+`-only block when the original lines
---can't be recovered — never falls back to showing the raw fence, and never
---shows a bare `+` block unlabelled (that would be indistinguishable from a
---genuine pure addition).
---@param body string|nil
---@param pos table|nil  the thread anchor's normalized position
---@param origin_fn fun(): string[]|nil  lazy NEW-side source at the head rev
---@return string[] lines
---@return string[] kinds  per line: "text"|"label"|"removed"|"added"
function M.render(body, pos, origin_fn)
  local src = M.body_lines(body)
  local lines, kinds = {}, {}
  local function push(text, kind)
    lines[#lines + 1] = text
    kinds[#kinds + 1] = kind
  end

  local origin, origin_done = nil, false
  local function origin_once()
    if not origin_done then
      origin_done = true
      origin = origin_fn and origin_fn() or nil
    end
    return origin
  end

  local i = 1
  while i <= #src do
    local fence_len, above, below = M.parse_open(src[i])
    if not fence_len then
      push(src[i], "text")
      i = i + 1
    else
      -- Collect the block body up to the matching close (or end of note).
      local proposed = {}
      i = i + 1
      while i <= #src and not M.is_close(src[i], fence_len) do
        proposed[#proposed + 1] = src[i]
        i = i + 1
      end
      i = i + 1  -- step over the closing fence

      local removed, status = nil, "unavailable"
      local from, to = nil, nil
      if type(pos) == "table" then
        from, to = replaced_span(pos, above or 0, below or 0)
      end
      if from and to then
        removed, status = original_lines(origin_once(), from, to)
      end

      if removed and #removed > 0 then
        push("Suggested change:", "label")
        for _, l in ipairs(removed) do push("- " .. l, "removed") end
      else
        push("Suggested change (original lines unavailable):", "label")
      end
      for _, l in ipairs(proposed) do push("+ " .. l, "added") end
      if status == "clipped" then
        push("  … original truncated at end of file", "label")
      end
    end
  end

  return lines, kinds
end

return M
