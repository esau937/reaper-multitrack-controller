-- Detects cue crossings independently from REAPER UI and output protocols.
-- The callback can later be replaced by MIDI, API or lighting backends.

local CueEngine = {}

function CueEngine.new()
  return { lastPosition = nil, triggered = {} }
end

function CueEngine.reset(engine, position)
  engine.lastPosition = position
  engine.triggered = {}
end

function CueEngine.update(engine, position, is_playing, cues, on_trigger)
  if not is_playing then
    engine.lastPosition = position
    return "stopped"
  end
  if not engine.lastPosition then
    engine.lastPosition = position
    return "started"
  end

  -- Rewind or loop wrap: reset so cues can fire on the next forward pass.
  if position < engine.lastPosition - 0.001 then
    CueEngine.reset(engine, position)
    return "rewind"
  end

  -- A large forward jump is a seek, not normal playback through every cue.
  if position - engine.lastPosition > 3 then
    engine.lastPosition = position
    return "seek"
  end

  for _, cue in ipairs(cues or {}) do
    if cue.time > engine.lastPosition and cue.time <= position and not engine.triggered[cue.id] then
      engine.triggered[cue.id] = true
      on_trigger(cue)
    end
  end
  engine.lastPosition = position
  return "playing"
end

return CueEngine
