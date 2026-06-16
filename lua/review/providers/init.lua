local M = {}

local REGISTRY = {
  gitlab = "review.providers.gitlab",
  github = "review.providers.github",
}

function M.get(name)
  local mod = REGISTRY[name]
  if not mod then
    error("review: unknown provider: " .. tostring(name))
  end
  return require(mod)
end

function M.detect(host, cfg)
  cfg = cfg or {}
  host = (host or ""):lower()

  if cfg.host_providers and cfg.host_providers[host] then
    return cfg.host_providers[host]
  end

  if host == "github.com" or host:match("^ghes%.") then
    return "github"
  end
  if host:match("^gitlab%.") or host:match("gitlab") then
    return "gitlab"
  end

  return "gitlab"
end

return M
