local clipboard = {}

local filename = ".code-clipboard"

---Returns the current content of the clipboard.
---@return string text, boolean fullLine
function clipboard.get()
  local file = fs.open(filename, "rb")
  local data = file.readAll()
  file.close()
  return data:sub(2), data:sub(1, 1) == "\1"
end

---Sets the content of the clipboard with the given values.
---@param text string
---@param fullLine boolean?
function clipboard.set(text, fullLine)
  local file = fs.open(filename, "wb")
  file.write((fullLine and "\1" or "\0") .. text)
  file.close()
end

return clipboard
