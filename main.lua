-- ============================================================
--   Multitrack Controller for Reaper
--   Requires: js_ReaScriptAPI + ReaImGui  (via ReaPack)
--
--   Install to:  %APPDATA%\REAPER\Scripts\MultitrackController\
--   Load via:    Actions > Load ReaScript > main.lua
-- ============================================================

-- ─── Dependency check ────────────────────────────────────────────────────────

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "ReaImGui não encontrado!\n\n" ..
    "Instale via ReaPack:\n" ..
    "  Extensions > ReaPack > Browse packages\n" ..
    "  Busque por 'ReaImGui' e instale.\n\n" ..
    "Depois reinicie o Reaper e rode o script novamente.",
    "Multitrack Controller — Dependência faltando", 0)
  return
end

-- ─── Toggle command state & Single Instance ──────────────────────────────────

local _, _, section_id, cmd_id = reaper.get_action_context()

local is_running = reaper.GetExtState("MultitrackController", "running") == "true"
local toggle_state = reaper.GetToggleCommandStateEx(section_id, cmd_id)

-- Se o Reaper ou nosso estado dizem que já está rodando, vamos desligar.
if is_running or toggle_state == 1 then
  -- Sinaliza para a instância antiga (se existir) fechar
  reaper.SetExtState("MultitrackController", "quit", "true", false)
  -- Limpa o estado IMEDIATAMENTE para evitar travamentos caso a antiga tenha morrido
  reaper.SetExtState("MultitrackController", "running", "false", false)
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
  return -- Encerra esta segunda chamada
end

-- --- Início normal da primeira instância ---
reaper.SetExtState("MultitrackController", "running", "true", false)
reaper.SetExtState("MultitrackController", "quit", "false", false)

reaper.SetToggleCommandState(section_id, cmd_id, 1)
reaper.RefreshToolbar2(section_id, cmd_id)

-- Quando o script terminar naturalmente, limpa os estados
reaper.atexit(function()
  reaper.SetExtState("MultitrackController", "running", "false", false)
  reaper.SetToggleCommandState(section_id, cmd_id, 0)
  reaper.RefreshToolbar2(section_id, cmd_id)
end)

-- ─── Path setup ──────────────────────────────────────────────────────────────

local SCRIPT_PATH = ({reaper.get_action_context()})[2]:match("^(.*[/\\])") or ""
package.path = SCRIPT_PATH .. "?.lua;"
             .. SCRIPT_PATH .. "modules/?.lua;"
             .. SCRIPT_PATH .. "lib/?.lua;"
             .. package.path

-- ─── Load modules ────────────────────────────────────────────────────────────

local json       = require("json")
local KeyDetect  = require("keydetect")
local Sections   = require("sections")
local Pads       = require("pads")
local Repertoire = require("repertoire")

Repertoire.init(SCRIPT_PATH)

-- ─── ImGui context ───────────────────────────────────────────────────────────

local ctx = reaper.ImGui_CreateContext("Multitrack Controller", reaper.ImGui_ConfigFlags_DockingEnable())

-- Cria fontes modernas e suaves para remover o aspecto pixelado
local font = reaper.ImGui_CreateFont('Arial', 14)
local font_large = reaper.ImGui_CreateFont('Arial', 18, reaper.ImGui_FontFlags_Bold())
local font_small = reaper.ImGui_CreateFont('Arial', 10, reaper.ImGui_FontFlags_Bold())
reaper.ImGui_Attach(ctx, font)
reaper.ImGui_Attach(ctx, font_large)
reaper.ImGui_Attach(ctx, font_small)

-- ─── Color palette (0xRRGGBBAA) ──────────────────────────────────────────────

local C = {
  win_bg      = 0x000000FF,   -- Fundo preto puro
  header_bg   = 0x000000FF,
  border      = 0x1A1A1AFF,   -- Bordas bem discretas
  text        = 0xFFFFFFFF,   -- Texto branco puro
  text_dim    = 0x999999FF,   -- Texto secundário
  accent      = 0xFF1493FF,   -- Rosa Choque Forte (Ativo/Destaque)
  accent_hover= 0xFF69B4FF,   -- Rosa Choque Claro (Hover)
  green       = 0xFF1493FF,   -- Substituindo o verde pelo Rosa Choque
  green_hover = 0xFF69B4FF,
  red         = 0xEF4444FF,
  yellow      = 0xFF1493FF,   -- BPM em Rosa Choque
  btn_normal  = 0x151515FF,   -- Botões inativos quase pretos
  btn_hover   = 0x2A2A2AFF,
  btn_active  = 0x333333FF,
  waveform    = 0xFFFFFF3A,   -- Waveform mais branca e visível
  playhead    = 0xFFFFFFFF,   -- Agulha Branca
  ruler_text  = 0x555555FF,
}

-- ─── Layout constants ─────────────────────────────────────────────────────────

local PANEL_H      = 165
local TRANSPORT_W  = 158
local MENU_W       = 108
local BOTTOM_BAR_H = 38

-- ─── App state ───────────────────────────────────────────────────────────────

local DEFAULT_MIDI_MAP = {
  ["Contagem"]   = 35,
  ["Introdução"] = 36,
  ["Verso"]      = 37,
  ["Pré-refrão"] = 38,
  ["Refrão"]     = 39,
  ["Turnaround"] = 40,
  ["Ponte"]      = 41,
  ["Interlúdio"] = 42,
  ["Solo"]       = 43,
  ["Saída"]      = 44,
  ["Final"]      = 45
}

local midi_map_state = {}
for k, v in pairs(DEFAULT_MIDI_MAP) do
  local saved = reaper.GetExtState("MultitrackController", "midimap_" .. k)
  if saved and saved ~= "" then
    midi_map_state[k] = tonumber(saved)
  else
    midi_map_state[k] = v
  end
end

local state = {
  current_key      = nil,
  current_proj_name= "",
  current_proj_path= "",
  sections         = {},
  setlist          = nil,
  pads = {
    { name = "PAD", file = nil, playing = false, loop = true },
  },
  hold             = false,
  auto_next        = false,
  pending_jump_pos = nil,
    key_mappings     = {},
    mapping_target   = nil,
  pending_jump_trigger_time = nil,
  click_ducked     = false,
  duck_factor      = 1.0,
  duck_target      = 1.0,
  is_scrubbing     = false,
  scrub_pos        = 0,
  show_marker_modal = false,
  show_render_modal = false,
  show_midi_mapping_modal = false,
  show_holyrics_modal = false,
  holyrics_text = "",
  holyrics_parsed = {},
  holyrics_slides = {},
  holyrics_mapping = {},
  holyrics_selected_region = nil,
  holyrics_lines_per_slide = tonumber(reaper.GetExtState("MultitrackController", "holyrics_lines")) or 4,
  holyrics_has_manual_edits = false,
  holyrics_editing_slide = nil,
  holyrics_editing_line = nil,
  holyrics_editing_text = "",
  holyrics_editing_focused = false,
  render_format     = "WAV",
  render_path       = "",
  render_mode       = "TUDO",
  show_add_custom_modal = false,
  new_sec_name      = "",
  new_sec_color_int = 0xFFFFFFFF,
  original_vols    = {},
  duck_projects    = {},
  loudness_active  = false,
  loudness_originals = {},
  pitch_offset     = 0,
  pitch_projects   = {},
  _last_play_state = 0,
  _last_play_pos   = 0,
  -- Cache
  _last_check      = 0,
  _proj_change     = -1,
  midi_map         = midi_map_state,
  DEFAULT_MIDI_MAP = DEFAULT_MIDI_MAP,
}

local loaded_keys = reaper.GetExtState("MultitrackController", "key_mappings")
if loaded_keys and loaded_keys ~= "" then
  local ok, data = pcall(json.decode, loaded_keys)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do
      if reaper.ImGui_Key_MouseLeft and v == reaper.ImGui_Key_MouseLeft() then data[k] = nil end
      if reaper.ImGui_Key_MouseRight and v == reaper.ImGui_Key_MouseRight() then data[k] = nil end
    end
    state.key_mappings = data
  end
end

local function get_note_name(pitch)
  local names = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
  local octave = math.floor(pitch / 12) - 2 -- 36 is C1
  return names[(pitch % 12) + 1] .. octave
end

-- Garante que se o usuário fechar o script durante/depois do fade, os volumes voltem ao normal
local function restore_ducking()
  for _, snapshot in pairs(state.duck_projects) do
    for tr, volume in pairs(snapshot.volumes) do
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", volume)
    end
  end
  state.duck_projects = {}
  state.original_vols = {}
  state.duck_factor, state.duck_target, state.click_ducked = 1.0, 1.0, false
end

local function restore_project_pitch(project_state)
  if not project_state then return end
  for take, pitch in pairs(project_state.originals) do
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch)
  end
  project_state.originals = {}
  project_state.offset = 0
end

local function restore_all_pitch()
  for _, project_state in pairs(state.pitch_projects) do
    restore_project_pitch(project_state)
  end
  state.pitch_projects = {}
  state.pitch_offset = 0
end

reaper.atexit(function()
  restore_ducking()
  restore_all_pitch()
end)

-- ─── Utilities ───────────────────────────────────────────────────────────────

-- Push a simple style for plain buttons
local function push_btn_style()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.btn_normal)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.btn_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   C.btn_active)
end
local function pop_btn_style() reaper.ImGui_PopStyleColor(ctx, 3) end

-- Round a number for display
local function fmt_time(secs)
  local m = math.floor(secs / 60)
  local s = math.floor(secs % 60)
  return string.format("%d:%02d", m, s)
end

-- ─── Elite Map IO ──────────────────────────────────────────────────────────────

local DEFAULT_SECTIONS = {
  { name = "Contagem",     r = 255, g = 255, b = 255 },
  { name = "Introdução",   r = 40,  g = 200, b = 80  }, -- Verde
  { name = "Verso",        r = 255, g = 140, b = 0   },
  { name = "Pré-refrão",   r = 0,   g = 220, b = 255 },
  { name = "Refrão",       r = 0,   g = 100, b = 255 },
  { name = "Turnaround",   r = 255, g = 255, b = 255 },
  { name = "Ponte",        r = 220, g = 40,  b = 40  },
  { name = "Grande pausa", r = 255, g = 255, b = 255 },
  { name = "Saída",        r = 40,  g = 200, b = 80  },
  { name = "Final",        r = 255, g = 255, b = 255 }
}

local user_sections = nil

local function get_next_free_pitch()
  local used = {}
  if user_sections then
    for _, sec in ipairs(user_sections) do
      if sec.pitch then used[sec.pitch] = true end
    end
  end
  local p = 35
  while used[p] do p = p + 1 end
  return p
end

local function load_user_sections()
  local str = reaper.GetExtState("MultitrackController", "user_sections")
  if str and str ~= "" then
    local ok, data = pcall(json.decode, str)
    if ok and type(data) == "table" and #data > 0 then
      user_sections = data
    end
  end
  
  if not user_sections then
    user_sections = {}
    for i, v in ipairs(DEFAULT_SECTIONS) do
      table.insert(user_sections, {name=v.name, r=v.r, g=v.g, b=v.b})
    end
  end
  
  -- Sincroniza pitch (MIDI Mapping) diretamente no Maker
  for i, sec in ipairs(user_sections) do
    if not sec.pitch then
      -- Tenta recuperar o mapping anterior feito pela etapa 4
      local saved = reaper.GetExtState("MultitrackController", "midimap_" .. sec.name)
      if saved and saved ~= "" then
        sec.pitch = tonumber(saved)
      else
        sec.pitch = get_next_free_pitch()
      end
    end
  end
end
load_user_sections()

local function save_user_sections()
  local str = json.encode(user_sections)
  reaper.SetExtState("MultitrackController", "user_sections", str, true)
end

local function load_render_settings()
  local fmt = reaper.GetExtState("MultitrackController", "render_format")
  local path = reaper.GetExtState("MultitrackController", "render_path")
  local mode = reaper.GetExtState("MultitrackController", "render_mode")
  if fmt == "WAV" or fmt == "MP3" then state.render_format = fmt end
  if path and path ~= "" then state.render_path = path end
  if mode == "TUDO" or mode == "PISTAS" or mode == "REGIOES" then state.render_mode = mode end
end

