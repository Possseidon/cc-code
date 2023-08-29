local Editor = require "code.Editor"

---@alias Action fun()

---Maps event names to event handlers.
---@type table<string, fun(code: Code, ...): boolean?>
local on = {}

---A char was typed and gets inserted at the current cursor position.
---@param code Code
---@param char string
function on.char(code, char)
  code._editor:insert(char)
  return true
end

---A key was pressed, triggering corresponding shortcut actions and updating internal modifier key state.
---@param code Code
---@param key integer
---@param _held boolean
function on.key(code, key, _held)
  if key == keys.leftCtrl or key == keys.rightCtrl then
    code._modifierKeys.ctrl = true
  elseif key == keys.leftShift or key == keys.rightShift then
    code._modifierKeys.shift = true
  elseif key == keys.leftAlt or key == keys.rightAlt then
    code._modifierKeys.alt = true
  else
    if code._config.swapYZ then
      if key == keys.z then
        key = keys.y
      elseif key == keys.y then
        key = keys.z
      end
    end

    local keyName = keys.getName(key)
    if not keyName then
      return
    end

    local ctrl = code._modifierKeys.ctrl and "ctrl+" or ""
    local shift = code._modifierKeys.shift and "shift+" or ""
    local alt = code._modifierKeys.alt and "alt+" or ""
    local action = code._shortcuts[ctrl .. shift .. alt .. keyName]
    if action then
      local ok, err = pcall(action, code)
      if not ok then
        -- TODO: self:setStatus(err)
        printError(err)
        ---@diagnostic disable-next-line: undefined-field
        os.pullEvent("key")
        code._modifierKeys.ctrl = false
        code._modifierKeys.shift = false
        code._modifierKeys.alt = false
      end
      return true
    end
  end
end

---A key was released, updating internal modifier key state.
---@param code Code
---@param key integer
function on.key_up(code, key)
  if key == keys.leftCtrl or key == keys.rightCtrl then
    code._modifierKeys.ctrl = false
  elseif key == keys.leftShift or key == keys.rightShift then
    code._modifierKeys.shift = false
  elseif key == keys.leftAlt or key == keys.rightAlt then
    code._modifierKeys.alt = false
  end
end

---The term was resized, requiring a redraw.
---@param _code Code
function on.term_resize(_code)
  return true
end

---A mouse button was clicked, moving the cursor to that position.
---@param code Code
---@param _button integer
---@param x integer
---@param y integer
function on.mouse_click(code, _button, x, y)
  code._editor:click(x, y)
  return true
end

---The mouse is being dragged for selecting text.
---@param code Code
---@param _button integer
---@param x integer
---@param y integer
function on.mouse_drag(code, _button, x, y)
  code._editor:drag(x, y)
  return true
end

---Scrolls the editor.
---@param code Code
---@param direction integer
---@param _x integer
---@param _y integer
function on.mouse_scroll(code, direction, _x, _y)
  code._editor:scrollBy(0, direction * code._config.scrollAmount)
  return true
end

---A mouse button was released.
---@param code Code
---@param _button integer
---@param _x integer
---@param _y integer
function on.mouse_up(code, _button, _x, _y)
  code._editor:release()
end

---Pastes text from the internal clipboard (or from the real clipboard if shift was held down).
---@param code Code
---@param text string
function on.paste(code, text)
  if code._modifierKeys.shift then
    code._editor:insert(text)
  else
    code._editor:paste()
  end
  return true
end

---@class Code
local Code = {}

function Code:new(filename)
  self._running = true
  self._filename = filename
  self._shortcuts = {}

  self._modifierKeys = {
    ctrl = false,
    shift = false,
    alt = false,
  }

  self._editor = Editor()
  self._savedRevision = nil

  self._config = nil
  self._invalidConfig = false

  self:loadConfig()
  self:registerDefaultShortcuts()
  self:registerConfigShortcuts()
  self:open(filename)
  self:updateMultishell()
end

