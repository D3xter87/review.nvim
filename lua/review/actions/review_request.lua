-- :ReviewRequest — list open MRs/PRs in the current repo where you are a
-- requested reviewer, then open the chosen one (auto-open on a single hit).

local M = {}

function M.run()
  require("review.controller").pick_and_open(
    function(provider, remote, cb) provider.fetch_review_requested(remote, cb) end,
    "no open MRs awaiting your review in this repo")
end

return M