local function save_render_settings()
  reaper.SetExtState("MultitrackController", "render_format", state.render_format, true)
  reaper.SetExtState("MultitrackController", "render_path", state.render_path, true)
  reaper.SetExtState("MultitrackController", "render_mode", state.render_mode, true)
end

load_render_settings()

local function export_mapa_to_txt()
  local out = {}
  local i = 0
  while true do
    local ok, is_rgn, pos, rgnend, name, _ = reaper.EnumProjectMarkers3(0, i)
    if ok == 0 then break end
    if is_rgn and name and name ~= "" then
      local min = math.floor(pos / 60)
      local sec = math.floor(pos % 60)
      local ms = math.floor((pos * 1000) % 1000)
      local timecode = string.format("%02d%02d%03d", min, sec, ms)
      table.insert(out, name .. "\n" .. timecode .. "\n")
    end
    i = i + 1
  end
  
  if #out > 0 then
    local dir = ""
    local _, proj_path = reaper.EnumProjects(-1, "")
    if proj_path and proj_path ~= "" then
      dir = proj_path:match("^(.*)[/\\]")
    end
    local audio_dir = reaper.GetProjectPathEx(0, "")
    if audio_dir == "" then audio_dir = dir end
    
    if audio_dir and audio_dir ~= "" then
      local filepath = audio_dir .. "/MapaTrack_Regions.txt"
      local file = io.open(filepath, "w")
      if file then
        file:write(table.concat(out, "\n"))
        file:close()
        reaper.MB("Arquivo MapaTrack_Regions.txt gerado com sucesso na pasta:\n" .. audio_dir, "Timecode Finalizado", 0)
      end
    end
  else
    reaper.MB("Nenhuma região encontrada no projeto para exportar.", "Aviso", 0)
  end
end

local function import_mapa_if_empty(proj, proj_path)
  local retval, num_markers, num_regions = reaper.CountProjectMarkers(proj, 0)
  if num_markers > 0 or num_regions > 0 then return end
  
  local dir = ""
  if proj_path and proj_path ~= "" then
    dir = proj_path:match("^(.*)[/\\]")
  end
  local audio_dir = reaper.GetProjectPathEx(proj, "")
  
  local paths = {}
  if audio_dir and audio_dir ~= "" then table.insert(paths, audio_dir .. "/MapaTrack_Regions.txt") end
  if dir and dir ~= "" then table.insert(paths, dir .. "/MapaTrack_Regions.txt") end
  if dir and dir ~= "" then table.insert(paths, dir .. "/Media/MapaTrack_Regions.txt") end
  
  local content = nil
  for _, path in ipairs(paths) do
    local f = io.open(path, "r")
    if f then
      content = f:read("*a")
      f:close()
      break
    end
  end
  
  if not content then return end
  
  local current_name = nil
  local parsed = {}
  for line in content:gmatch("[^\r\n]+") do
    if line:match("^%d%d%d%d%d%d%d$") then
      if current_name then
        local min = tonumber(line:sub(1, 2))
        local sec = tonumber(line:sub(3, 4))
        local ms = tonumber(line:sub(5, 7))
        local total_secs = min * 60 + sec + (ms / 1000.0)
        
        local r, g, b = 100, 100, 100
        for _, std in ipairs(user_sections) do
          if string.upper(current_name) == string.upper(std.name) then
            r, g, b = std.r, std.g, std.b
            break
          end
        end
        local color = reaper.ColorToNative(r, g, b) | 0x1000000
        table.insert(parsed, {name=current_name, pos=total_secs, color=color})
        current_name = nil
      end
    else
      current_name = line
    end
  end
  
  local proj_len = reaper.GetProjectLength(proj)
  for i, p in ipairs(parsed) do
    local end_pos = parsed[i+1] and parsed[i+1].pos or proj_len
    if end_pos <= p.pos then end_pos = p.pos + 10 end
    reaper.AddProjectMarker2(proj, true, p.pos, end_pos, p.name, -1, p.color)
    reaper.AddProjectMarker2(proj, false, p.pos, 0, p.name, -1, p.color)
  end
  reaper.UpdateTimeline()
end

-- ─── State update (runs at reduced rate) ─────────────────────────────────────

local function update_state()
  local now = reaper.time_precise()
  if now - state._last_check < 0.4 then return end
  state._last_check = now

  local proj = reaper.EnumProjects(-1)
  -- Detect project change via state change counter
  local change = reaper.GetProjectStateChangeCount(proj)
  local _, proj_path = reaper.EnumProjects(-1, "")
  local proj_name = proj_path and proj_path:match("([^/\\]+)$") or ""

  if proj_name ~= state.current_proj_name or change ~= state._proj_change then
    local is_new_proj = (proj_name ~= state.current_proj_name)
    state.current_proj_name = proj_name
    state.current_proj_path = proj_path or ""
    state._proj_change = change
    state.current_key = KeyDetect.detect(proj_name)
    
    if is_new_proj then
      local pitch_state = state.pitch_projects[tostring(proj)]
      state.pitch_offset = pitch_state and pitch_state.offset or 0
      import_mapa_if_empty(proj, proj_path)
    end
    
    state.sections = Sections.get_from_project(proj)
  end
end

-- ─── Waveform renderer ───────────────────────────────────────────────────────

local reset_pitch
local toggle_loudness

-- Deterministic waveform amplitude at pixel X (0..1)
local _wave_cache = {}
local function wave_amp(px, seed)
  seed = seed or 42
  local k = px + seed * 1000
  if _wave_cache[k] then return _wave_cache[k] end
  -- Layered sine approximation — looks like a real waveform
  local t = px / 1000.0
  local v = math.abs(
    math.sin(t * 73.1 + seed)  * 0.35 +
    math.sin(t * 19.7 + seed)  * 0.25 +
    math.sin(t * 311.3 + seed) * 0.15 +
    math.sin(t * 5.3  + seed)  * 0.25
  )
  v = math.min(1.0, math.max(0.05, v))
  _wave_cache[k] = v
  return v
end

local function handle_mapped_button(ctx, button_id, action_func, extra_menu_func)
  if reaper.ImGui_BeginPopupContextItem(ctx, "mapping_popup_" .. button_id) then
    if reaper.ImGui_Selectable(ctx, "MAPPING BOTON") then
      state.mapping_target = button_id
      reaper.ImGui_OpenPopup(ctx, "Mapear Tecla")
    end
    if extra_menu_func then extra_menu_func() end
    reaper.ImGui_EndPopup(ctx)
  end

  local mapped_key = state.key_mappings[button_id]
  if mapped_key and reaper.ImGui_IsKeyPressed(ctx, mapped_key, false) then
    if not reaper.ImGui_IsAnyItemActive(ctx) then
      action_func()
    end
  end
end

