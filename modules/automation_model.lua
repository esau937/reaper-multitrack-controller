-- modules/automation_model.lua
-- Stable data model for lyric lines and presentation slides.
-- It deliberately has no REAPER or ImGui dependency so it can be tested in
-- isolation and later shared by the editor, cue engine and output backends.

local AutomationModel = {}

local function index_by_id(items, id)
  for index, item in ipairs(items) do
    if item.id == id then return index, item end
  end
  return nil, nil
end

local function copy_list(items)
  local copy = {}
  for index, item in ipairs(items or {}) do copy[index] = item end
  return copy
end

local function next_id(model, kind)
  local key = kind == "line" and "nextLineNumber" or "nextSlideNumber"
  local number = model[key] or 1
  model[key] = number + 1
  return kind .. "-" .. number, (kind == "line" and "L" or "S") .. number
end

local function find_line(model, line_id)
  return index_by_id(model.lyrics.lines, line_id)
end

local function find_slide(model, slide_id)
  return index_by_id(model.slides, slide_id)
end

local function remove_line_from_slides(model, line_id)
  for _, slide in ipairs(model.slides) do
    for index = #slide.lineIds, 1, -1 do
      if slide.lineIds[index] == line_id then table.remove(slide.lineIds, index) end
    end
  end
end

function AutomationModel.new()
  return {
    schemaVersion = 1,
    lyrics = { lines = {} },
    slides = {},
    cues = {},
    nextLineNumber = 1,
    nextSlideNumber = 1,
    nextCueNumber = 1,
  }
end

