local VERSION_FILE = "/code/version"

local function getOnlineVersion()
  local request, err = http.get("https://api.github.com/repos/Possseidon/cc-code/commits/main")
  if not request then return nil, err end
  local json = request.readAll()
  if not json then return nil, "could not read from online version request" end
  local main = textutils.unserializeJSON(json)
  if not main then return nil, "could not parse online version request" end
  return main.sha
end

local function getInstalledVersion()
  local f = fs.open(VERSION_FILE, "r")
  if not f then return nil end
  local version = f.readAll()
  f.close()
  return version
end

local function downloadUpdate(dir)
  ---@type table<string, string>
  local requests = {}
  local totalRequests = 0

  ---Queues up a number of file requests.
  ---@param urlBase string
  ---@param root string
  ---@param filenames string[]
  local function addRequests(urlBase, root, filenames)
    totalRequests = totalRequests + #filenames
    for _, filename in ipairs(filenames) do
      requests[urlBase .. "/" .. filename] = root .. "/" .. filename
    end
  end

  local GITHUB_POSSSEIDON = "https://raw.githubusercontent.com/Possseidon/"

  addRequests(GITHUB_POSSSEIDON .. "cc-code/main", "", {
    "code/highlighter/vscode.lua",
    "code/polyfill/table.lua",
    "code/class.lua",
    "code/Code.lua",
    "code/Editor.lua",
    "code/Highlighter.lua",
    "code.lua",
  })

  addRequests(GITHUB_POSSSEIDON .. "lua-lexers/main", "code/lexers", {
    "lexLua.lua",
  })

  term.setTextColor(colors.lightBlue)
  write("Downloading... ")

  for url, _filename in pairs(requests) do
    assert(http.request { url = url, binary = true })
  end

  term.setTextColor(colors.blue)
  local x, y = term.getCursorPos()

  local requestsDone = 0

  local function updateStatus()
    term.setCursorPos(x, y)
    write("[" .. requestsDone .. "/" .. totalRequests .. "]")
  end

  updateStatus()

  ---Handles a single http event, ignoring other events.
  ---@param event string
  ---@param ... any
  ---@return boolean ok, string? error
  local function handleHttpEvent(event, ...)
    if event == "http_success" then
      local url, response = ...
      local filename = requests[url]
      if filename then
        requests[url] = nil
      end
      local file, err = fs.open(fs.combine(dir, filename), "wb")
      if not file then
        return false, err
      end
      file.write(response.readAll())
      file.close()
      requestsDone = requestsDone + 1
      updateStatus()
      return true
    elseif event == "http_failure" then
      local url, err, _response = ...
      local filename = requests[url]
      if filename then
        return false, "Download Failed: " .. filename .. " (" .. err .. ")"
      end
    end
    return true
  end

  while next(requests) do
    ---@diagnostic disable-next-line: undefined-field
    local ok, err = handleHttpEvent(os.pullEvent())
    if not ok then
      print()
      return false, err
    end
  end

  print()
  return true
end

local function installUpdate(stagingDir, newVersion, oldVersion)
  assert(fs.exists(stagingDir), "staging dir missing")
  fs.delete("/code")
  fs.delete("/code.lua")
  fs.move(fs.combine(stagingDir, "code"), "/code")
  fs.move(fs.combine(stagingDir, "code.lua"), "/code.lua")
  fs.delete(stagingDir)

  local f = assert(fs.open(VERSION_FILE, "w"))
  f.write(newVersion)
  f.close()

  term.setTextColor(colors.lightBlue)
  write("Installed Version: ")
  if oldVersion then
    term.setTextColor(colors.red)
    write(oldVersion:sub(1, 8))
    term.setTextColor(colors.white)
    write(" -> ")
  end
  term.setTextColor(colors.green)
  print(newVersion:sub(1, 8))
end

local function getStagingDir()
  local baseName = "/code_update"
  local stagingDir = baseName
  local i = 1
  while fs.exists(stagingDir) do
    stagingDir = baseName .. i
    i = i + 1
  end
  return stagingDir
end

local onlineVersion, onlineVersionError = getOnlineVersion()
if not onlineVersion then
  printError("Update Failed: " .. onlineVersionError)
  return
end

local installedVersion = getInstalledVersion()
if onlineVersion == installedVersion then
  term.setTextColor(colors.lightBlue)
  print("cc-code already up to date")
  term.setTextColor(colors.lightGray)
  print("To force an update, delete /code/version")
  return
end

term.setTextColor(colors.lightBlue)
print((installedVersion and "Updating" or "Installing") .. " cc-code...")

local stagingDir = getStagingDir()

local ok, err = downloadUpdate(stagingDir)
if not ok then
  fs.delete(stagingDir)
  printError(err)
  return
end

if getOnlineVersion() ~= onlineVersion then
  fs.delete(stagingDir)
  printError("Online Version no longer matches the just downloaded version.")
  printError("An update was just pushed. Please try again.")
  return
end

installUpdate(stagingDir, onlineVersion, installedVersion)

term.setTextColor(colors.white)
