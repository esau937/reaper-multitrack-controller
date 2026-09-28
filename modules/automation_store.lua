-- Persists automation data inside the active REAPER project.
-- Project ExtState travels with the .RPP and avoids machine-specific paths.

local json = require("json")
local Model = require("automation_model")

local Store = {}
local SECTION = "MultitrackControllerAutomation"
local KEY = "model"

local function validate_json(value)
  local ok, model = pcall(json.decode, value)
  if not ok or type(model) ~= "table" then return nil, "Não foi possível ler a automação salva." end
  local errors = Model.validate(model)
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  return model
end

-- A portable copy for Trackly and other players. It lives beside the .RPP,
-- so it can travel with the song without anyone parsing REAPER's project file.
function Store.sidecar_path(proj)
  -- EnumProjects(-1) is REAPER's active-project selector.  `proj` is kept in
  -- the public signature for consistency with load/save, but paths are always
  -- resolved from the currently open song.
  local _, project_file = reaper.EnumProjects(-1, "")
  if not project_file or project_file == "" then
    return nil, "Salve o projeto .RPP antes de criar o mapa universal do Trackly."
  end
  local folder, filename = project_file:match("^(.*[/\\])([^/\\]+)$")
  if not folder or not filename then
    return nil, "Não foi possível localizar a pasta do projeto para criar o mapa universal."
  end
  local basename = filename:gsub("%.rpp$", ""):gsub("%.RPP$", "")
  return folder .. basename .. ".trackly-automation.json"
end

function Store.export_sidecar(model, proj)
  local path, path_error = Store.sidecar_path(proj)
  if not path then return nil, path_error end
  local file, open_error = io.open(path, "w")
  if not file then return nil, "Não foi possível criar o mapa universal: " .. tostring(open_error) end
  local ok, write_error = file:write(json.encode(model, true))
  file:close()
  if not ok then return nil, "Não foi possível gravar o mapa universal: " .. tostring(write_error) end
  return path
end

function Store.load(proj)
  local retval, value = reaper.GetProjExtState(proj or 0, SECTION, KEY)
  if retval ~= 0 and value ~= "" then return validate_json(value) end

  local path = Store.sidecar_path(proj)
  if not path then return nil end
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return validate_json(content)
end

function Store.save(model, proj)
  local errors = Model.validate(model)
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  reaper.SetProjExtState(proj or 0, SECTION, KEY, json.encode(model))
  reaper.MarkProjectDirty(proj or 0)
  local path, export_error = Store.export_sidecar(model, proj)
  -- Internal .RPP saving succeeds even if the project does not yet have a
  -- filename. The third result lets the UI show that Trackly export is pending.
  return true, path, export_error
end

return Store
