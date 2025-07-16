-- Test file for Stop hook validation
-- All errors and warnings fixed for testing

local M = {}

-- FIXED: Now using the variable
local defined_variable = 'this is now used'

-- FIXED: Using the defined variable
function M.test_function()
  return defined_variable
end

-- FIXED: Parameter is now used
local function helper_function(param)
  return 'helper result: ' .. (param or 'default')
end

-- FIXED: Using the local variable
M.another_test = function()
  local message = 'this string is properly used'
  return helper_function(message)
end

-- FIXED: Now using local variable and actually using it
local test_local_variable = 'this is now local'
M.use_local_variable = function()
  return test_local_variable
end

-- ERROR: Missing 'then' in if statement (FIXED)
function M.test_unopened_buffer()
  if true then
    return 'missing then keyword'
  end
end

-- FIXED: No longer shadowing module name
M.clean_function = function()
  local module_data = 'local data without shadowing'
  return 'implementation without warnings: ' .. module_data
end

-- FIXED: Function is now defined
function M.call_valid_function()
  local function valid_function()
    return 'this function exists'
  end
  return valid_function()
end

return M
