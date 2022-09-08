local Code = require "code.Code"

local function printUsage()
  printError("Usage:")
  printError("  " .. arg[0] .. " <filename>")
end

local args = { ... }
if #args ~= 1 then
  printUsage()
  return
end

local filename = args[1]

if multishell then
  multishell.setTitle(multishell.getCurrent(), filename)
end

local code = Code(filename)

code:run()

term.setCursorPos(1, 1)
term.clear()
