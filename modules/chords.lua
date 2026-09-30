-- Read-only display of pre-analysed chords. No audio or track changes.
local Chords = {}
local cached_path, cached_data, checked_at = nil, nil, -math.huge

function Chords.at(events, position)
  local lo, hi, found = 1, #events, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if events[mid].start <= position then found = mid; lo = mid + 1 else hi = mid - 1 end
  end
  if found == 0 then return nil, events[1] end
  local event = events[found]
  if position >= event["end"] then return nil, events[found + 1] end
  return event, events[found + 1]
end


-- Conservative display filter: bridge at most 1 second of passing chords
-- only when bounded by stable (>=1.5s) chords. Preserve rests, gaps,
-- manually edited events, and sequences of intentional fast changes.
function Chords.basic_name(chord)
  if not chord or chord == "N" then return chord end
  local root, quality = chord:match("^([A-G][#b]?)(.*)$")
  if not root then return chord end
  local q = quality:lower()
  -- Retain diminished/augmented triads; changing them to major is incorrect.
  if q:match("^dim") or q:match("^m7b5") then return root .. "dim" end
  if q:match("^aug") or q:match("^%+") then return root .. "aug" end
  if quality:match("^m") and not quality:match("^maj") then return root .. "m" end
  return root
end

function Chords.simplify(events)
  -- Work on copies, leaving the complete map unchanged. Collapse adjacent
  -- extensions/inversions of the same basic chord before passage filtering.
  local basic = {}
  for _, event in ipairs(events) do
    local chord = Chords.basic_name(event.chord)
    local last = basic[#basic]
    if last and last.chord == chord and math.abs(last["end"] - event.start) < 0.000001 then
      last["end"] = event["end"]
      last.edited = last.edited or event.edited
      last.keep = last.keep or event.keep
    else
      basic[#basic + 1] = {start=event.start, ["end"]=event["end"], chord=chord, edited=event.edited, keep=event.keep}
    end
  end
  -- The automatic detector can briefly prefer a neighbouring chord while a
  -- note is being played. A musician cannot use 100 ms flashes of a chord on
  -- stage, so absorb every unstable change shorter than this threshold into
  -- its longer neighbour. The original, complete map remains available when
  -- the simplified display option is disabled.
  local stable = {}
  for _, event in ipairs(basic) do
    stable[#stable + 1] = {start=event.start, ["end"]=event["end"], chord=event.chord,
      edited=event.edited, keep=event.keep}
  end
  -- Two seconds is deliberately conservative for the on-stage display. It
  -- keeps the player on the harmonic pulse instead of flashing incidental
  -- notes, bends and passing tones detected in the source tracks.
  local minimum_duration = 2.0
  local index = 1
  while index <= #stable do
    local event = stable[index]
    local duration = event["end"] - event.start
    if duration < minimum_duration and not event.edited and not event.keep and #stable > 1 then
      local previous, following = stable[index - 1], stable[index + 1]
      if previous and following and previous.chord == following.chord then
        previous["end"] = following["end"]
        table.remove(stable, index + 1)
        table.remove(stable, index)
        index = math.max(1, index - 1)
      elseif previous and (not following or previous["end"] - previous.start >= following["end"] - following.start) then
        previous["end"] = event["end"]
        table.remove(stable, index)
        index = math.max(1, index - 1)
      elseif following then
        following.start = event.start
        table.remove(stable, index)
      else
        index = index + 1
      end
    else
      index = index + 1
    end
  end
  return stable
end

function Chords.is_simplified()
  return reaper.GetExtState("MultitrackController", "chords_simplified") ~= "false"
end
function Chords.toggle_mode()
  reaper.SetExtState("MultitrackController", "chords_simplified", Chords.is_simplified() and "false" or "true", true)
end

function Chords.read(project_path, json)
  local now = reaper.time_precise()
  if project_path == cached_path and now - checked_at < 2 then return cached_data end
  cached_path, cached_data, checked_at = project_path, nil, now
  if not project_path or project_path == "" then return nil end
  local file = io.open(project_path .. ".chords.json", "r")
  if not file then return nil end
  local content = file:read("*a"); file:close()
  local ok, data = pcall(json.decode, content)
  if not ok or type(data) ~= "table" or type(data.events) ~= "table" then return nil end
  local previous_end = -math.huge
  for _, event in ipairs(data.events) do
    if type(event) ~= "table" or type(event.start) ~= "number" or
       type(event["end"]) ~= "number" or type(event.chord) ~= "string" or
       event.start < previous_end or not (event["end"] > event.start) then return nil end
    previous_end = event["end"]
  end
  data.simplified_events = Chords.simplify(data.events)
  cached_data = data
  return data
end

local notes = {C=0, ["C#"]=1, Db=1, D=2, ["D#"]=3, Eb=3, E=4, F=5,
  ["F#"]=6, Gb=6, G=7, ["G#"]=8, Ab=8, A=9, ["A#"]=10, Bb=10, B=11}
local sharp = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
function Chords.transpose(chord, shift)
  if not chord or chord == "N" then return "—" end
  shift = math.floor(tonumber(shift) or 0)
  if shift == 0 then return chord end
  local function convert(note) return notes[note] and sharp[(notes[note] + shift) % 12 + 1] or note end
  local root, rest = chord:match("^([A-G][#b]?)(.*)$")
  if not root then return chord end
  return convert(root) .. rest:gsub("/([A-G][#b]?)", function(bass) return "/" .. convert(bass) end)
end

function Chords.display(json, shift)
  local _, path = reaper.EnumProjects(-1, "")
  local data = Chords.read(path, json)
  if not data then return "SEM MAPA", "—", false end
  local position = (reaper.GetPlayState() & 3) ~= 0 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  -- Anticipate displayed transitions by 2 ms during playback only.
  -- Paused/stopped inspection remains aligned with the exact cursor position.
  local display_position = position
  if (reaper.GetPlayState() & 1) ~= 0 then display_position = position + 0.002 end
  -- Automatic maps are always shown in their stable form. The raw result is
  -- useful only for diagnostics; showing it live makes the chord display
  -- unusable due to incidental-note changes.
  local display_events = data.status == "automatic" and data.simplified_events or
    (Chords.is_simplified() and data.simplified_events or data.events)
  local current, next_event = Chords.at(display_events, display_position)
  return Chords.transpose(current and current.chord, shift),
    Chords.transpose(next_event and next_event.chord, shift), data.status ~= "reviewed"
end
return Chords
