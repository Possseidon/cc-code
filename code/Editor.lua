local Highlighter = require "code.Highlighter"
local lexLua      = require "code.lexers.lexLua"
local table       = require "code.polyfill.table"

---@class Point
---@field x integer
---@field y integer

---@alias SelectionAnchor
---| "start"
---| "stop"

---@class Selection
---@field start Point
---@field stop Point
---@field anchor SelectionAnchor

---Returns the anchor point of a selection.
---@param selection Selection
---@return Point
local function selectionAnchorPoint(selection)
  return selection.anchor == "start" and selection.start or selection.stop
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
  self._mouseDown = false
  self._cursor = { x = 1, y = 1 }
  self._scroll = { x = 0, y = 0 }
  self._history = {}
  self._revision = 0
  self._savedRevision = 0
  self._historyGroupNesting = 0
  self._historyGroupRevision = nil

  -- TODO: make dynamic
  self._highlighter = Highlighter(require "code.highlighter.vscode")
  -- TODO: optional/configurable lexer

  -- TODO: move to config
  self._visibleLines = { above = 3, below = 1 }
  self._lineNumberWidth = 3
  self._tabWidth = 2
end

---Whether the editor matches the last call to markSaved.
---@return boolean
function Editor:saved()
  return self._revision == self._savedRevision
end

---Marks the current state as saved, so that a call to saved returns true for this revision.
function Editor:markSaved()
  self._savedRevision = self._revision
end

---All new history entries after this call will be merged together once endHistoryGroup is called.
function Editor:beginHistoryGroup()
  if self._historyGroupNesting == 0 then
    self._historyGroupRevision = self._revision + 1
  end
  self._historyGroupNesting = self._historyGroupNesting + 1
end

---Merges after the matching beginHistoryGroup call into a single history entry.
function Editor:endHistoryGroup()
  assert(self._historyGroupNesting > 0, "mismatched endHistoryGroup")
  self._historyGroupNesting = self._historyGroupNesting - 1
  if self._historyGroupNesting == 0 then
    if self._historyGroupRevision < #self._history then
      local group = {}
      for i = self._historyGroupRevision, #self._history do
        table.insert(group, self._history[i])
      end
      for i = #self._history, self._historyGroupRevision + 1, -1 do
        self._history[i] = nil
      end
      self._history[self._historyGroupRevision] = {
        execute = function(editor)
          for i = 1, #group do
            group[i].execute(editor)
          end
        end,
        revert = function(editor)
          for i = #group, 1, -1 do
            group[i].revert(editor)
          end
        end,
      }
      self._revision = self._historyGroupRevision
    end
    self._historyGroupRevision = nil
  end
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
  if self._savedRevision == self._revision then
    self._savedRevision = nil
  end
end

