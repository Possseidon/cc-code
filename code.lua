local OPTION_SHORT = 1
local OPTION_LONG = 2
local OPTION_PARAM = 3
local OPTION_TYPE = 4
local OPTION_HELP = 5

local OPTIONS = {
  { "u", "update", nil, nil, {
    "Update to the latest version.",
  } },
  { nil, "line", "index", "integer", {
    "Start at the specified line.",
  } },
  { "v", "version", nil, nil, {
    "Print version (git commit hash).",
  } },
  { "h", "help", nil, nil, {
    "Print usage.",
  } },
}

local optionMap = {}
for _, option in ipairs(OPTIONS) do
  if option[OPTION_SHORT] then
    optionMap[option[OPTION_SHORT]] = option
  end
  optionMap[option[OPTION_LONG]] = option
end

local function printUsage(asError)
  local formattedOptions = {}
  local maxWidth = 0
  for _, option in ipairs(OPTIONS) do
    local text = "  "
    if option[OPTION_SHORT] then
      text = text .. "-" .. option[OPTION_SHORT] .. " "
    end
    text = text .. "--" .. option[OPTION_LONG]
    if option[OPTION_PARAM] then
      text = text .. " <" .. option[OPTION_PARAM] .. ">"
    end
    table.insert(formattedOptions, text)
    maxWidth = math.max(maxWidth, #text)
  end

  -- add space between longest option and help text
  maxWidth = maxWidth + 1

  local defaultColor = asError and colors.red or colors.white
  local highlightColor = asError and colors.pink or colors.lightBlue

  term.setTextColor(defaultColor)

  print("Usage:")
  term.setTextColor(highlightColor)
  print("  " .. arg[0] .. " [options] [filename]")
  term.setTextColor(defaultColor)
  print()
  print("Options:")
  for i, option in ipairs(OPTIONS) do
    local helpLines = option[OPTION_HELP]
    term.setTextColor(highlightColor)
    write(("%-" .. maxWidth .. "s"):format(formattedOptions[i]))
    term.setTextColor(defaultColor)
    local lastPrintLines = print(helpLines[1])
    for j = 2, #helpLines do
      lastPrintLines = print((" "):rep(maxWidth) .. helpLines[j])
    end
    if lastPrintLines > 1 and i < #OPTIONS then
      print()
    end
  end
end

local function parseArgs(...)
  local raw = { ... }
  local args = {}
  local allValid = true
  local i = 1

  local function add(name, canSkip)
    local option = optionMap[name]
    if option then
      local long = option[OPTION_LONG]
      local optionType = option[OPTION_TYPE]
      if optionType then
        if not canSkip then
          printError("Unknown option: " .. name)
          allValid = false
        else
          i = i + 1
          local param = raw[i]
          if optionType == "integer" then
            local number = tonumber(param)
            local integer = number and number % 1 == 0 and number
            if integer then
              args[long] = integer
            else
              printError(name .. ": integer expected, found " .. param)
              allValid = false
            end
          elseif optionType == "number" then
            local number = tonumber(param)
            if number then
              args[long] = number
            else
              printError(name .. ": number expected, found " .. param)
              allValid = false
            end
          elseif optionType == "string" then
            args[long] = param
          else
            error("unexpected option type: " .. tostring(optionType))
          end
        end
      else
        args[long] = true
      end
    else
      printError("Unknown option: " .. name)
      allValid = false
    end
  end

  while i <= #raw do
    local arg = raw[i]
    local long = arg:match("%-%-(.*)")
    if long == "" then
      printError("\"--\" is not allowed")
      allValid = false
    elseif long then
      add(long, true)
    else
      local shorts = arg:match("%-(.*)")
      if shorts == "" then
        printError("\"-\" is not allowed")
        allValid = false
      elseif shorts then
        for j = 1, #shorts do
          add(shorts:sub(j, j), j == #shorts)
        end
      else
        table.insert(args, arg)
      end
    end
    i = i + 1
  end

  return allValid and args or nil
end

local function printVersion()
  printError("not yet implemented: --version")
end

local function update()
  print("Updating...")
  shell.run("wget run https://raw.githubusercontent.com/Possseidon/cc-code/main/code/update.lua")
end

local function run(args)
  local filename = args[1]

  local code = require "code.Code" (filename)

  if args.line then
    code._editor:setCursor(1, args.line)
    code._editor:makeCursorVisible()
  end

  local oldTextColor = term.getTextColor()
  local oldBackgroundColor = term.getBackgroundColor()

  code:run()

  term.setTextColor(oldTextColor)
  term.setBackgroundColor(oldBackgroundColor)
  term.clear()
  term.setCursorPos(1, 1)
end

local args = parseArgs(...)

if not args then
  print()
  printUsage(true)
  return
end

if args.help then
  printUsage()
elseif args.version then
  printVersion()
elseif args.update then
  update()
elseif #args == 1 then
  run(args)
else
  printUsage(true)
end
