-- modules/pads.lua
-- Manages PAD and PAD INTRO buttons.
-- MP3 files are played via reaper.PlayPreviewEx() (native, low latency).
-- Right-click opens a file dialog to select the MP3.

local Pads = {}

-- Internal preview handles (to allow stopping)
local _preview_handles = {}

-- ─── Playback ────────────────────────────────────────────────────────────────

--- Start playing a pad's MP3 file.
-- @param pad  { name, file, playing, loop }
function Pads.resolve_file(pad, current_key)
  local folder = reaper.GetExtState("MultitrackController", "pads_folder")
  if folder and folder ~= "" and current_key and current_key ~= "" then
    local sep = folder:match("\\") and "\\" or "/"
    
    local relative_majors = {
      ["am"] = "c",  ["a#m"] = "c#", ["bbm"] = "db",
      ["bm"] = "d",  ["cm"] = "eb",  ["c#m"] = "e",
      ["dm"] = "f",  ["d#m"] = "f#", ["ebm"] = "f#",
      ["em"] = "g",  ["fm"] = "g#",  ["f#m"] = "a",
      ["gm"] = "a#", ["g#m"] = "b",  ["abm"] = "b"
    }
    
    -- We can also map enharmonics for the major files if needed, but let's try to match what's there.
    local target_key = current_key:lower()
    local target_relative = relative_majors[target_key]
    
    local found_exact = nil
    local found_relative = nil
    
    local i = 0
    while true do
      local file = reaper.EnumerateFiles(folder, i)
      if not file then break end
      local name = (file:match("(.+)%.[^.]+$") or file):lower()
      
      if name == target_key then
        found_exact = folder .. sep .. file
      end
      
      if target_relative then
         if name == target_relative then
           found_relative = folder .. sep .. file
         elseif target_relative == "c#" and name == "db" then found_relative = folder .. sep .. file
         elseif target_relative == "db" and name == "c#" then found_relative = folder .. sep .. file
         elseif target_relative == "d#" and name == "eb" then found_relative = folder .. sep .. file
         elseif target_relative == "eb" and name == "d#" then found_relative = folder .. sep .. file
         elseif target_relative == "f#" and name == "gb" then found_relative = folder .. sep .. file
         elseif target_relative == "gb" and name == "f#" then found_relative = folder .. sep .. file
         elseif target_relative == "g#" and name == "ab" then found_relative = folder .. sep .. file
         elseif target_relative == "ab" and name == "g#" then found_relative = folder .. sep .. file
         elseif target_relative == "a#" and name == "bb" then found_relative = folder .. sep .. file
         elseif target_relative == "bb" and name == "a#" then found_relative = folder .. sep .. file
         end
      end
      
      -- Also handle enharmonics for exact match if it's a major key
      if not target_relative then
         if target_key == "c#" and (name == "db" or name == "csus") then found_exact = folder .. sep .. file
         elseif target_key == "db" and (name == "c#" or name == "csus") then found_exact = folder .. sep .. file
         elseif target_key == "d#" and (name == "eb" or name == "dsus") then found_exact = folder .. sep .. file
         elseif target_key == "eb" and (name == "d#" or name == "dsus") then found_exact = folder .. sep .. file
         elseif target_key == "f#" and (name == "gb" or name == "fsus") then found_exact = folder .. sep .. file
         elseif target_key == "gb" and (name == "f#" or name == "fsus") then found_exact = folder .. sep .. file
         elseif target_key == "g#" and (name == "ab" or name == "gsus") then found_exact = folder .. sep .. file
         elseif target_key == "ab" and (name == "g#" or name == "gsus") then found_exact = folder .. sep .. file
         elseif target_key == "a#" and (name == "bb" or name == "asus") then found_exact = folder .. sep .. file
         elseif target_key == "bb" and (name == "a#" or name == "asus") then found_exact = folder .. sep .. file
         
         -- Handle the direct match if the target_key itself doesn't trigger the enharmonic block
         -- But wait, if target_key is "c#" and name is "c#", it's already caught by `name == target_key`.
         -- What if target_key is "c#" and file is "csus"? Handled above.
         end
      end
      
      -- Also handle if the script asks for the relative minor but the file is named "sus"
      if target_relative then
         if target_relative == "c#" and (name == "db" or name == "csus") then found_relative = folder .. sep .. file
         elseif target_relative == "db" and (name == "c#" or name == "csus") then found_relative = folder .. sep .. file
         elseif target_relative == "d#" and (name == "eb" or name == "dsus") then found_relative = folder .. sep .. file
         elseif target_relative == "eb" and (name == "d#" or name == "dsus") then found_relative = folder .. sep .. file
         elseif target_relative == "f#" and (name == "gb" or name == "fsus") then found_relative = folder .. sep .. file
         elseif target_relative == "gb" and (name == "f#" or name == "fsus") then found_relative = folder .. sep .. file
         elseif target_relative == "g#" and (name == "ab" or name == "gsus") then found_relative = folder .. sep .. file
         elseif target_relative == "ab" and (name == "g#" or name == "gsus") then found_relative = folder .. sep .. file
         elseif target_relative == "a#" and (name == "bb" or name == "asus") then found_relative = folder .. sep .. file
         elseif target_relative == "bb" and (name == "a#" or name == "asus") then found_relative = folder .. sep .. file
         end
      end

      i = i + 1
    end
    
    if found_exact then return found_exact end
    if found_relative then return found_relative end
  end
  return pad.file