---Sets the selection to the given range and anchor.
---
---Avoids unnecessary table creation if a selection table already exists.
---
---@param startX integer
---@param startY integer
---@param stopX integer
---@param stopY integer
---@param anchor SelectionAnchor
function Editor:setSelection(startX, startY, stopX, stopY, anchor)
  local selection = self._selection
  if selection then
    selection.start.x = startX
    selection.start.y = startY
    selection.stop.x = stopX
    selection.stop.y = stopY
    selection.anchor = anchor
  else
    self._selection = {
      start = { x = startX, y = startY },
      stop = { x = stopX, y = stopY },
      anchor = anchor,
    }
  end
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
---@param selection Selection? The selection after the modification.
---@return fun(editor: Editor) modifier A function that modifies the editor's text and cursor position.
local function makeModifier(from, to, text, cursorX, cursorY, selection)
  local selectionStartX = selection and selection.start.x
  local selectionStartY = selection and selection.start.y
  local selectionStopX = selection and selection.stop.x
  local selectionStopY = selection and selection.stop.y
  local selectionAnchor = selection and selection.anchor

  return function(editor)
    local lines = splitLines(text)
    local delta = #lines - (to - from + 1)
    table.move(editor._lines.text, to + 1, #editor._lines.text, to + 1 + delta)
    for i = #editor._lines.text + delta + 1, #editor._lines.text do
      editor._lines.text[i] = nil
    end
    table.move(lines, 1, #lines, from, editor._lines.text)

    editor:invalidateLine(from)
    editor._cursor.x = cursorX
    editor._cursor.y = cursorY
    if selectionStartX then
      ---@diagnostic disable-next-line: param-type-mismatch
      editor:setSelection(selectionStartX, selectionStartY, selectionStopX, selectionStopY, selectionAnchor)
    else
      editor._selection = nil
    end
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
  local oldX, oldY = self:getCursor()
  self:record(
    makeModifier(from, to, text, cursorX, cursorY),
    makeModifier(from, to + delta, mergeLines(self._lines.text, from, to), oldX, oldY, self._selection))
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

---Undoably deletes the currently selected text.
---
---Does nothing if there is no selection.
function Editor:deleteSelection()
  local selection = self._selection
  if not selection then return end
  local start = self._selection.start
  local stop = self._selection.stop
  local before = self._lines.text[start.y]:sub(1, start.x - 1)
  local after = self._lines.text[stop.y]:sub(stop.x)
  self:replaceLines(start.y, stop.y, before .. after, start.x, start.y)
end

---Inserts the given text at the current cursor position.
---@param text string?
function Editor:insert(text)
  self:beginHistoryGroup()

  self:deleteSelection()

  local lines = splitLines(text)
  local x, y = self:getCursor()
  local cursorX = #lines > 1 and #lines[#lines] + 1 or x + #text
  local original = self._lines.text[y]
  if x > #original + 1 then
    local pad = x - #original - 1
    self:modifyLine(y, original .. (" "):rep(pad) .. text, cursorX, y + #lines - 1)
  else
    self:modifyLine(y, original:sub(1, x - 1) .. text .. original:sub(x), cursorX, y + #lines - 1)
  end

  self:endHistoryGroup()
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
  if self._selection then
    self:deleteSelection()
  else
    local x, y = self:getCursor()
    if x ~= 1 then
      self:removeRelative(-1, -1)
    elseif y ~= 1 then
      self:replaceLines(y - 1, y, self._lines.text[y - 1] .. self._lines.text[y], #self._lines.text[y - 1] + 1, y - 1)
    end
  end
end

---Does what one would expect from hitting delete in an editor.
---
---In other words, deletes the character after the cursor without moving the cursor.
---Also joins lines if the cursor is past the end of the line.
function Editor:delete()
  if self._selection then
    self:deleteSelection()
  else
    local x, y = self:getCursor()
    if x <= #self._lines.text[y] then
      self:removeRelative(0, 0)
    elseif y ~= #self._lines.text then
      self:replaceLines(y, y + 1, self._lines.text[y] .. self._lines.text[y + 1], x, y)
    end
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
    self:setCursor(
      self._cursor.x - oldX + self._scroll.x,
      self._cursor.y - oldY + self._scroll.y,
      true)
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
  local anchorPoint
  if select then
    anchorPoint = self._selection
        and selectionAnchorPoint(self._selection)
        or { x = self._cursor.x, y = self._cursor.y }
  end
  self._cursor.x = math.max(1, x or self._cursor.x)
  self._cursor.y = math.min(math.max(1, y or self._cursor.y), #self._lines.text)
  if anchorPoint then
    self:select(anchorPoint, self._cursor)
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

---Selects everything from the given anchor point to the other point.
---
---Clears the selection if the points are the same.
---
---@param anchorPoint Point
---@param other Point
function Editor:select(anchorPoint, other)
  if anchorPoint.x == other.x and anchorPoint.y == other.y then
    self._selection = nil
  else
    local anchor
    if anchorPoint.y > other.y or anchorPoint.y == other.y and anchorPoint.x > other.x then
      anchorPoint, other = other, anchorPoint
      anchor = "stop"
    else
      anchor = "start"
    end
    self:setSelection(anchorPoint.x, anchorPoint.y, other.x, other.y, anchor)
  end
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
function Editor:render()
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
end

---Updates the cursor position, color and visibility.
function Editor:updateCursor()
  if self:isCursorVisible() then
    term.setTextColor(colors.white)
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

---Moves the cursor to the first non-whitespace character, possibly dragging along a selection.
---
---If the cursor is already on the first non-whitespace character it moves to the beginning of the line instead.
---
---@param select boolean?
function Editor:cursorLineHome(select)
  local firstNonWhitespace = self._lines.text[self._cursor.y]:find("[^ ]") or 1
  if self._cursor.x == firstNonWhitespace then
    self:setCursor(1, self._cursor.y, select)
  else
    self:setCursor(firstNonWhitespace, self._cursor.y, select)
  end
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

---Undoably indents the current selection.
---
---This more efficient than undentSelection, since indenting is a "lossless" operation.
---With undenting, differing amounts of whitespace might be removed, making it "lossy".
function Editor:indentSelection()
  local cursorX, cursorY = self:getCursor()
  local selectionStartX = self._selection.start.x
  local selectionStartY = self._selection.start.y
  local selectionStopX = self._selection.stop.x
  local selectionStopY = self._selection.stop.y
  local selectionAnchor = self._selection.anchor

  self:record(
    function(editor)
      local indent = (" "):rep(editor._tabWidth)
      for i = selectionStartY, selectionStopX == 1 and selectionStopY - 1 or selectionStopY do
        editor._lines.text[i] = indent .. editor._lines.text[i]
      end
      editor._cursor.x = cursorX == 1 and cursorX or cursorX + editor._tabWidth
      editor._cursor.y = cursorY
      local newSelectionStartX = selectionStartX == 1 and selectionStartX or selectionStartX + editor._tabWidth
      local newSelectionStopX = selectionStopX == 1 and selectionStopX or selectionStopX + editor._tabWidth
      editor:setSelection(newSelectionStartX, selectionStartY, newSelectionStopX, selectionStopY, selectionAnchor)
      editor:invalidateLine(selectionStartY)
      editor:makeCursorVisible()
    end,
    function(editor)
      for i = selectionStartY, selectionStopX == 1 and selectionStopY - 1 or selectionStopY do
        editor._lines.text[i] = editor._lines.text[i]:sub(editor._tabWidth + 1)
      end
      editor._cursor.x = cursorX
      editor._cursor.y = cursorY
      editor:setSelection(selectionStartX, selectionStartY, selectionStopX, selectionStopY, selectionAnchor)
      editor:invalidateLine(selectionStartY)
      editor:makeCursorVisible()
    end)
end

---Undoably undents the current selection.
---
---This is slightly more complex than indenting, as it has to remember how deep everything was undented.
---Yes, this has some code duplication with indentSelection, but honestly, I'm just happy it works.
function Editor:undentSelection()
  local cursorX, cursorY = self:getCursor()
  local selectionStartX = self._selection.start.x
  local selectionStartY = self._selection.start.y
  local selectionStopX = self._selection.stop.x
  local selectionStopY = self._selection.stop.y
  local selectionAnchor = self._selection.anchor

  local undents
  local canUndent = false
  for i = selectionStartY, selectionStopX == 1 and selectionStopY - 1 or selectionStopY do
    local firstNonWhitespace = self._lines.text[i]:find("[^ ]") or #self._lines.text + 1
    if firstNonWhitespace - 1 < self._tabWidth then
      undents = undents or {}
      undents[i - selectionStartY + 1] = firstNonWhitespace - 1
    end
    canUndent = canUndent or firstNonWhitespace > 1
  end

  if not canUndent then return end

  self:record(
    function(editor)
      for i = selectionStartY, selectionStopX == 1 and selectionStopY - 1 or selectionStopY do
        editor._lines.text[i] = editor._lines.text[i]:sub(
          (undents and undents[i - selectionStartY + 1] or editor._tabWidth) + 1)
      end
      local cursorUndents = undents and undents[cursorY - selectionStartY + 1] or editor._tabWidth
      editor._cursor.x = cursorX == 1 and cursorX or math.max(1, cursorX - cursorUndents)
      editor._cursor.y = cursorY
      local selectionStartUndents = undents and undents[1] or editor._tabWidth
      local newSelectionStartX = selectionStartX == 1 and selectionStartX or selectionStartX - selectionStartUndents
      local selectionStopUndents = undents and undents[selectionStopY - selectionStartY + 1] or editor._tabWidth
      local newSelectionStopX = selectionStopX == 1 and selectionStopX or selectionStopX - selectionStopUndents
      editor:setSelection(newSelectionStartX, selectionStartY, newSelectionStopX, selectionStopY, selectionAnchor)
      editor:invalidateLine(selectionStartY)
      editor:makeCursorVisible()
    end,
    function(editor)
      for i = selectionStartY, selectionStopX == 1 and selectionStopY - 1 or selectionStopY do
        editor._lines.text[i] = (" "):rep(
          undents and undents[i - selectionStartY + 1] or editor._tabWidth) .. editor._lines.text[i]
      end
      editor._cursor.x = cursorX
      editor._cursor.y = cursorY
      editor:setSelection(selectionStartX, selectionStartY, selectionStopX, selectionStopY, selectionAnchor)
      editor:invalidateLine(selectionStartY)
      editor:makeCursorVisible()
    end)
end

---Inserts a tab or indents/undents the current selection.
---@param shift boolean?
function Editor:tab(shift)
  local x, y = self:getCursor()
  local selection = self._selection
  if selection then
    if shift then
      self:undentSelection()
    else
      self:indentSelection()
    end
  else
    if shift then
      local original = self._lines.text[y]
      local undented = original:match("^" .. (" ?"):rep(self._tabWidth) .. "(.*)")
      self:modifyLine(y, undented, math.max(1, x - #original + #undented), y)
    else
      self:insert((" "):rep((self._tabWidth - x) % self._tabWidth + 1))
    end
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
  local wordX = self:findWordLeft()
  if wordX and not self._selection then
    local cursorX, _cursorY = self:getCursor()
    self:remove(wordX, cursorX - 1)
  else
    self:backspace()
  end
end

---Deletes everything until the start of the next word.
function Editor:deleteWord()
  local wordX = self:findWordRight()
  if wordX and not self._selection then
    local cursorX, _cursorY = self:getCursor()
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

---Returns a function that swaps the given line with the one below.
---@param x integer
---@param y integer
---@param line integer
---@return fun(editor: Editor)
local function makeLineSwapper(x, y, line)
  return function(editor)
    local lines = editor._lines.text
    lines[line], lines[line + 1] = lines[line + 1], lines[line]

    editor:invalidateLine(line)
    editor:setCursor(x, y)
    editor:makeCursorVisible()
  end
end

---Swaps the given range up by moving the line above `from` to `to`.
---@param x integer
---@param y integer
---@param selectionStartX integer
---@param selectionStartY integer
---@param selectionStopX integer
---@param selectionStopY integer
---@param selectionAnchor SelectionAnchor
---@param from integer
---@param to integer
---@return fun(editor: Editor)
local function makeSelectionSwapperUp(x, y, selectionStartX, selectionStartY, selectionStopX, selectionStopY,
                                      selectionAnchor, from, to)
  return function(editor)
    local lines = editor._lines.text
    local swapLine = lines[from - 1]
    table.move(lines, from, to, from - 1)
    lines[to] = swapLine

    editor:invalidateLine(from - 1)
    editor._cursor.x = x
    editor._cursor.y = y
    editor:setSelection(selectionStartX, selectionStartY, selectionStopX, selectionStopY, selectionAnchor)
    editor:makeCursorVisible()
  end
end

---Swaps the given range down by moving the line below `to` to `from`.
---@param x integer
---@param y integer
---@param selectionStartX integer
---@param selectionStartY integer
---@param selectionStopX integer
---@param selectionStopY integer
---@param selectionAnchor SelectionAnchor
---@param from integer
---@param to integer
---@return fun(editor: Editor)
local function makeSelectionSwapperDown(x, y, selectionStartX, selectionStartY, selectionStopX, selectionStopY,
                                        selectionAnchor, from, to)
  return function(editor)
    local lines = editor._lines.text
    local swapLine = lines[to + 1]
    table.move(lines, from, to, from + 1)
    lines[from] = swapLine

    editor:invalidateLine(from)
    editor._cursor.x = x
    editor._cursor.y = y
    editor:setSelection(selectionStartX, selectionStartY, selectionStopX, selectionStopY, selectionAnchor)
    editor:makeCursorVisible()
  end
end

---Swaps the current/selected lines with the line above.
function Editor:swapLinesUp()
  local x, y = self:getCursor()
  local selection = self._selection
  if selection then
    if selection.start.y > 1 then
      local to = selection.stop.y
      if selection.stop.x == 1 then
        to = to - 1
      end
      self:record(
        makeSelectionSwapperUp(
          x, y - 1,
          selection.start.x, selection.start.y - 1,
          selection.stop.x, selection.stop.y - 1,
          selection.anchor,
          selection.start.y, to),
        makeSelectionSwapperDown(
          x, y,
          selection.start.x, selection.start.y,
          selection.stop.x, selection.stop.y,
          selection.anchor,
          selection.start.y - 1, to - 1))
    end
  elseif y > 1 then
    self:record(makeLineSwapper(x, y - 1, y - 1), makeLineSwapper(x, y, y - 1))
  end
end

---Swaps the current/selected lines with the line below.
function Editor:swapLinesDown()
  local x, y = self:getCursor()
  local selection = self._selection
  if selection then
    if selection.stop.y < #self._lines.text then
      local to = selection.stop.y
      if selection.stop.x == 1 then
        to = to - 1
      end
      self:record(
        makeSelectionSwapperDown(
          x, y + 1,
          selection.start.x, selection.start.y + 1,
          selection.stop.x, selection.stop.y + 1,
          selection.anchor,
          selection.start.y, to),
        makeSelectionSwapperUp(
          x, y,
          selection.start.x, selection.start.y,
          selection.stop.x, selection.stop.y,
          selection.anchor,
          selection.start.y + 1, to + 1))
    end
  else
    if y < #self._lines.text then
      self:record(makeLineSwapper(x, y + 1, y), makeLineSwapper(x, y, y))
    end
  end
end

---@type fun(): Editor
local new = require "code.class" (Editor)
return new
