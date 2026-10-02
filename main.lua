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
local Chords = require("chords")
local ChordAnalyzer = require("chord_analyzer")
local AutomationModel = require("automation_model")
local AutomationStore = require("automation_store")
local CueEngine = require("cue_engine")
local holyrics_transport = require("holyrics_transport").new(reaper)

Repertoire.init(SCRIPT_PATH)

-- ─── ImGui context ───────────────────────────────────────────────────────────

local ctx = reaper.ImGui_CreateContext("Multitrack Controller", reaper.ImGui_ConfigFlags_DockingEnable())

-- Cria fontes modernas e suaves para remover o aspecto pixelado
local font = reaper.ImGui_CreateFont('Arial', 14)
-- Algumas versões do ReaImGui aceitam somente família e tamanho.
-- Evita falhar em instalações com uma API mais antiga.
local font_large = reaper.ImGui_CreateFont('Arial', 18)
local font_small = reaper.ImGui_CreateFont('Arial', 10)
local font_preview = reaper.ImGui_CreateFont('Arial', 32)
local font_preview_sm = reaper.ImGui_CreateFont('Arial', 18)
reaper.ImGui_Attach(ctx, font)
reaper.ImGui_Attach(ctx, font_large)
reaper.ImGui_Attach(ctx, font_small)
reaper.ImGui_Attach(ctx, font_preview)
reaper.ImGui_Attach(ctx, font_preview_sm)

-- PushFont requer o tamanho como terceiro argumento nas versões atuais do
-- ReaImGui. Mantemos o tamanho local porque o REAPER valida os argumentos
-- antes de executar a função.
local function push_font_compat(font_to_push, size)
  reaper.ImGui_PushFont(ctx, font_to_push, size)
end

