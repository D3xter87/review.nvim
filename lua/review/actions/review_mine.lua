-- :ReviewMine — list open MRs/PRs in the current repo that are "mine"
-- (you are the assignee OR the author), then open the chosen one
-- (auto-open on a single hit).

local M = {}

function M.run()
  require("review.controller").pick_and_open(
    function(provider, remote, cb) provider.fetch_review_mine(remote, cb) end,
    "no open MRs assigned to or authored by you in this repo")
end

return M
