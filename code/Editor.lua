local lexLua = require "code.lexers.lexLua"
local Highlighter = require "code.Highlighter"

---@class Point
---@field x integer
---@field y integer

table.move = table.move or function(from, fromStart, fromEnd, toStart, to)
  to = to or from
  if from ~= to or fromStart ~= toStart then
    if fromStart < toStart then
      for i = fromEnd, fromStart, -1 do
        to[i - fromStart + toStart] = from[i]
      end
    else
      for i = fromStart, fromEnd do
        to[i - fromStart + toStart] = from[i]
      end
    end
  end
  return to
end

---Splits the given string on linebreaks.
---
---Returns an empty table when passed nil.
---
---@param text string?
---@return string[]
local function splitLines(text)
  if not text then return {} end
  local lines = {}
  local pos = 1
  while true do
    local nextLineBreak = text:find("\n", pos, true)
    if nextLineBreak then
      table.insert(lines, text:sub(pos, nextLineBreak - 1))
      pos = nextLineBreak + 1
    else
      table.insert(lines, text:sub(pos))
      break
    end
  end
  return lines
end

---Merges the given table of lines into a single string with linebreaks.
---
---Similar to splitLines, an empty table returns nil.
---
---@param lines string[]
---@param from integer?
---@param to integer?
---@return string?
local function mergeLines(lines, from, to)
  -- Technically this should also work, but CC's table.concat implementation is broken regarding nil.
  -- return #lines > 0 and table.concat(lines, "\n", from, to) or nil
  return #lines > 0 and table.concat(lines, "\n", from or 1, to or #lines) or nil
end

---@class Editor
local Editor = {}

