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
  return basic
end

-- Audio analysis works in short FFT windows, whereas musicians change
-- harmony on the project's beat grid. Re-bin the detected harmony by the
-- actual REAPER tempo map: no arbitrary delay or duration threshold is used.
function Chords.quantize_to_project_beats(events, project)
  if not reaper.TimeMap2_timeToBeats or not reaper.TimeMap2_beatsToTime then return events end
  local length = reaper.GetProjectLength(project)
  if length <= 0 or #events == 0 then return events end
  local _, _, _, first_beat = reaper.TimeMap2_timeToBeats(project, 0)
  local _, _, _, last_beat = reaper.TimeMap2_timeToBeats(project, length)
  if type(first_beat) ~= "number" or type(last_beat) ~= "number" then return events end
  local out, event_index = {}, 1
  for beat = math.floor(first_beat), math.ceil(last_beat) do
    local begin_at = reaper.TimeMap2_beatsToTime(project, beat)
    local end_at = math.min(reaper.TimeMap2_beatsToTime(project, beat + 1), length)
    if end_at > begin_at then
      while event_index <= #events and events[event_index]["end"] <= begin_at do event_index = event_index + 1 end
      local probe, best_chord, best_overlap = event_index, nil, 0
      while probe <= #events and events[probe].start < end_at do
        local event = events[probe]
        local overlap = math.max(0, math.min(event["end"], end_at) - math.max(event.start, begin_at))
        if overlap > best_overlap then best_chord, best_overlap = event.chord, overlap end
        probe = probe + 1
      end
      if best_chord and best_chord ~= "N" then
        local previous = out[#out]
        if previous and previous.chord == best_chord and math.abs(previous["end"] - begin_at) < 0.0001 then
          previous["end"] = end_at
        else
          out[#out + 1] = {start=begin_at, ["end"]=end_at, chord=best_chord}
        end
      end
    end
  end
  return #out > 0 and out or events
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
  data.beat_events = data.status == "automatic" and Chords.quantize_to_project_beats(data.events, 0) or data.events
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
  -- Automatic maps use the REAPER beat grid, preserving the real musical
  -- position even in projects whose tempo changes during the arrangement.
  local current, next_event = Chords.at(data.beat_events or data.events, display_position)
  return Chords.transpose(current and current.chord, shift),
    Chords.transpose(next_event and next_event.chord, shift), data.status ~= "reviewed"
end
return Chords
