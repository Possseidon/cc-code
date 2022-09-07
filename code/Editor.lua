local lexLua = require "code.lexers.lexLua"

local Editor = {}

function Editor:new()
  self.lines = {
    text = {},
    color = {},
    background = {},
    state = {},
  }
  self.cursor = { x = 1, y = 1 }
  self.scroll = { x = 0, y = 0 }
end

function Editor:loadFromFile(filename)
  local lines = {}
  for line in io.lines(filename) do
    table.insert(lines, line)
  end
  self.lines = lines
end

function Editor:getLineHighlighting(line)
  local lines = self.lines

  if not lines.state[line] then
    local state = nil
    local lastLine = 0
    for i = line - 1, 1, -1 do
      state = lines.state[i]
      if state then
        lastLine = i
        break
      end
    end

    state = state and state:copy() or lexLua.State.new()

    for i = lastLine + 1, line do
      local color = {}
      local background = {}
      for token, kind, subKind in lexLua.tokenize(lines.text[i], state) do
        -- TODO: Make char dependent on kind and subKind
        table.insert(color, ("f"):rep(#token))
        table.insert(background, ("0"):rep(#token))
      end
      lines.color[i] = table.concat(color)
      lines.background[i] = table.concat(background)
      state[i] = state:copy()
    end
  end

  return lines.color[line], lines.background[line]
end

function Editor:render()
  local _width, height = term.getSize()
  for i = 1, height do
    local line = i + self.scroll.y
    term.setCursorPos(1, i)
    term.blit(self.lines.text[line], self:getLineHighlighting(line))
  end
end

return require "code.class" (Editor)