local configFilename = ".code"
local defaultConfig = {
  swapYZ = false,
  scrollAmount = 3,
  shortcuts = {},
}

---Loads settings from the config file.
function Code:loadConfig()
  local config
  if fs.exists(configFilename) then
    local file = assert(fs.open(configFilename, "rb"))
    local content = file.readAll()
    file.close()
    config = textutils.unserialize(content)
    if not config then
      self._invalidConfig = true
      printError("Invalid config file, using default config.")
      ---@diagnostic disable-next-line: undefined-field
      os.pullEvent("key")
      config = {}
    end
  else
    config = {}
  end
  self._config = setmetatable(config, { __index = defaultConfig })
end

---Saves settings to the config file.
function Code:saveConfig()
  if self._invalidConfig then return end
  local meta = getmetatable(self._config)
  setmetatable(self._config, nil)
  if next(self._config) == nil then
    fs.delete(configFilename)
  else
    local content = textutils.serialize(self._config)
    local file = assert(fs.open(configFilename, "wb"))
    file.write(content)
    file.close()
  end
  setmetatable(self._config, meta)
end

---Opens the given file for editing.
---@param filename string
function Code:open(filename)
  if fs.exists(filename) then
    local file = assert(fs.open(filename, "rb"))
    local content = file.readAll() or ""
    file.close()
    self._editor:setContent(content)
    self:markSaved()
  end
end

---Updates the multishell title to the current filename, possibly with an `*` indicating modifications.
function Code:updateMultishell()
  if multishell then
    local title = fs.getName(self._filename)
    if not self:saved() then
      title = title .. "*"
    end
    multishell.setTitle(multishell.getCurrent(), title)
  end
end

---Whether the editor matches the current file on disk.
---@return boolean
function Code:saved()
  return self._editor:revision() == self._savedRevision
end

---Marks the current state as saved, so that soft exiting won't trigger a warning.
function Code:markSaved()
  self._savedRevision = self._editor:revision()
end

---Registers all default shortcuts for general purpose editing.
function Code:registerDefaultShortcuts()
  self:registerScript("shift?+left", "editor:cursorLeft(shift)")
  self:registerScript("ctrl+shift?+left", "editor:cursorWordLeft(shift)")

  self:registerScript("shift?+right", "editor:cursorRight(shift)")
  self:registerScript("ctrl+shift?+right", "editor:cursorWordRight(shift)")

  self:registerScript("alt+up", "editor:swapLinesUp()")
  self:registerScript("shift?+up", "editor:moveCursor(0, -1, shift)")
  self:registerScript("ctrl+up", "editor:scrollBy(0, -1)")

  self:registerScript("alt+down", "editor:swapLinesDown()")
  self:registerScript("shift?+down", "editor:moveCursor(0, 1, shift)")
  self:registerScript("ctrl+down", "editor:scrollBy(0, 1)")

  self:registerScript("shift?+tab", "editor:tab(shift)")
  self:registerScript("shift?+enter", "editor:enter(shift)")

  self:registerScript("backspace", "editor:backspace()")
  self:registerScript("ctrl+backspace", "editor:backspaceWord()")

  self:registerScript("delete", "editor:delete()")
  self:registerScript("ctrl+delete", "editor:deleteWord()")
  self:registerScript("shift+delete", "editor:deleteLine()")

  self:registerScript("shift?+home", "editor:cursorLineHome(shift)")
  self:registerScript("ctrl+shift?+home", "editor:cursorDocumentHome(shift)")

  self:registerScript("shift?+end", "editor:cursorLineEnd(shift)")
  self:registerScript("ctrl+shift?+end", "editor:cursorDocumentEnd(shift)")

  self:registerScript("alt+pageUp", "editor:scrollPageUp()")
  self:registerScript("shift?+pageUp", "editor:cursorPageUp(shift)")

  self:registerScript("alt+pageDown", "editor:scrollPageDown()")
  self:registerScript("shift?+pageDown", "editor:cursorPageDown(shift)")

  self:registerScript("ctrl+a", "editor:selectAll()")

  self:registerScript("ctrl+z", "editor:undo()")
  self:registerScript("ctrl+shift+z", "editor:redo()")
  self:registerScript("ctrl+y", "editor:redo()")

  self:registerScript("ctrl+x", "editor:cut()")
  self:registerScript("ctrl+c", "editor:copy()")
  -- Only triggers a paste event and is hardcoded there.
  -- self:registerScript("ctrl+v", "editor:paste()")

  self:registerScript("ctrl+s", "code:save()")
  self:registerScript("ctrl+d", "code:save()")
  self:registerScript("ctrl+shift?+f4", "code:quit(shift)")

  -- Using shortcuts to switch tabs doesn't work because of modifier keys.
  -- Modifier keys would need to be stored globally e.g. in a file.
  -- self:registerScript("ctrl+shift?+tab", "code:switchTab(shift)")