-- O ReaImGui 0.10 não aceita mais índices numéricos genéricos de teclado.
-- Mantemos uma lista explícita de teclas suportadas tanto para os atalhos como
-- para a janela de mapeamento, evitando que um atalho salvo numa versão antiga
-- interrompa a renderização do controlador.
local MAPPABLE_KEY_NAMES = {
  "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
  "Space", "Enter", "Tab", "Backspace", "Delete", "Insert", "Escape",
  "UpArrow", "DownArrow", "LeftArrow", "RightArrow", "Home", "End", "PageUp", "PageDown",
  "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
}
local MAPPABLE_KEYS, MAPPABLE_KEY_SET = {}, {}
for _, name in ipairs(MAPPABLE_KEY_NAMES) do
  local getter = reaper["ImGui_Key_" .. name]
  if getter then
    local key = getter()
    MAPPABLE_KEYS[#MAPPABLE_KEYS + 1] = { code = key, name = name }
    MAPPABLE_KEY_SET[key] = true
  end
end

local function is_mappable_key_pressed(key, repeat_enabled)
  return MAPPABLE_KEY_SET[key] and reaper.ImGui_IsKeyPressed(ctx, key, repeat_enabled) or false
end

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

-- Holyrics is intentionally neutral: its status and identifiers use white,
-- without changing the pink accent used by the rest of the controller.
local HOLYRICS_ACCENT = 0xFFFFFFFF
local HOLYRICS_MAPPED_GREEN = 0x22C55EFF

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

local render_automation_preview

local state = {
  current_key      = nil,
  current_proj_name= "",
  current_proj_path= "",
  chord_analysis_status = nil,
  chord_analysis_checked_at = 0,
  sections         = {},
  setlist          = nil,
  pads = {
    {
      name = "PAD",
      file = (reaper.GetExtState("MultitrackController", "pad_file") ~= "" and reaper.GetExtState("MultitrackController", "pad_file")) or nil,
      playing = false,
      loop = true,
      volume = tonumber(reaper.GetExtState("MultitrackController", "pad_volume")) or 1.0,
      output_channel = tonumber(reaper.GetExtState("MultitrackController", "pad_output_channel")) or 0,
    },
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
  automation_enabled = false,
  live_mode = false,
  connection_monitor = {},  -- { [index] = { ok=bool, last_check=time } }
  show_lyrics_preview = false,
  lyrics_preview_lead = tonumber(reaper.GetExtState("MultitrackController", "lyrics_preview_lead")) or 0,
  lyrics_preview_theme = reaper.GetExtState("MultitrackController", "lyrics_preview_theme") ~= "" and reaper.GetExtState("MultitrackController", "lyrics_preview_theme") or "ESCURO",
  lyrics_preview_animation = reaper.GetExtState("MultitrackController", "lyrics_preview_animation") ~= "" and reaper.GetExtState("MultitrackController", "lyrics_preview_animation") or "FADE",
  lyrics_preview_last_target = nil,
  lyrics_preview_transition_at = 0,
  code_api_server = reaper.GetExtState("MultitrackController", "code_api_server"),
  code_api_token = reaper.GetExtState("MultitrackController", "code_api_token"),
  code_api_status = nil,
  holyrics_remote_open = false,
  holyrics_remote_model = nil,
  holyrics_remote_status = nil,
  cover_path = "",
  cover_image = nil,
  cover_image_path = nil,
  cover_image_w = 0,
  cover_image_h = 0,
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
  holyrics_editor_view = "SYNC",
  holyrics_window_w = tonumber(reaper.GetExtState("MultitrackController", "holyrics_window_w")) or 1400,
  holyrics_window_h = tonumber(reaper.GetExtState("MultitrackController", "holyrics_window_h")) or 900,
  holyrics_window_x = tonumber(reaper.GetExtState("MultitrackController", "holyrics_window_x")),
  holyrics_window_y = tonumber(reaper.GetExtState("MultitrackController", "holyrics_window_y")),
  scanner = { active = false, target_index = nil, ips = {}, total = 0, current = 0, found = {} },
  automation_model = nil,
  automation_import_text = "",
  automation_title_artist = "",
  automation_title_song = "",
  automation_new_line = "",
  automation_error = nil,
  automation_selected_slide_id = nil,
  automation_selected_line_id = nil,
  cue_engine = CueEngine.new(),
  automation_simulation_log = "Aguardando playback...",
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

local function get_shifted_key()
  local active_root = KeyDetect.get_root(state.current_key)
  if not active_root then return nil end
  local base_idx = nil
  for i, k in ipairs(KeyDetect.CHROMATIC) do
    if k == active_root then base_idx = i - 1; break end
  end
  if not base_idx then return nil end
  local abs_semitones = base_idx + (state.pitch_offset or 0)
  local new_idx = abs_semitones % 12
  return KeyDetect.CHROMATIC[new_idx + 1]
end

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

-- Um destino representa um computador que está executando o Holyrics. Mantemos
-- a configuração antiga como o primeiro destino, para projetos já configurados.
local saved_holyrics_targets = reaper.GetExtState("MultitrackController", "code_api_targets")
local targets_ok, decoded_targets = pcall(json.decode, saved_holyrics_targets or "")
if targets_ok and type(decoded_targets) == "table" and #decoded_targets > 0 then
  state.code_api_targets = decoded_targets
else
  state.code_api_targets = {
    {
      name = "Holyrics 1",
      url = state.code_api_server or "",
      token = state.code_api_token or ""
    }
  }
end

local function save_holyrics_targets()
  reaper.SetExtState("MultitrackController", "code_api_targets", json.encode(state.code_api_targets), true)
  -- Compatibilidade com a primeira versão da configuração de rota.
  local first = state.code_api_targets[1] or {}
  state.code_api_server, state.code_api_token = first.url or "", first.token or ""
  reaper.SetExtState("MultitrackController", "code_api_server", state.code_api_server, true)
  reaper.SetExtState("MultitrackController", "code_api_token", state.code_api_token, true)
end

local saved_automation, automation_load_error, automation_load_source = AutomationStore.load(0)
state.automation_model = saved_automation
state.automation_error = automation_load_error
if saved_automation then
  -- Upgrade older projects where LT was placed in the first lyric slide.
  local title_slide_upgraded = AutomationModel.normalize_title_slide(saved_automation)
  -- A sidecar is the portable Trackly source.  Mirror it back into the .RPP
  -- immediately so the map also survives a moved or renamed JSON file.
  if title_slide_upgraded or automation_load_source == "sidecar" then AutomationStore.save(saved_automation, 0) end
  local export_path, export_warning = AutomationStore.export_sidecar(saved_automation, 0)
  state.automation_export_path = export_path
  state.automation_export_warning = export_warning
end

local function save_automation_model()
  if not state.automation_model then return end
  local ok, path, export_error = AutomationStore.save(state.automation_model, 0)
  if ok then
    state.automation_error = nil
    state.automation_export_path = path
    state.automation_export_warning = export_error
  else
    state.automation_error = path
  end
end

local function log_simulated_cue(cue)
  local seconds = math.max(0, cue.time or 0)
  local time = string.format("%02d:%05.2f", math.floor(seconds / 60), seconds % 60)
  local target = cue.target
  if cue.action == "SHOW_LINE" and state.automation_model then
    local line = AutomationModel.get_line(state.automation_model, cue.target)
    if line then target = line.displayId end
  end
  local message = string.format("[%s] SIMULARIA: %s - %s", time, cue.action, target)
  local previous = state.automation_simulation_log or ""
  state.automation_simulation_log = message .. (previous ~= "" and "\n" .. previous or "")
end

local function get_note_name(pitch)
  local names = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
  local octave = math.floor(pitch / 12) - 1 -- 36 is C2
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
  Pads.stop_all()
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

local COVER_EXTENSIONS = { png = true, jpg = true, jpeg = true, bmp = true }

local function project_folder(project_path)
  return (project_path or ""):match("^(.*)[/\\]")
end

local function find_project_cover(folder)
  if not folder or folder == "" or not reaper.EnumerateFiles then return nil end
  local candidates = {}
  local index = 0
  while true do
    local filename = reaper.EnumerateFiles(folder, index)
    if not filename then break end
    index = index + 1
    local extension = filename:match("%.([^.]+)$")
    if extension and COVER_EXTENSIONS[extension:lower()] then
      local lower = filename:lower()
      local score = 0
      if lower:match("^capa") or lower:match("^cover") or lower:match("^folder") then score = score + 100 end
      if lower:find("capa", 1, true) or lower:find("cover", 1, true) then score = score + 50 end
      if lower:find("artwork", 1, true) or lower:find("front", 1, true) then score = score + 20 end
      candidates[#candidates + 1] = { path = folder .. "/" .. filename, score = score, name = lower }
    end
  end
  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  return candidates[1] and candidates[1].path or nil
end

local function load_cover_image(path)
  if path == state.cover_image_path then return end
  state.cover_image_path, state.cover_image = path, nil
  state.cover_image_w, state.cover_image_h = 0, 0
  if not path or path == "" or not reaper.ImGui_CreateImage then return end
  local ok, image = pcall(reaper.ImGui_CreateImage, path)
  if not ok or not image then return end
  reaper.ImGui_Attach(ctx, image)
  local width, height = reaper.ImGui_Image_GetSize(image)
  state.cover_image, state.cover_image_w, state.cover_image_h = image, width or 0, height or 0
end

local function refresh_project_cover(proj, project_path)
  local _, selected = reaper.GetProjExtState(proj, "MultitrackController", "cover_path")
  local path = selected ~= "" and selected or find_project_cover(project_folder(project_path))
  state.cover_path = path or ""
  load_cover_image(state.cover_path)
end

local function choose_project_cover()
  local ok, path = reaper.GetUserFileNameForRead(state.cover_path or "", "Selecionar capa do projeto", "png,jpg,jpeg,bmp")
  if not ok then return end
  local proj = reaper.EnumProjects(-1)
  reaper.SetProjExtState(proj, "MultitrackController", "cover_path", path)
  state.cover_path = path
  load_cover_image(path)
end

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
      
      local pad = state.pads[1]
      if pad and Pads.is_active_or_transitioning(pad) then
        Pads.transition(pad, get_shifted_key())
      end
      
      import_mapa_if_empty(proj, proj_path)

      state.holyrics_remote_open  = false
      state.holyrics_remote_model = nil
      state.holyrics_remote_status = { ok = false, message = 'Sessao reiniciada. Aperte Play para sincronizar.' }

      state.cue_engine = CueEngine.new()

      local saved_automation, automation_load_error, automation_load_source = AutomationStore.load(0)
      state.automation_model = saved_automation
      state.automation_error  = automation_load_error
      if saved_automation and automation_load_source == "sidecar" then
        AutomationStore.save(saved_automation, 0)
      end
    end
    
    state.sections = Sections.get_from_project(proj)
    refresh_project_cover(proj, proj_path)
    state.chord_analysis_status = ChordAnalyzer.status(proj_path)
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
  if mapped_key and is_mappable_key_pressed(mapped_key, false) then
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
    
    for _, key_data in ipairs(MAPPABLE_KEYS) do
      local key = key_data.code
      if is_mappable_key_pressed(key, false) then
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
    
    if reaper.ImGui_Button(ctx, "Cancelar", 120, 30) then
      state.mapping_target = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

local function draw_gear_icon(draw_list, cx, cy, color, r)
  r = r or 6
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, r * 0.45, color, 12, 2.0)
  local teeth = 6
  for i = 0, teeth - 1 do
    local a = (i / teeth) * math.pi * 2
    local dx1, dy1 = math.cos(a - 0.25), math.sin(a - 0.25)
    local dx2, dy2 = math.cos(a + 0.25), math.sin(a + 0.25)
    local r1 = r * 0.65
    local r2 = r
    reaper.ImGui_DrawList_AddQuadFilled(draw_list, 
      cx + dx1 * r1, cy + dy1 * r1,
      cx + dx2 * r1, cy + dy2 * r1,
      cx + dx2 * r2, cy + dy2 * r2,
      cx + dx1 * r2, cy + dy1 * r2,
      color)
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
    local view_start, view_end = reaper.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
    if math.abs(view_start - state.locked_start) > 0.000001 or
       math.abs(view_end - state.locked_end) > 0.000001 then
      reaper.GetSet_ArrangeView2(0, true, 0, 0, state.locked_start, state.locked_end)
    end
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
  -- Durante o playback usamos menos amostras visuais. A forma permanece
  -- legível, mas o desenho gera muito menos comandos por frame no ReaImGui.
  local wave_step = (play_state & 1 == 1) and 16 or 3
  
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
  for px = 0, draw_w - 1, wave_step do
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
      for px = px_start, px_end, wave_step do
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
  
  if state.live_mode then
    -- Modo ao vivo: capa grande com cantos arredondados + titulo/artista abaixo
    local panel_x = grid_x
    local panel_w = grid_w
    local panel_y = draw_y
    local panel_h = draw_h
    -- Reserva espaco para titulo (14px) + artista (12px) + margens
    local text_reserve = 34
    local cover_size = math.min(panel_w - 4, panel_h - text_reserve - 4)
    cover_size = math.max(40, cover_size)
    local cover_x = panel_x + (panel_w - cover_size) / 2
    local cover_y = panel_y + 2
    local corner_r = 8  -- raio dos cantos arredondados
    -- Capa do album com cantos arredondados
    local text_y = cover_y + cover_size + 6
    if state.cover_image and state.cover_image_w > 0 then
      local iw, ih = state.cover_image_w, state.cover_image_h
      local scale = math.min(cover_size / iw, cover_size / ih)
      local dw, dh = math.floor(iw * scale), math.floor(ih * scale)
      local ix = panel_x + (panel_w - dw) / 2
      local iy = cover_y
      -- Desenha imagem com cantos arredondados via DrawList
      local ok_img, _ = pcall(reaper.ImGui_DrawList_AddImageRounded, draw_list, state.cover_image, ix, iy, ix + dw, iy + dh, 0, 0, 1, 1, 0xFFFFFFFF, corner_r)
      if not ok_img then
        -- Fallback: sem arredondamento
        reaper.ImGui_SetCursorScreenPos(ctx, ix, iy)
        reaper.ImGui_Image(ctx, state.cover_image, dw, dh)
      end
      text_y = iy + dh + 5
    else
      -- Placeholder cinza arredondado
      reaper.ImGui_DrawList_AddRectFilled(draw_list, cover_x, cover_y, cover_x + cover_size, cover_y + cover_size, 0x2A2A2AFF, corner_r)
      reaper.ImGui_DrawList_AddRect(draw_list, cover_x, cover_y, cover_x + cover_size, cover_y + cover_size, 0x444444FF, corner_r, 0, 1)
      local lbl = "SEM CAPA"
      local lw = reaper.ImGui_CalcTextSize(ctx, lbl)
      reaper.ImGui_DrawList_AddText(draw_list, cover_x + (cover_size - lw) / 2, cover_y + cover_size / 2 - 7, 0x555555FF, lbl)
      text_y = cover_y + cover_size + 5
    end
    -- Titulo e artista abaixo da capa, centralizados e truncados se necessario
    local sname = state.current_proj_name:gsub("%.[Rr][Pp][Pp]$", "")
    local artist, title = sname:match("^(.-)%s*-%s*(.+)$")
    if not artist then artist = ""; title = sname end
    -- Trunca se nao couber
    local max_w = panel_w - 8
    local function truncate(txt, mw)
      local w = reaper.ImGui_CalcTextSize(ctx, txt)
      if w <= mw then return txt end
      while #txt > 1 and reaper.ImGui_CalcTextSize(ctx, txt .. "...") > mw do
        txt = txt:sub(1, -2)
      end
      return txt .. "..."
    end
    local ttxt = truncate(title, max_w)
    local tw = reaper.ImGui_CalcTextSize(ctx, ttxt)
    reaper.ImGui_DrawList_AddText(draw_list, panel_x + (panel_w - tw) / 2, text_y, 0xFFFFFFFF, ttxt)
    if artist ~= "" then
      local atxt = truncate(artist, max_w)
      local aw = reaper.ImGui_CalcTextSize(ctx, atxt)
      reaper.ImGui_DrawList_AddText(draw_list, panel_x + (panel_w - aw) / 2, text_y + 16, 0xAAAAAAFF, atxt)
    end
  elseif grid_w > 100 then -- Só desenha se houver espaço (usuário não escondeu o TCP)
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
    -- Largura original do bloco de tom: 22 (-) + 4 (gap) + 54 (B) + 4 (gap) + 22 (+) = 106
    local pitch_widget_w = 22 + 4 + 54 + 4 + 22
    local fader_pad_w = 120
    local fader_gap = 16
    local gear_w = 18
    local gear_gap = 8
    local total_widget_w = pitch_widget_w + fader_gap + fader_pad_w + gear_gap + gear_w
    local panel_y = draw_y + (total_h - btn_h) / 2
    
    -- Centralizado acima das teclas cromáticas
    local px = start_x + (total_w - total_widget_w) / 2
    
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
    push_font_compat(font, 14)
    local w1, h1 = reaper.ImGui_CalcTextSize(ctx, txt)
    reaper.ImGui_PopFont(ctx)
    
    local w2, h2 = 0, 0
    if display_octave then
      push_font_compat(font_small, 10)
      w2, h2 = reaper.ImGui_CalcTextSize(ctx, tostring(display_octave))
      reaper.ImGui_PopFont(ctx)
    end
    
    local total_txt_w = w1 + w2 + (display_octave and 1 or 0)
    local txt_start_x = btn_center_x - (total_txt_w / 2)
    
    push_font_compat(font, 14)
    reaper.ImGui_DrawList_AddText(draw_list, txt_start_x, btn_center_y - (h1/2), 0xFFFFFFFF, txt)
    reaper.ImGui_PopFont(ctx)
    
    if display_octave then
      push_font_compat(font_small, 10)
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

    -- Fader de Volume do PAD
    reaper.ImGui_SameLine(ctx, 0, fader_gap)
    local pad = state.pads[1]
    
    -- Padronizando visual para combinar com os botões (escuro e rosa)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x555555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x444444FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(), C.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), C.accent_hover)
    
    -- Ajusta altura e centraliza verticalmente em relação ao botão de 36px
    -- Padding(4, 2) faz com que a altura do fader seja FontSize(14) + 4 = 18px
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 9)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 4.0, 2.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(), 12.0)

    reaper.ImGui_PushItemWidth(ctx, fader_pad_w)
    local display_vol = math.floor((pad.volume or 1.0) * 100 + 0.5)
    local changed_padvol, new_display = reaper.ImGui_SliderInt(ctx, "##padvol_bottom", display_vol, 0, 100, "%d")
    if changed_padvol then
      local real_vol = new_display / 100.0
      Pads.set_volume(pad, real_vol)
      reaper.SetExtState("MultitrackController", "pad_volume", tostring(real_vol), true)
    end
    reaper.ImGui_PopItemWidth(ctx)
    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Volume do PAD") end

    reaper.ImGui_PopStyleVar(ctx, 3)
    reaper.ImGui_PopStyleColor(ctx, 5)

    -- Botão Engrenagem (Roteamento do Pad)
    reaper.ImGui_SameLine(ctx, 0, gear_gap)
    reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 9)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x333333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x555555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), C.accent)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6.0)
    
    -- Usando desenho vetorial manual pois a fonte atual (Arial) não possui glifos de engrenagem
    -- Altura do fader é 18px (FontSize(14) + padding(4)). Então usamos 18x18
    local gear_h = 18
    if reaper.ImGui_Button(ctx, "##pad_route", gear_w, gear_h) then
       Pads.show_routing(pad)
    end
    local btn_min_x, btn_min_y = reaper.ImGui_GetItemRectMin(ctx)
    local btn_max_x, btn_max_y = reaper.ImGui_GetItemRectMax(ctx)
    -- Ajustamos o raio no desenho vetorial dinamicamente (18/2 = 9, então r=5)
    draw_gear_icon(draw_list, (btn_min_x + btn_max_x) / 2, (btn_min_y + btn_max_y) / 2, 0xFFFFFFFF, 5)
    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Abrir roteamento do PAD no REAPER") end
    
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
  -- Painel direito: botoes normais ou preview ao vivo
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

  -- Chords sit above the right-hand button grid, in the unused header space.
  local pitch_state = state.pitch_projects[tostring(proj)]
  local chord, next_chord, automatic = Chords.display(json, pitch_state and pitch_state.offset or 0)
  if chord == "SEM MAPA" and state.chord_analysis_status then
    chord = string.upper(state.chord_analysis_status)
  end
  local chord_y = row1_y - 48
  reaper.ImGui_DrawList_PushClipRect(draw_list, marker_x, chord_y, marker_x + combined_w, row1_y - 2, true)
  reaper.ImGui_DrawList_AddText(draw_list, marker_x + 4, chord_y, C.text_dim, automatic and (Chords.is_simplified() and "AUTO · SIMPLES" or "ACORDE · AUTO") or "ACORDE")
  reaper.ImGui_DrawList_AddText(draw_list, marker_x + 144, chord_y, C.text_dim, "PRÓXIMO")
  push_font_compat(font_large, 18)
  reaper.ImGui_DrawList_AddText(draw_list, marker_x + 4, chord_y + 19, C.accent, chord)
  reaper.ImGui_DrawList_AddText(draw_list, marker_x + 144, chord_y + 19, C.text, next_chord)
  reaper.ImGui_PopFont(ctx)
  reaper.ImGui_DrawList_PopClipRect(draw_list)

  -- Modo ao vivo: painel direito exibe preview do Holyrics
  if state.live_mode then
    local right_x = marker_x
    local right_w = combined_w
    local right_y = draw_y
    local right_h = draw_h
    reaper.ImGui_SetCursorScreenPos(ctx, right_x, right_y)
    
    if reaper.ImGui_BeginChild(ctx, "##live_preview_container", right_w, right_h, reaper.ImGui_ChildFlags_None()) then
      if render_automation_preview then
        render_automation_preview(ctx, false)
      end
      reaper.ImGui_EndChild(ctx)
    end
    
    return  -- nao desenha os botoes normais
  end



  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8.0)

  -- ================== COLUNA 1 ==================

  -- MIDI (toggle de automacoes)
  reaper.ImGui_SetCursorScreenPos(ctx, marker_x, row1_y)
  if state.automation_enabled then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0xEC4899FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xF472B6FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xDB2777FF)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, "MIDI", marker_w, marker_h) then
    state.automation_enabled = not state.automation_enabled
  end
  if state.automation_enabled then
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    pop_btn_style()
  end

  -- HOLYRICS (Linha 2)
  reaper.ImGui_SetCursorScreenPos(ctx, marker_x, row2_y)
  push_btn_style()
  if reaper.ImGui_Button(ctx, state.live_mode and "ENSAIO##panel" or "AO VIVO##panel", marker_w, marker_h) then
    state.live_mode = not state.live_mode
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
    if reaper.ImGui_Selectable(ctx, "Acordes simplificados", Chords.is_simplified(), 0, 0, 22) then
      Chords.toggle_mode()
    end

    if reaper.ImGui_Selectable(ctx, "Reanalisar acordes automaticamente", false, 0, 0, 22) then
      ChordAnalyzer.reset(state.current_proj_path)
      state.chord_analysis_status = "Aguardando nova análise"
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

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
      state.show_holyrics_modal = true
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
  
  local pad = state.pads[1]
  if pad and pad.playing then
    Pads.play(pad, get_shifted_key())
  end

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
  
  local pad = state.pads[1]
  if pad and pad.playing then
    Pads.play(pad, get_shifted_key())
  end

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
  local cover_size = 38

  -- RECURSO FUTURO: Exibição de Capa do Álbum
  -- se state.cover_image então ... etc
  -- x = x + cover_size + 8

  -- Título centralizado verticalmente (ajustado para a fonte maior)
  local title_y_offset = (top_h / 2) - 9
  
  reaper.ImGui_SetCursorScreenPos(ctx, x, y + title_y_offset)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), C.text)
  push_font_compat(font_large, 18)
  reaper.ImGui_Text(ctx, sname)
  reaper.ImGui_PopFont(ctx)
  reaper.ImGui_PopStyleColor(ctx)

  -- RECURSO FUTURO: Botão de Trocar Capa
  -- local title_w = reaper.ImGui_CalcTextSize(ctx, sname)
  -- ...

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
  if reaper.ImGui_Button(ctx, "PAD", pad_w, bh) then Pads.toggle(pad, get_shifted_key()) end
  handle_mapped_button(ctx, "PAD", function() Pads.toggle(pad, get_shifted_key()) end, function()
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

  -- Botao ENSAIO / AO VIVO (modo ensaio) na barra de transporte
  reaper.ImGui_SameLine(ctx, 0, 8)
  if state.live_mode then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0xEC4899FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xF472B6FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xDB2777FF)
  else
    push_btn_style()
  end
  if reaper.ImGui_Button(ctx, state.live_mode and "ENSAIO##transport" or "AO VIVO##transport", click_w, bh) then
    state.live_mode = not state.live_mode
  end
  if state.live_mode then
    reaper.ImGui_PopStyleColor(ctx, 3)
  else
    pop_btn_style()
  end

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

  reaper.ImGui_PopStyleVar(ctx) -- Restaura o arredondamento padrão
