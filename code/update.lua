print("Installing cc-code...")

fs.delete("code.lua")
fs.delete("code")

---@type table<string, string>
local requests = {}

---Queues up a number of file requests.
---@param urlBase string
---@param root string
---@param filenames string[]
local function addRequests(urlBase, root, filenames)
  for _, filename in ipairs(filenames) do
    requests[urlBase .. "/" .. filename] = root .. "/" .. filename
  end
end

local githubPossseidon = "https://raw.githubusercontent.com/Possseidon/"

addRequests(githubPossseidon .. "cc-code/main", "", {
  "code/highlighter/vscode.lua",
  "code/class.lua",
  "code/Code.lua",
  "code/Editor.lua",
  "code/Highlighter.lua",
  "code.lua",
})

addRequests(githubPossseidon .. "lua-lexers/main", "code/lexers", {
  "lexLua.lua",
})

for url, _filename in pairs(requests) do
  assert(http.request { url = url, binary = true })
end

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
    local file = fs.open("/" .. filename, "wb")
    file.write(response.readAll())
    file.close()
    print(filename)
    return true
  elseif event == "http_failure" then
    local url, err, _response = ...
    local filename = requests[url]
    if filename then
      return false, filename .. "\n-> " .. err
    end
  end
  return true
end

while next(requests) do
  ---@diagnostic disable-next-line: undefined-field
  local ok, err = handleHttpEvent(os.pullEvent())
  if not ok then
    printError(err)
    break
  end
end

print("Done!")
