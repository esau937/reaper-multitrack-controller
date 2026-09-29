package.path = 'modules/?.lua;lib/?.lua;' .. package.path
local Model = require('automation_model')
local Editor = require('manual_lyrics_editor')
local json = require('json')
local model = Model.import_text('Primeira\nSegunda\nTerceira\nQuarta', 2)
Model.set_title_line(model, 'Cantor', 'Música')
Model.add_cue(model, 5, '1', 'SHOW_LINE', 'line-1')
Model.add_cue(model, 12, '1', 'SHOW_LINE', 'line-2')
local before = json.encode(model)
local project, click = 1, nil
local api = setmetatable({
  EnumProjects = function() return project end,
  ImGui_BeginPopupModal = function() return true, true end,
  ImGui_Button = function(_, label) return label == click end,
  ImGui_Selectable = function() return false end,
  ImGui_InputText = function(_, _, value) return false, value end,
  ImGui_BeginCombo = function() return false end,
}, { __index = function() return function() end end })
local editor = Editor.new(api)
editor:open({}, model)
editor.selected = 'slide-1'
editor.draft.lyrics.lines[2].text = 'Texto corrigido'
assert(Model.move_line(editor.draft, 'line-2', 'slide-2'))
assert(Model.move_slide(editor.draft, 'slide-2', -1))
assert(json.encode(model) == before, 'draft must not mutate live mappings')
click = 'CANCELAR'
editor:render({}, model, function() error('cancel must not save') end)
assert(not editor.draft and json.encode(model) == before)
editor:open({}, model)
editor.selected = 'slide-1'
editor.draft.lyrics.lines[2].text = 'Texto corrigido'
Model.move_line(editor.draft, 'line-2', 'slide-2')
local saved
click = 'APLICAR E SALVAR'
editor:render({}, model, function(draft) saved = draft; return true end)
assert(saved and #Model.validate(saved) == 0)
assert(saved.cues[1].target == 'line-1' and saved.cues[1].time == 5)
assert(saved.cues[2].target == 'line-2' and saved.cues[2].time == 12)
assert(Model.get_line(saved, 'line-1').text == 'Texto corrigido')
assert(saved.lyrics.source:find('Texto corrigido', 1, true))
-- Preserve the title card even when adding or moving content around it.
assert(not Model.move_line(saved, 'line-title', 'slide-1'))
assert(not Model.move_line(saved, 'line-1', 'slide-title'))
assert(not Model.move_slide(saved, 'slide-title', 1))
assert(not Model.move_slide(saved, 'slide-1', -1))
local added = Model.add_line(saved, 'Nova', 'slide-title')
assert(#saved.slides[1].lineIds == 1 and #Model.validate(saved) == 0)
assert(added.displayId == 'L5')
-- A stale editor may not save into another project.
editor:open({}, model)
editor.selected = 'slide-1'
project = 2
editor:render({}, model, function() error('must not save into another project') end)
assert(editor.error)
print('manual_lyrics_editor_test: passed')
