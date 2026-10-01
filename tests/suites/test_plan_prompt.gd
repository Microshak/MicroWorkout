extends TestSuite
## The prompts, the catalog embedding and the prompt digest.
##
## The strongest assertion here is [method _test_system_prompt_verbatim]: the sha256 of
## `PlanPrompt.system_prompt()` is pinned to a literal. If a single character of the prompt ever
## changes, the provider starts receiving a different instruction set and this suite fails rather
## than quietly blessing it — updating the hash is a deliberate, reviewed act.
##
## Everything else is about the parts of the prompt that depend on data: the catalog cap, the
## digest, and the repair block's documented limits.

## sha256 of the system prompt (2690 bytes, UTF-8).
const SYSTEM_SHA256 := "d0ab4eb09b33954661e5ec0144f492f4e7e528b5d0d00fdf3a6ff493c987ac77"
## sha256 of `"a\nb"`, computed outside GDScript so the digest arithmetic is independently checked.
const AB_SHA256 := "7e18f737311b2dc3b2f269dd78396b0351f14fb66efa879f768cb23181883c78"

const SAMPLE_AREAS: PackedStringArray = ["chest", "back", "shoulders", "core"]
const SAMPLE_EQUIPMENT: PackedStringArray = [
	"barbell", "machine", "cable", "dumbbell", "bodyweight",
]

## The R9 `sample_input()` shape, which is also what the emulator's debug row sends.
const SAMPLE_INPUT: Dictionary = {
	"goal": "hypertrophy",
	"days_per_week": 4,
	"duration_min": 40,
	"areas": SAMPLE_AREAS,
	"equipment": SAMPLE_EQUIPMENT,
	"notes": "",
}


func _init() -> void:
	suite_name = "plan_prompt"


func run() -> void:
	_test_versions()
	_test_system_prompt_verbatim()
	_test_system_prompt_content()
	_test_schema_block()
	_test_user_prompt_values()
	_test_user_prompt_catalog()
	_test_catalog_lines_shape()
	_test_catalog_cap()
	_test_catalog_char_cap()
	_test_catalog_determinism()
	_test_catalog_digest()
	_test_filter_records()
	_test_repair_prompt()
	_test_no_key_shaped_text()


# ------------------------------------------------------------------ constants

func _test_versions() -> void:
	begin("the prompt version is pinned and R4's limits are the documented ones")
	assert_eq(PlanPrompt.PROMPT_VERSION, "mw-plan-prompt/1", "R4's version string")
	assert_eq(PlanPrompt.CATALOG_MAX_LINES, 220, "R10's line cap")
	assert_eq(PlanPrompt.CATALOG_MAX_CHARS, 24000, "R10's character cap")
	assert_eq(PlanPrompt.REPAIR_ERRORS_MAX, 20, "at most 20 errors are sent back")
	assert_eq(PlanPrompt.REPAIR_MESSAGE_MAX, 200, "each message is truncated to 200")
	assert_eq(PlanPrompt.REPAIR_PREVIOUS_MAX, 4000, "the previous reply is sliced to 4000")
	assert_eq(PlanPrompt.NONE_TEXT, "(none)", "R4's empty-list rendering")


# ------------------------------------------------------------------ R4 system prompt

func _test_system_prompt_verbatim() -> void:
	begin("system_prompt() is byte-identical to the pinned constant")
	var prompt := PlanPrompt.system_prompt()
	assert_eq(prompt.sha256_text(), SYSTEM_SHA256, "sha256 of the prompt")
	assert_eq(prompt.to_utf8_buffer().size(), 2690, "byte length of the prompt")
	assert_eq(prompt.split("\n").size(), 36, "36 lines")
	assert_true(prompt.begins_with("You are the workout-planning engine inside MicroWorkout,"
		+ " a personal Android training app.\n"), "first line verbatim")
	assert_true(prompt.ends_with("plan that validates is far more useful than an explanation."),
		"last line verbatim, with no trailing newline")
	assert_false(prompt.begins_with("\n"), "no leading newline")
	assert_eq(PlanPrompt.SYSTEM_PROMPT, prompt, "the constant and the accessor agree")