local function render_key_mapping_modal(ctx, win_x, win_y, win_w, win_h)
  if state.mapping_target then
    if not reaper.ImGui_IsPopupOpen(ctx, "Mapear Tecla") then
      reaper.ImGui_OpenPopup(ctx, "Mapear Tecla")
    end
  end
  
  local center_x = win_x
  local center_y = win_y
  reaper.ImGui_SetNextWindowPos(ctx, center_x + (win_w/2) - 150, center_y + (win_h/2) - 50, reaper.ImGui_Cond_Appearing())
  
  if reaper.ImGui_BeginPopupModal(ctx, "Mapear Tecla", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoMove()) then
    reaper.ImGui_Text(ctx, "Pressione a tecla para o botao: " .. string.upper(state.mapping_target))
    reaper.ImGui_Separator(ctx)
    
    for key = 0, 650 do
      if reaper.ImGui_IsKeyPressed(ctx, key, false) then
        local is_mouse = false
        if reaper.ImGui_Key_MouseLeft and key == reaper.ImGui_Key_MouseLeft() then is_mouse = true end
        if reaper.ImGui_Key_MouseRight and key == reaper.ImGui_Key_MouseRight() then is_mouse = true end
        if reaper.ImGui_Key_MouseMiddle and key == reaper.ImGui_Key_MouseMiddle() then is_mouse = true end
        
        if not is_mouse then
          if key == reaper.ImGui_Key_Escape() then
            -- Cancela
          elseif reaper.ImGui_Key_Delete and key == reaper.ImGui_Key_Delete() then
            state.key_mappings[state.mapping_target] = nil
            reaper.SetExtState("MultitrackController", "key_mappings", json.encode(state.key_mappings), true)
          elseif reaper.ImGui_Key_Backspace and key == reaper.ImGui_Key_Backspace() then
            state.key_mappings[state.mapping_target] = nil
            reaper.SetExtState("MultitrackController", "key_mappings", json.encode(state.key_mappings), true)
          else
            state.key_mappings[state.mapping_target] = key
            reaper.SetExtState("MultitrackController", "key_mappings", json.encode(state.key_mappings), true)
          end
          state.mapping_target = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
          break
        end
      end
    end
    
    if reaper.ImGui_Button(ctx, "Cancelar", 120, 30) then
      state.mapping_target = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function render_waveform_area(draw_list, wx, wy, ww, wh)
  local pad_top = 10
  local pad_bottom = 58
  
  -- Layout deliberadamente independente do Arrange View. A largura do TCP e o
  -- zoom do projeto não podem deslocar nem redimensionar a visualização.
  local margin_x = 10
  local draw_x = wx + 320

  -- Reserva fixa para os controles da direita.
  local right_buttons_w = (84 * 3) + 8 + 20 -- ~280px
  local draw_w = math.max(20, ww - (draw_x - wx) - right_buttons_w)

  local draw_y = wy + pad_top
  
  -- Esmaga a waveform para ter a exata altura do bloco 3x3 de botões (3 * 48 + 2 * 4 = 152)
  -- Assim a borda superior da waveform fica milimetricamente alinhada com os botões superiores.
  local draw_h = 152

  local proj     = reaper.EnumProjects(-1)
  local proj_len = reaper.GetProjectLength(proj)
  if not proj_len or proj_len <= 0 then proj_len = 300 end
  
  -- Opcional: mantem a funcionalidade do Grid Lock apenas para congelar o Reaper
  if state.grid_lock and state.locked_start and state.locked_end then
    reaper.GetSet_ArrangeView2(0, true, 0, 0, state.locked_start, state.locked_end)
  end
  
  -- Waveform SEMPRE ESTÁTICA do início ao fim da música
  local start_time = 0
  local end_time = proj_len
  
  local view_len = end_time - start_time
  if view_len <= 0 then view_len = 10 end
  
  -- Função helper para converter segundos do projeto em coordenadas X da tela
  local function time_to_x(t)
    return draw_x + ((t - start_time) / view_len) * draw_w
  end

  -- A waveform ocupa sempre toda a área. Regiões não podem cortar o seu fim.
  local max_x = draw_x + draw_w

  -- Corrige a leitura da posição para atualizar imediatamente quando estiver pausado/parado
  local play_state = reaper.GetPlayState()
  local play_pos = (play_state & 1 == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  
  -- Background preto total
  reaper.ImGui_DrawList_AddRectFilled(draw_list, wx, wy, wx+ww, wy+wh, C.win_bg)

  -- Input Invisível para Scrubbing 
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  
  -- Só consideramos "hover" na waveform se o mouse estiver estritamente dentro da área de desenho da onda (até o max_x)
  local wave_hovered = reaper.ImGui_IsWindowHovered(ctx) and (mx >= draw_x and mx <= max_x and my >= draw_y and my <= draw_y + draw_h)
  
  local w_clicked = false
  if wave_hovered and reaper.ImGui_IsMouseClicked(ctx, 0) then
    w_clicked = true
    state._waveform_active = true
  end
  if reaper.ImGui_IsMouseReleased(ctx, 0) then
    state._waveform_active = false
  end
  local w_active = state._waveform_active
  local hit_sec_pos = nil

  -- Variáveis para controle de colisão inteligente dos badges
  local last_top_x2 = -9999
  local last_bot_x2 = -9999
  
  -- Seed constante: a waveform é um elemento visual fixo do controlador.
  local seed = 42
  local mid = draw_y + draw_h / 2

  -- ── Section Outlines & Waveform (Estilo Elite Flush & Glow) ──
  -- Protege contra vazamento horizontal (por cima do teclado)
  reaper.ImGui_DrawList_PushClipRect(draw_list, draw_x, -9999, draw_x + draw_w, 9999, true)
  
  -- ── Base Waveform (Sempre visível mesmo sem regiões) ──
  local amp_scale_base = state.loudness_active and 0.50 or 0.90
  for px = 0, draw_w - 1, 2 do
      local stable_x = px * 10
      local amp = wave_amp(stable_x, seed) * ((draw_h / 2) * amp_scale_base)
    reaper.ImGui_DrawList_AddLine(draw_list, draw_x + px, mid - amp, draw_x + px, mid + amp, 0xFFFFFF12, 1.0)
  end

  for i, sec in ipairs(state.sections) do
    local x1 = time_to_x(sec.pos)
    local x2 = time_to_x(sec.end_pos)
    
    -- Se a seção inteira estiver fora da tela, pula o render
    if x2 > draw_x and x1 < draw_x + draw_w then
      
      local r = math.floor(sec.color / 0x1000000) % 0x100
      local g = math.floor(sec.color / 0x10000)   % 0x100
      local b = math.floor(sec.color / 0x100)     % 0x100
      local solid_color = r * 0x1000000 + g * 0x10000 + b * 0x100 + 0xFF
      local current_pos = state.is_scrubbing and reaper.GetCursorPosition() or play_pos
      local is_active = (current_pos >= sec.pos) and (current_pos < sec.end_pos)
      local is_queued = (state.pending_jump_pos == sec.pos)
      local blink_on = is_queued and ((math.floor(reaper.time_precise() * 4) % 2) == 0)
      local visually_active = is_active or blink_on
    
    -- Determina quais quinas arredondar (para ficarem unidas/flush)
    local draw_flags = 0
    if i == 1 and i == #state.sections then
      draw_flags = reaper.ImGui_DrawFlags_RoundCornersAll()
    elseif i == 1 then
      draw_flags = reaper.ImGui_DrawFlags_RoundCornersLeft()
    elseif i == #state.sections then
      draw_flags = reaper.ImGui_DrawFlags_RoundCornersRight()
    else
      draw_flags = reaper.ImGui_DrawFlags_RoundCornersNone()
    end
    
    -- Desenha a caixa da secao
    if visually_active then
      local alpha_fill = is_queued and 0x40 or 0x25
      local fill_color = r * 0x1000000 + g * 0x10000 + b * 0x100 + alpha_fill
      reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, draw_y, x2, draw_y + draw_h, fill_color, 8.0, draw_flags)
      reaper.ImGui_DrawList_AddRect(draw_list, x1, draw_y, x2, draw_y + draw_h, solid_color, 8.0, draw_flags, is_queued and 3.0 or 2.0)
    else
      reaper.ImGui_DrawList_AddRect(draw_list, x1, draw_y, x2, draw_y + draw_h, solid_color, 8.0, draw_flags, 1.5)
    end
    
    -- Desenha o Glow da Waveform DENTRO da secao se estiver ativa
    if visually_active then
      reaper.ImGui_DrawList_PushClipRect(draw_list, x1, draw_y, x2, draw_y + draw_h, true)
      
      local px_start = math.max(0, math.floor(x1 - draw_x))
      local px_end = math.min(draw_w - 1, math.floor(x2 - draw_x))
      for px = px_start, px_end, 2 do
        -- Usa a mesma coordenada fixa da base; o brilho da região não pode
        -- redesenhar a waveform quando a duração da música muda.
        local stable_x = px * 10
        local amp = wave_amp(stable_x, seed) * ((draw_h / 2) * amp_scale_base)
        reaper.ImGui_DrawList_AddLine(draw_list,
          draw_x + px, mid - amp,
          draw_x + px, mid + amp,
          is_queued and 0xFFFFFF70 or 0xFFFFFF45, 1.0)
      end
      
      reaper.ImGui_DrawList_PopClipRect(draw_list)
    end
    
    if (x2 - x1) > 5 then
      local text_w, text_h = reaper.ImGui_CalcTextSize(ctx, sec.name)
      local pad_x = 6
      local pad_y = 3
      
      local badge_x1 = x1 + 2
      local badge_x2 = badge_x1 + text_w + (pad_x * 2)
      
      -- Lógica de colisão inteligente:
      -- Tenta colocar em cima (offset 0). Se bater no badge anterior, vai pra baixo.
      local offset = 0
      local min_gap = 15 -- Margem de segurança de 15px entre badges
      
      if badge_x1 >= (last_top_x2 + min_gap) then
        offset = 0
        last_top_x2 = badge_x2
      elseif badge_x1 >= (last_bot_x2 + min_gap) then
        offset = 28
        last_bot_x2 = badge_x2
      else
        -- Se estiverem tão próximos que bateriam em ambos, coloca no que estiver menos estrangulado
        if last_top_x2 <= last_bot_x2 then
          offset = 0
          last_top_x2 = badge_x2
        else
          offset = 28
          last_bot_x2 = badge_x2
        end
      end
      
      local text_y = draw_y + draw_h + 8 + offset
      local badge_y1 = text_y
      local badge_y2 = badge_y1 + text_h + (pad_y * 2)
      
      if badge_x2 > draw_x and badge_x1 < draw_x + draw_w then
        -- Renderiza o fundo do badge (fundinho na cor do mapa) mais arredondado
        reaper.ImGui_DrawList_AddRectFilled(draw_list, 
          badge_x1, badge_y1, badge_x2, badge_y2, 
          solid_color, 6.0
        )
        
        if reaper.ImGui_IsMouseClicked(ctx, 0) and mx >= badge_x1 and mx <= badge_x2 and my >= badge_y1 and my <= badge_y2 then
          hit_sec_pos = sec.pos
        end
        
        -- Texto com contraste inteligente (branco ou preto)
        local text_color = ((r/255) + (g/255) + (b/255) > 2.0) and 0x000000FF or 0xFFFFFFFF
        
        reaper.ImGui_DrawList_AddText(draw_list, badge_x1 + pad_x, badge_y1 + pad_y, text_color, sec.name)
      end
    end
    end -- fim if visible
  end
  
  reaper.ImGui_DrawList_PopClipRect(draw_list)

  if hit_sec_pos then
    local is_playing = (reaper.GetPlayState() & 1) == 1
    if state.hold and is_playing then
      state.pending_jump_pos = hit_sec_pos
      local p = reaper.GetPlayPosition()
      state.pending_jump_trigger_time = p
      for _, s in ipairs(state.sections) do
        if p >= s.pos and p < s.end_pos then
           state.pending_jump_trigger_time = s.end_pos
           break
        end
      end
    else
      reaper.SetEditCurPos(hit_sec_pos, true, true)
      reaper.Main_OnCommand(40150, 0) -- View: Go to play position
      state.badge_click_active = true
      state.pending_jump_pos = nil
    end
  elseif w_clicked then
    local t = start_time + ((mx - draw_x) / draw_w) * view_len
    reaper.SetEditCurPos(t, true, true)
    reaper.Main_OnCommand(40150, 0)
    state.badge_click_active = false
  end
  
  -- Evita que o "arrastar" anule o "clique" no exato mesmo frame
  if w_active and not w_clicked and not state.badge_click_active then
    state.is_scrubbing = true
    local t = start_time + ((mx - draw_x) / draw_w) * view_len
    state.scrub_pos = t
    reaper.SetEditCurPos(state.scrub_pos, true, false)
  elseif not w_active then
    state.badge_click_active = false
    if state.is_scrubbing then
      state.is_scrubbing = false
      reaper.SetEditCurPos(state.scrub_pos, true, true)
      reaper.Main_OnCommand(40150, 0)
    end
  end

  -- ── Playhead ──
  local current_pos = state.is_scrubbing and reaper.GetCursorPosition() or play_pos
  if current_pos and current_pos >= 0 then
    local px = time_to_x(current_pos)
    if px >= draw_x and px <= max_x then
      reaper.ImGui_DrawList_AddLine(draw_list, px, draw_y, px, draw_y + draw_h, C.playhead, 1.5)
    end
  end

  -- ── Teclas cromáticas no espaço vazio à esquerda (Sob o TCP) ──
  local grid_x = wx + margin_x
  local grid_w = draw_x - grid_x - 12 -- 12px de respiro antes da onda
  
  if grid_w > 100 then -- Só desenha se houver espaço (usuário não escondeu o TCP)
    local cols = 6
    local rows = 2
    local spacing = 4
    
    -- A altura total das duas linhas será exatamente a metade da altura da waveform
    local total_h = draw_h / 2
    local key_h = (total_h - (rows - 1) * spacing) / rows
    
    -- A largura preenche o espaço, mas com um limite para não ficar distorcido
    local key_w = (grid_w - (cols - 1) * spacing) / cols
    if key_w > 55 then key_w = 55 end
    local total_w = cols * key_w + (cols - 1) * spacing
    
    -- Alinha pela base da waveform (embaixo) e encostado no início da waveform (direita do espaço livre)
    local start_x = draw_x - 12 - total_w
    local start_y = draw_y + draw_h - total_h
    
    local active_root = KeyDetect.get_root(state.current_key)
    local display_root = active_root
    local display_octave = nil
    
    if active_root then
      local orig_idx = 1
      for i, k in ipairs(KeyDetect.CHROMATIC) do
        if k == active_root then orig_idx = i; break end
      end
      
      -- Assumimos que a música original está na oitava 4
      local abs_semitones = (4 * 12) + (orig_idx - 1) + state.pitch_offset
      local new_octave = math.floor(abs_semitones / 12)
      local new_idx = abs_semitones % 12
      
      display_root = KeyDetect.CHROMATIC[new_idx + 1]
      display_octave = new_octave
    end
    
    -- ==== MÁQUINA DE TOM (Top Half) ====
    local btn_h = 36
    -- Nova largura apenas com o bloco de tom: 22 (-) + 4 (gap) + 54 (B) + 4 (gap) + 22 (+) = 106
    local widget_w = 22 + 4 + 54 + 4 + 22
    local panel_y = draw_y + (total_h - btn_h) / 2
    
    -- Centralizado acima das teclas cromáticas
    local px = start_x + (total_w - widget_w) / 2
    
    reaper.ImGui_SetCursorScreenPos(ctx, px, panel_y)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x555555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
    
    -- Botão -
    local cx1, cy1 = reaper.ImGui_GetCursorScreenPos(ctx)
    if reaper.ImGui_Button(ctx, "##minus", 22, btn_h) then shift_pitch(-1) end
    reaper.ImGui_DrawList_AddLine(draw_list, cx1 + 6, cy1 + (btn_h/2), cx1 + 16, cy1 + (btn_h/2), 0xFFFFFFFF, 2.0)
    
    -- Display Central do Tom
    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
    
    if reaper.ImGui_Button(ctx, "##pitch_display", 54, btn_h) then reset_pitch() end
    
    local r_min_x, r_min_y = reaper.ImGui_GetItemRectMin(ctx)
    local r_max_x, r_max_y = reaper.ImGui_GetItemRectMax(ctx)
    local btn_center_x = (r_min_x + r_max_x) / 2
    local btn_center_y = (r_min_y + r_max_y) / 2
    
    local txt = display_root or "?"
    reaper.ImGui_PushFont(ctx, font)
    local w1, h1 = reaper.ImGui_CalcTextSize(ctx, txt)
    reaper.ImGui_PopFont(ctx)
    
    local w2, h2 = 0, 0
    if display_octave then
      reaper.ImGui_PushFont(ctx, font_small)
      w2, h2 = reaper.ImGui_CalcTextSize(ctx, tostring(display_octave))
      reaper.ImGui_PopFont(ctx)
    end
    
    local total_txt_w = w1 + w2 + (display_octave and 1 or 0)
    local txt_start_x = btn_center_x - (total_txt_w / 2)
    
    reaper.ImGui_PushFont(ctx, font)
    reaper.ImGui_DrawList_AddText(draw_list, txt_start_x, btn_center_y - (h1/2), 0xFFFFFFFF, txt)
    reaper.ImGui_PopFont(ctx)
    
    if display_octave then
      reaper.ImGui_PushFont(ctx, font_small)
      -- Alinha a oitava pela base do texto principal
      reaper.ImGui_DrawList_AddText(draw_list, txt_start_x + w1 + 1, btn_center_y + (h1/2) - h2 - 1, 0xFFFFFFFF, tostring(display_octave))
      reaper.ImGui_PopFont(ctx)
    end
    
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    -- Botão +
    reaper.ImGui_SameLine(ctx, 0, 4)
    local cx2, cy2 = reaper.ImGui_GetCursorScreenPos(ctx)
    if reaper.ImGui_Button(ctx, "##plus", 22, btn_h) then shift_pitch(1) end
    reaper.ImGui_DrawList_AddLine(draw_list, cx2 + 6, cy2 + (btn_h/2), cx2 + 16, cy2 + (btn_h/2), 0xFFFFFFFF, 2.0)
    reaper.ImGui_DrawList_AddLine(draw_list, cx2 + 11, cy2 + (btn_h/2)-5, cx2 + 11, cy2 + (btn_h/2)+5, 0xFFFFFFFF, 2.0)
    
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    -- ==== TECLAS CROMÁTICAS (Bottom Half) ====
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    
    for idx, key in ipairs(KeyDetect.CHROMATIC) do
      local r = math.floor((idx - 1) / cols)
      local c = (idx - 1) % cols
      
      local kx = start_x + c * (key_w + spacing)
      local ky = start_y + r * (key_h + spacing)
      
      reaper.ImGui_SetCursorScreenPos(ctx, kx, ky)
      
      local is_active = (key == display_root)
      if is_active then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.accent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.accent_hover)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   C.accent)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           0xFFFFFFFF)
      else
        push_btn_style()
      end
      
      reaper.ImGui_Button(ctx, key, key_w, key_h)
      
      if is_active then reaper.ImGui_PopStyleColor(ctx, 4) else pop_btn_style() end
    end
    
    reaper.ImGui_PopStyleVar(ctx)
  end
  
  -- =========================================================
  -- Botões MARKER, LOUDNESS e SALVAR ao lado da Waveform
  -- =========================================================
  local marker_w = 84
  local marker_h = 48
  local gap = 4
  local combined_w = marker_w * 3 + gap * 2
  
  -- Os botões ficam fixos logo após o fim da waveform (que já tem uma margem garantida)
  local marker_x = draw_x + draw_w + 10
  
  -- Abaixando os botões: alinhado com a base inferior da waveform
  local marker_y = draw_y + draw_h - marker_h

  local row1_y = marker_y - (marker_h + gap) * 2
  local row2_y = marker_y - marker_h - gap

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8.0)

  -- ================== COLUNA 1 ==================

  -- MIDI (Linha 1)
  reaper.ImGui_SetCursorScreenPos(ctx, marker_x, row1_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "MIDI", marker_w, marker_h) then
    local target_tr = nil
    local num_tracks = reaper.CountTracks(0)
    for i = 0, num_tracks - 1 do
      local tr = reaper.GetTrack(0, i)
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      if name == "MIDI" then
        target_tr = tr
        break
      end
    end
    
    if not target_tr then
      reaper.InsertTrackAtIndex(num_tracks, true)
      target_tr = reaper.GetTrack(0, num_tracks)
      reaper.GetSetMediaTrackInfo_String(target_tr, "P_NAME", "MIDI", true)
    end
    
    local midi_item = nil
    if reaper.CountTrackMediaItems(target_tr) > 0 then
      midi_item = reaper.GetTrackMediaItem(target_tr, 0)
    else
      local proj_len = reaper.GetProjectLength(0)
      if proj_len <= 0 then proj_len = 300 end
      midi_item = reaper.CreateNewMIDIItemInProj(target_tr, 0, proj_len, false)
    end
    
    if midi_item then
      local take = reaper.GetActiveTake(midi_item)
      if take and reaper.TakeIsMIDI(take) then
        -- Limpa notas existentes para não duplicar se clicar de novo
        local _, notecnt = reaper.MIDI_CountEvts(take)
        for j = notecnt - 1, 0, -1 do
          reaper.MIDI_DeleteNote(take, j)
        end
        
        -- Usa o MIDI Mapping salvo nas configurações
        local idx = 0
        while true do
          local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers2(0, idx)
          if retval == 0 then break end
          
          if isrgn and name and name ~= "" then
            -- Remove números no começo (ex: "1 Verso" -> "Verso") e ajusta maiúsculas
            local clean_name = name:match("^%d+[%.-_]?%s*(.+)") or name
            clean_name = clean_name:gsub("^%l", string.upper)
            
            -- Pega do mapping associado ao Maker ou cai para um default fixo
            local pitch = 36
            for _, sec in ipairs(user_sections) do
              if string.upper(sec.name) == string.upper(clean_name) then
                pitch = sec.pitch
                break
              end
            end 
            
            -- Converte tempo do projeto (segundos) para PPQ (ticks MIDI)
            local start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pos)
            -- Nota curta funcionando apenas como trigger (480 PPQ)
            local end_ppq = start_ppq + 480 
            
            reaper.MIDI_InsertNote(take, false, false, start_ppq, end_ppq, 0, pitch, 100, true)
          end
          idx = idx + 1
        end
        
        reaper.MIDI_Sort(take)
        reaper.UpdateArrange()
      end
    end
  end
  pop_btn_style()

  -- HOLYRICS (Linha 2)
  reaper.ImGui_SetCursorScreenPos(ctx, marker_x, row2_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "HOLYRICS", marker_w, marker_h) then
    state.show_holyrics_modal = not state.show_holyrics_modal
  end
  pop_btn_style()

  -- MARKER (Linha 3)
  reaper.ImGui_SetCursorScreenPos(ctx, marker_x, marker_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "MARKER", marker_w, marker_h) then
    state.show_marker_modal = not state.show_marker_modal
  end
  pop_btn_style()
  
  -- ================== COLUNA 2 ==================
  local loud_x = marker_x + marker_w + gap

  -- GRID LOCK (Linha 1)
  reaper.ImGui_SetCursorScreenPos(ctx, loud_x, row1_y)
  
  if state.grid_lock then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
  else
    push_btn_style()
  end
  
  if reaper.ImGui_Button(ctx, "GRID LOCK", marker_w, marker_h) then
    state.grid_lock = not state.grid_lock
    if state.grid_lock then
      state.locked_start, state.locked_end = reaper.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
    end
  end
  
  if state.grid_lock then
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    pop_btn_style()
  end

  -- REPERTÓRIO (Linha 2)
  reaper.ImGui_SetCursorScreenPos(ctx, loud_x, row2_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "REPERTÓRIO", marker_w, marker_h) then
    Repertoire.browse(state, json)
  end
  pop_btn_style()

  -- LOUDNESS (Linha 3)
  reaper.ImGui_SetCursorScreenPos(ctx, loud_x, marker_y)
  local active_loud = state.loudness_active
  if active_loud then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.green)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.green_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.btn_active)
  else
    push_btn_style()
  end
  
  if reaper.ImGui_Button(ctx, "LOUDNESS", marker_w, marker_h) then
    toggle_loudness()
  end
  
  if active_loud then
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    pop_btn_style()
  end
  
  -- ================== COLUNA 3 ==================
  local save_x = loud_x + marker_w + gap

  -- OPÇÕES (Linha 1)
  reaper.ImGui_SetCursorScreenPos(ctx, save_x, row1_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "OPÇÕES", marker_w, marker_h) then
    reaper.ImGui_OpenPopup(ctx, "OpcoesPopup")
  end
  pop_btn_style()
  
  -- Âncora no canto inferior direito do popup para ele crescer pra cima e pra esquerda (1.0, 1.0)
  reaper.ImGui_SetNextWindowPos(ctx, save_x + marker_w, row1_y - 4, reaper.ImGui_Cond_Appearing(), 1.0, 1.0)
  
  -- Substitui o azul padrão do SO por um cinza escuro no hover e rosa no clique
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), 0x555555FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(), C.accent)
  
  -- Espaçamento mais folgado para o menu de opções
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 12)
  
  -- Define a largura mínima do menu
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 180, 0, 9999, 9999)
  
  if reaper.ImGui_BeginPopup(ctx, "OpcoesPopup") then
    if reaper.ImGui_Selectable(ctx, "Pasta de Pads", false, 0, 0, 22) then
      if reaper.JS_Dialog_BrowseForFolder then
        local current_folder = reaper.GetExtState("MultitrackController", "pads_folder")
        local retval, folder = reaper.JS_Dialog_BrowseForFolder("Selecionar Pasta Base de Pads", current_folder)
        if retval == 1 or retval == true then
          reaper.SetExtState("MultitrackController", "pads_folder", folder, true)
          reaper.ShowMessageBox("Pasta de Pads configurada com sucesso!\n\nO controlador agora usara esta pasta automaticamente de acordo com o tom da musica.", "Multitrack Controller", 0)
        end
      else
        reaper.ShowMessageBox("Requer extensao JS_ReaScriptAPI.", "Multitrack Controller", 0)
      end
    end
    
    if reaper.ImGui_Selectable(ctx, "Renderizar", false, 0, 0, 22) then
      state.show_render_modal = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    
    if reaper.ImGui_Selectable(ctx, "MIDI Mapping", false, 0, 0, 22) then
      state.show_midi_mapping_modal = true
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    
    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- ABRIR (Linha 2)
  reaper.ImGui_SetCursorScreenPos(ctx, save_x, row2_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "ABRIR", marker_w, marker_h) then
    Repertoire.load(state, json)
  end
  pop_btn_style()

  -- SALVAR (Linha 3)
  reaper.ImGui_SetCursorScreenPos(ctx, save_x, marker_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, "SALVAR", marker_w, marker_h) then
    Repertoire.save(state, json, KeyDetect)
  end
  pop_btn_style()
  
  reaper.ImGui_PopStyleVar(ctx)
  
