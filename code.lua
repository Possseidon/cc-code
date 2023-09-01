local Code = require "code.Code"

local function printUsage()
  printError("Usage:")
  printError("  " .. arg[0] .. " <filename>")
  printError("  " .. arg[0] .. " --update")
end

local function update()
  print("Please wait...")
  shell.run("wget run https://raw.githubusercontent.com/Possseidon/cc-code/main/code/update.lua")
end

local args = { ... }
if #args ~= 1 then
  printUsage()
  return
elseif args[1] == "--update" then
  update()
  return
end

local filename = args[1]
local code = Code(filename)

local oldTextColor = term.getTextColor()
local oldBackgroundColor = term.getBackgroundColor()

code:run()

term.setTextColor(oldTextColor)
term.setBackgroundColor(oldBackgroundColor)
term.clear()
term.setCursorPos(1, 1)