function AutomationModel.add_slide(model, line_ids, insert_at)
  local id, display_id = next_id(model, "slide")
  local slide = { id = id, displayId = display_id, lineIds = {} }
  local position = math.max(1, math.min(insert_at or (#model.slides + 1), #model.slides + 1))
  table.insert(model.slides, position, slide)

  for _, line_id in ipairs(line_ids or {}) do
    if find_line(model, line_id) then
      remove_line_from_slides(model, line_id)
      table.insert(slide.lineIds, line_id)
    end
  end
  return slide
end

function AutomationModel.add_line(model, text, slide_id, insert_at)
  local id, display_id = next_id(model, "line")
  local line = { id = id, displayId = display_id, text = text or "" }
  table.insert(model.lyrics.lines, line)

  local _, slide = find_slide(model, slide_id)
  if not slide then
    slide = model.slides[#model.slides] or AutomationModel.add_slide(model)
  end
  local position = math.max(1, math.min(insert_at or (#slide.lineIds + 1), #slide.lineIds + 1))
  table.insert(slide.lineIds, position, line.id)
  return line
end

function AutomationModel.set_title_line(model, artist, title)
  artist = (artist or ""):match("^%s*(.-)%s*$")
  title = (title or ""):match("^%s*(.-)%s*$")
  local text = artist ~= "" and title ~= "" and (artist .. " - " .. title) or (artist ~= "" and artist or title)
  if text == "" then return nil, "Informe o cantor ou o título da música." end

  local title_line = nil
  for _, line in ipairs(model.lyrics.lines) do
    if line.isTitle then title_line = line; break end
  end
  if not title_line then
    title_line = { id = "line-title", displayId = "LT", text = text, isTitle = true }
    table.insert(model.lyrics.lines, 1, title_line)
    local first_slide = model.slides[1] or AutomationModel.add_slide(model)
    remove_line_from_slides(model, title_line.id)
    table.insert(first_slide.lineIds, 1, title_line.id)
  else
    title_line.text = text
  end
  model.lyrics.titleArtist = artist
  model.lyrics.titleSong = title
  return title_line
end

function AutomationModel.import_text(text, lines_per_slide)
  local model = AutomationModel.new()
  lines_per_slide = math.max(1, math.min(tonumber(lines_per_slide) or 4, 4))
  local active_slide = nil
  local line_count = 0
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  model.lyrics.source = text
  for raw_line in (text .. "\n"):gmatch("(.-)\n") do
    local value = raw_line:match("^%s*(.-)%s*$")
    if value ~= "" then
      if not active_slide or line_count >= lines_per_slide then
        active_slide = AutomationModel.add_slide(model)
        line_count = 0
      end
      AutomationModel.add_line(model, value, active_slide.id)
      line_count = line_count + 1
    end
  end
  return model
end

function AutomationModel.move_line(model, line_id, target_slide_id, target_index)
  local _, line = find_line(model, line_id)
  local _, target = find_slide(model, target_slide_id)
  if not line then return nil, "Linha não encontrada: " .. tostring(line_id) end
  if not target then return nil, "Slide não encontrado: " .. tostring(target_slide_id) end
  remove_line_from_slides(model, line_id)
  local position = math.max(1, math.min(target_index or (#target.lineIds + 1), #target.lineIds + 1))
  table.insert(target.lineIds, position, line_id)
  return true
end

function AutomationModel.move_line_within_slide(model, line_id, slide_id, direction)
  local _, slide = find_slide(model, slide_id)
  if not slide then return nil, "Slide não encontrado: " .. tostring(slide_id) end
  local line_index = nil
  for index, id in ipairs(slide.lineIds) do
    if id == line_id then line_index = index; break end
  end
  if not line_index then return nil, "Linha não pertence ao slide informado." end
  local destination = line_index + direction
  if destination < 1 or destination > #slide.lineIds then return false end
  slide.lineIds[line_index], slide.lineIds[destination] = slide.lineIds[destination], slide.lineIds[line_index]
  return true
end

function AutomationModel.reflow_slides(model, lines_per_slide)
  lines_per_slide = math.max(1, math.min(tonumber(lines_per_slide) or 4, 4))
  local ordered_lines, seen = {}, {}
  for _, slide in ipairs(model.slides) do
    for _, line_id in ipairs(slide.lineIds) do
      if not seen[line_id] then
        table.insert(ordered_lines, line_id)
        seen[line_id] = true
      end
    end
  end
  for _, line in ipairs(model.lyrics.lines) do
    if not seen[line.id] then table.insert(ordered_lines, line.id) end
  end
  local required = math.ceil(#ordered_lines / lines_per_slide)
  while #model.slides < required do AutomationModel.add_slide(model) end
  for _, slide in ipairs(model.slides) do slide.lineIds = {} end
  for index, line_id in ipairs(ordered_lines) do
    table.insert(model.slides[math.ceil(index / lines_per_slide)].lineIds, line_id)
  end
  return true
end

function AutomationModel.get_line(model, line_id)
  local _, line = find_line(model, line_id)
  return line
end

function AutomationModel.add_cue(model, time, region_id, action, target_id)
  action = action or "SHOW_SLIDE"
  if action == "SHOW_LINE" then
    local _, line = find_line(model, target_id)
    if not line then return nil, "Linha não encontrada: " .. tostring(target_id) end
  else
    local _, slide = find_slide(model, target_id)
    if not slide then return nil, "Slide não encontrado: " .. tostring(target_id) end
  end
  -- Models saved before the cue phase do not contain this collection yet.
  -- Create it lazily so opening an older .RPP remains safe.
  model.cues = model.cues or {}
  local normalized_time = tonumber(time) or 0
  for _, existing in ipairs(model.cues) do
    if existing.action == action
      and existing.target == target_id
      and math.abs(existing.time - normalized_time) < 0.001 then
      return nil, "Este slide já possui um cue neste ponto."
    end
  end
  local number = model.nextCueNumber or 1
  model.nextCueNumber = number + 1
  local cue = {
    id = "cue-" .. number,
    displayId = "C" .. number,
    time = normalized_time,
    regionId = region_id,
    action = action,
    target = target_id,
  }
  table.insert(model.cues, cue)
  table.sort(model.cues, function(a, b)
    if a.time == b.time then return a.id < b.id end
    return a.time < b.time
  end)
  return cue
end

function AutomationModel.remove_cue(model, cue_id)
  model.cues = model.cues or {}
  local index = index_by_id(model.cues, cue_id)
  if not index then return nil, "Cue não encontrado: " .. tostring(cue_id) end
  table.remove(model.cues, index)
  return true
end

function AutomationModel.move_cue(model, cue_id, time)
  local _, cue = index_by_id(model.cues or {}, cue_id)
  if not cue then return nil, "Cue não encontrado: " .. tostring(cue_id) end
  cue.time = math.max(0, tonumber(time) or cue.time)
  table.sort(model.cues, function(a, b)
    if a.time == b.time then return a.id < b.id end
    return a.time < b.time
  end)
  return true
end

function AutomationModel.remove_slide(model, slide_id, destination_slide_id)
  local slide_index, slide = find_slide(model, slide_id)
  if not slide then return nil, "Slide não encontrado: " .. tostring(slide_id) end
  if #slide.lineIds > 0 then
    local _, destination = find_slide(model, destination_slide_id)
    if not destination or destination.id == slide_id then
      return nil, "Escolha outro slide para receber as linhas antes de excluir."
    end
    for _, line_id in ipairs(copy_list(slide.lineIds)) do
      table.insert(destination.lineIds, line_id)
    end
  end
  table.remove(model.slides, slide_index)
  return true
end

function AutomationModel.validate(model)
  local errors, known_lines, known_slides, referenced, known_cues = {}, {}, {}, {}, {}
  if type(model) ~= "table" or model.schemaVersion ~= 1 then
    return { "Schema de automação inválido." }
  end
  for _, line in ipairs((model.lyrics or {}).lines or {}) do
    if not line.id or known_lines[line.id] then
      table.insert(errors, "Linha com ID ausente ou duplicado.")
    else
      known_lines[line.id] = true
    end
  end
  for _, slide in ipairs(model.slides or {}) do
    if not slide.id or type(slide.lineIds) ~= "table" then
      table.insert(errors, "Slide inválido.")
    else
      if known_slides[slide.id] then table.insert(errors, "Slide com ID duplicado: " .. slide.id .. ".") end
      known_slides[slide.id] = true
      for _, line_id in ipairs(slide.lineIds) do
        if not known_lines[line_id] then
          table.insert(errors, "Slide " .. slide.id .. " referencia linha inexistente " .. tostring(line_id) .. ".")
        elseif referenced[line_id] then
          table.insert(errors, "Linha " .. line_id .. " pertence a mais de um slide.")
        else
          referenced[line_id] = true
        end
      end
    end
  end
  for line_id in pairs(known_lines) do
    if not referenced[line_id] then table.insert(errors, "Linha " .. line_id .. " não pertence a nenhum slide.") end
  end
  for _, cue in ipairs(model.cues or {}) do
    if not cue.id or known_cues[cue.id] then
      table.insert(errors, "Cue com ID ausente ou duplicado.")
    else
      known_cues[cue.id] = true
      if type(cue.time) ~= "number" then table.insert(errors, "Cue " .. cue.id .. " tem tempo inválido.") end
      if cue.action == "SHOW_SLIDE" and not known_slides[cue.target] then
        table.insert(errors, "Cue " .. cue.id .. " referencia slide inexistente " .. tostring(cue.target) .. ".")
      end
      if cue.action == "SHOW_LINE" and not known_lines[cue.target] then
        table.insert(errors, "Cue " .. cue.id .. " referencia linha inexistente " .. tostring(cue.target) .. ".")
      end
    end
  end
  return errors
end

return AutomationModel