end

local function render_midi_mapping_modal(ctx, win_x, win_y, win_w, win_h)
  if not state.show_midi_mapping_modal then return end

  reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w / 2), win_y + (win_h / 2), reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16.0, 16.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1A1A1AF2)
  
  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoResize() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
  local visible, open = reaper.ImGui_Begin(ctx, "Configuracao de MIDI Mapping", true, flags)
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

local function format_cue_time(seconds)
  seconds = math.max(0, seconds or 0)
  return string.format("%02d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

local function refresh_lyric_source(model)
  local lines = {}
  for _, line in ipairs(model.lyrics.lines or {}) do
    if not line.isTitle then lines[#lines + 1] = line.text or "" end
  end
  model.lyrics.source = table.concat(lines, "\n")
end

local function cue_target_label(model, cue)
  if cue.action == "SHOW_LINE" then
    local line = AutomationModel.get_line(model, cue.target)
    return line and line.displayId or "?"
  end
  for _, slide in ipairs(model.slides) do
    if slide.id == cue.target then return slide.displayId end
  end
  return "?"
end

local function region_at_position(regions, position)
  for _, region in ipairs(regions) do
    if position >= region.pos and position <= region.end_pos then return region end
  end
  return nil
end

local function active_line_cue(model, position)
  local active = nil
  for _, cue in ipairs(model.cues or {}) do
    if cue.action == "SHOW_LINE" and cue.time <= position then
      if not active or cue.time > active.time then active = cue end
    end
  end
  return active
end

local function region_has_line_cue(model, region)
  if not region then return false end
  for _, cue in ipairs(model.cues or {}) do
    if cue.action == "SHOW_LINE" and cue.regionId == tostring(region.idx) then return true end
  end
  return false
end

local function render_visual_click(ctx, position, is_playing)
  local metro_text = "-"
  if is_playing then
    local beats = reaper.TimeMap2_timeToBeats(0, position)
    metro_text = tostring(math.floor(beats or 0) + 1)
  end
  reaper.ImGui_Text(ctx, "CLICK")
  reaper.ImGui_SameLine(ctx)
  if is_playing then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xFFFFFFFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xEEEEEEFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xFFFFFFFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x000000FF)
  else
    push_btn_style()
  end
  reaper.ImGui_Button(ctx, metro_text .. "##sync_visual_click", 42, 24)
  if is_playing then reaper.ImGui_PopStyleColor(ctx, 4) else pop_btn_style() end
end

local function start_network_scan(target_index)
  if not reaper.ExecProcess then return false, "Incompatível" end
  local ok, output = pcall(reaper.ExecProcess, "arp -a", 1000)
  if not ok or not output then return false, "Falha arp" end
  
  local ips = {}
  for ip in output:gmatch("%s+(192%.168%.%d+%.%d+)%s+") do
    if not ip:match("%.255$") then table.insert(ips, ip) end
  end
  for ip in output:gmatch("%s+(10%.%d+%.%d+%.%d+)%s+") do
    if not ip:match("%.255$") then table.insert(ips, ip) end
  end
  
  if #ips == 0 then return false, "Vazio" end
  
  state.scanner = {
    active = true,
    show_modal = true,
    finished = false,
    target_index = target_index,
    ips = ips,
    total = #ips,
    current = 0,
    found = {}
  }
  return true, nil
end

local function process_network_scan()
  if not state.scanner.active then return end
  
  if #state.scanner.ips > 0 then
    local ip = table.remove(state.scanner.ips, 1)
    state.scanner.current = state.scanner.current + 1
    
    local request_url = "http://" .. ip .. ":8091/api/GetThemes?token=SCAN"
    local tok, tout = pcall(reaper.ExecProcess, 'curl.exe -s -X POST -H "Content-Type: application/json" -m 1 "' .. request_url .. '" -d "{}"', 1200)
    if tok and tout then
      tout = tostring(tout)
      if tout:match("invalid token") or tout:match("unauthorized") or tout:match('"status"') or tout:match("%{%}") then
        table.insert(state.scanner.found, "http://" .. ip .. ":8091")
      end
    end
  else
    -- Done
    state.scanner.active = false
    state.scanner.finished = true
  end
end

-- Monitor de conexao assíncrono: checa cada target a cada 15s
-- Usa curl com timeout curto para nao bloquear o UI
local CONNECTION_CHECK_INTERVAL = 15  -- segundos entre verificacoes

local function ping_target_async(target, index)
  if not reaper.ExecProcess then return end
  local url = (target.url or ""):match("^%s*(.-)%s*$")
  local token = (target.token or ""):match("^%s*(.-)%s*$")
  if url == "" or token == "" then
    state.connection_monitor[index] = { ok = false, last_check = reaper.time_precise(), msg = "Sem URL/token" }
    return
  end
  if not url:match("^https?://[%w%._%-]+:%d+/?$") then
    state.connection_monitor[index] = { ok = false, last_check = reaper.time_precise(), msg = "URL invalida" }
    return
  end
  local request_url = url:gsub("/$", "") .. "/api/GetThemes?token=" .. token
  local ok, output = pcall(reaper.ExecProcess,
    'curl.exe -s -X POST -H "Content-Type: application/json" -d "{}" --connect-timeout 2 "' .. request_url .. '"',
    3000)
  local out = ok and tostring(output) or ""
  local is_ok = false
  local msg = "Offline"
  if out:match('"status"%s*:%s*"ok"') then
    is_ok = true
    msg = "Online"
  elseif out:match("unauthorized") or out:match("permission") then
    is_ok = true
    msg = "Online"
  elseif out:match("invalid token") then
    is_ok = false
    msg = "Token Invalido"
  end
  state.connection_monitor[index] = {
    ok = is_ok,
    last_check = reaper.time_precise(),
    msg = msg
  }
end

local function update_connection_monitors()
  local now = reaper.time_precise()
  for index, target in ipairs(state.code_api_targets or {}) do
    local mon = state.connection_monitor[index]
    local last = mon and mon.last_check or 0
    if now - last > CONNECTION_CHECK_INTERVAL then
      -- Marca como "checking" com timestamp para nao re-iniciar
      if not state.connection_monitor[index] then
        state.connection_monitor[index] = { ok = nil, last_check = now, msg = "Verificando..." }
      else
        state.connection_monitor[index].last_check = now
        state.connection_monitor[index].msg = "Verificando..."
      end
      ping_target_async(target, index)
    end
  end
end

local function test_route_api(url, token)
  if (reaper.GetPlayState() & 1) == 1 then
    return nil, "Pare a reprodução antes de testar a conexão."
  end
  url = (url or ""):match("^%s*(.-)%s*$")
  if not url:match("^https?://[%w%._%-]+:%d+/?$") then
    return nil, "Informe um endereço no formato http://IP:PORTA."
  end
  token = (token or ""):match("^%s*(.-)%s*$")
  if token == "" then return nil, "Cole o token do API Server para testar as permissões." end
  if not token:match("^[%w_%-]+$") then return nil, "Token inválido. Cole o código exibido pelo Holyrics sem espaços." end
  if not reaper.ExecProcess then
    return nil, "Esta versão do REAPER não possui o teste de conexão."
  end
  local request_url = url:gsub("/$", "") .. "/api/GetThemes?token=" .. token
  local ok, output = pcall(reaper.ExecProcess,
    'curl.exe -s -X POST -H "Content-Type: application/json" -d "{}" --connect-timeout 2 "' .. request_url .. '" -w "\nHTTP:%{http_code}"', 3500)
  if not ok or not output then return nil, "Não foi possível executar o teste de conexão." end
  output = tostring(output)
  if output:match('"status"%s*:%s*"ok"') then return true, "Conexão autorizada. Permissões OK." end
  if output:match("invalid token") then return nil, "Token inválido. Verifique o código colado." end
  if output:match("unauthorized") or output:match("permission") then return true, "Conectado! (Automação pronta para enviar as letras)" end
  return nil, "Falha na comunicação. Verifique se o API Server está rodando no IP correto."
end

-- Envia uma ação para o API Server sem bloquear o ciclo de áudio do REAPER.
-- O JSON vai para um arquivo temporário único, preservando acentos, aspas e
-- quebras de linha sem deixar o curl disputar tempo com o playback.
local function holyrics_post(action, payload, timeout, target)
  target = target or state.code_api_targets[1] or {}
  return holyrics_transport:enqueue(target, action, payload or {})
end

local function holyrics_slide_index(model, line_id)
  local index = 0
  for _, slide in ipairs(model.slides or {}) do
    for _, slide_line_id in ipairs(slide.lineIds or {}) do
      if slide_line_id == line_id then return index end -- Holyrics começa em zero.
    end
    if #(slide.lineIds or {}) > 0 then index = index + 1 end
  end
  return 0
end

local function open_holyrics_presentation(model, line_id)
  if not model or not model.lyrics or #(model.lyrics.lines or {}) == 0 then
    return nil, "Gere a letra antes de enviar para o Holyrics."
  end
  local slides = {}
  for _, slide in ipairs(model.slides or {}) do
    local slide_lines = {}
    for _, line_id in ipairs(slide.lineIds or {}) do
      local line = AutomationModel.get_line(model, line_id)
      if line then slide_lines[#slide_lines + 1] = line.text or "" end
    end
    if #slide_lines > 0 then
      slides[#slides + 1] = { text = table.concat(slide_lines, "\n") }
    end
  end
  if #slides == 0 then return nil, "Não há slides de letra para enviar." end
  local delivered, failures = 0, {}
  for _, target in ipairs(state.code_api_targets or {}) do
    local ok, err = holyrics_post("ShowQuickPresentation", {
      slides = slides,
      initial_index = holyrics_slide_index(model, line_id)
    }, 3500, target)
    target.status = { ok = false, message = ok and "Apresentação na fila." or err }
    if ok then delivered = delivered + 1 else failures[#failures + 1] = (target.name or "Holyrics") .. ": " .. (err or "erro") end
  end
  if delivered > 0 then
    state.holyrics_remote_open = true
    state.holyrics_remote_model = model
    if #failures == 0 then return true, "Apresentação na fila para " .. delivered .. " Holyrics; confira a confirmação de cada destino." end
    return nil, "Enviado para " .. delivered .. "; falhou em " .. table.concat(failures, " | ")
  end
  return nil, #failures > 0 and table.concat(failures, " | ") or "Nenhum destino Holyrics foi configurado."
end

local function send_holyrics_line(cue)
  if not cue or cue.action ~= "SHOW_LINE" then return end
  if not state.holyrics_remote_open or state.holyrics_remote_model ~= state.automation_model then
    local ok, err = open_holyrics_presentation(state.automation_model, cue.target)
    state.holyrics_remote_status = { ok = ok, message = err or "Apresentação iniciada no Holyrics." }
    return
  end
  local delivered, failures = 0, {}
  for _, target in ipairs(state.code_api_targets or {}) do
    local ok, err = holyrics_post("ActionGoToIndex", {
      index = holyrics_slide_index(state.automation_model, cue.target)
    }, 1500, target)
    target.status = { ok = false, message = ok and "Slide na fila." or err }
    if ok then delivered = delivered + 1 else failures[#failures + 1] = target.name or "Holyrics" end
  end
  state.holyrics_remote_status = {
    ok = delivered > 0 and #failures == 0,
    message = #failures == 0 and ("Slide na fila para " .. delivered .. " Holyrics.")
      or ("Slide enviado para " .. delivered .. "; falhou: " .. table.concat(failures, ", "))
  }
end

local function draw_status_badge(ctx, id, status)
  if not status or not status.message or status.message == "" then return end
  local bg_color = status.ok and 0x05966933 or 0xDC262633
  local text_color = status.ok and 0x34D399FF or 0xF87171FF
  
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), bg_color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x00000000)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 6.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12.0, 6.0)
  
  -- Calcular a largura do texto para o tamanho da badge
  local text_w = reaper.ImGui_CalcTextSize(ctx, status.message)
  
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) - 2)
  reaper.ImGui_BeginChild(ctx, "badge_" .. id, text_w + 24, 28, reaper.ImGui_ChildFlags_Borders(), reaper.ImGui_WindowFlags_NoScrollbar())
  reaper.ImGui_TextColored(ctx, text_color, status.message)
  reaper.ImGui_EndChild(ctx)
  
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 2)
end