func _test_system_prompt_content() -> void:
	begin("every rule R4 lists is actually in the prompt")
	var prompt := PlanPrompt.system_prompt()
	var required: PackedStringArray = [
		"OUTPUT CONTRACT — follow exactly:",
		"Reply with ONE JSON object and nothing else.",
		"The object must match the PLAN SCHEMA in the user message exactly.",
		"MUST be copied verbatim from the ALLOWED EXERCISES list in the user message.",
		"Never invent an id, never translate a name",
		"\"sessions\" must contain exactly DAYS_PER_WEEK objects",
		"Session \"title\" values must be different from each other",
		"\"warmup\" and \"cooldown\" each contain exactly 2 items",
		"chosen only from exercises marked \"is_stretch\"",
		"reps as a string range like \"8-10\"",
		"rest_seconds as an integer",
		"est_minutes must be within 15% of DURATION_MIN",
		"Write \"split_name\" as the split you actually used",
		"PROGRAMMING RULES:",
		"1 = Full Body; 2 = Full Body A/B; 3 = Chest & Back / Legs & Arms / Shoulders & Core",
		"4 = Chest & Back, Legs & Arms, Shoulders & Core, Chest & Back",
		"5 = Chest & Back, Legs & Arms, Shoulders & Core, Chest & Back, Legs & Arms",
		"6 = that three-day cycle twice",
		"Never put the same area in two sessions that sit next to each other",
		"If AREAS has 3 or fewer entries, use Full Body for every session instead",
		"strength = 4-5 sets, 3-6 reps, 150-180 s rest",
		"hypertrophy = 3-4 sets, 8-12 reps, 75-90 s rest",
		"general_fitness = 2-3 sets, 8-15 reps, 60-75 s rest",
		"conditioning = 2-3 sets, 12-20 reps, 30-45 s rest, circuit-style",
		"Weekly volume: at least 10 hard sets for every area in AREAS and never more than 22.",
		"Compound lifts first in each session, isolation work after.",
		"Never place two exercises with the same primary muscle back to back",
		"Cap each session at 12 working blocks. Never produce a session with zero blocks.",
		"Respect NOTES exactly",
		"treat them as hard constraints, not suggestions",
		"Do not add medical advice, warnings, encouragement, or commentary",
	]
	for line in required:
		assert_true(prompt.contains(line), "missing: %s" % line)

	begin("the prompt names no provider, no URL and no model")
	for token in PackedStringArray(["http", "api.", ".com", "openai", "anthropic", "gemini",
			"deepseek"]):
		assert_false(prompt.to_lower().contains(token), "the prompt must not mention '%s'" % token)


func _test_schema_block() -> void:
	begin("the user template carries R4's PLAN SCHEMA block verbatim")
	var template := PlanPrompt.USER_PROMPT_TEMPLATE
	assert_true(template.contains("PLAN SCHEMA (return this object, keys exactly as written):"),
		"the schema heading")
	for key in PackedStringArray(["name", "split_name", "goal", "days_per_week", "duration_min",
			"areas", "equipment", "notes", "sessions", "id", "index", "title", "focus",
			"est_minutes", "warmup", "blocks", "cooldown", "exercise_id", "sets", "reps",
			"rest_seconds", "duration_sec"]):
		assert_true(template.contains("\"%s\"" % key), "the schema names '%s'" % key)
	assert_true(template.contains("Return only the JSON object."), "the closing instruction")
	assert_true(template.contains("\"warmup\":  [{\"exercise_id\": \"<stretch id>\","
		+ " \"duration_sec\": 60}]"), "the warm-up example")
	assert_true(template.contains("\"reps\": \"8-10\", \"rest_seconds\": 90}],"),
		"the block example")

	begin("the template has exactly the seven documented placeholders")
	assert_eq(template.count("%s") + template.count("%d"), 7, "seven placeholders")
	assert_eq(template.count("%s"), 5, "five %s")
	assert_eq(template.count("%d"), 2, "two %d")


# ------------------------------------------------------------------ R4 user prompt

