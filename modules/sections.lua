-- modules/sections.lua
-- Reads Reaper project markers and turns them into named sections
-- with start/end positions used for waveform overlay and navigation buttons.

local Sections = {}

-- ─── Section → Color mapping (RGBA 0xRRGGBBAA) ──────────────────────────────

local COLORS = {
  default      = 0x6B728055,
  branca       = 0xFFFFFF55,
  verso        = 0xFF8C0055, -- Laranja
  pre_refrao   = 0x00DCFF55, -- Ciano
  refrao       = 0x0064FF55, -- Azul
  ponte        = 0xDC282855, -- Vermelha
  saida        = 0x28C85055, -- Verde
}

local PATTERN_MAP = {
  {"contagem",   COLORS.branca},
  {"introdu",    COLORS.saida}, -- Verde
  {"intro",      COLORS.saida}, -- Verde
  {"verso",      COLORS.verso},
  {"pr[eé]",     COLORS.pre_refrao},
  {"pre.ref",    COLORS.pre_refrao},
  {"refr[aã]",   COLORS.refrao},
  {"chorus",     COLORS.refrao},
  {"turnaround", COLORS.branca},
  {"ponte",      COLORS.ponte},
  {"bridge",     COLORS.ponte},
  {"pausa",      COLORS.branca},
  {"sa[ií]da",   COLORS.saida},
  {"final",      COLORS.branca},
  {"outro",      COLORS.branca},
}

--- Return color for a section name
function Sections.color_for(name)
  local lower = name:lower()
  for _, rule in ipairs(PATTERN_MAP) do
    if lower:match(rule[1]) then return rule[2] end
  end
  return COLORS.default
end

-- ─── Read markers from current Reaper project ────────────────────────────────