local function render_route_editor(ctx)
  if state.scanner and state.scanner.show_modal then
    reaper.ImGui_OpenPopup(ctx, "Scanner de Rede")
    state.scanner.show_modal = false
  end

  -- Modal do Scanner
  local center_x = reaper.ImGui_GetWindowPos(ctx) + reaper.ImGui_GetWindowSize(ctx) * 0.5
  local center_y = select(2, reaper.ImGui_GetWindowPos(ctx)) + select(2, reaper.ImGui_GetWindowSize(ctx)) * 0.5
  reaper.ImGui_SetNextWindowPos(ctx, center_x, center_y, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(), 0x00000001)
  if reaper.ImGui_BeginPopupModal(ctx, "Scanner de Rede", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    if state.scanner.active then
      reaper.ImGui_Text(ctx, "Buscando o Holyrics na rede local...")
      reaper.ImGui_Dummy(ctx, 0, 10)
      local progress = state.scanner.total > 0 and (state.scanner.current / state.scanner.total) or 0
      reaper.ImGui_ProgressBar(ctx, progress, 300, 20, string.format("%d / %d IPs verificados", state.scanner.current, state.scanner.total))
    elseif state.scanner.finished then
      if #state.scanner.found == 0 then
        reaper.ImGui_TextColored(ctx, C.red, "Nenhum Holyrics foi encontrado.")
        reaper.ImGui_Text(ctx, "Certifique-se de que o Holyrics está aberto e o 'API Server' está iniciado.")
        reaper.ImGui_Dummy(ctx, 0, 10)
        if reaper.ImGui_Button(ctx, "Fechar", 100, 0) then reaper.ImGui_CloseCurrentPopup(ctx) end
      else
        reaper.ImGui_Text(ctx, "Selecione o Holyrics desejado:")
        reaper.ImGui_Dummy(ctx, 0, 10)
        
        local target = state.code_api_targets[state.scanner.target_index]
        for _, ip_url in ipairs(state.scanner.found) do
          if reaper.ImGui_Button(ctx, "CONECTAR A " .. ip_url, 300, 30) then
            if target then
              target.url = ip_url
              target.status = nil -- Clear status to remove inline green text
              if state.connection_monitor then
                state.connection_monitor[state.scanner.target_index] = nil -- Força nova checagem
              end
              save_holyrics_targets()
            end
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
        end
        reaper.ImGui_Dummy(ctx, 0, 10)
        if reaper.ImGui_Button(ctx, "Cancelar", 100, 0) then reaper.ImGui_CloseCurrentPopup(ctx) end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_Text(ctx, "ROUTE")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, C.text_dim, "Conexão da automação")
  reaper.ImGui_Separator(ctx)

  reaper.ImGui_Text(ctx, "DESTINOS HOLYRICS")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, C.text_dim, "Um destino para cada PC que exibirá a letra")
  local password_flag = reaper.ImGui_InputTextFlags_Password and reaper.ImGui_InputTextFlags_Password() or 0
  local remove_index = nil
  for index, target in ipairs(state.code_api_targets or {}) do
    reaper.ImGui_PushID(ctx, index)
    
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1A1A1AFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x333333FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 8.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16.0, 16.0)
    
    reaper.ImGui_BeginChild(ctx, "card_"..index, 0, 130, reaper.ImGui_ChildFlags_Borders())
    
    -- LED de status de conexao
    do
      local mon = state.connection_monitor[index]
      local now = reaper.time_precise()
      local led_color, status_text
      if not mon or mon.ok == nil then
        led_color = 0x666666FF
        status_text = "Aguardando..."
      elseif mon.ok then
        local pulse = 0.65 + 0.35 * math.abs(math.sin(now * 2.5))
        local g = math.floor(0xB9 * pulse)
        led_color = 0x10000000 + g * 0x10000 + 0x8100 + 0xFF
        status_text = "Online"
      else
        led_color = 0xEF4444FF
        status_text = "Offline"
      end
      local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
      cx = cx + 7; cy = cy + 8
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 6, led_color)
      reaper.ImGui_Dummy(ctx, 16, 14)
      reaper.ImGui_SameLine(ctx, 0, 4)
      local txt_color = (mon and mon.ok) and 0x10B981FF or ((mon and mon.ok == false) and 0xEF4444FF or 0x888888FF)
      reaper.ImGui_TextColored(ctx, txt_color, status_text)
      if mon and mon.last_check and mon.last_check > 0 then
        local next_check = math.max(0, math.ceil(CONNECTION_CHECK_INTERVAL - (now - mon.last_check)))
        reaper.ImGui_SameLine(ctx, 0, 8)
        reaper.ImGui_TextColored(ctx, C.text_dim, "(prox: " .. next_check .. "s)")
      end
    end

    -- Labels
    reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, "NOME DA CONEXÃO")
    reaper.ImGui_SameLine(ctx, 150)
    reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, "URL / IP (ex: http://192.168.1.5:8091)")
    reaper.ImGui_SameLine(ctx, 430)
    reaper.ImGui_TextColored(ctx, 0xAAAAAAFF, "TOKEN DE ACESSO")
    
    -- Inputs
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    local name_changed, name = reaper.ImGui_InputText(ctx, "##Nome", target.name or ("Holyrics " .. index))
    reaper.ImGui_SameLine(ctx, 150)
    
    reaper.ImGui_SetNextItemWidth(ctx, 260)
    local url_changed, url = reaper.ImGui_InputText(ctx, "##Endereço", target.url or "")
    reaper.ImGui_SameLine(ctx, 430)
    
    reaper.ImGui_SetNextItemWidth(ctx, 220)
    local token_changed, token = reaper.ImGui_InputText(ctx, "##Token", target.token or "", password_flag)
    
    if name_changed or url_changed or token_changed then
      target.name, target.url, target.token = name, url, token
      target.status = nil
      save_holyrics_targets()
    end
    
    -- Bottom row: Test & Remove & Scan
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x2563EBFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x3B82F6FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x1D4ED8FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "TESTAR CONEXÃO", 155, 28) then
      local ok, message = test_route_api(target.url, target.token)
      target.status = { ok = ok, message = message }
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x10B981FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x34D399FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x059669FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    
    if reaper.ImGui_Button(ctx, "BUSCAR IP NA REDE", 155, 28) then
      if not state.scanner.active then
        start_network_scan(index)
        target.status = nil -- Limpa o status feio
      end
    end
    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Faz uma varredura para achar o IP do Holyrics") end
    
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)

    -- Botao Conectar: preenche com localhost:8091 automaticamente
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x7C3AEDFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x8B5CF6FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x6D28D9FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
    if reaper.ImGui_Button(ctx, "CONECTAR##notebook_" .. index, 155, 28) then
      target.url = "http://localhost:8091"
      target.status = nil
      state.connection_monitor[index] = nil  -- Forca re-verificacao
      save_holyrics_targets()
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Define como localhost:8091 (Holyrics no mesmo notebook)")
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)
    
    if #state.code_api_targets > 1 then
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x442222FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x663333FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x884444FF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
      if reaper.ImGui_Button(ctx, "REMOVER", 100, 28) then remove_index = index end
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx, 3)
    end
    
    -- removido a pedido do usuario
    
    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 2)
    
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)
  end
  if remove_index then
    table.remove(state.code_api_targets, remove_index)
    save_holyrics_targets()
  end
  
  reaper.ImGui_Dummy(ctx, 0, 8)
  
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x10B981FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x34D399FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x059669FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
  if reaper.ImGui_Button(ctx, "+ ADICIONAR HOLYRICS", 180, 32) then
    state.code_api_targets[#state.code_api_targets + 1] = { name = "Holyrics " .. (#state.code_api_targets + 1), url = "", token = "" }
    save_holyrics_targets()
  end
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 3)
  
  reaper.ImGui_SameLine(ctx, 0, 16)
  
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4F46E5FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x6366F1FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x4338CAFF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4.0)
  if reaper.ImGui_Button(ctx, "ABRIR APRESENTAÇÃO", 180, 32) then
    local ok, message = open_holyrics_presentation(state.automation_model)
    state.holyrics_remote_status = { ok = ok, message = message }
  end
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx, 3)
  
  -- removido a pedido do usuario
  
  reaper.ImGui_Dummy(ctx, 0, 16)
  reaper.ImGui_TextColored(ctx, C.text_dim, "Para o envio ao vivo, libere no token: ShowQuickPresentation e ActionGoToIndex (Local).")
  reaper.ImGui_TextColored(ctx, C.text_dim, "Durante o playback, cada L mapeada mostra no Holyrics o slide que contém essa linha.")