end

---Switches to the next (or previous) multishell tab.
---@param back boolean?
function Code:switchTab(back)
  if multishell then
    local current = multishell.getCurrent()
    if current ~= multishell.getFocus() then return end
    multishell.setFocus((back and current - 2 or current) % multishell.getCount() + 1)
  end
end

---Registers shortcuts from the currently loaded config.
function Code:registerConfigShortcuts()
  for combo, script in pairs(self._config.shortcuts) do
    self:registerScript(combo, script)
  end
end

---Creates a new action from the given script containing Lua code.
---
---The script has a few globals set:
--- - `code` for access to this current class
--- - `editor` as shorthand for `code._editor`
--- - `ctrl`, `shift` and `alt` to get modifier keys (as boolean)
---
---@param script string
---@return Action
function Code:createAction(script)
  local env = _ENV
  return assert(load(script, nil, nil, setmetatable({
    code = self,
    editor = self._editor,
  }, {
    __index = function(action, key)
      if key == "ctrl" then
        return action.code._modifierKeys.ctrl
      elseif key == "shift" then
        return action.code._modifierKeys.shift
      elseif key == "alt" then
        return action.code._modifierKeys.alt
      else
        return env[key]
      end
    end,
  })))
end

---Registers an action with a key combination.
---
---The combo has the format `ctrl?+shift+s` which allows using `ctrl` as a boolean in the action.
---
---@param combo string
---@param action Action
function Code:registerAction(combo, action)
  local optional = combo:match("(%w+)%?%+")
  if optional then
    self:registerAction(combo:gsub(optional .. "%?%+", ""), action)
    self:registerAction(combo:gsub(optional .. "%?", optional), action)
  else
    self._shortcuts[combo] = action
  end
end

---Registers a Lua script to the given key combination.
---
---This is just a shorthand for calling both createAction and registerAction.
---
---@param combo string
---@param script string
function Code:registerScript(combo, script)
  self:registerAction(combo, self:createAction(script))
end

---Exits, asking for confirmation on unsaved changes (unless `force` is set to true).
---@param force boolean?
function Code:quit(force)
  if force or self:saved() then
    self._running = false
  end
  -- TODO: message for normal close without force
end

---Saves the current state to disk and also marks the current state as "saved" internally.
function Code:save()
  local content = self._editor:getContent()
  local file = assert(fs.open(self._filename, "wb"))
  file.write(content)
  file.close()
  self:markSaved()
end

---Forwards an event with all its parameters to the `on` table of event handlers.
---
---Ignores events that aren't in the `on` table.
---
---@param event string
---@param ... any
---@return boolean?
function Code:processEvent(event, ...)
  local handler = on[event]
  if handler then
    return handler(self, ...)
  end
end

---Runs the application until the user exits.
function Code:run()
  self._editor:render()
  while self._running do
    ---@diagnostic disable-next-line: undefined-field
    if self:processEvent(os.pullEvent()) then
      self._editor:render()
      self:updateMultishell()
    end
  end
  if fs.combine(self._filename) ~= configFilename then
    self:saveConfig()
  end
end

---@type fun(filename: string): Code
local new = require "code.class" (Code)
return new