--- Fetch all non-region markers from the active Reaper project.
-- Returns array of { name, pos, end_pos, color }
-- end_pos is the start of the NEXT marker (or project length for the last one).
function Sections.get_from_project(proj)
  proj = proj or reaper.EnumProjects(-1)
  local markers = {}

  local i = 0
  while true do
    local ok, is_rgn, pos, rgnend, name, idx_num, m_col = reaper.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    if is_rgn and name and name ~= "" then
      markers[#markers + 1] = { name = name, pos = pos, end_pos = rgnend, color_native = m_col, idx = idx_num }
    end
    i = i + 1
  end

  -- Sort by position
  table.sort(markers, function(a, b) return a.pos < b.pos end)

  local sections = {}
  for idx, m in ipairs(markers) do
    local final_col = Sections.color_for(m.name)
    if m.color_native and m.color_native > 0 then
      local raw_col = m.color_native & 0xFFFFFF
      local r, g, b = reaper.ColorFromNative(raw_col)
      final_col = r * 0x1000000 + g * 0x10000 + b * 0x100 + 0x55
    end
    
    sections[#sections + 1] = {
      name    = m.name,
      pos     = m.pos,
      end_pos = m.end_pos,
      color   = final_col,
      idx     = m.idx
    }
  end

  return sections
end

function Sections.add_region_at_cursor(name, r, g, b)
  reaper.Undo_BeginBlock2(0)
  local play_state = reaper.GetPlayState()
  local pos = (play_state & 1 == 1) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local color = reaper.ColorToNative(r, g, b) | 0x1000000
  local proj_len = reaper.GetProjectLength(0)
  if proj_len <= pos then proj_len = pos + 300 end
  
  local i = 0
  local regions = {}
  while true do
    local ok, is_rgn, r_pos, r_end, r_name, r_idx, r_col = reaper.EnumProjectMarkers3(0, i)
    if ok == 0 then break end
    if is_rgn then
      table.insert(regions, {idx = r_idx, pos = r_pos, end_pos = r_end, name = r_name, color = r_col})
    end
    i = i + 1
  end
  
  local prev_rgn = nil
  for _, rgn in ipairs(regions) do
    if rgn.pos <= pos and rgn.end_pos > pos then
      prev_rgn = rgn
      break
    end
  end
  
  if not prev_rgn then
    local max_pos = -1
    for _, rgn in ipairs(regions) do
      if rgn.pos <= pos and rgn.pos > max_pos then
        max_pos = rgn.pos
        prev_rgn = rgn
      end
    end
  end
  
  local new_end = proj_len
  if prev_rgn and prev_rgn.end_pos > pos then
    new_end = prev_rgn.end_pos
    reaper.SetProjectMarker3(0, prev_rgn.idx, true, prev_rgn.pos, pos, prev_rgn.name, prev_rgn.color)
  elseif prev_rgn then
    -- if it doesn't overlap but is just behind, we might not need to adjust its end_pos 
    -- unless we want it to snap to our new pos if there's a gap. 
    -- Reaper regions can have gaps. Let's just leave it as is if it doesn't overlap.
  end
  
  local min_pos = math.huge
  for _, rgn in ipairs(regions) do
    if rgn.pos > pos and rgn.pos < min_pos then
      min_pos = rgn.pos
    end
  end
  if min_pos < math.huge and new_end > min_pos then
    new_end = min_pos
  end
  
  if new_end <= pos then new_end = pos + 10 end
  
  -- Cria a Region
  reaper.AddProjectMarker2(0, true, pos, new_end, name, -1, color)
  -- Cria o Marker pontual no mesmo lugar
  reaper.AddProjectMarker2(0, false, pos, 0, name, -1, color)
  reaper.Undo_EndBlock2(0, "Multitrack Controller: adicionar seção", -1)
end

--- Navigate Reaper's playhead to a section position.
-- @param pos  time in seconds
-- @param play  if true, also triggers play
function Sections.go_to(pos, play)
  reaper.SetEditCurPos(pos, true, play == true)
  if play then reaper.OnPlayButton() end
end

-- ─── Marker ↔ Region linking ────────────────────────────────────────────────
-- Cada seção criada pelo controlador é um PAR: uma região e um marker pontual
-- na mesma posição e com o mesmo nome. Se o usuário apagar um dos dois, o
-- outro precisa sumir junto. Guardamos o snapshot dos pares do último ciclo e
-- comparamos com o estado atual do projeto.

local link_snapshot = { proj = nil, pairs = {} }

local function pair_key(pos, name)
  return string.format("%.3f|%s", pos, name or "")
end

local function enumerate(proj)
  local regions, markers = {}, {}
  local i = 0
  while true do
    local ok, is_rgn, pos, _, name, idx = reaper.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    local bucket = is_rgn and regions or markers
    bucket[idx] = { pos = pos, name = name or "" }
    i = i + 1
  end
  return regions, markers
end

local function build_pairs(regions, markers)
  local by_key = {}
  for idx, m in pairs(markers) do
    local key = pair_key(m.pos, m.name)
    by_key[key] = by_key[key] or {}
    table.insert(by_key[key], idx)
  end
  local result = {}
  for r_idx, r in pairs(regions) do
    local list = by_key[pair_key(r.pos, r.name)]
    if list and #list > 0 then
      result[#result + 1] = { region = r_idx, marker = table.remove(list, 1) }
    end
  end
  return result
end

--- Apaga o "irmão" de qualquer região/marker removido desde o último ciclo.
-- Retorna true se algo foi apagado.
function Sections.sync_linked(proj)
  proj = proj or reaper.EnumProjects(-1)
  local regions, markers = enumerate(proj)

  -- Troca de projeto: apenas tira um novo snapshot, sem apagar nada.
  if link_snapshot.proj ~= proj then
    link_snapshot.proj = proj
    link_snapshot.pairs = build_pairs(regions, markers)
    return false
  end

  local to_delete = {}
  for _, p in ipairs(link_snapshot.pairs) do
    local has_rgn, has_mrk = regions[p.region] ~= nil, markers[p.marker] ~= nil
    if not has_rgn and has_mrk then
      to_delete[#to_delete + 1] = { idx = p.marker, is_rgn = false }
    elseif has_rgn and not has_mrk then
      to_delete[#to_delete + 1] = { idx = p.region, is_rgn = true }
    end
  end

  if #to_delete > 0 then
    reaper.Undo_BeginBlock2(proj)
    for _, d in ipairs(to_delete) do
      reaper.DeleteProjectMarker(proj, d.idx, d.is_rgn)
    end
    reaper.Undo_EndBlock2(proj, "Multitrack Controller: apagar marker/região vinculados", -1)
    reaper.UpdateTimeline()
    regions, markers = enumerate(proj)
  end

  link_snapshot.pairs = build_pairs(regions, markers)
  return #to_delete > 0
end

return Sections