func _test_user_prompt_values() -> void:
	begin("user_prompt() fills the header from the request")
	var prompt := PlanPrompt.user_prompt(SAMPLE_INPUT, _sample_catalog())
	assert_true(prompt.begins_with("PLAN REQUEST\n"), "starts with the request block")
	assert_true(prompt.contains("GOAL: hypertrophy\n"), "the literal goal")
	assert_true(prompt.contains("DAYS_PER_WEEK: 4\n"), "the literal day count")
	assert_true(prompt.contains("DURATION_MIN: 40\n"), "the literal duration")
	assert_true(prompt.contains("AREAS: chest, back, shoulders, core\n"), "the literal areas")
	assert_true(prompt.contains("EQUIPMENT: barbell, machine, cable, dumbbell, bodyweight\n"),
		"the literal equipment")
	assert_true(prompt.contains("NOTES: (none)\n"), "an empty note renders as (none)")
	assert_false(prompt.contains("%s"), "no placeholder survived")

	begin("an empty AREAS/EQUIPMENT list renders as (none) too")
	var bare := PlanPrompt.user_prompt({"goal": "strength", "days_per_week": 1,
		"duration_min": 20, "areas": [], "equipment": [], "notes": ""}, [])
	assert_true(bare.contains("AREAS: (none)"), "areas")
	assert_true(bare.contains("EQUIPMENT: (none)"), "equipment")

	begin("notes are copied back verbatim")
	var noted := PlanPrompt.user_prompt({"goal": "strength", "days_per_week": 3,
		"duration_min": 60, "areas": ["legs"], "equipment": ["barbell"],
		"notes": "bad left knee, no deadlift"}, _sample_catalog())
	assert_true(noted.contains("NOTES: bad left knee, no deadlift\n"), "the user's own words")

	begin("defaults fill in for a partial request")
	var partial := PlanPrompt.user_prompt({}, [])
	assert_true(partial.contains("GOAL: %s" % Generator.DEFAULT_GOAL), "the generator's default goal")
	assert_true(partial.contains("DAYS_PER_WEEK: %d" % Generator.DEFAULT_DAYS), "default days")
	assert_true(partial.contains("DURATION_MIN: %d" % Generator.DEFAULT_DURATION_MIN),
		"default duration")

	begin("the prompt is a pure function of its arguments")
	var first := PlanPrompt.user_prompt(SAMPLE_INPUT, _sample_catalog())
	var second := PlanPrompt.user_prompt(SAMPLE_INPUT.duplicate(), _sample_catalog())
	assert_eq(first, second, "identical inputs, identical prompt")
	assert_eq(first.sha256_text(), second.sha256_text(), "byte-identical")


func _test_user_prompt_catalog() -> void:
	begin("every id in the catalog appears in the prompt")
	var catalog := _sample_catalog()
	var prompt := PlanPrompt.user_prompt(SAMPLE_INPUT, catalog)
	assert_gt(float(catalog.size()), 0.0, "the sample catalog is not empty")
	for record in catalog:
		assert_true(prompt.contains(String(record["id"])),
			"'%s' is offered to the model" % record["id"])

	begin("the catalog header line is R4's")
	assert_true(prompt.contains("ALLOWED EXERCISES (id | name | areas | equipment | type | kind "
		+ "| default sets x reps @ rest):"), "the ALLOWED EXERCISES header")

	begin("the real shipped catalog survives the prompt too")
	var real := _real_catalog()
	assert_gt(float(real.size()), 100.0, "the shipped library is large")
	var lines := PlanPrompt.catalog_lines(real)
	assert_le(float(lines.size()), float(PlanPrompt.CATALOG_MAX_LINES), "under the cap")
	var real_prompt := PlanPrompt.user_prompt(SAMPLE_INPUT, real)
	for line in lines:
		assert_true(real_prompt.contains(String(line)), "every catalog line is embedded")
	assert_true(real_prompt.contains("bench-press | Bench Press |"), "bench-press is offered")


# ------------------------------------------------------------------ R4 catalog lines

