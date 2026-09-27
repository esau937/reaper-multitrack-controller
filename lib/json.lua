-- json.lua — Pure Lua JSON encoder/decoder
-- Based on json.lua by rxi (MIT License)

local json = {}

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function kind_of(obj)
  if type(obj) ~= "table" then return type(obj) end
  local i = 1
  for _ in pairs(obj) do
    if obj[i] ~= nil then i = i + 1 else return "object" end
  end
  if i == 1 then return "object" else return "array" end
end

local function escape_str(s)
  local in_char  = {"\\", '"', "/", "\b", "\f", "\n", "\r", "\t"}
  local out_char = {"\\", '"', "/",  "b",  "f",  "n",  "r",  "t"}
  for i, c in ipairs(in_char) do s = s:gsub(c, "\\" .. out_char[i]) end
  return s
end

local function skip_delim(str, pos, delim, err_if_missing)
  pos = pos + #str:match("^%s*", pos)
  if str:sub(pos, pos) ~= delim then
    if err_if_missing then
      error("Expected " .. delim .. " near position " .. pos)
    end
    return pos, false
  end
  return pos + 1, true
end

local function parse_str_val(str, pos, val)
  val = val or ""
  if pos > #str then error("End of input while parsing string.") end
  local c = str:sub(pos, pos)
  if c == '"' then return val, pos + 1 end
  if c ~= "\\" then return parse_str_val(str, pos + 1, val .. c) end
  local esc = {b="\b", f="\f", n="\n", r="\r", t="\t"}
  local nc = str:sub(pos + 1, pos + 1)
  return parse_str_val(str, pos + 2, val .. (esc[nc] or nc))
end

local function parse_num_val(str, pos)
  local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  local val = tonumber(num_str)
  if not val then error("Error parsing number at position " .. pos) end
  return val, pos + #num_str
end

-- ─── Parser ─────────────────────────────────────────────────────────────────

json.null = {}

local function parse(str, pos, end_delim)
  pos = (pos or 1) + #str:match("^%s*", pos or 1)
  if pos > #str then error("Unexpected end of input.") end
  local first = str:sub(pos, pos)

  if first == "{" then
    local obj, key, delim_found = {}, true, true
    pos = pos + 1
    while true do
      key, pos = parse(str, pos, "}")
      if key == nil then return obj, pos end
      if not delim_found then error("Comma missing between object items.") end
      pos = skip_delim(str, pos, ":", true)
      obj[key], pos = parse(str, pos)
      pos, delim_found = skip_delim(str, pos, ",")
    end

  elseif first == "[" then
    local arr, val, delim_found = {}, true, true
    pos = pos + 1
    while true do
      val, pos = parse(str, pos, "]")
      if val == nil then return arr, pos end
      if not delim_found then error("Comma missing between array items.") end
      arr[#arr + 1] = val
      pos, delim_found = skip_delim(str, pos, ",")
    end

  elseif first == '"' then
    return parse_str_val(str, pos + 1)
  elseif first == "-" or first:match("%d") then
    return parse_num_val(str, pos)
  elseif first == "t" then
    return true, pos + 4
  elseif first == "f" then
    return false, pos + 5
  elseif first == "n" and str:sub(pos, pos+3) == "null" then
    return json.null, pos + 4
  elseif end_delim and first == end_delim then
    return nil, pos + 1
  end
  error("Invalid JSON at position " .. pos .. ': "' .. str:sub(pos, pos+10) .. '"')
end

-- ─── Encoder ────────────────────────────────────────────────────────────────

local function stringify(obj)
  local t = kind_of(obj)
  if t == "array" then
    local parts = {}
    for _, v in ipairs(obj) do parts[#parts+1] = stringify(v) end
    return "[" .. table.concat(parts, ",") .. "]"
  elseif t == "object" then
    local parts = {}
    for k, v in pairs(obj) do
      if v ~= json.null then
        parts[#parts+1] = '"' .. tostring(k) .. '":' .. stringify(v)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return '"' .. escape_str(obj) .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(obj)
  elseif obj == json.null then
    return "null"
  end
  return "null"
end

-- Pretty-print with indentation
local function stringify_pretty(obj, indent, level)
  indent = indent or "  "
  level  = level  or 0
  local pad = string.rep(indent, level)
  local pad1 = string.rep(indent, level + 1)
  local t = kind_of(obj)

  if t == "array" then
    if #obj == 0 then return "[]" end
    local parts = {}
    for _, v in ipairs(obj) do
      parts[#parts+1] = pad1 .. stringify_pretty(v, indent, level+1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  elseif t == "object" then
    local parts = {}
    for k, v in pairs(obj) do
      parts[#parts+1] = pad1 .. '"' .. tostring(k) .. '": ' ..
                         stringify_pretty(v, indent, level+1)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  elseif t == "string" then
    return '"' .. escape_str(obj) .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(obj)
  end
  return "null"
end

-- ─── Public API ─────────────────────────────────────────────────────────────

function json.encode(obj, pretty)
  if pretty then return stringify_pretty(obj) end
  return stringify(obj)
end

function json.decode(str)
  if type(str) ~= "string" then return nil, "Input must be a string" end
  local ok, val_or_err = pcall(parse, str)
  if ok then return val_or_err end
  return nil, val_or_err
end

return json