end

local function render_automation_sync_editor(ctx)
  local model = state.automation_model
  -- SYNC has one workspace only. A new song uses a temporary empty model in
  -- this same renderer; it never switches to a separate setup screen.
  local generated_line_count = 0
  if model then
    for _, line in ipairs(model.lyrics.lines or {}) do
      if not line.isTitle then generated_line_count = generated_line_count + 1 end
    end
  end
  local is_new_map = generated_line_count == 0
  if not model then model = AutomationModel.new() end
  local regions = Sections.get_from_project(0)
  local is_playing = (reaper.GetPlayState() & 1) == 1
  local timeline_position = is_playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local current_region = region_at_position(regions, timeline_position)
  local current_line_cue = active_line_cue(model, timeline_position + (state.lyrics_preview_lead or 0))
  if not region_has_line_cue(model, current_region) then current_line_cue = nil end

  -- Wait briefly before committing a simple click. This distinguishes it from
  -- the first half of a double click without placing an invisible widget over
  -- the lyric row (which previously caused ReaImGui child-stack crashes).
  local pending_map = state.pending_lyric_map
  if pending_map and reaper.time_precise() - pending_map.started_at >= 0.24 then
    state.pending_lyric_map = nil
    if pending_map.model == model then
      local cue, err = AutomationModel.add_cue(model, pending_map.time, pending_map.region_id, "SHOW_LINE", pending_map.line_id)
      if cue then
        state.automation_error = nil
        save_automation_model()
      else
        state.automation_error = err
      end
    end
  end

  local available_w, available_h = reaper.ImGui_GetContentRegionAvail(ctx)
  -- The timeline is the main working surface: give it the full width and a
  -- taller lane. Mapping details live in the compact panels underneath.
  local timeline_h = math.max(152, math.min(188, available_h * 0.25))
  reaper.ImGui_BeginChild(ctx, "##sync_timeline", 0, timeline_h, reaper.ImGui_ChildFlags_Borders())
  reaper.ImGui_Text(ctx, "TIMELINE")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, C.text_dim, format_cue_time(timeline_position))
  reaper.ImGui_SameLine(ctx)
  render_visual_click(ctx, timeline_position, is_playing)
  local bar_x, bar_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local bar_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local bar_h = 118
  local project_length = math.max(reaper.GetProjectLength(0), 1)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, bar_x, bar_y + 14, bar_x + bar_w, bar_y + 90, 0x151515FF, 4)
  for _, region in ipairs(regions) do
    local x1 = bar_x + (region.pos / project_length) * bar_w
    local x2 = bar_x + (region.end_pos / project_length) * bar_w
    local is_mapped_current = current_region and region.idx == current_region.idx and region_has_line_cue(model, current_region)
    local region_color = is_mapped_current and HOLYRICS_MAPPED_GREEN or region.color
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, bar_y + 14, x2, bar_y + 90, region_color, 2)
    local label_w = reaper.ImGui_CalcTextSize(ctx, region.name)
    if (x2 - x1) >= label_w + 8 then
      reaper.ImGui_DrawList_AddText(draw_list, x1 + 5, bar_y + 43, C.text, region.name)
    end
  end
  for _, cue in ipairs(model.cues or {}) do
    local x = bar_x + (cue.time / project_length) * bar_w
    reaper.ImGui_DrawList_AddLine(draw_list, x, bar_y + 5, x, bar_y + 101, HOLYRICS_ACCENT, 2)
    reaper.ImGui_DrawList_AddText(draw_list, x + 3, bar_y + 103, HOLYRICS_ACCENT, cue_target_label(model, cue))
    reaper.ImGui_SetCursorScreenPos(ctx, x - 6, bar_y + 2)
    reaper.ImGui_InvisibleButton(ctx, "##drag_cue_" .. cue.id, 12, 116)
    if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDown(ctx, 0) then
      local mouse_x = reaper.ImGui_GetMousePos(ctx)
      local ratio = math.max(0, math.min(1, (mouse_x - bar_x) / bar_w))
      if AutomationModel.move_cue(model, cue.id, ratio * project_length) then save_automation_model() end
    end
    if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, "Arraste para mover este mapa na timeline.") end
  end
  local playhead_x = bar_x + (timeline_position / project_length) * bar_w
  reaper.ImGui_DrawList_AddLine(draw_list, playhead_x, bar_y, playhead_x, bar_y + 120, 0xFFFFFFFF, 2)
  reaper.ImGui_SetCursorScreenPos(ctx, bar_x, bar_y)
  reaper.ImGui_InvisibleButton(ctx, "##timeline_scrub", bar_w, bar_h)
  if reaper.ImGui_IsItemActive(ctx) and reaper.ImGui_IsMouseDown(ctx, 0) then
    local mouse_x = reaper.ImGui_GetMousePos(ctx)
    local ratio = math.max(0, math.min(1, (mouse_x - bar_x) / bar_w))
    reaper.SetEditCurPos(ratio * project_length, true, is_playing)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Clique ou arraste para mover a posição na timeline.")
  end

  reaper.ImGui_EndChild(ctx)

  local _, details_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local cue_panel_w = available_w * 0.28
  local lyric_panel_w = available_w * 0.45
  reaper.ImGui_BeginChild(ctx, "##cue_list", cue_panel_w, details_h, 0)
  reaper.ImGui_Text(ctx, "LINHAS MAPEADAS")
  reaper.ImGui_Dummy(ctx, 0, 6)
  if #(model.cues or {}) == 0 then
    reaper.ImGui_TextDisabled(ctx, is_new_map and "Cole a letra no painel central para criar as linhas." or "Nenhuma linha mapeada ainda.")
  end
  for _, cue in ipairs(model.cues or {}) do
    reaper.ImGui_PushID(ctx, cue.id)
    reaper.ImGui_TextColored(ctx, HOLYRICS_ACCENT, cue.displayId)
    reaper.ImGui_SameLine(ctx, 48)
    reaper.ImGui_Text(ctx, format_cue_time(cue.time))
    reaper.ImGui_SameLine(ctx, 114)
    reaper.ImGui_Text(ctx, "LINE " .. cue_target_label(model, cue))
    reaper.ImGui_SameLine(ctx, 204)
    if reaper.ImGui_Button(ctx, "REMOVER", 70, 0) then
      AutomationModel.remove_cue(model, cue.id)
      state.automation_error = nil
      save_automation_model()
    end
    reaper.ImGui_PopID(ctx)
  end
  reaper.ImGui_EndChild(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginChild(ctx, "##sync_lyrics_preview", lyric_panel_w, details_h, 0)
  local lyric_header_x, lyric_header_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local lyric_header_w = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_Text(ctx, "LETRA DA MÚSICA")
  -- Keep the primary action first and the destructive action at the far edge.
  reaper.ImGui_SetCursorScreenPos(ctx, lyric_header_x + lyric_header_w - 154, lyric_header_y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5)
  local generate_lines = reaper.ImGui_Button(ctx, "GERAR LINHAS", 120, 24)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, lyric_header_x + lyric_header_w - 28, lyric_header_y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5)
  local clear_generated = reaper.ImGui_Button(ctx, "##clear_generated_lines", 28, 24)
  reaper.ImGui_PopStyleVar(ctx)
  local trash_x1, trash_y1 = reaper.ImGui_GetItemRectMin(ctx)
  local trash_x2, trash_y2 = reaper.ImGui_GetItemRectMax(ctx)
  local trash_draw = reaper.ImGui_GetWindowDrawList(ctx)
  local trash_color = generated_line_count > 0 and C.text or C.text_dim
  local trash_cx = (trash_x1 + trash_x2) / 2
  reaper.ImGui_DrawList_AddRect(trash_draw, trash_cx - 5, trash_y1 + 8, trash_cx + 5, trash_y2 - 4, trash_color, 1, 0, 1.3)
  reaper.ImGui_DrawList_AddLine(trash_draw, trash_cx - 7, trash_y1 + 6, trash_cx + 7, trash_y1 + 6, trash_color, 1.3)
  reaper.ImGui_DrawList_AddLine(trash_draw, trash_cx - 2, trash_y1 + 4, trash_cx + 2, trash_y1 + 4, trash_color, 1.3)
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Excluir todas as linhas geradas (" .. tostring(generated_line_count) .. ")")
  end
  if clear_generated and generated_line_count > 0 then
    AutomationModel.clear_generated_lines(model)
    -- Return to the pasted-text state so the lyric can be corrected and
    -- generated again; deleting generated lines must not discard the source.
    state.automation_import_text = (model.lyrics and model.lyrics.source) or state.automation_import_text
    state.inline_lyric_edit_id = nil
    state.inline_slide_edit_id = nil
    state.pending_lyric_map = nil
    state.automation_error = nil
    save_automation_model()
  end
  reaper.ImGui_SetCursorScreenPos(ctx, lyric_header_x, lyric_header_y + reaper.ImGui_GetTextLineHeightWithSpacing(ctx) + 4)
  reaper.ImGui_Dummy(ctx, 0, 2)
  if is_new_map then
    -- Same black lyric workspace as a mapped song.  The only empty-state
    -- affordance is a transparent paste target; metadata can be corrected by
    -- clicking LT after the lines are created.
    reaper.ImGui_TextColored(ctx, C.text_dim, "Artista")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x141A22FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x1E293BFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x1E293BFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x3A4A60FF)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
    local draft_artist = state.automation_title_artist or ""
    local draft_song = state.automation_title_song or ""
    if model and model.lyrics then
      if draft_artist == "" then draft_artist = model.lyrics.titleArtist or "" end
      if draft_song == "" then draft_song = model.lyrics.titleSong or "" end
    end
    local artist_changed, artist = reaper.ImGui_InputText(ctx, "##automation_artist", draft_artist)
    if artist_changed then state.automation_title_artist = artist end
    reaper.ImGui_TextColored(ctx, C.text_dim, "Música")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local title_changed, title = reaper.ImGui_InputText(ctx, "##automation_title", draft_song)
    if title_changed then state.automation_title_song = title end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 4)
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x00000000)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
    local lyric_height = math.max(120, details_h - 96)
    local lyric_changed, lyrics = reaper.ImGui_InputTextMultiline(ctx, "##automation_lyrics", state.automation_import_text or "", -1, lyric_height)
    if lyric_changed then state.automation_import_text = lyrics end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_PopStyleColor(ctx, 3)

    if generate_lines then
      local song = (state.automation_title_song or ""):match("^%s*(.-)%s*$")
      local singer = (state.automation_title_artist or ""):match("^%s*(.-)%s*$")
      local source = (state.automation_import_text or ""):match("^%s*(.-)%s*$")
      if source == "" then
        state.automation_error = "Cole ou escreva ao menos uma linha da letra."
      else
        if song == "" and model and model.lyrics then
          song = (model.lyrics.titleSong or ""):match("^%s*(.-)%s*$")
          singer = singer ~= "" and singer or (model.lyrics.titleArtist or ""):match("^%s*(.-)%s*$")
        end
        if singer == "" or song == "" then
          state.automation_error = "Informe o artista e o nome da música antes de gerar as linhas."
        else
          local new_model = AutomationModel.import_text(source, state.holyrics_lines_per_slide)
          local title_line, title_error = AutomationModel.set_title_line(new_model, singer, song)
          if title_line then
            state.automation_model = new_model
            state.automation_error = nil
            save_automation_model()
          else
            state.automation_error = title_error
          end
        end
      end
    end
  else
  if generate_lines then
    AutomationModel.reflow_slides(model, state.holyrics_lines_per_slide)
    refresh_lyric_source(model)
    save_automation_model()
  end
  for _, line in ipairs(model.lyrics.lines) do
    reaper.ImGui_PushID(ctx, "sync_" .. line.id)
    local editing = state.inline_lyric_edit_id == line.id
    local label = line.displayId .. "  " .. line.text
    local is_active_line = current_line_cue and current_line_cue.target == line.id
    if line.isTitle then
      reaper.ImGui_TextColored(ctx, C.text_dim, "SLIDE DE TÍTULO")
    end
    local row_x, row_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local row_w = reaper.ImGui_GetContentRegionAvail(ctx)
    if editing then
      reaper.ImGui_TextColored(ctx, is_active_line and HOLYRICS_MAPPED_GREEN or HOLYRICS_ACCENT, line.displayId)
      reaper.ImGui_SameLine(ctx, 38)
      reaper.ImGui_SetNextItemWidth(ctx, -1)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x00000000)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x00000000)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x00000000)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
      if state.inline_lyric_focus_id == line.id then
        reaper.ImGui_SetKeyboardFocusHere(ctx)
        state.inline_lyric_focus_id = nil
      end
      local submitted, text = reaper.ImGui_InputText(ctx, "##inline_edit", line.text, reaper.ImGui_InputTextFlags_EnterReturnsTrue())
      local changed = text ~= line.text
      if changed then line.text = text end
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx, 3)
      if submitted or reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
        state.inline_lyric_edit_id = nil
        refresh_lyric_source(model)
        save_automation_model()
      end
    elseif line.isTitle then
      local line_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx), row_x, row_y, row_x + row_w, row_y + line_h, 0x193B5C88)
      reaper.ImGui_TextColored(ctx, HOLYRICS_ACCENT, label)
    elseif is_active_line then
      local line_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
      reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx), row_x, row_y, row_x + row_w, row_y + line_h, 0x14532D88)
      reaper.ImGui_TextColored(ctx, HOLYRICS_MAPPED_GREEN, label)
    else
      reaper.ImGui_Text(ctx, label)
    end
    if not editing then
      if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        state.pending_lyric_map = nil
        state.inline_lyric_edit_id = line.id
        state.inline_lyric_focus_id = line.id
      elseif reaper.ImGui_IsItemClicked(ctx, 0) then
        state.pending_lyric_map = {
          model = model,
          line_id = line.id,
          time = timeline_position,
          region_id = current_region and tostring(current_region.idx) or nil,
          started_at = reaper.time_precise(),
        }
      end
    end
    if line.isTitle then reaper.ImGui_Dummy(ctx, 0, 6) end
    reaper.ImGui_PopID(ctx)
  end
  end
  reaper.ImGui_EndChild(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_BeginChild(ctx, "##sync_slides_preview", 0, details_h, 0)
  local header_x, header_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local header_w = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_Text(ctx, "SLIDES")
  reaper.ImGui_SetCursorScreenPos(ctx, header_x + math.max(0, header_w - 44), header_y)
  reaper.ImGui_SetNextItemWidth(ctx, 44)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5)
  if reaper.ImGui_BeginCombo(ctx, "##sync_lines_per_slide", tostring(state.holyrics_lines_per_slide)) then
    for _, option in ipairs({"1", "2", "3", "4"}) do
      if reaper.ImGui_Selectable(ctx, option, option == tostring(state.holyrics_lines_per_slide)) then
        state.holyrics_lines_per_slide = tonumber(option)
        reaper.SetExtState("MultitrackController", "holyrics_lines", option, true)
        if not is_new_map then
          AutomationModel.reflow_slides(model, state.holyrics_lines_per_slide)
          refresh_lyric_source(model)
          save_automation_model()
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_SetCursorScreenPos(ctx, header_x, header_y + reaper.ImGui_GetTextLineHeightWithSpacing(ctx) + 4)
  reaper.ImGui_Dummy(ctx, 0, 6)
  if is_new_map then
    reaper.ImGui_TextColored(ctx, HOLYRICS_ACCENT, "SLIDE DE TÍTULO")
    local title_preview = ((state.automation_title_artist or "") .. " - " .. (state.automation_title_song or "")):gsub("^%s*%-%s*", "")
    reaper.ImGui_TextColored(ctx, C.text_dim, "LT")
    reaper.ImGui_SameLine(ctx, 42)
    reaper.ImGui_TextWrapped(ctx, title_preview ~= "" and title_preview or "Cantor - título da música")
    local preview_lines, line_number = {}, 0
    for value in ((state.automation_import_text or "") .. "\n"):gmatch("(.-)\n") do
      value = value:match("^%s*(.-)%s*$")
      if value ~= "" then preview_lines[#preview_lines + 1] = value end
    end
    for index, value in ipairs(preview_lines) do
      if (index - 1) % state.holyrics_lines_per_slide == 0 then
        reaper.ImGui_Dummy(ctx, 0, 6)
        reaper.ImGui_TextColored(ctx, HOLYRICS_ACCENT, "SLIDE S" .. tostring(math.floor((index - 1) / state.holyrics_lines_per_slide) + 1))
      end
      line_number = line_number + 1
      reaper.ImGui_TextColored(ctx, C.text_dim, "L" .. tostring(line_number))
      reaper.ImGui_SameLine(ctx, 42)
      reaper.ImGui_TextWrapped(ctx, value)
    end
    if #preview_lines == 0 then reaper.ImGui_TextDisabled(ctx, "A prévia dos slides aparecerá aqui.") end
  else
  for _, slide in ipairs(model.slides or {}) do
    reaper.ImGui_PushID(ctx, "slide_preview_" .. slide.id)
    local is_active_slide = false
    if current_line_cue then
      for _, line_id in ipairs(slide.lineIds or {}) do
        if line_id == current_line_cue.target then
          is_active_slide = true
          break
        end
      end
    end
    local title_color = is_active_slide and HOLYRICS_MAPPED_GREEN or HOLYRICS_ACCENT
    if is_active_slide then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), HOLYRICS_MAPPED_GREEN)
    end
    if slide.isTitle then
      reaper.ImGui_TextColored(ctx, title_color, "SLIDE DE TÍTULO")
    else
      reaper.ImGui_TextColored(ctx, title_color, "SLIDE " .. slide.displayId)
    end
    if reaper.ImGui_BeginPopupContextItem(ctx, "##slide_actions") then
      if not slide.isTitle and reaper.ImGui_MenuItem(ctx, "Adicionar linha") then
        AutomationModel.add_line(model, "Nova linha", slide.id)
        refresh_lyric_source(model)
        save_automation_model()
      end
      if not slide.isTitle and reaper.ImGui_MenuItem(ctx, "Mover slide para a esquerda") then
        if AutomationModel.move_slide(model, slide.id, -1) then save_automation_model() end
      end
      if not slide.isTitle and reaper.ImGui_MenuItem(ctx, "Mover slide para a direita") then
        if AutomationModel.move_slide(model, slide.id, 1) then save_automation_model() end
      end
      reaper.ImGui_EndPopup(ctx)
    end
    for _, line_id in ipairs(slide.lineIds or {}) do
      local line = AutomationModel.get_line(model, line_id)
      if line then
        local editing_slide_line = state.inline_slide_edit_id == line.id
        reaper.ImGui_TextColored(ctx, is_active_slide and HOLYRICS_MAPPED_GREEN or C.text_dim, line.displayId)
        reaper.ImGui_SameLine(ctx, 42)
        if editing_slide_line then
          reaper.ImGui_SetNextItemWidth(ctx, -1)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x00000000)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x00000000)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x00000000)
          reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 0)
          if state.inline_slide_focus_id == line.id then
            reaper.ImGui_SetKeyboardFocusHere(ctx)
            state.inline_slide_focus_id = nil
          end
          local submitted, text = reaper.ImGui_InputText(ctx, "##edit_slide_line", line.text, reaper.ImGui_InputTextFlags_EnterReturnsTrue())
          line.text = text
          reaper.ImGui_PopStyleVar(ctx)
          reaper.ImGui_PopStyleColor(ctx, 3)
          local delete_empty = text == "" and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Backspace())
          if delete_empty and not line.isTitle then
            local line_position
            for index, id in ipairs(slide.lineIds) do if id == line.id then line_position = index; break end end
            local previous_id = line_position and slide.lineIds[line_position - 1]
            AutomationModel.remove_line(model, line.id)
            state.inline_slide_edit_id = previous_id
            state.inline_slide_focus_id = previous_id
            refresh_lyric_source(model)
            save_automation_model()
          elseif submitted then
            refresh_lyric_source(model)
            save_automation_model()
            if line.isTitle then
              state.inline_slide_edit_id = nil
            else
              local line_position = 1
              for index, id in ipairs(slide.lineIds) do if id == line.id then line_position = index; break end end
              local new_line = AutomationModel.add_line(model, "", slide.id, line_position + 1)
              state.inline_slide_edit_id = new_line.id
              state.inline_slide_focus_id = new_line.id
              refresh_lyric_source(model)
              save_automation_model()
            end
          elseif reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
            state.inline_slide_edit_id = nil
            refresh_lyric_source(model)
            save_automation_model()
          end
        else
          reaper.ImGui_TextWrapped(ctx, line.text)
          if reaper.ImGui_IsItemClicked(ctx, 0) then
            state.inline_slide_edit_id = line.id
            state.inline_slide_focus_id = line.id
          end
        end
      end
    end
    if is_active_slide then reaper.ImGui_PopStyleColor(ctx) end
    reaper.ImGui_Dummy(ctx, 0, 5)
    reaper.ImGui_PopID(ctx)
  end
  end
  reaper.ImGui_EndChild(ctx)