end

-- ─── 1. Top Bar ───────────────────────────────────────────────────────────────

local function draw_transport_icon(draw_list, type, cx, cy, color)
  if type == "play" then
    -- Triângulo perfeito apontando para a direita
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx - 5, cy - 10, cx - 5, cy + 10, cx + 11, cy, color)
  elseif type == "stop" then
    -- Quadrado robusto
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cx - 8, cy - 8, cx + 8, cy + 8, color)
  elseif type == "prev" then
    -- Duas setas e barra
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx + 1, cy - 8, cx + 1, cy + 8, cx - 7, cy, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx + 9, cy - 8, cx + 9, cy + 8, cx + 1, cy, color)
    reaper.ImGui_DrawList_AddLine(draw_list, cx - 10, cy - 8, cx - 10, cy + 8, color, 3.0)
  elseif type == "next" then
    -- Duas setas e barra
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx - 9, cy - 8, cx - 9, cy + 8, cx - 1, cy, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx - 1, cy - 8, cx - 1, cy + 8, cx + 7, cy, color)
    reaper.ImGui_DrawList_AddLine(draw_list, cx + 10, cy - 8, cx + 10, cy + 8, color, 3.0)
  elseif type == "next_song" then
    -- Três setas
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx - 12, cy - 8, cx - 12, cy + 8, cx - 4, cy, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx - 4, cy - 8, cx - 4, cy + 8, cx + 4, cy, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list, cx + 4, cy - 8, cx + 4, cy + 8, cx + 12, cy, color)
  end
end

local function get_safe_tracks()
  local safe = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    local n = name:lower()
    if n:match("click") or n:match("metronomo") or n:match("metrônomo") then
      safe[tr] = true
      local parent = reaper.GetParentTrack(tr)
      while parent do
        safe[parent] = true
        parent = reaper.GetParentTrack(parent)
      end
    end
  end
  return safe
end

