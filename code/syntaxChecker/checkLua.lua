---Checks the given Lua code for syntax errors.
---@param code string
---@return table<integer, string>?
local function check(code)
  local _, err = load(code, "")
  if err then
    local line, message = err:match(":(%d+): (.+)")
    line = tonumber(line)
    return line and { [line] = message } or { err }
  end
end

return check
