-- modules/keydetect.lua
-- Detects the musical key (TOM) from the Reaper project filename.
--
-- Supported formats (case-insensitive):
--   "Song Name_D.RPP"           → D
--   "Song Name - Am.RPP"        → Am
--   "Song Name [Cm].RPP"        → Cm
--   "Song Name (Gb).RPP"        → Gb
--   "Song Name TOM D.RPP"       → D

local KeyDetect = {}

-- All 12 chromatic keys shown in the bottom bar (in display order)
KeyDetect.CHROMATIC = {"C","Db","D","Eb","E","F","Gb","G","Ab","A","Bb","B"}

-- Full list (minor variants tried first to avoid partial matches)
-- e.g. "Am" must be tried before "A"
local ORDERED_KEYS = {
  "Dbm","Ebm","Gbm","Abm","Bbm",
  "Cm","Dm","Em","Fm","Gm","Am","Bm",
  "Db","Eb","Gb","Ab","Bb",
  "C","D","E","F","G","A","B",
}

-- Separators that can appear before/after the key token in the filename
local SEP = "[%s%_%-%(%[%{]"
local SEP_END = "[%)%]%}%s%_%-%.]?"

--- Detect key from a project file name.
-- @param filename  e.g. "Uma Carta Viva_D.RPP" or full path
-- @return  key string (e.g. "D", "Am") or nil if not found
function KeyDetect.detect(filename)
  if not filename or filename == "" then return nil end

  -- Work with just the base filename, strip path and extension
  local name = filename:match("([^/\\]+)$") or filename
  name = name:gsub("%.[Rr][Pp][Pp]$", "")

  for _, key in ipairs(ORDERED_KEYS) do
    -- Simple approach: look for the key preceded and followed by a separator or end-of-string
    -- We do a case-insensitive comparison by uppercasing both
    local upper_name = name:upper()
    local upper_key  = key:upper()

    -- Pattern: separator + KEY + (separator or end)
    local pattern = SEP .. upper_key .. SEP_END .. "$"

    if upper_name:match(pattern) then
      return key
    end

    -- Also match "TOM: KEY" or "TOM KEY" patterns
    local tom_pattern = "TOM[:%s]+" .. upper_key .. SEP_END .. "$"
    if upper_name:match(tom_pattern) then
      return key
    end
  end

  return nil
end

--- Get the root chromatic note from a key (strips minor 'm').
-- e.g. "Am" → "A", "Cm" → "C", "G" → "G"
-- @return  one of the 12 chromatic keys or nil
function KeyDetect.get_root(key)
  if not key then return nil end
  return key:gsub("m$", "")
end

--- Check if a chromatic button label is the active key.
-- @param btn_label  e.g. "C", "Db"
-- @param current_key  e.g. "Cm", "D"
function KeyDetect.is_active(btn_label, current_key)
  if not current_key then return false end
  return btn_label == KeyDetect.get_root(current_key)
end

return KeyDetect