func _test_catalog_lines_shape() -> void:
	begin("a catalog line is `id | Name | areas | equipment | type | kind | sets x reps @ rest`")
	var record: Dictionary = {
		"id": "bench-press",
		"name": "Bench Press",
		"areas": ["chest", "arms", "shoulders"],
		"equipment": "Barbell",
		"exercise_type": "weight_reps",
		"is_stretch": false,
		"compound": true,
		"default_sets": 4,
		"rep_min": 8,
		"rep_max": 12,
		"rest_seconds": 90,
	}
	assert_eq(PlanPrompt.catalog_line(record),
		"bench-press | Bench Press | chest, arms, shoulders | barbell | weight_reps | compound "
		+ "| 4 x 8-12 @ 90", "the exact R4 line")
	assert_eq(PlanPrompt.catalog_line(record).split(" | ").size(), 7, "seven columns")

	begin("an isolation lift reads `isolation`, a stretch reads `stretch`")
	var isolation := record.duplicate()
	isolation["compound"] = false
	assert_true(PlanPrompt.catalog_line(isolation).contains("| isolation |"), "isolation")
	var stretch := record.duplicate()
	stretch["is_stretch"] = true
	stretch["compound"] = false
	stretch["id"] = "childs-pose"
	stretch["name"] = "Child's Pose"
	stretch["equipment"] = "Bodyweight"
	assert_true(PlanPrompt.catalog_line(stretch).contains("| stretch |"),
		"the model needs to be able to tell a stretch from a lift")

	begin("library equipment strings map to the five wizard keys")
	var bodyweight := record.duplicate()
	bodyweight["equipment"] = "Pull-up Bar"
	assert_true(PlanPrompt.catalog_line(bodyweight).contains("| bodyweight |"), "Pull-up Bar")
	var bench := record.duplicate()
	bench["equipment"] = "Bench"
	assert_true(PlanPrompt.catalog_line(bench).contains("| barbell |"), "Bench")
	var cardio := record.duplicate()
	cardio["equipment"] = "Cardio"
	assert_true(PlanPrompt.catalog_line(cardio).contains("| machine |"), "Cardio")

	begin("an empty catalog produces no lines")
	assert_empty(PlanPrompt.catalog_lines([]), "no lines")
	assert_empty(PlanPrompt.catalog_lines(_catalog_with([{}])), "a record without an id is skipped")


func _test_catalog_cap() -> void:
	begin("302 records are capped at 220 lines")
	var big := _synthetic_catalog(302)
	assert_eq(big.size(), 302, "the synthetic catalog is 302 records")
	var lines := PlanPrompt.catalog_lines(big)
	assert_eq(lines.size(), PlanPrompt.CATALOG_MAX_LINES, "exactly the 220-line cap")
	assert_le(float(lines.size()), 220.0, "and never above it")

	begin("all 13 stretch records survive the cap, at the end")
	var stretches := 0
	for line in lines:
		if String(line).contains("| stretch |"):
			stretches += 1
	assert_eq(stretches, 13,
		"every stretch is offered, because warm-up items may only be stretches")
	assert_true(String(lines[lines.size() - 1]).contains("| stretch |"), "stretches come last")

	begin("compound movements come first when the cap bites")
	var first_line := String(lines[0])
	assert_true(first_line.contains("| compound |"), "line 0 is compound: %s" % first_line)
	var compounds := 0
	var seen_isolation := false
	for line in lines:
		if String(line).contains("| compound |"):
			assert_false(seen_isolation, "a compound line appears after an isolation line")
			compounds += 1
		elif String(line).contains("| isolation |"):
			seen_isolation = true
	assert_gt(float(compounds), 0.0, "some compounds were kept")

	begin("a catalog just under the cap is untouched")
	var small := _synthetic_catalog(100)
	assert_eq(PlanPrompt.catalog_lines(small).size(), 100, "no cap applied")
	assert_eq(PlanPrompt.catalog_lines(_synthetic_catalog(220)).size(), 220, "exactly at the cap")