end

--- Start playing a pad's MP3 file.
-- @param pad  { name, file, playing, loop }
function Pads.play(pad, current_key)
  local file_to_play = Pads.resolve_file(pad, current_key)
  if not file_to_play or file_to_play == "" then
    reaper.ShowMessageBox(
      "Nenhum arquivo encontrado para o tom \"" .. (current_key or "N/A") .. "\" na pasta de pads.\n\nOu configure um arquivo manualmente com o botao direito.",
      "Multitrack Controller", 0)
    return
  end

  if pad.playing and _preview_handles[pad.name] then
    Pads.stop(pad)
    return
  end

  local src = reaper.PCM_Source_CreateFromFile(file_to_play)
  if not src then
    reaper.ShowMessageBox("Erro ao carregar: \"" .. file_to_play .. "\"", "Multitrack Controller", 0)
    return
  end

  local handle = nil
  if reaper.PlayPreviewEx then
    handle = reaper.PlayPreviewEx(src, pad.loop and 1 or 0, 1.0)
  elseif reaper.Xen_StartSourcePreview then
    reaper.Xen_StartSourcePreview(src, 1.0, pad.loop == true)
    handle = { type = "xen", src = src }
  else
    reaper.ShowMessageBox("Sua vers�o do REAPER n�o suporta a fun��o nativa de Pads (PlayPreviewEx). Atualize o REAPER para a vers�o 7.07+ ou instale a extens�o SWS.", "Multitrack Controller", 0)
    return
  end

  _preview_handles[pad.name] = handle
  pad.playing = true
end

--- Stop a playing pad.
function Pads.stop(pad)
  local handle = _preview_handles[pad.name]
  if handle then
    if type(handle) == "table" and handle.type == "xen" then
      if reaper.Xen_StopSourcePreview then reaper.Xen_StopSourcePreview(handle.src) end
    else
      if reaper.StopPreview then reaper.StopPreview(handle) end
    end
    _preview_handles[pad.name] = nil
  end
  pad.playing = false
end

--- Toggle play/stop for a pad.
function Pads.toggle(pad, current_key)
  if pad.playing then
    Pads.stop(pad)
  else
    Pads.play(pad, current_key)
  end
end

-- ─── Configuration ───────────────────────────────────────────────────────────

--- Open a file dialog to select an MP3 for a pad.
-- Returns the selected path or nil.
function Pads.select_file()
  local ok, file = reaper.GetUserFileNameForRead("", "Selecionar arquivo de pad", "mp3,wav,ogg,flac")
  if ok then return file end
  return nil
end

--- Configure a pad (select file, name, mode).
-- Called on right-click of a pad button.
-- @param pad  the pad table (modified in-place)
function Pads.configure(pad)
  local path = Pads.select_file()
  if path then
    pad.file = path
    -- Auto-name from filename
    local fname = path:match("([^/\\]+)$") or path
    fname = fname:gsub("%.[^.]+$", "")  -- remove extension
    if fname ~= "" then pad.name = fname end
  end
end

-- ─── Serialization ───────────────────────────────────────────────────────────

--- Serialize pad list to a plain table (for JSON).
function Pads.to_table(pads)
  local out = {}
  for i, p in ipairs(pads) do
    out[i] = { name = p.name, file = p.file or "", loop = p.loop or false }
  end
  return out
end

--- Restore pad list from a plain table (from JSON).
function Pads.from_table(data, pads)
  for i, d in ipairs(data) do
    if pads[i] then
      pads[i].name = d.name or pads[i].name
      pads[i].file = d.file ~= "" and d.file or nil
      pads[i].loop = d.loop or false
    end
  end
end

return Pads