end

-- A faithful local output preview.  It intentionally uses the same cue and
-- region rules as SYNC, making it the visual contract for Holyrics and Trackly.
render_automation_preview = function(ctx, show_settings)
  local model = state.automation_model
  if not model or #model.lyrics.lines == 0 then
    reaper.ImGui_TextDisabled(ctx, "Gere e mapeie a letra antes de abrir a prévia.")
    return
  end

  local is_playing = (reaper.GetPlayState() & 1) == 1
  local transport_position = is_playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local position = transport_position + (state.lyrics_preview_lead or 0)
  local regions = Sections.get_from_project(0)
  local current_region = region_at_position(regions, position)
  local active_cue = active_line_cue(model, position)
  if not region_has_line_cue(model, current_region) then active_cue = nil end

  local active_slide = nil
  if active_cue then
    for _, slide in ipairs(model.slides or {}) do
      for _, line_id in ipairs(slide.lineIds or {}) do
        if line_id == active_cue.target then active_slide = slide; break end
      end
      if active_slide then break end
    end
  end

  local preview_w, preview_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local light_theme = state.lyrics_preview_theme == "CLARO"
  local preview_bg = light_theme and 0xF5F5F5FF or 0x000000FF
  local preview_text = light_theme and 0x181818FF or C.text
  local preview_dim = light_theme and 0x666666FF or C.text_dim
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), preview_bg)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ChildRounding(), 8.0)
  reaper.ImGui_BeginChild(ctx, "##live_lyric_preview", 0, preview_h, reaper.ImGui_ChildFlags_Borders())
  if show_settings then
    reaper.ImGui_TextColored(ctx, preview_text, "PRÉVIA AO VIVO")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, preview_dim, format_cue_time(transport_position))
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, preview_dim, is_playing and "SINCRONIZADA COM PLAY" or "CURSOR PARADO")
  else
    local target = state.code_api_targets and state.code_api_targets[1]
    local mon = target and state.connection_monitor and state.connection_monitor[1]
    local now = reaper.time_precise()
    local led_color, status_text
    if not target then
      led_color = 0x666666FF
      status_text = "Nenhum destino configurado"
    elseif not mon or mon.ok == nil then
      led_color = 0x666666FF
      status_text = target.name .. " (Aguardando...)"
    elseif mon.ok then
      local pulse = 0.65 + 0.35 * math.abs(math.sin(now * 2.5))
      local g = math.floor(0xB9 * pulse)
      led_color = 0x10000000 + g * 0x10000 + 0x8100 + 0xFF
      status_text = target.name
    else
      led_color = 0xEF4444FF
      status_text = target.name .. " (Offline)"
    end
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    cx = cx + 8; cy = cy + 7
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 5, led_color)
    reaper.ImGui_Dummy(ctx, 16, 14)
    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_TextColored(ctx, (mon and mon.ok) and 0x10B981FF or 0xAAAAAAFF, status_text)
  end
  if show_settings then
    reaper.ImGui_SameLine(ctx, preview_w - 34)
    if reaper.ImGui_Button(ctx, "⚙##lyrics_preview_settings", 26, 22) then
      reaper.ImGui_OpenPopup(ctx, "LyricsPreviewSettings")
    end
    if reaper.ImGui_BeginPopup(ctx, "LyricsPreviewSettings") then
      reaper.ImGui_Text(ctx, "ANTECIPAÇÃO DA LETRA")
      reaper.ImGui_TextColored(ctx, preview_dim, "Dispara o Holyrics e a prévia antes da região.")
      if reaper.ImGui_BeginCombo(ctx, "##preview_lead", string.format("%.1f s", state.lyrics_preview_lead)) then
        for _, seconds in ipairs({0, 0.5, 1.0, 1.5, 2.0, 3.0}) do
          local selected = state.lyrics_preview_lead == seconds
          if reaper.ImGui_Selectable(ctx, string.format("%.1f s", seconds), selected) then
            state.lyrics_preview_lead = seconds
            reaper.SetExtState("MultitrackController", "lyrics_preview_lead", tostring(seconds), true)
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Text(ctx, "TEMA")
      if reaper.ImGui_BeginCombo(ctx, "##preview_theme", state.lyrics_preview_theme) then
        for _, theme in ipairs({"ESCURO", "CLARO"}) do
          if reaper.ImGui_Selectable(ctx, theme, state.lyrics_preview_theme == theme) then
            state.lyrics_preview_theme = theme
            reaper.SetExtState("MultitrackController", "lyrics_preview_theme", theme, true)
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      reaper.ImGui_Text(ctx, "ANIMAÇÃO")
      if reaper.ImGui_BeginCombo(ctx, "##preview_animation", state.lyrics_preview_animation) then
        for _, animation in ipairs({"FADE", "SEM ANIMAÇÃO"}) do
          if reaper.ImGui_Selectable(ctx, animation, state.lyrics_preview_animation == animation) then
            state.lyrics_preview_animation = animation
            reaper.SetExtState("MultitrackController", "lyrics_preview_animation", animation, true)
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      reaper.ImGui_EndPopup(ctx)
    end
  end
  reaper.ImGui_Separator(ctx)

  if not active_slide then
    reaper.ImGui_Dummy(ctx, 0, show_settings and preview_h * 0.32 or 8)
    reaper.ImGui_TextColored(ctx, preview_dim, "Aguardando uma linha mapeada nesta região.")
  else
    if state.lyrics_preview_last_target ~= active_cue.target then
      state.lyrics_preview_last_target = active_cue.target
      state.lyrics_preview_transition_at = reaper.time_precise()
    end
    local alpha = 255
    if state.lyrics_preview_animation == "FADE" then
      alpha = math.floor(math.min(1, (reaper.time_precise() - state.lyrics_preview_transition_at) / 0.22) * 255)
    end
    local function with_alpha(color) return (color & 0xFFFFFF00) | alpha end
    reaper.ImGui_Dummy(ctx, 0, math.max(28, preview_h * 0.20))
    for _, line_id in ipairs(active_slide.lineIds) do
      local line = AutomationModel.get_line(model, line_id)
      if line then
        local is_active = line.id == active_cue.target
        local use_font = show_settings and font_preview or font_preview_sm
        local use_size = show_settings and 32 or 18
        push_font_compat(use_font, use_size)
        if show_settings then
          -- Janela flutuante: centraliza com fonte grande
          local text_w = reaper.ImGui_CalcTextSize(ctx, line.text)
          reaper.ImGui_SetCursorPosX(ctx, math.max(20, (preview_w - text_w) / 2))
          reaper.ImGui_TextColored(ctx, with_alpha(is_active and HOLYRICS_MAPPED_GREEN or preview_text), line.text)
        else
          -- Painel embutido: wrap para nao cortar na direita
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), with_alpha(is_active and HOLYRICS_MAPPED_GREEN or preview_text))
          reaper.ImGui_TextWrapped(ctx, line.text)
          reaper.ImGui_PopStyleColor(ctx)
        end
        reaper.ImGui_PopFont(ctx)
        reaper.ImGui_Dummy(ctx, 0, show_settings and 18 or 4)
      end
    end
    reaper.ImGui_Dummy(ctx, 0, show_settings and 22 or 6)
    reaper.ImGui_TextColored(ctx, with_alpha(preview_dim), active_slide.isTitle and "SLIDE DE TÍTULO" or "SLIDE " .. active_slide.displayId)
  end
  reaper.ImGui_EndChild(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx)
