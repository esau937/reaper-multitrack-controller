-- Automatic, one-time chord-map generator. It deliberately listens only to
-- piano and bass tracks, then stores <project>.chords.json beside the project.
local Analyzer = {}

local pending = {}
local function quote(value)
  return '"' .. tostring(value):gsub('"', '\\"') .. '"'
end

local function project_dir(path)
  return path:match("^(.*)[/\\][^/\\]+$")
end

local function file_stem(path)
  return (path:match("([^/\\]+)%.rpp$") or path:match("([^/\\]+)$") or "project")
end

local function source_tracks(proj)
  local tracks, names = {}, {}
  for index = 0, reaper.CountTracks(proj) - 1 do
    local track = reaper.GetTrack(proj, index)
    local _, name = reaper.GetTrackName(track, "")
    local normalized = (name or ""):upper()
    if normalized:find("PIANO", 1, true) or normalized:find("BASS", 1, true) or
       normalized:find("BAIXO", 1, true) or normalized:find("CONTRABAIXO", 1, true) then
      tracks[#tracks + 1], names[#names + 1] = track, name
    end
  end
  return tracks, names
end

local function set_render_property(proj, key, value)
  reaper.GetSetProjectInfo(proj, key, value, true)
end

local function create_render(proj, project_path, tracks)
  local folder = project_dir(project_path)
  if not folder then return nil, "Salve o projeto antes de analisar os acordes." end
  local stem = file_stem(project_path) .. ".chords-input"
  local input = folder .. "/" .. stem .. ".wav"
  local old = {
    file = ({reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", "", false)})[2],
    pattern = ({reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", "", false)})[2],
    format = ({reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", "", false)})[2],
    settings = reaper.GetSetProjectInfo(proj, "RENDER_SETTINGS", 0, false),
    bounds = reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 0, false),
  }
  local mute = {}
  for index = 0, reaper.CountTracks(proj) - 1 do
    local track = reaper.GetTrack(proj, index)
    mute[track] = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
    local keep = false
    for _, wanted in ipairs(tracks) do if wanted == track then keep = true; break end end
    reaper.SetMediaTrackInfo_Value(track, "B_MUTE", keep and 0 or 1)
  end
  reaper.PreventUIRefresh(1)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", folder, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", stem, true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", string.pack("c4", "wave"), true)
  set_render_property(proj, "RENDER_SETTINGS", 0) -- master mix, containing only piano+bass
  set_render_property(proj, "RENDER_BOUNDSFLAG", 1) -- whole project
  local rendered, render_error = pcall(reaper.Main_OnCommand, 41824, 0) -- no render dialog
  for track, was_muted in pairs(mute) do reaper.SetMediaTrackInfo_Value(track, "B_MUTE", was_muted) end
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", old.file or "", true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", old.pattern or "", true)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT", old.format or "", true)
  set_render_property(proj, "RENDER_SETTINGS", old.settings)
  set_render_property(proj, "RENDER_BOUNDSFLAG", old.bounds)
  reaper.PreventUIRefresh(-1)
  if not rendered then return nil, "Não foi possível renderizar piano e baixo: " .. tostring(render_error) end
  if not reaper.file_exists(input) then return nil, "Não foi possível renderizar piano e baixo." end
  return input
end

function Analyzer.ensure(proj, project_path, script_path)
  if not project_path or project_path == "" then return "Aguardando projeto ser salvo" end
  local output = project_path .. ".chords.json"
  if reaper.file_exists(output) then return "Pronto" end
  local error_file = output .. ".error"
  if reaper.file_exists(error_file) then
    local file = io.open(error_file, "r")
    local message = file and file:read("*l") or "falha desconhecida"
    if file then file:close() end
    return "Falha na análise: " .. (message or "falha desconhecida")
  end
  if (reaper.GetPlayState() & 1) ~= 0 then return "Aguardando parar" end
  if pending[project_path] then return "Analisando" end
  local tracks, names = source_tracks(proj)
  if #tracks == 0 then return "Aguardando pistas PIANO e BASS/BAIXO" end
  pending[project_path] = true
  local input, err = create_render(proj, project_path, tracks)
  if not input then pending[project_path] = nil; return err end
  local python = os.getenv("LOCALAPPDATA") .. "\\Programs\\Python\\Python311\\python.exe"
  local script = script_path .. "tools\\analyze_chords.py"
  local launcher = script_path .. "tools\\run_hidden.vbs"
  os.remove(error_file)
  local command = quote(os.getenv("WINDIR") .. "\\System32\\wscript.exe") .. " " .. quote(launcher) .. " " ..
    quote(python) .. " " .. quote(script) .. " " .. quote(input) .. " " .. quote(output)
  for _, name in ipairs(names) do command = command .. " " .. quote(name) end
  -- wscript returns immediately after starting Python, so REAPER never blocks.
  reaper.ExecProcess(command, -1)
  return "Analisando"
end

function Analyzer.status(project_path)
  if project_path and reaper.file_exists(project_path .. ".chords.json") then
    pending[project_path] = nil
    return "Pronto"
  end
  return project_path and pending[project_path] and "Analisando" or nil
end

-- Used only when the arrangement itself changes. This does not ask the user
-- to map anything: it merely rebuilds the same automatic sidecar next time.
function Analyzer.reset(project_path)
  if not project_path or project_path == "" then return end
  pending[project_path] = nil
  os.remove(project_path .. ".chords.json")
  os.remove(project_path .. ".chords.json.error")
end

return Analyzer