func _test_catalog_char_cap() -> void:
	begin("the 24 000-character cap is enforced independently of the line cap")
	var long_names := _synthetic_catalog(220, 200)
	var lines := PlanPrompt.catalog_lines(long_names)
	var total := 0
	for line in lines:
		total += String(line).length() + 1
	assert_le(float(total), float(PlanPrompt.CATALOG_MAX_CHARS), "catalog text stays under 24 000")
	assert_le(float(lines.size()), 219.0, "the character cap bit before the line cap")
	assert_gt(float(lines.size()), 0.0, "and something was still produced")

	begin("the shipped catalog is comfortably inside both caps")
	var real_lines := PlanPrompt.catalog_lines(_real_catalog())
	var real_chars := 0
	for line in real_lines:
		real_chars += String(line).length() + 1
	assert_le(float(real_chars), 24000.0, "shipped catalog characters: %d" % real_chars)
	assert_le(float(real_lines.size()), 220.0, "shipped catalog lines: %d" % real_lines.size())


func _test_catalog_determinism() -> void:
	begin("the line order does not depend on the catalog array's own order")
	var forward := _synthetic_catalog(60)
	var backward := forward.duplicate()
	backward.reverse()
	assert_eq(", ".join(PlanPrompt.catalog_lines(forward)),
		", ".join(PlanPrompt.catalog_lines(backward)), "same lines, same order")


func _test_catalog_digest() -> void:
	begin("catalog_digest() is a 64-character sha256")
	var digest := PlanPrompt.catalog_digest(PackedStringArray(["a", "b"]))
	assert_eq(digest, AB_SHA256, "sha256(\"a\\nb\"), checked independently")
	assert_eq(digest.length(), 64, "64 characters")
	var pattern := RegEx.new()
	assert_eq(pattern.compile("^[0-9a-f]{64}$"), OK, "the pattern compiles")
	assert_true(pattern.search(digest) != null, "lowercase hex only")
	assert_eq(PlanPrompt.catalog_digest(PackedStringArray()).length(), 64, "even when empty")

	begin("the digest changes with the content")
	var lines := PlanPrompt.catalog_lines(_sample_catalog())
	assert_ne(PlanPrompt.catalog_digest(lines), PlanPrompt.catalog_digest(
		PlanPrompt.catalog_lines(_synthetic_catalog(5))), "two different catalogs differ")
	assert_eq(PlanPrompt.catalog_digest(lines), PlanPrompt.catalog_digest(
		PlanPrompt.catalog_lines(_sample_catalog())), "the same catalog is stable")

	begin("the digest is a hash and never the catalog text")
	assert_false(digest.contains("bench-press"), "no id leaks into the digest")
	assert_false(PlanPrompt.catalog_digest(lines).contains("|"), "no separator either")


# ------------------------------------------------------------------ R10 filter

func _test_filter_records() -> void:
	begin("filter_records() keeps records whose areas intersect and whose equipment matches")
	var records := _mixed_catalog()
	var kept := PlanPrompt.filter_records(records, PackedStringArray(["chest"]),
		PackedStringArray(["barbell"]))
	var ids := _ids_of(kept)
	assert_true(ids.has("barbell-chest"), "a barbell chest exercise is kept")
	assert_false(ids.has("machine-chest"), "a machine exercise is filtered out by equipment")
	assert_false(ids.has("barbell-legs"), "a legs-only exercise is filtered out by area")

	begin("the stretches are kept whatever the filter says")
	assert_true(ids.has("leg-stretch"), "a legs stretch is kept for a chest-only request")
	assert_true(ids.has("shoulder-stretch"), "and so is an unrelated one")
	assert_true(ids.has("chest-stretch"), "and an on-area one")

	begin("an empty filter dimension means no constraint")
	var areas_only := _ids_of(PlanPrompt.filter_records(records, PackedStringArray(["chest"]),
		PackedStringArray()))
	assert_true(areas_only.has("machine-chest"), "no equipment constraint")
	assert_false(areas_only.has("barbell-legs"), "but the area constraint still applies")
	var equipment_only := _ids_of(PlanPrompt.filter_records(records, PackedStringArray(),
		PackedStringArray(["machine"])))
	assert_true(equipment_only.has("machine-chest"), "equipment-only filter")
	assert_false(equipment_only.has("barbell-chest"), "barbell excluded")
	var everything := PlanPrompt.filter_records(records, PackedStringArray(), PackedStringArray())
	assert_eq(everything.size(), records.size(), "no constraint keeps everything")

	begin("hostile input is skipped rather than crashing")
	var broken: Array[Dictionary] = [{}, {"id": ""}, {"id": "ok", "areas": [], "equipment": ""}]
	var survived := PlanPrompt.filter_records(broken, PackedStringArray(), PackedStringArray())
	assert_eq(survived.size(), 1, "only the record with an id survives")
	assert_eq(String(survived[0]["id"]), "ok", "and it is the right one")

	begin("the shipped library filters to a believable catalog for R9's sample input")
	var filtered := PlanPrompt.filter_records(_real_catalog(), SAMPLE_AREAS, SAMPLE_EQUIPMENT)
	assert_gt(float(filtered.size()), 60.0, "a large but bounded catalog")
	assert_le(float(filtered.size()), 203.0, "smaller than the whole library")
	var filtered_ids := _ids_of(filtered)
	assert_true(filtered_ids.has("bench-press"), "bench-press is offered")
	assert_true(filtered_ids.has("arm-circles"), "and so is a stretch")
	for id in PackedStringArray(["leg-swings-stretch", "hamstring-stretch"]):
		assert_true(filtered_ids.has(id), "%s is offered for the warm-up list" % id)