toggle_loudness = function()
  local sws_normalize_cmd = reaper.NamedCommandLookup("_BR_NORMALIZE_LOUDNESS_ITEMS23")
  if not state.loudness_active and (not reaper.BR_GetMediaItemTakeGUID or sws_normalize_cmd == 0) then
    reaper.ShowMessageBox("LOUDNESS requer a extensão SWS/S&M com a ação de normalização por loudness.", "Multitrack Controller", 0)
    return
  end

  local selected_tracks, selected_items = {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    selected_tracks[tr] = reaper.IsTrackSelected(tr)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local item = reaper.GetTrackMediaItem(tr, j)
      selected_items[item] = reaper.IsMediaItemSelected(item)
    end
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(0)
  local safe_tracks = get_safe_tracks()
  
  if state.loudness_active then
    -- TOGGLE OFF: Restaura os volumes originais dos itens (instantâneo)
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if not safe_tracks[tr] then
        for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
          local item = reaper.GetTrackMediaItem(tr, j)
          local take = reaper.GetActiveTake(item)
          if take then
            local guid = reaper.BR_GetMediaItemTakeGUID(take)
            local rv, val = reaper.GetProjExtState(0, "AntigravityMultitrack", "LoudnessOrig_" .. guid)
            if rv == 1 then
              reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", tonumber(val))
            end
          end
        end
      end
    end
    state.loudness_active = false
    reaper.SetProjExtState(0, "AntigravityMultitrack", "LoudnessActive", "0")
    
  else
    -- TOGGLE ON: Verifica se já analisou antes
    local needs_analysis = true
    
    -- Checa se já existe cache de volume normalizado
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if not safe_tracks[tr] and reaper.CountTrackMediaItems(tr) > 0 then
        local item = reaper.GetTrackMediaItem(tr, 0)
        local take = reaper.GetActiveTake(item)
        if take then
          local guid = reaper.BR_GetMediaItemTakeGUID(take)
          local rv, _ = reaper.GetProjExtState(0, "AntigravityMultitrack", "LoudnessNorm_" .. guid)
          if rv == 1 then needs_analysis = false end
          break
        end
      end
    end
    
    if not needs_analysis then
      -- JÁ FOI ANALISADO: Apenas aplica os volumes normalizados do cache (instantâneo)
      for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if not safe_tracks[tr] then
          for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
            local item = reaper.GetTrackMediaItem(tr, j)
            local take = reaper.GetActiveTake(item)
            if take then
              local guid = reaper.BR_GetMediaItemTakeGUID(take)
              local rv, val = reaper.GetProjExtState(0, "AntigravityMultitrack", "LoudnessNorm_" .. guid)
              if rv == 1 then
                reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", tonumber(val))
              end
            end
          end
        end
      end
    else
      -- PRIMEIRA VEZ: Salva originais, roda o SWS, e salva os novos volumes
      reaper.Main_OnCommand(40296, 0) -- Select all tracks
      reaper.Main_OnCommand(40182, 0) -- Select all items
      
      for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if safe_tracks[tr] then
           -- Deseleciona click
           reaper.SetTrackSelected(tr, false)
           for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
              local item = reaper.GetTrackMediaItem(tr, j)
              reaper.SetMediaItemSelected(item, false)
           end
        else
          -- Salva o volume ORIGINAL de quem será processado
          for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
            local item = reaper.GetTrackMediaItem(tr, j)
            local take = reaper.GetActiveTake(item)
            if take then
              local guid = reaper.BR_GetMediaItemTakeGUID(take)
              local current_vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
              reaper.SetProjExtState(0, "AntigravityMultitrack", "LoudnessOrig_" .. guid, tostring(current_vol))
            end
          end
        end
      end
      
      reaper.UpdateArrange()
      
      -- Aciona SWS Normalize (demorado)
      reaper.Main_OnCommand(sws_normalize_cmd, 0)
      
      -- Após o SWS finalizar, salva o NOVO volume como cache "Normalizado"
      for i = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, i)
        if not safe_tracks[tr] then
          for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
            local item = reaper.GetTrackMediaItem(tr, j)
            local take = reaper.GetActiveTake(item)
            if take then
              local guid = reaper.BR_GetMediaItemTakeGUID(take)
              local norm_vol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
              reaper.SetProjExtState(0, "AntigravityMultitrack", "LoudnessNorm_" .. guid, tostring(norm_vol))
            end
          end
        end
      end
    end
    
    state.loudness_active = true
    reaper.SetProjExtState(0, "AntigravityMultitrack", "LoudnessActive", "1")
  end
  
  reaper.UpdateArrange()
  for tr, selected in pairs(selected_tracks) do reaper.SetTrackSelected(tr, selected) end
  for item, selected in pairs(selected_items) do reaper.SetMediaItemSelected(item, selected) end
  reaper.Undo_EndBlock2(0, "Multitrack Controller: alternar loudness", -1)
  reaper.PreventUIRefresh(-1)
end

local function is_click_active()
  return state.click_ducked
end

local function capture_duck_snapshot(proj)
  local key = tostring(proj)
  if state.duck_projects[key] then return state.duck_projects[key] end
  local snapshot = { volumes = {} }
  local safe_tracks = get_safe_tracks()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not safe_tracks[tr] then
      snapshot.volumes[tr] = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
    end
  end
  state.duck_projects[key] = snapshot
  return snapshot
end

local function toggle_click_duck()
  state.click_ducked = not state.click_ducked
  state.duck_target = state.click_ducked and 0.0 or 1.0
  
  -- Se começamos a dar duck e o volume estava cheio (não estava no meio de uma transição)
  if state.click_ducked and state.duck_factor >= 0.99 then
    local safe_tracks = get_safe_tracks()
    state.original_vols = {}
    state.duck_projects = {}
    local proj = reaper.EnumProjects(-1)
    local snapshot = capture_duck_snapshot(proj)
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      local guid = reaper.GetTrackGUID(tr)
      if not safe_tracks[tr] then
        state.original_vols[guid] = snapshot.volumes[tr]
      end
    end
  end
end

function shift_pitch(semitones)
  local proj = reaper.EnumProjects(-1)
  local project_key = tostring(proj)
  local project_state = state.pitch_projects[project_key]
  if not project_state then
    project_state = { proj = proj, originals = {}, offset = 0 }
    state.pitch_projects[project_key] = project_state
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(proj)
  local safe_tracks = get_safe_tracks()
  
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not safe_tracks[tr] then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local item = reaper.GetTrackMediaItem(tr, j)
        local take = reaper.GetActiveTake(item)
        if take then
          if project_state.originals[take] == nil then
            project_state.originals[take] = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
          end
          reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", project_state.originals[take] + project_state.offset + semitones)
        end
      end
    end
  end
  
  project_state.offset = project_state.offset + semitones
  state.pitch_offset = project_state.offset
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "Multitrack Controller: transpor tom", -1)
  reaper.PreventUIRefresh(-1)
end

reset_pitch = function()
  local project_state = state.pitch_projects[tostring(reaper.EnumProjects(-1))]
  if not project_state or project_state.offset == 0 then return end
  reaper.Undo_BeginBlock2(project_state.proj)
  restore_project_pitch(project_state)
  state.pitch_offset = 0
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(project_state.proj, "Multitrack Controller: restaurar tom original", -1)
end

local function render_marker_modal(ctx)
  if not state.show_marker_modal then return end

  -- Somente posiciona na primeira vez que for aberto. Depois o ImGui lembra sozinho!
  local center_x, center_y = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetWindowViewport(ctx))
  reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y - 200, reaper.ImGui_Cond_FirstUseEver(), 0.5, 0.5)
  
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1A1A1AF2)
  local visible, open = reaper.ImGui_Begin(ctx, "MakerTrack", true, reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoCollapse())
  if not open then state.show_marker_modal = false end
  
  if visible then
    reaper.ImGui_Dummy(ctx, 0, 4)
    
    for i, sec in ipairs(user_sections) do
      local r, g, b = sec.r/255, sec.g/255, sec.b/255
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 0.7))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 0.9))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 1.0))
      
      local text_col = (r + g + b > 2.0) and 0x000000FF or 0xFFFFFFFF
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), text_col)
      
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
      if reaper.ImGui_Button(ctx, sec.name, 220, 35) then
        Sections.add_region_at_cursor(sec.name, sec.r, sec.g, sec.b)
        
        -- Atualiza a UI imediatamente para refletir a nova região
        state.sections = Sections.get_from_project(0)
      end
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx, 4)
      reaper.ImGui_Dummy(ctx, 0, 2)
    end
    
    reaper.ImGui_Dummy(ctx, 0, 8)
    
    -- Botão de Adicionar Customizado
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x555555FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "+ ADICIONAR TIMECODE", 220, 35) then
      state.show_add_custom_modal = true
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    
    reaper.ImGui_Dummy(ctx, 0, 8)
    
    -- Botão de Finalizar Timecode (Exportar Mapa)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x3B82F6FF) -- Azul
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x60A5FAFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x2563EBFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "FINALIZAR TIMECODE", 220, 40) then
      export_mapa_to_txt()
      state.show_marker_modal = false
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    reaper.ImGui_Dummy(ctx, 0, 4)
    
    -- Botão Cancelar
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "CANCELAR", 220, 35) then
      state.show_marker_modal = false
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)
end

local function render_add_custom_modal(ctx)
  if state.show_add_custom_modal then
    reaper.ImGui_OpenPopup(ctx, "Novo Timecode Customizado")
    state.show_add_custom_modal = false
  end

  local center_x, center_y = reaper.ImGui_Viewport_GetCenter(reaper.ImGui_GetWindowViewport(ctx))
  reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)

  if reaper.ImGui_BeginPopupModal(ctx, "Novo Timecode Customizado", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize() | reaper.ImGui_WindowFlags_NoTitleBar()) then
    reaper.ImGui_Text(ctx, "ADICIONAR TIMECODE CUSTOMIZADO")
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)

    reaper.ImGui_Text(ctx, "Nome da Secao:")
    local rv, new_name = reaper.ImGui_InputText(ctx, "##name", state.new_sec_name or "")
    if rv then state.new_sec_name = new_name end

    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_Text(ctx, "Cor:")
    local rv_c, new_col = reaper.ImGui_ColorEdit4(ctx, "##color", state.new_sec_color_int or 0xFFFFFFFF, reaper.ImGui_ColorEditFlags_NoAlpha() | reaper.ImGui_ColorEditFlags_NoInputs())
    if rv_c then state.new_sec_color_int = new_col end

    reaper.ImGui_Dummy(ctx, 0, 8)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x22C55EFF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "SALVAR E ADICIONAR", 220, 35) then
      if state.new_sec_name and state.new_sec_name ~= "" then
        local r_d, g_d, b_d = reaper.ImGui_ColorConvertU32ToDouble4(state.new_sec_color_int or 0xFFFFFFFF)
        table.insert(user_sections, {
           name = state.new_sec_name,
           r = math.floor(r_d * 255),
           g = math.floor(g_d * 255),
           b = math.floor(b_d * 255),
           pitch = get_next_free_pitch()
        })
        save_user_sections()
        state.new_sec_name = ""
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    
    reaper.ImGui_Dummy(ctx, 0, 4)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x555555FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "CANCELAR", 220, 35) then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_EndPopup(ctx)
  end
end