end

local function render_lyrics_preview_window(ctx, win_x, win_y, win_w, win_h)
  if not state.show_lyrics_preview then return end
  reaper.ImGui_SetNextWindowPos(ctx, win_x + (win_w / 2), win_y + (win_h / 2), reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 620, 330, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 440, 240, 1100, 700)
  local window_bg = state.lyrics_preview_theme == "CLARO" and 0xF5F5F5FF or 0x000000FF
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), window_bg)
  local visible, open = reaper.ImGui_Begin(ctx, "Lyrics Preview", true, reaper.ImGui_WindowFlags_NoCollapse())
  if not open then state.show_lyrics_preview = false end
  if visible then render_automation_preview(ctx, true) end
  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleColor(ctx)
end

local function render_holyrics_modal(ctx, win_x, win_y, win_w, win_h)
  if not state.show_holyrics_modal then return end
  
  -- A primeira abertura começa em uma posição segura. Depois disso, a janela
  -- volta exatamente ao ponto em que o usuário a deixou.
  local initial_x = state.holyrics_window_x or 80
  local initial_y = state.holyrics_window_y or 70
  reaper.ImGui_SetNextWindowPos(ctx, initial_x, initial_y, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_SetNextWindowSize(ctx, state.holyrics_window_w, state.holyrics_window_h, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 960, 680, 2400, 1800)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x000000FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), 0x000000FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), 0x000000FF)
  
  reaper.ImGui_SetNextWindowSize(ctx, 900, 650, reaper.ImGui_Cond_FirstUseEver())
  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, "MIDI Mapping", true, flags)
  if not open then state.show_holyrics_modal = false end

  local actual_x, actual_y = reaper.ImGui_GetWindowPos(ctx)
  if actual_x ~= state.holyrics_window_x or actual_y ~= state.holyrics_window_y then
    state.holyrics_window_x, state.holyrics_window_y = actual_x, actual_y
    reaper.SetExtState("MultitrackController", "holyrics_window_x", tostring(actual_x), true)
    reaper.SetExtState("MultitrackController", "holyrics_window_y", tostring(actual_y), true)
  end
  
  if visible then
    local actual_w, actual_h = reaper.ImGui_GetWindowSize(ctx)
    if actual_w ~= state.holyrics_window_w or actual_h ~= state.holyrics_window_h then
      state.holyrics_window_w, state.holyrics_window_h = actual_w, actual_h
      reaper.SetExtState("MultitrackController", "holyrics_window_w", tostring(actual_w), true)
      reaper.SetExtState("MultitrackController", "holyrics_window_h", tostring(actual_h), true)
    end

    local header_y = reaper.ImGui_GetCursorPosY(ctx)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 7.0)
    if reaper.ImGui_Button(ctx, "##holyrics_home", 34, 26) then
      state.holyrics_editor_view = "SYNC"
    end
    local home_x1, home_y1 = reaper.ImGui_GetItemRectMin(ctx)
    local home_x2, home_y2 = reaper.ImGui_GetItemRectMax(ctx)
    local home_draw = reaper.ImGui_GetWindowDrawList(ctx)
    local hx, hy = (home_x1 + home_x2) / 2, home_y1 + 7
    local house_color = C.text
    -- Ícone desenhado à mão: evita depender de caracteres que a fonte do
    -- REAPER pode substituir por "?".
    reaper.ImGui_DrawList_AddLine(home_draw, hx - 8, hy + 6, hx, hy, house_color, 1.6)
    reaper.ImGui_DrawList_AddLine(home_draw, hx, hy, hx + 8, hy + 6, house_color, 1.6)
    reaper.ImGui_DrawList_AddRect(home_draw, hx - 6, hy + 6, hx + 6, hy + 15, house_color, 1.0, 0, 1.6)
    reaper.ImGui_DrawList_AddLine(home_draw, hx - 1.5, hy + 15, hx - 1.5, hy + 10, house_color, 1.6)
    reaper.ImGui_DrawList_AddLine(home_draw, hx + 1.5, hy + 15, hx + 1.5, hy + 10, house_color, 1.6)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Início")
    end

    -- SYNC é a própria tela inicial. As únicas ações ficam à direita para não
    -- disputar espaço com o mapa que é usado no dia a dia.
    local current_header_x = reaper.ImGui_GetCursorPosX(ctx)
    local header_width = current_header_x + reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPos(ctx, math.max(0, header_width - 226), header_y)
    if reaper.ImGui_Button(ctx, "ROUTE", 90, 26) then
      state.holyrics_editor_view = state.holyrics_editor_view == "ROUTE" and "SYNC" or "ROUTE"
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "SALVAR MAPA", 128, 26) then
      if state.automation_model then
        save_automation_model()
        if not state.automation_error then
          -- Save the project itself too, so the embedded map and the portable
          -- Trackly JSON always refer to the same revision of the song.
          reaper.Main_SaveProject(0, false)
        end
      else
        state.automation_error = "Não há letra mapeada para salvar."
      end
    end
    reaper.ImGui_PopStyleVar(ctx)
    reaper.ImGui_Separator(ctx)
    if state.automation_error then
      reaper.ImGui_TextColored(ctx, C.red, "Automação: " .. state.automation_error)
    end
    if state.holyrics_editor_view == "SYNC" then
      render_automation_sync_editor(ctx)
    elseif state.holyrics_editor_view == "ROUTE" then
      render_route_editor(ctx)
    else
      -- As abas antigas foram incorporadas ao SYNC. Qualquer estado antigo
      -- abre diretamente no fluxo compacto do dia a dia.
      state.holyrics_editor_view = "SYNC"
      render_automation_sync_editor(ctx)

    end -- selected editor view
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopStyleVar(ctx, 1)
end
-- ─── Main loop ───────────────────────────────────────────────────────────────

