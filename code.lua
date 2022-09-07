local Editor = require "code.Editor"

-- State
local running = true
local editors = {}
local activeEditorIndex = nil

-- State Handling
local function activeEditor()
  return activeEditorIndex and editors[activeEditorIndex]
end

-- Event Handlers
local on = {}

function on:char(char)
  return true
end

function on:key(key, held)
  return true
end

function on:key_up(key)
  return true
end

function on:term_resize()
  return true
end

function on:mouse_click(button, x, y)
  return true
end

function on:mouse_drag(button, x, y)
  return true
end

function on:mouse_scroll(direction, x, y)
  return true
end

function on:mouse_up(button, x, y)
  return true
end

local function processEvent(event, ...)
  local handler = on[event]
  if handler then
    return handler(...)
  end
end

-- Rendering
local function render()
  activeEditor():render()
end

-- Event Loop
while running do
  render()
  while not processEvent(os.pullEvent()) do end
end