local function render_render_modal(ctx, win_x, win_y, win_w, win_h)
  if not state.show_render_modal then return end

  reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y)
  reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x000000AA)
  if reaper.ImGui_Begin(ctx, "##render_dim", nil, reaper.ImGui_WindowFlags_NoDecoration() | reaper.ImGui_WindowFlags_NoMove() | reaper.ImGui_WindowFlags_NoInputs() | reaper.ImGui_WindowFlags_NoNav()) then
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  local w, h = 400, 320
  reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w - w) / 2, win_y + (win_h - h) / 2, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx, w, h)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1A1A1AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x333333FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16.0, 16.0)
  
  if reaper.ImGui_Begin(ctx, "Configuracoes de Render", nil, reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_NoDocking()) then
    reaper.ImGui_Text(ctx, "Formato:")
    if reaper.ImGui_BeginCombo(ctx, "##format", state.render_format) then
      if reaper.ImGui_Selectable(ctx, "WAV", state.render_format == "WAV") then state.render_format = "WAV" end
      if reaper.ImGui_Selectable(ctx, "MP3", state.render_format == "MP3") then state.render_format = "MP3" end
      reaper.ImGui_EndCombo(ctx)
    end
    
    reaper.ImGui_Dummy(ctx, 1, 10)
    
    reaper.ImGui_Text(ctx, "O que renderizar:")
    local mode_label = "Tudo (Master)"
    if state.render_mode == "PISTAS" then mode_label = "Apenas pistas selecionadas (Stems)"
    elseif state.render_mode == "REGIOES" then mode_label = "Regiões selecionadas" end
    
    if reaper.ImGui_BeginCombo(ctx, "##mode", mode_label) then
      if reaper.ImGui_Selectable(ctx, "Tudo (Master)", state.render_mode == "TUDO") then state.render_mode = "TUDO" end
      if reaper.ImGui_Selectable(ctx, "Apenas pistas selecionadas (Stems)", state.render_mode == "PISTAS") then state.render_mode = "PISTAS" end
      if reaper.ImGui_Selectable(ctx, "Regiões selecionadas", state.render_mode == "REGIOES") then state.render_mode = "REGIOES" end
      reaper.ImGui_EndCombo(ctx)
    end
    
    reaper.ImGui_Dummy(ctx, 1, 10)
    
    reaper.ImGui_Text(ctx, "Pasta de Destino:")
    local disp_path = state.render_path == "" and "(Pasta do Projeto)" or state.render_path
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x0F0F0FFF)
    reaper.ImGui_InputText(ctx, "##path", disp_path, reaper.ImGui_InputTextFlags_ReadOnly())
    reaper.ImGui_PopStyleColor(ctx)
    
    if reaper.ImGui_Button(ctx, "Procurar...", 100, 30) then
      if reaper.JS_Dialog_BrowseForFolder then
        local ok, folder = reaper.JS_Dialog_BrowseForFolder("Selecione a pasta de destino", state.render_path)
        if ok == 1 and folder ~= "" then
          state.render_path = folder
        end
      else
        reaper.ShowMessageBox("Selecionar uma pasta de destino requer js_ReaScriptAPI.", "Multitrack Controller", 0)
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Limpar", 100, 30) then
      state.render_path = ""
    end
    
    reaper.ImGui_SetCursorPosY(ctx, h - 46)
    local btn_w = (w - 32 - 16) / 3
    if reaper.ImGui_Button(ctx, "Cancelar", btn_w, 30) then
      load_render_settings()
      state.show_render_modal = false
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Salvar", btn_w, 30) then
      save_render_settings()
      state.show_render_modal = false
    end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
    if reaper.ImGui_Button(ctx, "RENDERIZAR", btn_w, 30) then
      save_render_settings()

      -- A janela de render precisa receber estas preferências, mas elas não devem
      -- contaminar a configuração persistente do projeto após ser aberta.
      local _, old_render_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
      local _, old_render_format = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false)
      local old_render_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
      local old_bounds_flag = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
      
      local proj_path = reaper.GetProjectPathEx(0, "")
      local out_path = state.render_path
      if not out_path or out_path == "" then out_path = proj_path end
      reaper.GetSetProjectInfo_String(0, "RENDER_FILE", out_path, true)
      
      local fmt = state.render_format == "MP3" and "l3pm" or "wave"
      reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", string.pack("c4", fmt), true)
      
      if state.render_mode == "PISTAS" then
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 1, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)
      elseif state.render_mode == "REGIOES" then
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)
      else
        reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)
        reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)
      end
      
      reaper.Main_OnCommand(42230, 0)
      reaper.GetSetProjectInfo_String(0, "RENDER_FILE", old_render_file or "", true)
      reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", old_render_format or "", true)
      reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", old_render_settings, true)
      reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", old_bounds_flag, true)
      state.show_render_modal = false
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_End(ctx)
  end
  
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 2)
end

local function render_top_bar(win_x, win_y, win_w, top_h)
  local y = win_y + 4
  local bh = top_h - 8
  local text_y_offset = (top_h / 2) - 6 -- Centraliza o texto verticalmente

  -- ─── ESQUERDA: Info (Título) ───
  local x = win_x + 10
  local sname = state.current_proj_name:gsub("%.[Rr][Pp][Pp]$","")
  
  -- Título centralizado verticalmente (ajustado para a fonte maior)
  local title_y_offset = (top_h / 2) - 9
  
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + title_y_offset)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text)
  reaper.ImGui_PushFont(ctx, font_large)
  reaper.ImGui_Text(ctx, sname)
  reaper.ImGui_PopFont(ctx)
  reaper.ImGui_PopStyleColor(ctx)

  -- ─── CENTRO: HOLD + LOOP + Transporte + PAD + CLICK ───
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  
  local hold_w, loop_w, pad_w, click_w, metro_w = 64, 64, 64, 64, 64
  local trans_w = hold_w + 8 + loop_w + 8 + 48 + 4 + 72 + 4 + 48 + 4 + 48 + 8 + pad_w + 8 + click_w + 8 + metro_w
  local center_x = win_x + (win_w / 2) - (trans_w / 2)

  -- Aplica cantos arredondados suaves (formato quadrado com quinas redondas)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8.0)

  -- HOLD
  local active_hold = state.hold
  reaper.ImGui_SetCursorScreenPos(ctx, center_x, y)
  if active_hold then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, "HOLD", hold_w, bh) then state.hold = not state.hold end
  handle_mapped_button(ctx, "HOLD", function() state.hold = not state.hold end)
  if active_hold then reaper.ImGui_PopStyleColor(ctx, 2) else pop_btn_style() end

  -- LOOP
  local is_loop = reaper.GetSetRepeat(-1) == 1
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 72, y)
  if is_loop then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
  else
    push_btn_style()
  end
  -- Usamos o Command Nativo para evitar qualquer erro de API do GetSetRepeat no click
  if reaper.ImGui_Button(ctx, "LOOP", loop_w, bh) then reaper.Main_OnCommand(1068, 0) end
  handle_mapped_button(ctx, "LOOP", function() reaper.Main_OnCommand(1068, 0) end)
  if is_loop then reaper.ImGui_PopStyleColor(ctx, 2) else pop_btn_style() end

  -- Prev
  push_btn_style()
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 144, y)
  if reaper.ImGui_Button(ctx, "##prev", 48, bh) then reaper.Main_OnCommand(40862, 0) end
  handle_mapped_button(ctx, "PREV", function() reaper.Main_OnCommand(40862, 0) end)
  local mx, my = reaper.ImGui_GetItemRectMin(ctx)
  local Mx, My = reaper.ImGui_GetItemRectMax(ctx)
  draw_transport_icon(draw_list, "prev", (mx + Mx)/2, (my + My)/2, C.text)
  pop_btn_style()

  -- Play
  local is_playing = (reaper.GetPlayState() & 1) == 1
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        is_playing and C.btn_active or C.green)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  is_playing and C.btn_hover or C.green_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),   C.accent)
  
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 196, y)
  if reaper.ImGui_Button(ctx, "##play", 72, bh) then 
    if is_playing then reaper.OnStopButton() else reaper.OnPlayButton() end
  end
  mx, my = reaper.ImGui_GetItemRectMin(ctx)
  Mx, My = reaper.ImGui_GetItemRectMax(ctx)
  local icon_col = is_playing and C.accent or C.text
  draw_transport_icon(draw_list, is_playing and "stop" or "play", (mx + Mx)/2, (my + My)/2, icon_col)
  reaper.ImGui_PopStyleColor(ctx, 3)

  -- Next
  push_btn_style()
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 272, y)
  if reaper.ImGui_Button(ctx, "##next", 48, bh) then reaper.Main_OnCommand(40861, 0) end
  handle_mapped_button(ctx, "NEXT", function() reaper.Main_OnCommand(40861, 0) end)
  mx, my = reaper.ImGui_GetItemRectMin(ctx)
  Mx, My = reaper.ImGui_GetItemRectMax(ctx)
  draw_transport_icon(draw_list, "next", (mx + Mx)/2, (my + My)/2, C.text)
  pop_btn_style()

  -- Next Song
  local active_auto_next = state.auto_next
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 324, y)
  if active_auto_next then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, "##next_song", 48, bh) then 
     state.auto_next = not state.auto_next
  end
  handle_mapped_button(ctx, "NEXT_SONG", function() state.auto_next = not state.auto_next end)
  mx, my = reaper.ImGui_GetItemRectMin(ctx)
  Mx, My = reaper.ImGui_GetItemRectMax(ctx)
  draw_transport_icon(draw_list, "next_song", (mx + Mx)/2, (my + My)/2, active_auto_next and 0xFFFFFFFF or C.text)
  if active_auto_next then reaper.ImGui_PopStyleColor(ctx, 2) else pop_btn_style() end

  -- PAD
  local pad = state.pads[1]
  local pad_playing = pad.playing
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 380, y)
  if pad_playing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        C.green)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),  C.green_hover)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, "PAD", pad_w, bh) then Pads.toggle(pad, state.current_key) end
  handle_mapped_button(ctx, "PAD", function() Pads.toggle(pad, state.current_key) end, function()
      if reaper.ImGui_Selectable(ctx, "Configurar Pad Manualmente") then Pads.configure(pad) end
  end)
  if pad_playing then reaper.ImGui_PopStyleColor(ctx, 2) else pop_btn_style() end

  -- CLICK
  local is_click = is_click_active()
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 452, y)
  if is_click then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, "CLICK", click_w, bh) then toggle_click_duck() end
  if is_click then reaper.ImGui_PopStyleColor(ctx, 2) else pop_btn_style() end

  -- METRONOMO VISUAL
  reaper.ImGui_SetCursorScreenPos(ctx, center_x + 524, y)
  
  local metro_text = "-"
  local is_odd_beat = false
  
  if is_playing then
    local ppos = reaper.GetPlayPosition()
    local retval = reaper.TimeMap2_timeToBeats(0, ppos)
    local beat = math.floor(retval) + 1
    metro_text = tostring(beat)
    is_odd_beat = (beat % 2 == 1)
  end
  
  if is_playing then
    if is_odd_beat then
      -- Ímpar (1, 3): Rosa
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.accent_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF) -- Branco
    else
      -- Par (2, 4): Branco
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFFFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xEEEEEEFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xFFFFFFFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x000000FF) -- Preto
    end
  else
    push_btn_style() -- Apenas quando parado (preto)
  end
  
  -- Para que o botão não faça nada se clicado, usamos ele apenas como display
  reaper.ImGui_Button(ctx, metro_text, metro_w, bh)
  
  if is_playing then
    reaper.ImGui_PopStyleColor(ctx, 4)
  else
    pop_btn_style()
  end

  -- ── Menus à direita (Canto Superior Direito) ──
  local menu_items = {}

  local total_menu_w = 0
  for _, item in ipairs(menu_items) do total_menu_w = total_menu_w + item.w + 4 end
  local menu_x = win_x + win_w - total_menu_w - 4

  local pending_action = nil
  for i = #menu_items, 1, -1 do
    local item = menu_items[i]
    reaper.ImGui_SetCursorScreenPos(ctx, menu_x, y)
    
    local active = item.is_active and item.is_active()
    if active then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), C.green)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), C.green_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.btn_active)
    else
      push_btn_style()
    end
    
    if reaper.ImGui_Button(ctx, item.label, item.w, bh) then 
      pending_action = item.action 
    end
    
    -- Desenha o ícone vetorial se for o botão de opções
    if item.icon == "dots_v" then
      local mx, my = reaper.ImGui_GetItemRectMin(ctx)
      local Mx, My = reaper.ImGui_GetItemRectMax(ctx)
      local cx, cy = (mx + Mx) / 2, (my + My) / 2
      local dot_r = 2.0
      local space = 7
      reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy - space, dot_r, C.text)
      reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy,         dot_r, C.text)
      reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy + space, dot_r, C.text)
    end
    
    if active then
      reaper.ImGui_PopStyleColor(ctx, 3)
    else
      pop_btn_style()
    end
    
    menu_x = menu_x + item.w + 4
  end

  reaper.ImGui_PopStyleVar(ctx) -- Restaura o arredondamento padrão

  if pending_action then pending_action() end
end

local function render_midi_mapping_modal(ctx, win_x, win_y, win_w, win_h)
  if not state.show_midi_mapping_modal then return end

  reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w / 2), win_y + (win_h / 2), reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16.0, 16.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1A1A1AF2)
  
  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  local visible, open = reaper.ImGui_Begin(ctx, "Configuração de MIDI Mapping", true, flags)
  if not open then state.show_midi_mapping_modal = false end
  
  if visible then
    for i, sec in ipairs(user_sections) do
      reaper.ImGui_PushItemWidth(ctx, 120)
      if reaper.ImGui_BeginCombo(ctx, sec.name, get_note_name(sec.pitch)) then
        for p = 0, 127 do
          if reaper.ImGui_Selectable(ctx, get_note_name(p), p == sec.pitch) then
            sec.pitch = p
            save_user_sections()
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      reaper.ImGui_PopItemWidth(ctx)
    end
    
    reaper.ImGui_Dummy(ctx, 0, 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x444444FF)
    if reaper.ImGui_Button(ctx, "FECHAR", 120, 32) then
      state.show_midi_mapping_modal = false
    end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 2)