local function loop()
  local frame_started = reaper.time_precise()
  
  -- Processa crossfades do PAD
  Pads.process_fades()
  
  -- Roda a máquina de estado do scanner de rede (1 IP por frame se ativo)
  process_network_scan()

  -- Monitor de conexao: verifica status dos targets periodicamente
  update_connection_monitors()
  
  -- Lógica do HOLD (Auto-Avanço de Aba)
  local current_play_state = reaper.GetPlayState() & 1
  local playback_started = current_play_state == 1 and state._last_play_state ~= 1
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

  -- Chords are generated once, only while stopped, from tracks named PIANO
  -- and BASS/BAIXO. Once the sidecar exists this is an inexpensive file check.
  if frame_started - (state.chord_analysis_checked_at or 0) >= 2 then
    state.chord_analysis_checked_at = frame_started
    local active_project = reaper.EnumProjects(-1)
    state.chord_analysis_status = ChordAnalyzer.ensure(active_project, state.current_proj_path, SCRIPT_PATH)
  end

  if state.automation_model and state.automation_enabled then
    local automation_position = current_play_state == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    
    -- Aplica a antecipação global (configurada na engrenagem do preview) para o disparo real dos comandos
    local engine_position = automation_position + (state.lyrics_preview_lead or 0)
    
    local cue_state = CueEngine.update(
      state.cue_engine,
      engine_position,
      current_play_state == 1,
      state.automation_model.cues or {},
      function(cue)
        log_simulated_cue(cue)
        send_holyrics_line(cue)
      end
    )
    -- Ao apertar Play no meio da música, abre a apresentação já na L correta.
    -- Os próximos cues apenas avançam para a próxima linha, sem reabrir a tela.
    if playback_started or cue_state == "started" then
      local current_cue = active_line_cue(state.automation_model, engine_position)
      local ok, message = open_holyrics_presentation(state.automation_model, current_cue and current_cue.target or nil)
      state.holyrics_remote_status = { ok = ok, message = message }
    end
  end

  -- O duck é aplicado a cada projeto aberto, inclusive quando a aba muda durante a execução.
  local network_started = reaper.time_precise()
  holyrics_transport:update()
  local network_ms = (reaper.time_precise() - network_started) * 1000
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
  -- O controlador é um painel fixo de palco: ele deve abrir completo, sem
  -- exigir que o usuário redimensione a docka manualmente.
  reaper.ImGui_SetNextWindowSize(ctx, rw, 220, reaper.ImGui_Cond_Always())
  -- A UI possui 50px de transporte e 152px de waveform; não permita que
  -- uma docka baixa esconda todos os controles de mapa.
  reaper.ImGui_SetNextWindowSizeConstraints(ctx, 100, 220, 99999, 99999)
  local visible, open = reaper.ImGui_Begin(ctx, "Multitrack##mc_final", true, wflags)
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopStyleVar(ctx, 4)

  if visible then
    -- Ativa a fonte moderna para tudo dentro da janela
    push_font_compat(font, 14)

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
      render_holyrics_modal(ctx, win_x, win_y, win_w, win_h)
      render_lyrics_preview_window(ctx, win_x, win_y, win_w, win_h)
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

  -- In-memory diagnostics: no console output or disk writes during playback.
  local frame_ms = (reaper.time_precise() - frame_started) * 1000
  state.performance_peak_ms = math.max(state.performance_peak_ms or 0, frame_ms)
  state.performance_network_peak_ms = math.max(state.performance_network_peak_ms or 0, network_ms)
  if frame_started >= (state.performance_publish_at or 0) then
    reaper.SetExtState("MultitrackController", "performance", string.format(
      "frame_peak_ms=%.2f network_peak_ms=%.2f", state.performance_peak_ms, state.performance_network_peak_ms), false)
    state.performance_peak_ms, state.performance_network_peak_ms = 0, 0
    state.performance_publish_at = frame_started + 2
  end
  if open then
    reaper.defer(loop)
  end
end

-- Kick off
reaper.defer(loop)




















