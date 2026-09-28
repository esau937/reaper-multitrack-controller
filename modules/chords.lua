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
  events = basic
  local out = {}
  local function append(event)
    local last = out[#out]
    if last and last.chord == event.chord and math.abs(last["end"] - event.start) < 0.000001 then
      last["end"] = event["end"]
    else
      out[#out + 1] = {start=event.start, ["end"]=event["end"], chord=event.chord}
    end
  end
  local i = 1
  while i <= #events do
    local event, previous = events[i], events[i - 1]
    local finish, j = event.start, i
    if previous and previous.chord ~= "N" and previous["end"] - previous.start >= 1.5 then
      while j <= #events do
        local candidate = events[j]
        if candidate.chord == "N" or candidate.edited or candidate.keep or
           candidate["end"] - candidate.start >= 1 or
           math.abs(candidate.start - finish) > 0.000001 then break end
        finish = candidate["end"]
        j = j + 1
      end
    end
    local following = events[j]
    local can_bridge = j > i and finish - event.start <= 1 and
      math.abs(previous["end"] - event.start) < 0.000001 and following and
      following.chord ~= "N" and following["end"] - following.start >= 1.5 and
      math.abs(following.start - finish) < 0.000001
    if can_bridge then
      append({start=event.start, ["end"]=finish, chord=previous.chord})
      i = j
    else
      append(event)
      i = i + 1
    end
  end
  return out
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
  local current, next_event = Chords.at(Chords.is_simplified() and data.simplified_events or data.events, display_position)
  return Chords.transpose(current and current.chord, shift),
    Chords.transpose(next_event and next_event.chord, shift), data.status ~= "reviewed"
end
return Chords
