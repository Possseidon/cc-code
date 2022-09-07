local Highlighter = {}

function Highlighter:new(config)
  self._config = config
end

function Highlighter:highlight(token, kind, subKind)
  local config = self._config
  local color = config and config[kind] and (config[kind][subKind] or config[kind][1]) or colors.white
  local background = colors.black
  return token, colors.toBlit(color):rep(#token), colors.toBlit(background):rep(#token)
end

return require "code.class" (Highlighter)
