package.path = "modules/?.lua;" .. package.path
local Model = require("automation_model")

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local model = Model.import_text("Primeira linha\nSegunda linha\nTerceira linha", 2)
assert_equal(#model.lyrics.lines, 3, "imports every non-empty lyric line")
assert_equal(#model.slides, 2, "creates slides using the requested initial grouping")
assert_equal(model.lyrics.lines[3].displayId, "L3", "line display IDs are stable")

local first_slide, second_slide = model.slides[1], model.slides[2]
local line_three = model.lyrics.lines[3]
assert(Model.move_line(model, line_three.id, first_slide.id))
assert_equal(line_three.id, "line-3", "moving a line does not change its technical ID")
assert_equal(line_three.displayId, "L3", "moving a line does not change its display ID")
assert_equal(#Model.validate(model), 0, "a moved line remains valid and belongs to one slide")

assert(Model.move_line_within_slide(model, model.lyrics.lines[2].id, first_slide.id, -1))
assert_equal(first_slide.lineIds[1], model.lyrics.lines[2].id, "lines can be reordered without changing IDs")

local third_slide = Model.add_slide(model)
assert(Model.move_line(model, line_three.id, third_slide.id))
assert_equal(#Model.validate(model), 0, "new slides can receive moved lines")

local cue = assert(Model.add_cue(model, 42.5, "region-4", "SHOW_SLIDE", third_slide.id))
assert_equal(cue.displayId, "C1", "cues receive stable display IDs")
assert_equal(#Model.validate(model), 0, "a cue references an existing slide")

local line_cue = assert(Model.add_cue(model, 43, "region-4", "SHOW_LINE", line_three.id))
assert_equal(line_cue.target, line_three.id, "a cue can target a stable lyric line")
assert_equal(#Model.validate(model), 0, "a line cue references an existing line")

assert(Model.move_cue(model, line_cue.id, 44.25))
assert_equal(line_cue.time, 44.25, "a cue can be repositioned on the timeline")

assert(Model.reflow_slides(model, 1))
assert_equal(#model.slides, 3, "reflow creates additional slides when required")
assert_equal(model.slides[3].lineIds[1], line_three.id, "reflow preserves line identity")

model.cues = nil -- Simulates a project saved before the cue phase.
local migrated_cue = assert(Model.add_cue(model, 55, "region-5", "SHOW_SLIDE", third_slide.id))
assert_equal(#model.cues, 1, "older saved models are migrated when a cue is added")

print("automation_model_test: passed")