function Editor:new()
  self._lines = {
    text = { "" },
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
  self._history = {}
  self._revision = 0

  -- TODO: make dynamic
  self._highlighter = Highlighter(require "code.highlighter.vscode")
  -- TODO: optional/configurable lexer

  -- TODO: move to config
  self._visibleLines = { above = 3, below = 1 }
  self._lineNumberWidth = 3
  self._tabWidth = 2
end

---Invalidates the given line, and in turn everything after as well.
---@param line integer
function Editor:invalidateLine(line)
  local state = self._lines.state
  for i = line, #state do
    state[i] = nil
  end
end

---The current cursor position.
---@return integer x, integer y
function Editor:getCursor()
  return self._cursor.x, self._cursor.y
end

---Whether the undo history contains any entry.
---@return boolean
function Editor:canUndo()
  return self._revision > 0
end

---Reverts the most recent change if possible.
function Editor:undo()
  if self:canUndo() then
    self._history[self._revision].revert(self)
    self._revision = self._revision - 1
  end
end

---Whether the undo history contains any entries that were previously undone.
function Editor:canRedo()
  return self._revision < #self._history
end

---Plays back a single step of the undo history if possible.
function Editor:redo()
  if self:canRedo() then
    self._revision = self._revision + 1
    self._history[self._revision].execute(self)
  end
end

---Records and immediately executes an undoable action.
---
---Also clears any history that would cause a fork.
---
---@param execute fun(editor: Editor)
---@param revert fun(editor: Editor)
function Editor:record(execute, revert)
  for i = self._revision + 1, #self._history do
    self._history[i] = nil
  end
  table.insert(self._history, { execute = execute, revert = revert })
  self:redo()
end

---Creates a new function that replaces a range of lines.
---
---Meant to be used as parameter to `Editor:record()`.
---
---@param from integer The starting line index to modify.
---@param to integer The ending line index to modify.
---@param text string? The new text to insert.
---@param cursorX integer The X-coordinate of the cursor position after the modification.
---@param cursorY integer The Y-coordinate of the cursor position after the modification.
---@return fun(editor: Editor) modifier A function that modifies the editor's text and cursor position.
local function makeModifier(from, to, text, cursorX, cursorY)
  return function(editor)
    local lines = splitLines(text)
    local delta = #lines - (to - from + 1)
    table.move(editor._lines.text, to + 1, #editor._lines.text, to + 1 + delta)
    for i = #editor._lines.text + delta + 1, #editor._lines.text do
      editor._lines.text[i] = nil
    end
    table.move(lines, 1, #lines, from, editor._lines.text)

    editor:invalidateLine(from)
    editor:setCursor(cursorX, cursorY)
    editor:makeCursorVisible()
  end
end


---Undoably replaces the given range of lines with the given text.
---@param from integer The starting line index to modify.
---@param to integer The ending line index to modify.
---@param text string? The text to replace the lines with.
---@param cursorX integer The X-coordinate of the cursor position after the modification.
---@param cursorY integer The Y-coordinate of the cursor position after the modification.
function Editor:replaceLines(from, to, text, cursorX, cursorY)
  local delta = #splitLines(text) - (to - from + 1)
  self:record(
    makeModifier(from, to, text, cursorX, cursorY),
    makeModifier(from, to + delta, mergeLines(self._lines.text, from, to), self:getCursor()))
end

---Undoably replaces a single line with the given text.
---@param line integer
---@param text string?
---@param cursorX integer
---@param cursorY integer
function Editor:modifyLine(line, text, cursorX, cursorY)
  self:replaceLines(line, line, text, cursorX, cursorY)
end

---Undoable removes the given line.
---
---This is just a shorthand for passing `nil` as text for `Editor:modifyLine()`.
---
---@param line integer
---@param cursorX integer
---@param cursorY integer
function Editor:removeLine(line, cursorX, cursorY)
  self:replaceLines(line, line, nil, cursorX, cursorY)
end

---Inserts the given text at the current cursor position.
---@param text string?
function Editor:insert(text)
  local lines = splitLines(text)
  local x, y = self:getCursor()
  local cursorX = #lines > 1 and #lines[#lines] or x + #text
  local original = self._lines.text[y]
  if x > #original + 1 then
    local pad = x - #original - 1
    self:modifyLine(y, original .. (" "):rep(pad) .. text, cursorX, y + #lines - 1)
  else
    self:modifyLine(y, original:sub(1, x - 1) .. text .. original:sub(x), cursorX, y + #lines - 1)
  end
end

---Removes the given range of characters in the current line and moves the cursor to where the text was deleted.
---@param from integer
---@param to integer
function Editor:remove(from, to)
  local _x, y = self:getCursor()
  local line = self._lines.text[y]
  self:modifyLine(y, line:sub(1, from - 1) .. line:sub(to + 1), from, y)
end

---Removes a range of characters relative to the current cursor.
---
---Properly deals with the cursor being past the end of the line.
---
---@param left integer
---@param right integer
function Editor:removeRelative(left, right)
  local x, y = self:getCursor()
  local line = self._lines.text[y]
  if x + left > #line + 1 then
    self:setCursor(x + left - 1, y)
    self:makeCursorVisible()
  else
    self:remove(x + left, x + right)
  end
end

---Does what one would expect from hitting backspace in an editor.
---
---In other words, deletes the character before the cursor and moves the cursor to the left.
---Also joins lines if the cursor is on the first character of the line.
function Editor:backspace()
  -- TODO: check for selection
  local x, y = self:getCursor()
  if x ~= 1 then
    self:removeRelative(-1, -1)
  elseif y ~= 1 then
    self:replaceLines(y - 1, y, self._lines.text[y - 1] .. self._lines.text[y], #self._lines.text[y - 1] + 1, y - 1)
  end
end

---Does what one would expect from hitting delete in an editor.
---
---In other words, deletes the character after the cursor without moving the cursor.
---Also joins lines if the cursor is past the end of the line.
function Editor:delete()
  -- TODO: check for selection
  local x, y = self:getCursor()
  if x <= #self._lines.text[y] then
    self:removeRelative(0, 0)
  elseif y ~= #self._lines.text then
    self:replaceLines(y, y + 1, self._lines.text[y] .. self._lines.text[y + 1], x, y)
  end
end

---Scrolls just enough to make the given position visible.
---@param x integer
---@param y integer
function Editor:scrollTo(x, y)
  local oldX, oldY = self._scroll.x, self._scroll.y
  self._scroll.x = math.max(0, x)
  self._scroll.y = math.min(math.max(0, y), #self._lines.text - 1)
  if self._mouseDown then
    self._cursor.x = self._cursor.x - oldX + self._scroll.x
    self._cursor.y = self._cursor.y - oldY + self._scroll.y
  end
end

---Scrolls by the given amount.
---@param dx integer
---@param dy integer
function Editor:scrollBy(dx, dy)
  self:scrollTo(self._scroll.x + dx, self._scroll.y + dy)
end

---Transforms screen coordinates to client coordinates.
---
---Screen coordinates are relative to the top-left corner of the screen.
---Client coordinates are relative to the beginning of the first line.
---
---@param x integer
---@param y integer
---@return integer x, integer y
function Editor:screenToClient(x, y)
  return x + self._scroll.x - self._lineNumberWidth, y + self._scroll.y
end

---Transforms client coordinates to screen coordinates.
---@see Editor.screenToClient
---@param x integer
---@param y integer
---@return integer x, integer y
function Editor:clientToScreen(x, y)
  return x - self._scroll.x + self._lineNumberWidth, y - self._scroll.y
end

---Makes sure the cursor is visible by scrolling just enough.
---
---This also takes _visibleLines into account to make sure at least that many lines remain visible.
function Editor:makeCursorVisible()
  local width, height = term.getSize()
  self:scrollTo(
    math.max(math.min(self._scroll.x, self._cursor.x - 1),
      self._cursor.x - width + self._lineNumberWidth),
    math.max(math.min(self._scroll.y, self._cursor.y - 1 - self._visibleLines.above),
      self._cursor.y - height + self._visibleLines.below))
end

---Moves the cursor to the given position, possibly dragging along a selection.
---@param x integer?
---@param y integer?
---@param select boolean?
function Editor:setCursor(x, y, select)
  self._selectionStart = select and (self._selectionStart or { x = self._cursor.x, y = self._cursor.y }) or nil
  self._cursor.x = math.max(1, x or self._cursor.x)
  self._cursor.y = math.min(math.max(1, y or self._cursor.y), #self._lines.text)
  if select then
    self:select(self._selectionStart, self._cursor)
  else
    self._selection = nil
  end
end

---Moves the cursor by the given amount, possibly dragging along a selection.
---@param dx integer
---@param dy integer
---@param select boolean?
function Editor:moveCursor(dx, dy, select)
  self:setCursor(self._cursor.x + dx, self._cursor.y + dy, select)
  self:makeCursorVisible()
end

---Moves the cursor to the given position and remembers that the mouse is currently pressed down.
---@param x integer
---@param y integer
function Editor:click(x, y)
  self:setCursor(self:screenToClient(x, y))
  self._mouseDown = true
end

---Drags the cursor to the given position, selecting the dragged region.
---@param x integer
---@param y integer
function Editor:drag(x, y)
  x, y = self:screenToClient(x, y)
  self:setCursor(x, y, true)
end

---Notifies the editor that a mouse button was released, signifying the end of a drag/selection.
function Editor:release()
  self._mouseDown = false
end

---Selects everything in the given range.
---
---`start` does not have to be before `stop`, they will be swapped if necessary.
---
---@param start Point
---@param stop Point
function Editor:select(start, stop)
  if start.y > stop.y or start.y == stop.y and start.x > stop.x then
    start, stop = stop, start
  end
  self._selection = {
    start = start,
    stop = stop,
  }
end

---Clears the entire history, but leaves the document fully intact.
function Editor:clearHistory()
  self._history = {}
  self._revision = 0
end

---Replaces the entire document with the given text.
---@param content string?
function Editor:setContent(content)
  self:replaceLines(1, #self._lines.text, content, 1, 1)
end

---Returns the content of the editor.
---@return string?
function Editor:getContent()
  return mergeLines(self._lines.text)
end

---Retrieves the text, color, and background attributes for a given line in the editor.
---
---If the line has not been highlighted yet, it performs the highlighting process.
---If there is a selection on the line, it applies the selection color to the background.
---
---@param line integer
---@return string text, string color, string background
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

---Returns the parameters to `term.blit` for the given line.
---@param line integer
---@return string text, string color, string background
function Editor:getBlitLine(line)
  local width, _height = term.getSize()
  local scroll = self._scroll.x

  local function makeBlit(text, fill, lineNumberFill)
    if scroll < 0 then -- left pad
      text = fill:rep(-scroll) .. text
    else               -- left cutoff
      text = text:sub(1 + scroll)
    end
    if #text < width then -- right pad
      text = text .. fill:rep(width - #text)
    else                  -- right cutoff
      text = text:sub(1, width)
    end

    if self._lineNumberWidth == 0 then
      return text
    end

    local lineNumber = lineNumberFill and lineNumberFill:rep(self._lineNumberWidth) or
        line >= 1 and line <= #self._lines.text and
        ("%" .. self._lineNumberWidth .. "d"):format(line):sub(-self._lineNumberWidth) or
        (" "):rep(self._lineNumberWidth)
    return lineNumber .. text:sub(1, -self._lineNumberWidth)
  end

  local text, color, background = self:getLineHighlighting(line)
  return makeBlit(text, " "),
      makeBlit(color, colors.toBlit(colors.white), colors.toBlit(colors.black)),
      makeBlit(background, colors.toBlit(colors.black), colors.toBlit(colors.gray))
end

---Renders all currently visible lines.
---
---Also temporarly hides the cursor to avoid it from jumping around.
---The cursor is then updated appropriately (hidden if not on screen).
function Editor:render()
  term.setCursorBlink(false)

  local _width, height = term.getSize()
  for i = 1, height do
    local line = i + self._scroll.y
    term.setCursorPos(1, i)
    if line >= 1 and line <= #self._lines.text then
      term.blit(self:getBlitLine(line))
    else
      term.setBackgroundColor(colors.gray)
      term.clearLine()
    end
  end

  if self:isCursorVisible() then
    term.setCursorPos(self:clientToScreen(self:getCursor()))
    term.setCursorBlink(true)
  else
    term.setCursorBlink(false)
  end
end

---Whether the cursor is currently visible.
---@return boolean
function Editor:isCursorVisible()
  local x, y = self:clientToScreen(self:getCursor())
  local width, height = term.getSize()
  return x >= 1 and x <= width and y >= 1 and y <= height
end

---Moves the cursor to the previous line, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorPreviousLine(select)
  local _x, y = self:getCursor()
  if y > 1 then
    self:setCursor(#self._lines.text[y - 1] + 1, y - 1, select)
    self:makeCursorVisible()
  end
end

---Moves the cursor one character to the left, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorLeft(select)
  local x, y = self:getCursor()
  if x > 1 then
    self:setCursor(x - 1, nil, select)
    self:makeCursorVisible()
  else
    self:cursorPreviousLine(select)
  end
end

---Returns the index of the first character of the word to the left of the cursor.
---@return integer?
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

---Moves the cursor to the beginning of the word to the left of the cursor, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorWordLeft(select)
  local x = self:findWordLeft()
  if x then
    self:setCursor(x, nil, select)
    self:makeCursorVisible()
  else
    self:cursorLeft(select)
  end
end

---Moves the cursor one character to the right, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorRight(select)
  self:moveCursor(1, 0, select)
end

---Moves the cursor to the next line, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorNextLine(select)
  local _x, y = self:getCursor()
  self:setCursor(1, y + 1, select)
  self:makeCursorVisible()
end

---Finds the index of the first character of the word to the right of the cursor.
---@return integer?
function Editor:findWordRight()
  local x, y = self:getCursor()
  local line = self._lines.text[y]
  if x > #line then
    return nil
  end
  return line:find("%f[%w_]", x + 1) or #line + 1
end

---Moves the cursor to the beginning of the word to the right of the cursor, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorWordRight(select)
  local x = self:findWordRight()
  if x then
    self:setCursor(x, nil, select)
    self:makeCursorVisible()
  else
    self:cursorNextLine(select)
  end
end

---Moves the cursor to the beginning of the line, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorLineHome(select)
  self:setCursor(1, self._cursor.y, select)
  self:makeCursorVisible()
end

---Moves the cursor to the beginning of the document, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorDocumentHome(select)
  self:setCursor(1, 1, select)
  self:makeCursorVisible()
end

---Moves the cursor to the end of the line, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorLineEnd(select)
  self:setCursor(#self._lines.text[self._cursor.y] + 1, self._cursor.y, select)
  self:makeCursorVisible()
end

---Moves the cursor to the end of the document, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorDocumentEnd(select)
  local y = #self._lines.text
  self:setCursor(#self._lines.text[y] + 1, y, select)
  self:makeCursorVisible()
end

---Inserts a newline, optionally forced at the end of the line.
---@param fromEndOfLine boolean?
function Editor:enter(fromEndOfLine)
  if fromEndOfLine then
    self:cursorLineEnd()
  end
  self:insert("\n")
end

---Inserts a tab or (un)indents the current selection.
---@param shift boolean?
function Editor:tab(shift)
  -- TODO: indent entire selection
  local x, y = self:getCursor()
  if shift then
    local original = self._lines.text[y]
    local undented = original:match("^" .. (" ?"):rep(self._tabWidth) .. "(.*)")
    self:modifyLine(y, undented, x - #original + #undented, y)
  else
    self:insert((" "):rep((self._tabWidth - x) % self._tabWidth + 1))
  end
end

---Moves the cursor a full page up, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorPageUp(select)
  local _width, height = term.getSize()
  self:moveCursor(0, 2 - height, select)
end

---Moves the cursor a full page down, possibly dragging along a selection.
---@param select boolean?
function Editor:cursorPageDown(select)
  local _width, height = term.getSize()
  self:moveCursor(0, height - 2, select)
end

---Deletes everything until the start of the previous word.
function Editor:backspaceWord()
  local cursorX, _cursorY = self:getCursor()
  local wordX = self:findWordLeft()
  if wordX then
    self:remove(wordX, cursorX - 1)
  else
    self:backspace()
  end
end

---Deletes everything until the start of the next word.
function Editor:deleteWord()
  local cursorX, _cursorY = self:getCursor()
  local wordX = self:findWordRight()
  if wordX then
    self:remove(cursorX, wordX - 1)
  else
    self:delete()
  end
end

---Deletes the current line or selection and stores it in the clipboard.
function Editor:cut()
  -- TODO: implement
end

---Stores the current line or selection in the clipboard.
function Editor:copy()
  -- TODO: implement
end

---Pastes the contents of the clipboard at the current cursor.
function Editor:paste()
  -- TODO: implement
  -- TODO: make sure to handle selection
end

---The current revision used by the undo history.
---@return integer
function Editor:revision()
  return self._revision
end

---Selects the entire document.
function Editor:selectAll()
  self:cursorDocumentHome()
  self:cursorDocumentEnd(true)
end

---Swaps the current/selected lines with the line above.
function Editor:swapLineUp()
  -- TODO: swap all selected lines
  local x, y = self:getCursor()
  if y > 1 then
    self:replaceLines(y - 1, y, self._lines.text[y] .. "\n" .. self._lines.text[y - 1], x, y - 1)
  end
end

---Swaps the current/selected lines with the line below.
function Editor:swapLineDown()
  -- TODO: swap all selected lines
  local x, y = self:getCursor()
  if y < #self._lines.text then
    self:replaceLines(y, y + 1, self._lines.text[y + 1] .. "\n" .. self._lines.text[y], x, y + 1)
  end
end

---@type fun(): Editor
local new = require "code.class" (Editor)
return new
