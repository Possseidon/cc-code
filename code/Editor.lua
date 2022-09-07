local lexLua = require "code.lexers.lexLua"
local Highlighter = require "code.Highlighter"

local Editor = {}

function Editor:new()
  self._lines = {
    text = {},
    state = {},
    blit = {
      text = {},
      color = {},
      background = {},
    },
  }
  self._selection = nil
  self._selectionStart = nil
  self._mouseDown = false
  self._cursor = { x = 1, y = 1 }
  self._scroll = { x = 0, y = 0 }
  self._highlighter = Highlighter(require "code.highlighter.vscode")
  self._history = {}
  self._historyIndex = 0
end

function Editor:invalidateLine(line)
  local state = self._lines.state
  for i = line, #state do
    state[i] = nil
  end
end

function Editor:getCursor()
  return self._cursor.x, self._cursor.y
end

function Editor:canUndo()
  return self._historyIndex > 0
end

function Editor:undo()
  if self:canUndo() then
    self._history[self._historyIndex].revert(self)
    self._historyIndex = self._historyIndex - 1
  end
end

function Editor:canRedo()
  return self._historyIndex < #self._history
end

function Editor:redo()
  if self:canRedo() then
    self._historyIndex = self._historyIndex + 1
    self._history[self._historyIndex].execute(self)
  end
end

function Editor:record(execute, revert)
  for i = self._historyIndex + 1, #self._history do
    self._history[i] = nil
  end
  table.insert(self._history, { execute = execute, revert = revert })
  self:redo()
end

function Editor:modifyLine(line, text, cursorX, cursorY)
  local original = self._lines.text[line]
  local originalX, originalY = self:getCursor()
  self:record(function(editor)
    editor:invalidateLine(line)
    editor._lines.text[line] = text
    editor:setCursor(cursorX, cursorY)
  end, function(editor)
    editor:invalidateLine(line)
    editor._lines.text[line] = original
    editor:setCursor(originalX, originalY)
  end)
end

