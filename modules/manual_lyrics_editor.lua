local Model = require('automation_model')
local json = require('json')
local Editor = {}
Editor.__index = Editor

function Editor.new(api)
  return setmetatable({ api = api }, Editor)
end

function Editor:open(ctx, model)
  self.original = model
  self.project = self.api.EnumProjects(-1)
  self.draft = json.decode(json.encode(model or Model.new()))
  self.selected = self.draft.slides[1] and self.draft.slides[1].id
  self.error = nil
  self.api.ImGui_OpenPopup(ctx, 'Editar letras e slides')
end

function Editor:render(ctx, current_model, save)
  local r = self.api
  r.ImGui_SetNextWindowSize(ctx, 880, 580, r.ImGui_Cond_Appearing())
  r.ImGui_SetNextWindowSizeConstraints(ctx, 720, 440, 1800, 1100)
  local visible, open = r.ImGui_BeginPopupModal(ctx, 'Editar letras e slides', true)
  if visible then
    local draft = self.draft
    if not draft then r.ImGui_CloseCurrentPopup(ctx); r.ImGui_EndPopup(ctx); return end
    r.ImGui_Text(ctx, 'Edite os textos e organize os slides. Aplique para salvar as alterações.')
    r.ImGui_TextDisabled(ctx, 'Os IDs e tempos mapeados são preservados. LT fica em seu próprio slide.')
    local action
    r.ImGui_BeginChild(ctx, '##manual_slide_list', 200, -88, true)
    if r.ImGui_Button(ctx, '+ SLIDE') then
      self.selected = Model.add_slide(draft).id
    end
    for _, slide in ipairs(draft.slides) do
      if r.ImGui_Selectable(ctx, (slide.isTitle and 'LT - TÍTULO' or 'SLIDE ' .. slide.displayId) ..
          '##' .. slide.id, self.selected == slide.id) then self.selected = slide.id end
    end
    if not draft.lyrics.lines[1] or not draft.lyrics.lines[1].isTitle then
      if r.ImGui_Button(ctx, '+ TÍTULO') then
        Model.set_title_line(draft, '', 'Título da música')
        self.selected = 'slide-title'
      end
    end
    r.ImGui_EndChild(ctx)
    r.ImGui_SameLine(ctx)
    r.ImGui_BeginChild(ctx, '##manual_slide_content', 0, -88, false)
    local selected
    for _, slide in ipairs(draft.slides) do
      if slide.id == self.selected then selected = slide; break end
    end
    if selected then
      r.ImGui_Text(ctx, selected.isTitle and 'SLIDE DE TÍTULO' or 'SLIDE ' .. selected.displayId)
      r.ImGui_Dummy(ctx, 0, 6)
      if selected.isTitle then
        local changed, artist = r.ImGui_InputText(ctx, 'Cantor', draft.lyrics.titleArtist or '')
        if changed then draft.lyrics.titleArtist = artist end
        local title_changed, song = r.ImGui_InputText(ctx, 'Música', draft.lyrics.titleSong or '')
        if title_changed then draft.lyrics.titleSong = song end
        if changed or title_changed then
          local line, err = Model.set_title_line(draft, draft.lyrics.titleArtist, draft.lyrics.titleSong)
          self.error = line and nil or err
        end
      else
        if r.ImGui_Button(ctx, '+ LINHA') then
          Model.add_line(draft, 'Nova linha', selected.id)
        end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, 'SLIDE ANTERIOR') then Model.move_slide(draft, selected.id, -1) end
        r.ImGui_SameLine(ctx)
        if r.ImGui_Button(ctx, 'SLIDE SEGUINTE') then Model.move_slide(draft, selected.id, 1) end
        for _, line_id in ipairs(selected.lineIds) do
          local line = Model.get_line(draft, line_id)
          if line then
            r.ImGui_PushID(ctx, line.id)
            r.ImGui_Text(ctx, line.displayId)
            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, -1)
            local changed, text = r.ImGui_InputText(ctx, '##edit_line', line.text)
            if changed then line.text = text end
            if r.ImGui_Button(ctx, 'SUBIR') then
              action = function() Model.move_line_within_slide(draft, line.id, selected.id, -1) end
            end
            r.ImGui_SameLine(ctx)
            if r.ImGui_Button(ctx, 'DESCER') then
              action = function() Model.move_line_within_slide(draft, line.id, selected.id, 1) end
            end
            r.ImGui_SameLine(ctx)
            r.ImGui_SetNextItemWidth(ctx, 160)
            if r.ImGui_BeginCombo(ctx, '##move_to_slide', 'Mover para slide...') then
              for _, destination in ipairs(draft.slides) do
                if not destination.isTitle and destination.id ~= selected.id and
                    r.ImGui_Selectable(ctx, destination.displayId) then
                  action = function() Model.move_line(draft, line.id, destination.id) end
                end
              end
              r.ImGui_EndCombo(ctx)
            end
            r.ImGui_Dummy(ctx, 0, 8)
            r.ImGui_PopID(ctx)
          end
        end
        if #selected.lineIds == 0 then
          r.ImGui_TextDisabled(ctx, 'Slide vazio: adicione ou mova uma linha para cá.')
          if r.ImGui_Button(ctx, 'REMOVER SLIDE VAZIO') then
            local mapped = false
            for _, cue in ipairs(draft.cues or {}) do
              if cue.action == 'SHOW_SLIDE' and cue.target == selected.id then mapped = true end
            end
            if mapped then self.error = 'Este slide possui mapeamento e não pode ser removido aqui.'
            else
              Model.remove_slide(draft, selected.id)
              self.selected = draft.slides[1] and draft.slides[1].id
            end
          end
        end
      end
    else
      r.ImGui_TextWrapped(ctx, 'Crie ou selecione um slide para editar a letra.')
    end
    if action then action() end
    r.ImGui_EndChild(ctx)
    if self.error then r.ImGui_TextWrapped(ctx, self.error) end
    if r.ImGui_Button(ctx, 'APLICAR E SALVAR', 170, 28) then
      local valid = true
      if draft.lyrics.lines[1] and draft.lyrics.lines[1].isTitle and
          not ((draft.lyrics.titleArtist or '') .. (draft.lyrics.titleSong or '')):match('%S') then
        valid = false
        self.error = 'Preencha o cantor ou o título da música.'
      end
      for _, line in ipairs(draft.lyrics.lines) do
        if not line.text:match('%S') then valid = false; self.error = line.displayId .. ': preencha o texto.'; break end
      end
      if self.project ~= r.EnumProjects(-1) or current_model ~= self.original then
        valid = false
        self.error = 'O projeto ou mapa mudou. Cancele e abra o editor novamente.'
      end
      if valid then
        local lines = {}
        for _, line in ipairs(draft.lyrics.lines) do
          if not line.isTitle then lines[#lines + 1] = line.text end
        end
        draft.lyrics.source = table.concat(lines, '\n')
        local ok, err = save(draft)
        if ok then self.draft = nil; r.ImGui_CloseCurrentPopup(ctx)
        else self.error = err end
      end
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'CANCELAR', 110, 28) then
      self.draft = nil
      r.ImGui_CloseCurrentPopup(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end
  if not open then self.draft = nil end
end

return Editor
