---Returns a constructor for a class using the given table for methods and class fields.
---
---Usage:
---
---```lua
------@class MyClass
---local MyClass = {}
---
---function MyClass:new(name)
---  self._name = name
---end
---
------Return the name of the thing.
---function MyClass:getName()
---  return self._name
---end
---
------@type fun(name: string): MyClass
---local new = require "code.class" (MyClass)
---return new
---```
local function class(newClass)
  local new = newClass.new
  local metatable = { __index = newClass }
  return new and function(...)
    local instance = setmetatable({}, metatable)
    new(instance, ...)
    return instance
  end or function()
    return setmetatable({}, metatable)
  end
end

return class