end
local function process_holyrics(text, proj_regions)
  local lines = {}
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in text:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  
  local text_sections = {}
  local current_section_name = "SEM SEÇÃO"
  local current_section_lines = {}
  
  local function flush_section()
    if #current_section_lines > 0 then
      local slides = {}
      local current_slide = {}
      for _, l in ipairs(current_section_lines) do
        table.insert(current_slide, l)
        if #current_slide >= state.holyrics_lines_per_slide then
          table.insert(slides, current_slide)
          current_slide = {}
        end
      end
      if #current_slide > 0 then
        table.insert(slides, current_slide)
      end
      table.insert(text_sections, {name = current_section_name, slides = slides})
      current_section_lines = {}
    end
  end

  for _, line in ipairs(lines) do
    local s = line:match("^%s*%[([^%]]+)%]%s*$")
    if s then
      flush_section()
      current_section_name = string.upper(s)
    else
      local content = line:match("^%s*(.-)%s*$")
      if content and content ~= "" then
        table.insert(current_section_lines, content)
      end
    end
  end
  flush_section()
  
  local unique_slides = {}
  local function get_slide_id(slide_lines)
    local t = table.concat(slide_lines, "\n")
    for i, ex in ipairs(unique_slides) do
      if table.concat(ex, "\n") == t then return i end
    end
    table.insert(unique_slides, slide_lines)
    return #unique_slides
  end
  
  local text_queues = {}
  for _, sec in ipairs(text_sections) do
    local ids = {}
    for _, slide in ipairs(sec.slides) do
      table.insert(ids, get_slide_id(slide))
    end
    if not text_queues[sec.name] then text_queues[sec.name] = {} end
    table.insert(text_queues[sec.name], ids)
  end
  
  state.holyrics_slides = unique_slides
  
  local no_lyrics = {["CONTAGEM"]=true, ["INTRODUÇÃO"]=true, ["INTRO"]=true, ["SOLO"]=true, ["SAÍDA"]=true, ["FINAL"]=true, ["PAUSA"]=true, ["TURNAROUND"]=true, ["INTERLÚDIO"]=true}
  local cursors = {}
  
  local new_mapping = {}
  for i, rgn in ipairs(proj_regions or {}) do
    local clean_name = string.upper(rgn.name:match("^%d+[%.-_]?%s*(.+)") or rgn.name)
    
    local manual_match = nil
    if state.holyrics_mapping then
      for _, old_m in ipairs(state.holyrics_mapping) do
        if old_m.pos == rgn.pos and old_m.name == rgn.name and old_m.manual then
          manual_match = old_m
          break
        end
      end
    end
    
    if manual_match then
      table.insert(new_mapping, {name = rgn.name, pos = rgn.pos, slide_ids = manual_match.slide_ids, manual = true})
    else
      local assigned_ids = {}
      if not no_lyrics[clean_name] then
         local q = text_queues[clean_name]
         if not q then
            for k, v in pairs(text_queues) do
               if clean_name:find(k) or k:find(clean_name) then q = v; clean_name = k; break end
            end
         end
         if q then
            cursors[clean_name] = (cursors[clean_name] or 0) + 1
            local s_ids = q[cursors[clean_name]] or q[#q]
            for _, id in ipairs(s_ids) do table.insert(assigned_ids, id) end
         end
      end
      table.insert(new_mapping, {name = rgn.name, pos = rgn.pos, slide_ids = assigned_ids, manual = false})
    end
  end
  
  state.holyrics_mapping = new_mapping
  return text_sections
end

local function cleanup_empty_slides()
  for i = #state.holyrics_slides, 1, -1 do
    if #state.holyrics_slides[i] == 0 and not state.holyrics_slides[i].keep_empty then
      table.remove(state.holyrics_slides, i)
      if state.holyrics_mapping then
        for _, m in ipairs(state.holyrics_mapping) do
          local new_ids = {}
          for _, id in ipairs(m.slide_ids) do
            if id < i then table.insert(new_ids, id)
            elseif id > i then table.insert(new_ids, id - 1)
            end
          end
          m.slide_ids = new_ids
        end
      end
    end
  end
end

local function move_lyric_line(s_idx, l_idx, dir)
  local slide = state.holyrics_slides[s_idx]
  
  if dir == -1 then -- UP
    if s_idx > 1 then
      local prev_slide = state.holyrics_slides[s_idx - 1]
      local to_move = {}
      for i = 1, l_idx do
        table.insert(to_move, slide[i])
      end
      for _, line in ipairs(to_move) do
        table.insert(prev_slide, line)
      end
      for i = 1, l_idx do
        table.remove(slide, 1)
      end
    end
  elseif dir == 1 then -- DOWN
    local to_move = {}
    for i = l_idx, #slide do
      table.insert(to_move, slide[i])
    end
    for i = #slide, l_idx, -1 do
      table.remove(slide, i)
    end
    
    if s_idx < #state.holyrics_slides then
      local next_slide = state.holyrics_slides[s_idx + 1]
      for i = #to_move, 1, -1 do
        table.insert(next_slide, 1, to_move[i])
      end
    else
      table.insert(state.holyrics_slides, to_move)
    end
  end
  
  cleanup_empty_slides()
end

local function render_holyrics_modal(ctx, win_x, win_y, win_w, win_h)
  if not state.show_holyrics_modal then return end
  
  reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w / 2), win_y + (win_h / 2), reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 1000, 700, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 800, 600, 2000, 1500)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x000000FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), 0x000000FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), 0x000000FF)
  
  local visible, open = reaper.ImGui_Begin(ctx, "HOLYRICS", true)
  if not open then state.show_holyrics_modal = false end
  
  if visible then
    local proj_regions = {}
    local idx = 0
    while true do
      local retval, isrgn, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, idx)
      if retval == 0 then break end
      if isrgn then
        table.insert(proj_regions, {name = name, pos = pos, rgnend = rgnend, color = color})
      end
      idx = idx + 1
    end
    
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local top_panel_h = avail_h * 0.25
    local bottom_panel_h = avail_h - top_panel_h - 16
    
    -- TOP PANEL
    reaper.ImGui_BeginChild(ctx, "##holyrics_top", avail_w, top_panel_h, true)
    
    reaper.ImGui_Text(ctx, "LETRA ORIGINAL")
    
    reaper.ImGui_SameLine(ctx, avail_w - 300)
    reaper.ImGui_Text(ctx, "LINHAS POR SLIDE")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 50)
    if reaper.ImGui_BeginCombo(ctx, "##linhas_slide", tostring(state.holyrics_lines_per_slide)) then
       for _, opt in ipairs({"1", "2", "3", "4"}) do
          if reaper.ImGui_Selectable(ctx, opt, tonumber(opt) == state.holyrics_lines_per_slide) then
             state.holyrics_lines_per_slide = tonumber(opt)
             reaper.SetExtState("MultitrackController", "holyrics_lines", opt, true)
          end
       end
       reaper.ImGui_EndCombo(ctx)
    end
    
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x22C55EFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x33D66FFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x11B44DFF)
    if reaper.ImGui_Button(ctx, "PROCESSAR LETRA", 120, 24) then
       if state.holyrics_has_manual_edits then
          reaper.ImGui_OpenPopup(ctx, "Confirmar Reprocessamento")
       else
          state.holyrics_parsed = process_holyrics(state.holyrics_text, proj_regions)
          state.holyrics_has_manual_edits = false
       end
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    -- Reprocess Popup
    reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w / 2), win_y + (win_h / 2), reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
    if reaper.ImGui_BeginPopupModal(ctx, "Confirmar Reprocessamento", true, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
       reaper.ImGui_Text(ctx, "Reprocessar a letra substituirá as edições manuais dos slides.\nContinuar?")
       reaper.ImGui_Dummy(ctx, 0, 8)
       if reaper.ImGui_Button(ctx, "Reprocessar", 120, 0) then
          state.holyrics_parsed = process_holyrics(state.holyrics_text, proj_regions)
          state.holyrics_has_manual_edits = false
          reaper.ImGui_CloseCurrentPopup(ctx)
       end
       reaper.ImGui_SameLine(ctx)
       if reaper.ImGui_Button(ctx, "Cancelar", 120, 0) then
          reaper.ImGui_CloseCurrentPopup(ctx)
       end
       reaper.ImGui_EndPopup(ctx)
    end
    
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x000000FF)
    local rv, text = reaper.ImGui_InputTextMultiline(ctx, "##holyrics_input", state.holyrics_text, -1, -1)
    reaper.ImGui_PopStyleColor(ctx)
    if rv then state.holyrics_text = text end
    
    reaper.ImGui_EndChild(ctx) -- end top panel
    
    reaper.ImGui_Dummy(ctx, 0, 8)
    
    -- BOTTOM AREA
    local col1_w = avail_w * 0.55
    local col2_w = avail_w - col1_w - 8
    
    -- SLIDES
    reaper.ImGui_BeginGroup(ctx)
    reaper.ImGui_Text(ctx, "SLIDES")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x000000FF)
    reaper.ImGui_BeginChild(ctx, "##holyrics_preview", col1_w, bottom_panel_h, true)
    
    for i, slide in ipairs(state.holyrics_slides) do
      local is_highlighted = false
      if state.holyrics_selected_region then
         local m = state.holyrics_mapping[state.holyrics_selected_region]
         if m then
            for _, id in ipairs(m.slide_ids) do
               if id == i then is_highlighted = true; break end
            end
         end
      end
      
      local frame_h = reaper.ImGui_GetFrameHeightWithSpacing(ctx)
      local lines_count = math.max(1, #slide)
      local card_h = 45 + (lines_count * frame_h)
      
      local p_min_x, p_min_y = reaper.ImGui_GetCursorScreenPos(ctx)
      local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
      local p_max_x = p_min_x + avail_w
      local p_max_y = p_min_y + card_h
      
      local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
      local bg_color = is_highlighted and 0x1A3A1AFF or 0x151515FF
      reaper.ImGui_DrawList_AddRectFilled(draw_list, p_min_x, p_min_y, p_max_x, p_max_y, bg_color, 6.0)
      reaper.ImGui_DrawList_AddRect(draw_list, p_min_x, p_min_y, p_max_x, p_max_y, 0x333333FF, 6.0)
      
      reaper.ImGui_SetCursorScreenPos(ctx, p_min_x + 8, p_min_y + 8)
      reaper.ImGui_BeginGroup(ctx)
      
      -- Header
      reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, "SLIDE " .. i)
      reaper.ImGui_SameLine(ctx, avail_w - 30)
      if reaper.ImGui_Button(ctx, "...##menu_" .. i) then
         reaper.ImGui_OpenPopup(ctx, "SlideMenu##" .. i)
      end
      
      if reaper.ImGui_BeginPopup(ctx, "SlideMenu##" .. i) then
         if reaper.ImGui_Selectable(ctx, "+ Adicionar linha") then
            table.insert(slide, "Nova linha")
            state.holyrics_has_manual_edits = true
            state.holyrics_editing_slide = i
            state.holyrics_editing_line = #slide
            state.holyrics_editing_text = "Nova linha"
            state.holyrics_editing_focused = false
         end
         if #slide == 0 then
            if reaper.ImGui_Selectable(ctx, "Excluir slide") then
               slide.keep_empty = false
               cleanup_empty_slides()
            end
         end
         reaper.ImGui_EndPopup(ctx)
      end
      
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Dummy(ctx, 0, 4)
      
      local to_remove = nil
      for l_idx, line in ipairs(slide) do
        reaper.ImGui_PushID(ctx, "slide_" .. i .. "_line_" .. l_idx)
        
        local is_editing = (state.holyrics_editing_slide == i and state.holyrics_editing_line == l_idx)
        
        if is_editing then
           if not state.holyrics_editing_focused then
              reaper.ImGui_SetKeyboardFocusHere(ctx)
              state.holyrics_editing_focused = true
           end
           
           if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
              state.holyrics_editing_slide = nil
           else
              local flags = reaper.ImGui_InputTextFlags_EnterReturnsTrue()
              reaper.ImGui_SetNextItemWidth(ctx, avail_w - 20)
              local rv, new_text = reaper.ImGui_InputText(ctx, "##edit", state.holyrics_editing_text, flags)
              state.holyrics_editing_text = new_text
              
              if rv or (reaper.ImGui_IsItemDeactivated(ctx)) then
                 slide[l_idx] = state.holyrics_editing_text
                 state.holyrics_has_manual_edits = true
                 state.holyrics_editing_slide = nil
              end
           end
        else
           local cur_x, cur_y = reaper.ImGui_GetCursorScreenPos(ctx)
           local rv = reaper.ImGui_Selectable(ctx, line, false, reaper.ImGui_SelectableFlags_AllowItemOverlap())
           local max_x = cur_x + avail_w - 16
           local max_y = cur_y + reaper.ImGui_GetTextLineHeight(ctx)
           local is_hovered = reaper.ImGui_IsMouseHoveringRect(ctx, cur_x, cur_y, max_x, max_y)
           
           if is_hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
              state.holyrics_editing_slide = i
              state.holyrics_editing_line = l_idx
              state.holyrics_editing_text = line
              state.holyrics_editing_focused = false
           end
           
           if is_hovered then
              reaper.ImGui_SameLine(ctx, avail_w - 95)
              
              local disable_up = (i == 1)
              if disable_up then reaper.ImGui_BeginDisabled(ctx) end
              if reaper.ImGui_Button(ctx, "^") then move_lyric_line(i, l_idx, -1); state.holyrics_has_manual_edits = true end
              if disable_up then reaper.ImGui_EndDisabled(ctx) end
              
              reaper.ImGui_SameLine(ctx)
              if reaper.ImGui_Button(ctx, "v") then move_lyric_line(i, l_idx, 1); state.holyrics_has_manual_edits = true end
              
              reaper.ImGui_SameLine(ctx)
              if reaper.ImGui_Button(ctx, "X") then to_remove = l_idx end
           end
        end
        reaper.ImGui_PopID(ctx)
      end
      
      if to_remove then
         table.remove(slide, to_remove)
         state.holyrics_has_manual_edits = true
         cleanup_empty_slides()
      end
      
      if #slide == 0 then
         reaper.ImGui_TextColored(ctx, 0x888888FF, "[Slide vazio]")
      end
      
      reaper.ImGui_EndGroup(ctx)
      reaper.ImGui_SetCursorScreenPos(ctx, p_min_x, p_max_y + 8)
    end
    
    if reaper.ImGui_Button(ctx, "+ NOVO SLIDE", -1) then
       table.insert(state.holyrics_slides, {keep_empty = true})
    end
    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_EndGroup(ctx)
    
    reaper.ImGui_SameLine(ctx)
    
    -- ESTRUTURA DA MÚSICA
    reaper.ImGui_BeginGroup(ctx)
    reaper.ImGui_Text(ctx, "ESTRUTURA DA MÚSICA")
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x000000FF)
    reaper.ImGui_BeginChild(ctx, "##holyrics_structure", col2_w, bottom_panel_h, true)
    
    if state.holyrics_mapping then
       for i, m in ipairs(state.holyrics_mapping) do
          local is_sel = (state.holyrics_selected_region == i)
          
          local p_min_x, p_min_y = reaper.ImGui_GetCursorScreenPos(ctx)
          local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
          local row_h = reaper.ImGui_GetFrameHeight(ctx) + 4
          
          if is_sel then
             local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
             reaper.ImGui_DrawList_AddRectFilled(draw_list, p_min_x - 4, p_min_y - 2, p_min_x + avail_w + 4, p_min_y + row_h - 2, 0x1A3A1AFF, 4.0)
          end
          
          reaper.ImGui_BeginGroup(ctx)
          
          local col_rgba = 0x888888FF
          if m.color and m.color ~= 0 then
             local r, g, b = reaper.ColorFromNative(m.color)
             col_rgba = (r << 24) | (g << 16) | (b << 8) | 0xFF
          end
          
          local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
          local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
          local lh = reaper.ImGui_GetTextLineHeight(ctx)
          reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx + 6, cy + lh/2, 4, col_rgba)
          
          reaper.ImGui_SetCursorScreenPos(ctx, cx + 16, cy)
          
          local num_str = string.format("%02d", i)
          if is_sel then
             reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, num_str)
          else
             reaper.ImGui_TextColored(ctx, 0x888888FF, num_str)
          end
          
          reaper.ImGui_SameLine(ctx, 40)
          if is_sel then
             reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, m.name)
          else
             reaper.ImGui_Text(ctx, m.name)
          end
          
          reaper.ImGui_SameLine(ctx, col2_w - 130)
          
          local btn_label = "Sem letra"
          if #m.slide_ids > 0 then
             local ids = {}
             for _, id in ipairs(m.slide_ids) do table.insert(ids, tostring(id)) end
             btn_label = "Slide " .. table.concat(ids, ", ")
          end
          
          reaper.ImGui_SetNextItemWidth(ctx, 110)
          if reaper.ImGui_BeginCombo(ctx, "##btn" .. i, btn_label) then
             state.holyrics_selected_region = i
             if reaper.ImGui_Selectable(ctx, "Sem letra", #m.slide_ids == 0) then
                m.slide_ids = {}
                m.manual = true
             end
             for s_idx, _ in ipairs(state.holyrics_slides) do
                local is_assigned = false
                for _, id in ipairs(m.slide_ids) do if id == s_idx then is_assigned = true; break end end
                local changed, new_v = reaper.ImGui_Checkbox(ctx, "Slide " .. s_idx, is_assigned)
                if changed then
                   if new_v then
                      table.insert(m.slide_ids, s_idx)
                      table.sort(m.slide_ids)
                   else
                      for k, id in ipairs(m.slide_ids) do if id == s_idx then table.remove(m.slide_ids, k); break end end
                   end
                   m.manual = true
                end
             end
             reaper.ImGui_EndCombo(ctx)
          end
          
          reaper.ImGui_EndGroup(ctx)
          
          local row_min_x, row_min_y = reaper.ImGui_GetItemRectMin(ctx)
          local row_max_x, row_max_y = reaper.ImGui_GetItemRectMax(ctx)
          if reaper.ImGui_IsMouseHoveringRect(ctx, row_min_x, row_min_y, row_max_x, row_max_y) and reaper.ImGui_IsMouseClicked(ctx, 0) then
             state.holyrics_selected_region = i
          end
          
          reaper.ImGui_Dummy(ctx, 0, 4)
       end
    end
    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_EndGroup(ctx)
    
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopStyleVar(ctx, 1)
end
-- ─── Main loop ───────────────────────────────────────────────────────────────

local function loop()
  -- ─── Lógica do HOLD (Auto-Avanço de Aba) ───
  local current_play_state = reaper.GetPlayState() & 1
  if current_play_state == 1 then
    state._last_play_pos = reaper.GetPlayPosition()
    
    if state.hold and state.pending_jump_pos and state.pending_jump_trigger_time then
      -- Jump if we are very close to the end of the region (e.g. 0.05s)
      if state._last_play_pos >= state.pending_jump_trigger_time - 0.05 then
         reaper.SetEditCurPos(state.pending_jump_pos, true, true)
         state.pending_jump_pos = nil
      end
    end
  else
    state.pending_jump_pos = nil
  end

  if state.auto_next and state._last_play_state == 1 and current_play_state == 0 then
    local len = reaper.GetProjectLength(0)
    -- Se parou e estava no final do projeto (margem de 0.5s), pula a aba e da play
    if state._last_play_pos >= len - 0.5 then
      reaper.Main_OnCommand(40861, 0) -- Next project tab
      reaper.Main_OnCommand(1007, 0) -- Transport: Play
    end
  end
  state._last_play_state = current_play_state

  update_state()

  -- O duck é aplicado a cada projeto aberto, inclusive quando a aba muda durante a execução.
  if state.click_ducked then
    capture_duck_snapshot(reaper.EnumProjects(-1))
  end
  
  -- ─── Lógica do FADE do CLICK ───
  if state.duck_factor ~= state.duck_target then
    local speed = 0.04 -- Velocidade da rampa do fade (~400 milissegundos para fade completo)
    if state.duck_factor < state.duck_target then
      state.duck_factor = math.min(state.duck_factor + speed, state.duck_target)
    else
      state.duck_factor = math.max(state.duck_factor - speed, state.duck_target)
    end
    
    for _, snapshot in pairs(state.duck_projects) do
      for tr, original_volume in pairs(snapshot.volumes) do
        reaper.SetMediaTrackInfo_Value(tr, "D_VOL", original_volume * state.duck_factor)
      end
    end
    
    if state.duck_factor >= 1.0 then
      restore_ducking()
    end
  end

  local rx, ry, rw, rh = 0, 0, 1920, 1080
  if reaper.JS_Window_GetRect then
    local hwnd = reaper.GetMainHwnd()
    local ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
    if ok and r > l and b > t then
      -- Converte as coordenadas físicas do Windows para lógicas do ImGui
      if reaper.ImGui_PointConvertNative then
        l, t = reaper.ImGui_PointConvertNative(ctx, l, t)
        r, b = reaper.ImGui_PointConvertNative(ctx, r, b)
      end
      rx, ry, rw, rh = l, t, r - l, b - t
    end
  end

  -- =========================================================================
  -- Deixamos a janela completamente livre para o sistema de DOCK nativo do Reaper.
  -- Assim, ao arrastar, os "quadradinhos" azuis de docagem vão aparecer novamente.
  -- =========================================================================

  local wflags = reaper.ImGui_WindowFlags_NoScrollbar()
               + reaper.ImGui_WindowFlags_NoScrollWithMouse()

  -- Style
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),  C.win_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),    C.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),      C.text)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),    0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(),      4, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),    6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0.0)

  -- Resolve o bug de não conseguir "encolher" a doca
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 100, 50, 99999, 99999)
  local visible, open = reaper.ImGui_Begin(ctx, "Multitrack##mc_final", true, wflags)
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopStyleVar(ctx, 4)

  if visible then
    -- Ativa a fonte moderna para tudo dentro da janela
    reaper.ImGui_PushFont(ctx, font)

    -- Usar um Child Window resolve o bug do Reaper não deixar encolher a doca!
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 10, 10, 99999, 99999)
    reaper.ImGui_BeginChild(ctx, "##canvas", 0, 0, 0, wflags)

    local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
    local win_w, win_h = reaper.ImGui_GetWindowSize(ctx)
    local draw_list    = reaper.ImGui_GetWindowDrawList(ctx)

    local ok, err = pcall(function()
      reaper.ImGui_DrawList_AddLine(draw_list, win_x, win_y, win_x + win_w, win_y, C.border, 2)
      
      local TOP_H = 50
      local wave_h = win_h - TOP_H

      reaper.ImGui_DrawList_AddLine(draw_list, win_x, win_y + TOP_H, win_x + win_w, win_y + TOP_H, C.border, 1)

      render_top_bar(win_x, win_y, win_w, TOP_H)
      render_waveform_area(draw_list, win_x, win_y + TOP_H, win_w, wave_h)
      
      render_marker_modal(ctx)
        render_key_mapping_modal(ctx, win_x, win_y, win_w, win_h)
      render_add_custom_modal(ctx)
      render_render_modal(ctx, win_x, win_y, win_w, win_h)
      render_midi_mapping_modal(ctx, win_x, win_y, win_w, win_h)
      render_holyrics_modal(ctx, win_x, win_y, win_w, win_h)
    end)

    if not ok then
      reaper.ShowConsoleMsg("\n[Multitrack Controller] ERRO DE RENDER:\n" .. tostring(err) .. "\n")
    end

    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopFont(ctx)
  end

  -- Verifica se recebeu sinal para fechar de outra instância
  if reaper.GetExtState("MultitrackController", "quit") == "true" then
    open = false
  end

  -- Atalho de teclado: Pass-through para Play/Pause (Espaço) se não estiver digitando
  if visible and not reaper.ImGui_IsAnyItemActive(ctx) and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
    reaper.Main_OnCommand(40044, 0) -- Transport: Play/stop
  end

  -- ALWAYS call End() — mesmo se visible=false ou se houve erro
  reaper.ImGui_End(ctx)

  if open then
    reaper.defer(loop)
  end
end

-- Kick off
reaper.defer(loop)



















