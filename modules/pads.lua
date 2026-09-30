-- modules/pads.lua
-- Manages PAD and PAD INTRO buttons.
-- Audio files are played using the SWS CF_Preview API.
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

-- Playback uses the SWS CF preview API. Each pad owns its preview handle.
local fading_out_previews = {}
local fading_in_previews = {}
local pending_starts = {}

-- A preview em fade ainda esta tocando no REAPER, mesmo depois de o PAD deixar
-- de apontar para ela. Sempre a encerramos antes de iniciar outra preview do
-- mesmo PAD; caso contrario, cliques repetidos acumulam audios sobrepostos.
local function stop_preview(handle)
  pcall(reaper.CF_Preview_Stop, handle)
  fading_out_previews[handle] = nil
  fading_in_previews[handle] = nil
end

local function stop_fading_previews_for(pad)
  local pending = {}
  for handle, fade in pairs(fading_out_previews) do
    if fade.pad == pad then pending[#pending + 1] = handle end
  end
  for handle, fade in pairs(fading_in_previews) do
    if fade.pad == pad then pending[#pending + 1] = handle end
  end
  for _, handle in ipairs(pending) do stop_preview(handle) end
end

local function pad_error(message)
  reaper.ShowMessageBox(message, "Multitrack Controller - PAD", 0)
end

function Pads.process_fades()
  local now = reaper.time_precise()
  for handle, fade in pairs(fading_out_previews) do
    local elapsed = now - fade.start_time
    local progress = elapsed / fade.duration
    if progress >= 1.0 then
      pcall(reaper.CF_Preview_Stop, handle)
      fading_out_previews[handle] = nil
    else
      local current_vol = fade.start_vol * (1.0 - progress)
      pcall(reaper.CF_Preview_SetValue, handle, "D_VOLUME", current_vol)
    end
  end
  for handle, fade in pairs(fading_in_previews) do
    local elapsed = now - fade.start_time
    local progress = elapsed / fade.duration
    if progress >= 1.0 then
      pcall(reaper.CF_Preview_SetValue, handle, "D_VOLUME", fade.target_vol)
      fading_in_previews[handle] = nil
    else
      local current_vol = fade.target_vol * progress
      pcall(reaper.CF_Preview_SetValue, handle, "D_VOLUME", current_vol)
    end
  end

  -- Em troca de musica, o proximo PAD so inicia depois que o anterior
  -- terminou de sair. Isso evita o corte seco e tambem evita sobreposicao.
  local ready = {}
  for pad, start in pairs(pending_starts) do
    if now >= start.at then ready[#ready + 1] = { pad = pad, start = start } end
  end
  for _, item in ipairs(ready) do
    pending_starts[item.pad] = nil
    Pads.play(item.pad, item.start.key, item.start.fade_in_duration)
  end
end

function Pads.stop(pad, fast)
  pending_starts[pad] = nil
  local handle = _preview_handles[pad]
  if handle then
    local duration = fast and 0.5 or 2.0
    fading_out_previews[handle] = {
      pad = pad,
      start_time = reaper.time_precise(),
      duration = duration,
      start_vol = pad.volume or 1.0,
    }
    fading_in_previews[handle] = nil
    _preview_handles[pad] = nil
  else
    -- O botao PAD tambem deve cancelar uma transicao que esteja apenas no
    -- fade-out, sem deixar o audio antigo terminar escondido.
    stop_fading_previews_for(pad)
  end
  pad.playing = false
  return true
end

function Pads.stop_all()
  pending_starts = {}
  local pending = {}
  for pad in pairs(_preview_handles) do pending[#pending + 1] = pad end
  for _, pad in ipairs(pending) do Pads.stop(pad, true) end
  -- atexit e trocas rapidas tambem precisam encerrar as previews que ja
  -- estavam saindo em fade.
  local fading = {}
  for handle in pairs(fading_out_previews) do fading[#fading + 1] = handle end
  for handle in pairs(fading_in_previews) do fading[#fading + 1] = handle end
  for _, handle in ipairs(fading) do stop_preview(handle) end
end

local function ensure_pad_track(pad)
  local project = reaper.EnumProjects(-1)
  local owner = pad.id or "main"
  local tag = "P_EXT:MultitrackController_PAD"
  for i = 0, reaper.CountTracks(project) - 1 do
    local track = reaper.GetTrack(project, i)
    local _, value = reaper.GetSetMediaTrackInfo_String(track, tag, "", false)
    if value == owner then
      local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      if name == "PAD" then
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "PAD CONTROLLER", true)
        reaper.TrackList_AdjustWindows(false)
        reaper.UpdateArrange()
      end
      reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
      reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
      reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
      return project, track
    end
  end
  -- Insert at the top to avoid accidentally nesting inside an existing folder.
  reaper.Undo_BeginBlock2(project)
  reaper.InsertTrackAtIndex(0, true)
  local track = reaper.GetTrack(project, 0)
  if track then
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "PAD CONTROLLER", true)
    reaper.GetSetMediaTrackInfo_String(track, tag, owner, true)
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
    reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock2(project, "Create PAD CONTROLLER track", -1)
  end
  return project, track
end

function Pads.play(pad, current_key, fade_in_duration)
  -- Nao deixe um fade antigo continuar audivel quando o usuario troca de tom
  -- ou aperta PAD novamente. Ha apenas uma preview por PAD.
  if _preview_handles[pad] then Pads.stop(pad, true) end
  stop_fading_previews_for(pad)
  for _, api in ipairs({"CF_CreatePreview", "CF_Preview_SetValue", "CF_Preview_GetValue", "CF_Preview_Play", "CF_Preview_Stop", "CF_Preview_SetOutputTrack"}) do
    if not reaper[api] then
      pad_error("O PAD requer a extensao SWS com a API CF_Preview. Atualize a SWS e reinicie o REAPER.")
      return false
    end
  end
  local file = Pads.resolve_file(pad, current_key)
  if not file or file == "" then
    pad_error("Nenhum arquivo de pad encontrado para o tom " .. (current_key or "N/A"))
    return false
  end
  local src = reaper.PCM_Source_CreateFromFile(file)
  if not src then
    pad_error("Erro ao carregar: " .. file)
    return false
  end
  
  local project, track = ensure_pad_track(pad)
  if not track then
    reaper.PCM_Source_Destroy(src)
    pad_error("Nao foi possivel criar a faixa do PAD.")
    return false
  end

  -- Re-route any fading out previews to the newly active track. 
  -- This prevents REAPER from muting them when switching tabs (projects).
  for old_handle, _ in pairs(fading_out_previews) do
    pcall(reaper.CF_Preview_SetOutputTrack, old_handle, project, track)
  end

  -- CF_CreatePreview duplicates the source; release our original source.
  local created, handle = pcall(reaper.CF_CreatePreview, src)
  reaper.PCM_Source_Destroy(src)
  if not created or not handle then
    pad_error("Nao foi possivel criar a reproducao do pad.")
    return false
  end
  local ok, started = pcall(function()
    if not reaper.CF_Preview_SetValue(handle, "B_LOOP", pad.loop and 1 or 0) then return false end
    -- Começa com volume 0 para o fade-in suave manual
    if not reaper.CF_Preview_SetValue(handle, "D_VOLUME", 0.0) then return false end
    if not reaper.CF_Preview_SetOutputTrack(handle, project, track) then return false end
    return reaper.CF_Preview_Play(handle)
  end)
  if not ok or not started then
    pcall(reaper.CF_Preview_Stop, handle)
    pad_error("Nao foi possivel iniciar o pad: " .. tostring(started))
    return false
  end
  
  local target_v = pad.volume or 1.0
  fading_in_previews[handle] = {
    pad = pad,
    start_time = reaper.time_precise(),
    duration = fade_in_duration or 0.15,
    target_vol = target_v,
  }
  
  _preview_handles[pad] = handle
  pad.playing = true
  return true
end

--- Troca de pad entre musicas: sai por completo antes de iniciar o novo.
-- Nao use Pads.play aqui, pois ele reinicia a preview imediatamente.
function Pads.transition(pad, current_key)
  local fade_out_duration = 1.0
  local fade_in_duration = 1.0
  pending_starts[pad] = nil

  if _preview_handles[pad] then
    -- stop() usa 2 segundos por padrao. Para a troca entre abas usamos uma
    -- transicao audivel, mas sem alongar demais a passagem para a proxima musica.
    local handle = _preview_handles[pad]
    fading_out_previews[handle] = {
      pad = pad,
      start_time = reaper.time_precise(),
      duration = fade_out_duration,
      start_vol = pad.volume or 1.0,
    }
    fading_in_previews[handle] = nil
    _preview_handles[pad] = nil
    pad.playing = false
    pending_starts[pad] = {
      at = reaper.time_precise() + fade_out_duration,
      key = current_key,
      fade_in_duration = fade_in_duration,
    }
    return true
  end

  -- Se ja houver um fade saindo (troca de aba repetida), conserva o fade e
  -- apenas substitui o tom que sera iniciado ao final dele.
  for _, fade in pairs(fading_out_previews) do
    if fade.pad == pad then
      pending_starts[pad] = {
        at = fade.start_time + fade.duration,
        key = current_key,
        fade_in_duration = fade_in_duration,
      }
      return true
    end
  end

  return Pads.play(pad, current_key, fade_in_duration)
end

function Pads.is_active_or_transitioning(pad)
  if _preview_handles[pad] or pending_starts[pad] then return true end
  for _, fade in pairs(fading_out_previews) do
    if fade.pad == pad then return true end
  end
  return false
end

function Pads.show_routing(pad)
  local project, track = ensure_pad_track(pad)
  if track then
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(40293, 0) -- Track: View routing and I/O for current/last touched track
  end
end

function Pads.set_volume(pad, volume)
  pad.volume = volume
  local handle = _preview_handles[pad]
  if handle then
    pcall(reaper.CF_Preview_SetValue, handle, "D_VOLUME", volume)
  end
  for _, fade in pairs(fading_in_previews) do
    if fade.pad == pad then fade.target_vol = volume end
  end
end

function Pads.toggle(pad, current_key)
  if Pads.is_active_or_transitioning(pad) then
    return Pads.stop(pad, true)
  end
  return Pads.play(pad, current_key)
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
    reaper.SetExtState("MultitrackController", "pad_file", path, true)
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






