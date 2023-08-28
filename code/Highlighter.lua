---@class Highlighter
local Highlighter = {}

function Highlighter:new(config)
  self._config = config
end

---Returns `term.blit` parameters for the given token.
---@param token string
---@param kind string
---@param subKind string
---@return string text, string color, string background
function Highlighter:highlight(token, kind, subKind)
  local config = self._config
  local color = config and config[kind] and (config[kind][subKind] or config[kind][1]) or colors.white
  local background = colors.black
  return token, colors.toBlit(color):rep(#token), colors.toBlit(background):rep(#token)
end

---@type fun(config: table<string, any>): Highlighter
local new = require "code.class" (Highlighter)
return new
