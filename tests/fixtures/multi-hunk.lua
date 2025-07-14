local function first_function()
  print('First function')
  return 1
end

local function second_function()
  print('Second function')
  return 2
end

local function third_function()
  print('Third function')
  return 3
end

local function fourth_function()
  print('Fourth function')
  return 4
end

return {
  first = first_function,
  second = second_function,
  third = third_function,
  fourth = fourth_function,
}