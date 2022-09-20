local Editor = require "code.Editor"

---@alias Action fun()

---@type table<string, fun(code: Code, ...): ...>
local on = {}

---TODO
---@param code Code
---@param char string
---@return boolean?
function on.char(code, char)
  code._editor:insert(char)
  return true
end

---TODO
---@param code Code
---@param key integer
---@param _held boolean
---@return boolean?
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

---TODO
---@param code Code
---@param key integer
---@return boolean?
function on.key_up(code, key)
  if key == keys.leftCtrl or key == keys.rightCtrl then
    code._modifierKeys.ctrl = false
  elseif key == keys.leftShift or key == keys.rightShift then
    code._modifierKeys.shift = false
  elseif key == keys.leftAlt or key == keys.rightAlt then
    code._modifierKeys.alt = false
  end
end

---TODO
---@param _code Code
---@return boolean?
function on.term_resize(_code)
  return true
end

---TODO
---@param code Code
---@param button integer
---@param x integer
---@param y integer
---@return boolean?
function on.mouse_click(code, button, x, y)
  code._editor:click(x, y)
  return true
end

---TODO
---@param code Code
---@param button integer
---@param x integer
---@param y integer
---@return boolean?
function on.mouse_drag(code, button, x, y)
  code._editor:drag(x, y)
  return true
end

---TODO
---@param code Code
---@param direction integer
---@param _x integer
---@param _y integer
---@return boolean?
function on.mouse_scroll(code, direction, _x, _y)
  code._editor:scrollBy(0, direction * 3)
  return true
end

---TODO
---@param code Code
---@param _button integer
---@param _x integer
---@param _y integer
---@return boolean?
function on.mouse_up(code, _button, _x, _y)
  code._editor:release()
end

---TODO
---@param code Code
---@param text string
---@return boolean?
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

---@type fun(filename: string): Code
local new = require "code.class" (Code)
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
  shortcuts = {},
}

---TODO
---@param config table<string, any>
local function cleanConfig(config)
  for key, value in pairs(config) do
    if value == defaultConfig[key] or defaultConfig[key] == nil then
      config[key] = nil
    end
  end
end

---TODO
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
    cleanConfig(config)
  else
    config = {}
  end
  self._config = setmetatable(config, { __index = defaultConfig })
end

---TODO
function Code:saveConfig()
  if self._invalidConfig then return end
  cleanConfig(self._config)
  if next(self._config) == nil then
    fs.delete(configFilename)
  else
    local content = textutils.serialize(self._config)
    local file = assert(fs.open(configFilename, "wb"))
    file.write(content)
    file.close()
  end
end

---TODO
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

---TODO
function Code:updateMultishell()
  if multishell then
    local title = fs.getName(self._filename)
    if not self:saved() then
      title = title .. "*"
    end
    multishell.setTitle(multishell.getCurrent(), title)
  end
end

---TODO
---@return boolean
function Code:saved()
  return self._editor:revision() == self._savedRevision
end

---TODO
function Code:markSaved()
  self._savedRevision = self._editor:revision()
end

---TODO
function Code:registerDefaultShortcuts()
  self:registerScript("shift?+left", "editor:cursorLeft(shift)")
  self:registerScript("ctrl+shift?+left", "editor:cursorWordLeft(shift)")

  self:registerScript("shift?+right", "editor:cursorRight(shift)")
  self:registerScript("ctrl+shift?+right", "editor:cursorWordRight(shift)")

  self:registerScript("alt+up", "editor:swapLineUp()")
  self:registerScript("shift?+up", "editor:moveCursor(0, -1, shift)")
  self:registerScript("ctrl+up", "editor:scrollBy(0, -1)")

  self:registerScript("alt+down", "editor:swapLineDown()")
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

---TODO
---@param back boolean?
function Code:switchTab(back)
  if multishell then
    local current = multishell.getCurrent()
    if current ~= multishell.getFocus() then return end
    multishell.setFocus((back and current - 2 or current) % multishell.getCount() + 1)
  end
end

---TODO
function Code:registerConfigShortcuts()
  for combo, script in pairs(self._config.shortcuts) do
    self:registerScript(combo, script)
  end
end

---TODO
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

---TODO
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

---TODO
---@param combo string
---@param script string
function Code:registerScript(combo, script)
  self:registerAction(combo, self:createAction(script))
end

---TODO
---@param force boolean?
function Code:quit(force)
  if force or self:saved() then
    self._running = false
  end
  -- TODO: Message for normal close without force.
end

---TODO
function Code:save()
  local content = self._editor:getContent()
  local file = assert(fs.open(self._filename, "wb"))
  file.write(content)
  file.close()
  self:markSaved()
end

---TODO
---@param event string
---@param ... any
---@return boolean?
function Code:processEvent(event, ...)
  local handler = on[event]
  if handler then
    return handler(self, ...)
  end
end

function Code:render()
  self._editor:render()
  self._editor:blink()
end

function Code:run()
  self:render()
  while self._running do
    ---@diagnostic disable-next-line: undefined-field
    if self:processEvent(os.pullEvent()) then
      self:render()
      self:updateMultishell()
    end
  end
  if fs.combine(self._filename) ~= configFilename then
    self:saveConfig()
  end
end

return new
