table.move = table.move or function(a1, f, e, t, a2)
  a2 = a2 or a1

  if a1 ~= a2 or f ~= t then
    local offset = t - f
    local dir = 1

    if f < t then
      f, e = e, f
      dir = -1
    end

    for i = f, e, dir do
      a2[i + offset] = a1[i]
    end
  end

  return a2
end

return table