# ------------------------------------------------------------------ R4 repair prompt

func _test_repair_prompt() -> void:
	begin("repair_prompt() appends the block to the original prompt")
	var base := "PLAN REQUEST\nGOAL: hypertrophy"
	var prompt := PlanPrompt.repair_prompt(base, _errors(1), "{\"name\":\"X\"}")
	assert_true(prompt.begins_with(base), "the original prompt is still there")
	assert_true(prompt.contains("YOUR PREVIOUS REPLY FAILED VALIDATION."), "the block heading")
	assert_true(prompt.contains("VALIDATION ERRORS (each line is: code | path | problem):"),
		"the error heading")
	assert_true(prompt.contains("YOUR PREVIOUS REPLY (truncated to 4000 characters):"),
		"the previous-reply heading")
	assert_true(prompt.ends_with("Fix exactly the problems listed, change nothing else, and "
		+ "return only the JSON object."), "the closing instruction")
	assert_eq(prompt.split(base).size(), 2, "the base prompt appears exactly once")

	begin("an error renders as `code | path | message`")
	var prompt_one := PlanPrompt.repair_prompt("BASE", [{
		"code": "E_UNKNOWN_EXERCISE",
		"path": "sessions[1].blocks[2].exercise_id",
		"message": "\"incline-fly-machine\" is not in ALLOWED EXERCISES",
	}] as Array[Dictionary], "")
	assert_true(prompt_one.contains("E_UNKNOWN_EXERCISE | sessions[1].blocks[2].exercise_id | "
		+ "\"incline-fly-machine\" is not in ALLOWED EXERCISES"), "R4's exact rendering")

	begin("at most 20 errors are sent")
	var prompt_many := PlanPrompt.repair_prompt("BASE", _errors(50), "")
	assert_eq(prompt_many.count(" | sessions["), PlanPrompt.REPAIR_ERRORS_MAX, "exactly 20 lines")

	begin("each message is truncated to 200 characters")
	var long_message := "x".repeat(500)
	var prompt_long := PlanPrompt.repair_prompt("BASE", [{"code": "E_BAD_REPS", "path": "p",
		"message": long_message}] as Array[Dictionary], "")
	assert_true(prompt_long.contains("E_BAD_REPS | p | " + "x".repeat(200)), "200 characters kept")
	assert_false(prompt_long.contains("x".repeat(201)), "and the 201st is gone")

	begin("the previous reply is sliced to 4000 characters")
	var big_reply := "y".repeat(9000)
	var prompt_big := PlanPrompt.repair_prompt("BASE", _errors(0), big_reply)
	assert_true(prompt_big.contains("y".repeat(4000)), "4000 characters kept")
	assert_false(prompt_big.contains("y".repeat(4001)), "and 4001 is gone")
	assert_true(PlanPrompt.repair_prompt("BASE", _errors(0), "short").contains("short"),
		"a short reply is untouched")

	begin("an error with no message still renders its code and path")
	var bare := PlanPrompt.repair_prompt("BASE", [{"code": "E_NOT_JSON", "path": "root"}]
		as Array[Dictionary], "")
	assert_true(bare.contains("E_NOT_JSON | root | "), "code and path survive an empty message")


