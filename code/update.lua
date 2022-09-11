print("Installing cc-code...")

fs.delete("code.lua")
fs.delete("code")

local requests = {}

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
  "code/update.lua",
  "code.lua",
})

addRequests(githubPossseidon .. "lua-lexers/main", "code/lexers", {
  "lexLua.lua",
})

for url, _filename in pairs(requests) do
  assert(http.request(url))
end

local function handleEvent(event, ...)
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
    local url, err, _resonse = ...
    local filename = requests[url]
    if filename then
      return false, filename .. "\n-> " .. err
    end
  end
  return true
end

while next(requests) do
  ---@diagnostic disable-next-line: undefined-field
  local ok, err = handleEvent(os.pullEvent())
  if not ok then
    printError(err)
    break
  end
end

print("Done!")
