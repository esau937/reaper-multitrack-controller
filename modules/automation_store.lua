-- Persists automation data inside the active REAPER project.
-- Project ExtState travels with the .RPP and avoids machine-specific paths.

local json = require("json")
local Model = require("automation_model")

local Store = {}
local SECTION = "MultitrackControllerAutomation"
local KEY = "model"

function Store.load(proj)
  local retval, value = reaper.GetProjExtState(proj or 0, SECTION, KEY)
  if retval == 0 or value == "" then return nil end
  local ok, model = pcall(json.decode, value)
  if not ok or type(model) ~= "table" then return nil, "Não foi possível ler a automação salva." end
  local errors = Model.validate(model)
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  return model
end

function Store.save(model, proj)
  local errors = Model.validate(model)
  if #errors > 0 then return nil, table.concat(errors, "\n") end
  reaper.SetProjExtState(proj or 0, SECTION, KEY, json.encode(model))
  reaper.MarkProjectDirty(proj or 0)
  return true
end

return Store
