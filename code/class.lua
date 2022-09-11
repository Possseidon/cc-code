local defaultMetatable = { __index = { new = function() end } }

return function(metatable)
  setmetatable(metatable, defaultMetatable)
  return function(...)
    local instance = {}
    setmetatable(instance, { __index = metatable })
    instance:new(...)
    return instance
  end
end
