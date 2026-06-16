local M = {}

local netrc = require("cicd.http.netrc")

local ENV_VAR = {
  gitlab = "GITLAB_TOKEN",
  github = "GITHUB_TOKEN",
}

function M.get_token(host, provider_name, cfg)
  local providers = cfg and cfg.providers or {}
  local explicit = providers[provider_name] and providers[provider_name].token
  if explicit and explicit ~= "" then
    return explicit
  end

  local from_netrc = netrc.resolve(host)
  if from_netrc and from_netrc ~= "" then
    return from_netrc
  end

  local env_name = ENV_VAR[provider_name]
  if env_name then
    local from_env = vim.env[env_name]
    if from_env and from_env ~= "" then
      return from_env
    end
  end

  return nil, string.format(
    "No token for %s (host %s). Add entry to ~/.netrc or set $%s",
    provider_name, host, env_name or "<TOKEN>"
  )
end

function M.headers_for(provider_name, token)
  if provider_name == "gitlab" then
    return { ["PRIVATE-TOKEN"] = token, ["Content-Type"] = "application/json" }
  elseif provider_name == "github" then
    return {
      ["Authorization"] = "Bearer " .. token,
      ["Accept"] = "application/vnd.github+json",
      ["X-GitHub-Api-Version"] = "2022-11-28",
      ["Content-Type"] = "application/json",
    }
  end
  return {}
end

return M
