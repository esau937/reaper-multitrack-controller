-- modules/repertoire.lua
-- Manages setlists (repertório): SALVAR, ABRIR, REPERTÓRIO.
-- Save standard RPL project lists; retain read compatibility with legacy JSON.

local Repertoire = {}

-- Resolve the data/setlists/ path relative to this script
local _script_dir = ""

function Repertoire.init(script_dir)
  _script_dir = script_dir
  -- Ensure data/setlists/ directory exists
  local dir = script_dir .. "data/setlists/"
  -- reaper doesn't have mkdir, but writing a file in a new path works on Windows
  -- We rely on the directory existing (created manually or by first save)
end

local function setlists_dir()
  return _script_dir .. "data/setlists/"
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  -- API nativa do REAPER, compat�vel com Windows e macOS.
  local dir = path:match("^(.*[/\\])")
  if dir and reaper.RecursiveCreateDirectory then reaper.RecursiveCreateDirectory(dir, 0) end
  local f = io.open(path, "w")
  if not f then return false, "Não foi possível gravar: " .. path end
  local written, err = f:write(content)
  local closed, close_err = f:close()
  if not written or not closed then return false, err or close_err end
  return true
end

-- ─── Current project list ────────────────────────────────────────────────────

--- Capture all currently open projects in Reaper.
-- Returns array of { name, path, key }
local function capture_open_projects(keydetect)
  local projects = {}
  local i = 0
  while true do
    local proj, path = reaper.EnumProjects(i, "")
    if not proj then break end
    local fname = path:match("([^/\\]+)$") or path
    projects[#projects + 1] = {
      name = fname:gsub("%.[Rr][Pp][Pp]$", ""),
      path = path,
      key  = keydetect and keydetect.detect(fname) or nil,
    }
    i = i + 1
  end
  return projects
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--- SALVAR — save current open projects as a named setlist.
-- @param state   global app state (pads etc.)
-- @param json    json module
-- @param keydetect  keydetect module
function Repertoire.save(state, json, keydetect)
  if not reaper.JS_Dialog_BrowseForSaveFile then
    reaper.ShowMessageBox("A janela Salvar como requer a extensao JS_ReaScriptAPI.", "Salvar Setlist", 0)
    return
  end
  local songs = capture_open_projects(keydetect)
  if #songs == 0 then return end
  for _, song in ipairs(songs) do
    if not song.path or song.path == "" then
      reaper.ShowMessageBox("Salve cada projeto aberto como .RPP antes de salvar o setlist.", "Salvar Setlist", 0)
      return
    end
  end
  local folder = reaper.GetExtState("MultitrackController", "setlist_folder")
  local result, path = reaper.JS_Dialog_BrowseForSaveFile(
    "Salvar Setlist", folder, "Novo Setlist.rpl",
    "Reaper Project List (*.rpl)\0*.rpl\0\0")
  if result ~= 1 and result ~= true then return end
  if not path or path == "" then return end
  if not path:lower():match("%.rpl$") then
    path = path:gsub("%.[Jj][Ss][Oo][Nn]$", "") .. ".rpl"
    -- The native dialog confirmed the selected name, not the appended name.
    local existing = io.open(path, "r")
    if existing then
      existing:close()
      if reaper.ShowMessageBox("Substituir o arquivo existente?\n" .. path, "Salvar Setlist", 4) ~= 6 then return end
    end
  end
  local lines = {}
  for _, song in ipairs(songs) do lines[#lines + 1] = song.path end
  local ok, err = write_file(path, table.concat(lines, "\n") .. "\n")
  if not ok then
    reaper.ShowMessageBox("Erro ao salvar:\n" .. (err or ""), "Salvar Setlist", 0)
    return
  end
  reaper.SetExtState("MultitrackController", "setlist_folder", path:match("^(.*[/\\])") or "", true)
  state.setlist = {name = path:match("([^/\\]+)$"), songs = songs}
  reaper.ShowMessageBox("Setlist RPL salvo com sucesso!\n\n" .. path, "Multitrack Controller", 0)
end

local function decode_setlist(content, path, json)
  if path:lower():match("%.json$") then return json.decode(content) end
  local data = {name = path:match("([^/\\]+)$") or "Setlist", songs = {}}
  content = content:gsub("^\239\187\191", "")
  local folder = path:match("^(.*[/\\])") or ""
  for line in content:gmatch("[^\r\n]+") do
    local project = line:match('^%s*"(.-)"%s*$') or line:match("^%s*(.-)%s*$")
    if project ~= "" then
      if not project:match("^%a:[/\\]") and not project:match("^[/\\]") then project = folder .. project end
      if not project:lower():match("%.rpp$") then return nil, "O RPL deve conter um caminho .RPP por linha." end
      data.songs[#data.songs + 1] = {path = project, name = project:match("([^/\\]+)$") or project}
    end
  end
  if #data.songs == 0 then return nil, "O setlist esta vazio." end
  return data
end

--- ABRIR — open a setlist file via dialog and return the loaded data.
-- @return  setlist table or nil
function Repertoire.load(state, json)
  local ok, path = reaper.GetUserFileNameForRead("", "Abrir Setlist (RPL ou JSON)", "rpl;json")
  if not ok then return nil end

  local content = read_file(path)
  if not content then
    reaper.ShowMessageBox("Não foi possível ler: " .. path, "Multitrack Controller", 0)
    return nil
  end

  local data, err = decode_setlist(content, path, json)
  if not data then
    reaper.ShowMessageBox("Erro ao ler setlist:\n" .. (err or ""), "Multitrack Controller", 0)
    return nil
  end

  -- Ask user to confirm loading (will open projects in Reaper)
  local names = {}
  for _, s in ipairs(data.songs or {}) do names[#names+1] = "  • " .. s.name end
  local msg = 'Carregar setlist "' .. (data.name or "") .. '"?\n\nMúsicas:\n' .. table.concat(names, "\n")
  local answer = reaper.ShowMessageBox(msg, "Multitrack Controller", 4)  -- 4 = Yes/No
  if answer ~= 6 then return nil end  -- 6 = Yes

  -- Open each project in a new tab
  for _, song in ipairs(data.songs or {}) do
    if song.path and song.path ~= "" then
      local proj_name = reaper.GetProjectName(0)
      local num_tracks = reaper.CountTracks(0)
      
      -- Se a aba atual j� tem alguma m�sica carregada, cria uma aba nova
      if proj_name ~= "" or num_tracks > 0 then
        reaper.Main_OnCommand(40859, 0) -- New project tab
      end
      
      reaper.Main_openProject("noprompt:" .. song.path)
    end
  end

  state.setlist = data
  return data
end

--- REPERTÓRIO — list saved setlists and let user pick one.
-- Returns the loaded setlist data or nil.
function Repertoire.browse(state, json)
  -- Collect .json files in the setlists folder
  local dir = reaper.GetExtState("MultitrackController", "setlist_folder")
  if dir == "" then dir = setlists_dir() end
  local files = {}

  -- Use Reaper's EnumerateFiles (available on all platforms)
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():match("%.rpl$") or f:lower():match("%.json$") then files[#files+1] = f end
    i = i + 1
  end

  if #files == 0 then
    reaper.ShowMessageBox("Nenhum setlist salvo encontrado em:\n" .. dir, "Multitrack Controller", 0)
    return nil
  end

  -- Build a selection list
  local labels = table.concat(files, "\n")
  local ok, chosen = reaper.GetUserInputs(
    "Repertório — Escolha um setlist",
    1,
    "Arquivo (copie um nome da lista):,extrawidth=300\n\n" .. labels,
    files[1] or ""
  )
  if not ok or chosen == "" then return nil end

  local path = dir .. chosen
  local content = read_file(path)
  if not content then
    reaper.ShowMessageBox("Arquivo não encontrado: " .. path, "Multitrack Controller", 0)
    return nil
  end

  local data, err = decode_setlist(content, path, json)
  if not data then
    reaper.ShowMessageBox("Erro ao ler setlist:\n" .. (err or ""), "Multitrack Controller", 0)
    return nil
  end

  state.setlist = data
  return data
end

return Repertoire