function Editor:insert(text)
  local x, y = self:getCursor()
  local line = self._lines.text[y]
  if x > #line + 1 then
    local pad = x - #line - 1
    self:modifyLine(y, line .. (" "):rep(pad) .. text, x + #text, y)
  else
    self:modifyLine(y, line:sub(1, x - 1) .. text .. line:sub(x), x + #text, y)
  end
end

function Editor:remove(left, right)
  local x, y = self:getCursor()
  local line = self._lines.text[y]
  if x + left > #line + 1 then
    self:setCursor(x + left - 1, y)
  else
    self:modifyLine(y, line:sub(1, x + left - 2) .. line:sub(x + right), x + left - 1, y)
  end
end

function Editor:backspace()
  -- TODO: Check for selection
  local x, _y = self:getCursor()
  if x == 1 then
    -- TODO: Merge lines
  else
    self:remove(0, 0)
  end
end

function Editor:delete()
  -- TODO: Check for selection
  local x, y = self:getCursor()
  if x > #self._lines.text[y] then
    -- TODO: Merge lines
  else
    self:remove(1, 1)
  end
end

function Editor:scrollTo(x, y)
  local oldX, oldY = self._scroll.x, self._scroll.y
  self._scroll.x = math.max(0, x)
  self._scroll.y = math.min(math.max(0, y), #self._lines.text - 1)
  if self._mouseDown then
    self._cursor.x = self._cursor.x - oldX + self._scroll.x
    self._cursor.y = self._cursor.y - oldY + self._scroll.y
  end
end

function Editor:scrollBy(dx, dy)
  self:scrollTo(self._scroll.x + dx, self._scroll.y + dy)
end

function Editor:screenToClient(x, y)
  return x + self._scroll.x, y + self._scroll.y
end

function Editor:clientToScreen(x, y)
  return x - self._scroll.x, y - self._scroll.y
end

function Editor:makeCursorVisible()
  local width, height = term.getSize()
  self:scrollTo(
    math.max(math.min(self._scroll.x, self._cursor.x - 1), self._cursor.x - width),
    math.max(math.min(self._scroll.y, self._cursor.y - 1), self._cursor.y - height)
  )
end

function Editor:setCursor(x, y, select)
  self._selectionStart = select and (self._selectionStart or { x = self._cursor.x, y = self._cursor.y }) or nil
  self._cursor.x = math.max(1, x or self._cursor.x)
  self._cursor.y = math.min(math.max(1, y or self._cursor.y), #self._lines.text)
  self:makeCursorVisible()
  if select then
    self:select(self._selectionStart, self._cursor)
  else
    self._selection = nil
  end
end

function Editor:moveCursor(dx, dy, select)
  self:setCursor(self._cursor.x + dx, self._cursor.y + dy, select)
end

function Editor:click(x, y)
  self:setCursor(self:screenToClient(x, y))
  self._mouseDown = true
end

function Editor:release()
  self._mouseDown = false
end

function Editor:select(start, stop)
  if start.y > stop.y or start.y == stop.y and start.x > stop.x then
    start, stop = stop, start
  end
  self._selection = {
    start = start,
    stop = stop,
  }
end

function Editor:drag(x, y)
  x, y = self:screenToClient(x, y)
  self:setCursor(x, y, true)
end

function Editor:loadFromFile(filename)
  local file = fs.open(filename, "rb")
  local content = file.readAll()
  file.close()
  local lines = {}
  local pos = 1
  while true do
    local nextLineBreak = content:find("\n", pos, true)
    if nextLineBreak then
      table.insert(lines, content:sub(pos, nextLineBreak - 1))
      pos = nextLineBreak + 1
    else
      table.insert(lines, content:sub(pos))
      break
    end
  end
  self._lines.text = lines
end

function Editor:getLineHighlighting(line)
  local lines = self._lines
  local highlighter = self._highlighter

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
      local textSegments = {}
      local colorSegments = {}
      local backgroundSegments = {}
      for token, kind, subKind in lexLua.tokenize(lines.text[i], state) do
        local text, color, background = highlighter:highlight(token, kind, subKind)
        assert(#text == #token and #color == #token and #background == #token,
          "highlighted token must have the same length")
        table.insert(textSegments, text)
        table.insert(colorSegments, color)
        table.insert(backgroundSegments, background)
      end
      lines.blit.text[i] = table.concat(textSegments)
      lines.blit.color[i] = table.concat(colorSegments)
      lines.blit.background[i] = table.concat(backgroundSegments)
      lines.state[i] = state:copy()
    end
  end

  local text, color, background = lines.blit.text[line], lines.blit.color[line], lines.blit.background[line]

  local selection = self._selection
  if selection then
    local selectionColor = colors.toBlit(colors.blue)

    local left = line == selection.start.y and selection.start.x or line > selection.start.y and 1 or #background + 2
    local right = line == selection.stop.y and selection.stop.x or line < selection.stop.y and #background + 2 or 1

    left = math.min(math.max(left, 1), #background + 2)
    right = math.min(math.max(right, 1), #background + 2)

    background = background:sub(1, left - 1) .. selectionColor:rep(right - left) .. background:sub(right)
  end

  return text, color, background
end

function Editor:getBlitLine(line)
  local width, _height = term.getSize()
  local scroll = self._scroll.x

  local function makeBlit(text, fill)
    if scroll < 0 then
      -- left pad
      text = fill:rep(-scroll) .. text
    else
      -- left cutoff
      text = text:sub(1 + scroll)
    end
    if #text < width then
      -- right pad
      return text .. fill:rep(width - #text)
    else
      -- right cutoff
      return text:sub(1, width)
    end
  end

  local text, color, background = self:getLineHighlighting(line)
  return makeBlit(text, " "), makeBlit(color, "0"), makeBlit(background, "f")
end

function Editor:render()
  term.setCursorBlink(false)

  local _width, height = term.getSize()
  for i = 1, height do
    local line = i + self._scroll.y
    term.setCursorPos(1, i)
    if line < 1 then
      term.clearLine()
    elseif line > #self._lines.text then
      term.clearLine()
    else
      term.blit(self:getBlitLine(line))
    end
  end

  term.setCursorPos(self:clientToScreen(self:getCursor()))
  term.setCursorBlink(true)
end

function Editor:cursorPreviousLine(shift)
  local _x, y = self:getCursor()
  if y > 1 then
    self:setCursor(#self._lines.text[y - 1] + 1, y - 1, shift)
  end
end

function Editor:cursorLeft(shift)
  local x, y = self:getCursor()
  if x > 1 then
    self:setCursor(x - 1, nil, shift)
  else
    self:cursorPreviousLine(shift)
  end
end

function Editor:findWordLeft()
  local x, y = self:getCursor()
  if x == 1 then
    return nil
  end
  local line = self._lines.text[y]
  x = math.min(x, #line + 1)
  while x > 1 and line:sub(x - 1, x - 1):find("[^%w_]") do x = x - 1 end
  while x > 1 and line:sub(x - 1, x - 1):find("[%w_]") do x = x - 1 end
  return x
end

function Editor:cursorWordLeft(shift)
  local x = self:findWordLeft()
  if x then
    self:setCursor(x, nil, shift)
  else
    self:cursorLeft(shift)
  end
end

function Editor:cursorRight(shift)
  self:moveCursor(1, 0, shift)
end

function Editor:cursorNextLine(shift)
  local _x, y = self:getCursor()
  self:setCursor(1, y + 1, shift)
end

function Editor:findWordRight()
  local x, y = self:getCursor()
  local line = self._lines.text[y]
  if x > #line then
    return nil
  end
  return line:find("%f[%w_]", x + 1) or #line + 1
end

function Editor:cursorWordRight(shift)
  local x = self:findWordRight()
  if x then
    self:setCursor(x, nil, shift)
  else
    self:cursorNextLine(shift)
  end
end

function Editor:cursorLineHome(shift)
  self:setCursor(1, self._cursor.y, shift)
end

function Editor:cursorDocumentHome(shift)
  self:setCursor(1, 1, shift)
end

function Editor:cursorLineEnd(shift)
  self:setCursor(#self._lines.text[self._cursor.y] + 1, self._cursor.y, shift)
end

function Editor:cursorDocumentEnd(shift)
  local y = #self._lines.text
  self:setCursor(#self._lines.text[y] + 1, y, shift)
end

return require "code.class" (Editor)
