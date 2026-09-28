package.path = "modules/?.lua;" .. package.path
local CueEngine = require("cue_engine")

local engine = CueEngine.new()
local fired = {}
local cues = {
  { id = "cue-1", time = 10 },
  { id = "cue-2", time = 20 },
}
local function trigger(cue) table.insert(fired, cue.id) end

CueEngine.update(engine, 0, false, cues, trigger)
CueEngine.update(engine, 9, true, cues, trigger)
CueEngine.update(engine, 11, true, cues, trigger)
assert(#fired == 1 and fired[1] == "cue-1", "fires a crossed cue once")
CueEngine.update(engine, 12, true, cues, trigger)
assert(#fired == 1, "does not duplicate a cue")
CueEngine.update(engine, 5, true, cues, trigger)
CueEngine.update(engine, 11, true, cues, trigger)
assert(#fired == 2 and fired[2] == "cue-1", "allows firing again after rewind")
CueEngine.update(engine, 40, true, cues, trigger)
assert(#fired == 2, "does not fire every skipped cue after a seek")

print("cue_engine_test: passed")