func _test_no_key_shaped_text() -> void:
	begin("no prompt can contain a key-shaped string (R12)")
	var pattern := RegEx.new()
	assert_eq(pattern.compile("sk-[A-Za-z0-9]{8,}"), OK, "the pattern compiles")
	var prompts: PackedStringArray = [
		PlanPrompt.system_prompt(),
		PlanPrompt.USER_PROMPT_TEMPLATE,
		PlanPrompt.REPAIR_TEMPLATE,
		PlanPrompt.user_prompt(SAMPLE_INPUT, _sample_catalog()),
		PlanPrompt.repair_prompt(PlanPrompt.user_prompt(SAMPLE_INPUT, _sample_catalog()),
			_errors(3), "{}"),
	]
	for prompt in prompts:
		assert_true(pattern.search(prompt) == null, "no key-shaped text in a prompt")
	assert_eq(PlanPrompt.system_prompt().count("sk-"), 0, "not even the prefix")


# ------------------------------------------------------------------ fixtures and helpers

func _errors(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in count:
		out.append({
			"code": "E_BAD_REPS",
			"path": "sessions[%d].blocks[0].reps" % index,
			"message": "bad reps on block %d" % index,
		})
	return out


func _catalog_with(records: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for record in records:
		if record is Dictionary:
			out.append(record)
	return out


func _ids_of(records: Array[Dictionary]) -> PackedStringArray:
	var out := PackedStringArray()
	for record in records:
		out.append(String(record.get("id", "")))
	return out


## The real library's records, straight from the core catalog loader (no autoload needed).
func _real_catalog() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var catalog := PlanModel.load_catalog()
	var ids: Array = catalog.keys()
	ids.sort()
	for id in ids:
		out.append(catalog[id])
	return out


## The areas R9's `sample_input()` asks for, filtered — the catalog the ladder embeds.
func _sample_catalog() -> Array[Dictionary]:
	return PlanPrompt.filter_records(_real_catalog(), SAMPLE_AREAS, SAMPLE_EQUIPMENT)


## A synthetic catalog for the cap tests. The last 13 records are stretches, mirroring the
## shipped library's own shape (appendix §7.2).
func _synthetic_catalog(count: int, name_length: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in count:
		var is_stretch := index >= count - 13
		var name := "Exercise %03d" % index
		if name_length > 0:
			name = name + "_" + "n".repeat(name_length)
		out.append({
			"id": "ex-%03d" % index,
			"name": name,
			"exercise_type": "weight_reps",
			"equipment": "Barbell" if index % 2 == 0 else "Dumbbell",
			"primary_muscle": "Chest",
			"secondary_muscles": [],
			"areas": ["chest"] if index % 3 == 0 else ["chest", "arms"],
			"is_stretch": is_stretch,
			"compound": (index % 4 == 0) and not is_stretch,
			"default_sets": 3,
			"rep_min": 8,
			"rep_max": 12,
			"rest_seconds": 90,
		})
	return out


## A small catalog with one record per filter dimension, for [method _test_filter_records].
func _mixed_catalog() -> Array[Dictionary]:
	return _catalog_with([
		{"id": "barbell-chest", "name": "Barbell Chest", "areas": ["chest", "arms"],
			"equipment": "Barbell", "compound": true, "is_stretch": false},
		{"id": "machine-chest", "name": "Machine Chest", "areas": ["chest"],
			"equipment": "Machine", "compound": false, "is_stretch": false},
		{"id": "barbell-legs", "name": "Barbell Legs", "areas": ["legs"],
			"equipment": "Barbell", "compound": true, "is_stretch": false},
		{"id": "chest-stretch", "name": "Chest Stretch", "areas": ["chest", "mobility"],
			"equipment": "Bodyweight", "is_stretch": true},
		{"id": "leg-stretch", "name": "Leg Stretch", "areas": ["legs", "mobility"],
			"equipment": "Bodyweight", "is_stretch": true},
		{"id": "shoulder-stretch", "name": "Shoulder Stretch", "areas": ["shoulders", "mobility"],
			"equipment": "Bodyweight", "is_stretch": true},
	])
