class_name Generator
extends RefCounted
## PRD-05 R4–R14 — the built-in, fully deterministic, seeded plan generator.
##
## `Generator.build_plan(input, seed)` turns a PRD-08 wizard input into exactly the
## PRD-00 §5.3 plan document, entirely on device with no network and no API key (D11 —
## this is the permanent offline fallback PRD-07 falls back *to*). Identical
## `(input, seed)` yields a **byte-identical** plan; the only randomness source is a
## [RandomNumberGenerator] seeded from `seed` and used solely for the per-area candidate
## rotation of R11 step 2. The global RNG helpers, `Array.shuffle()`,
## `Array.pick_random()`, any wall-clock read outside the `id`/`created_at` default path,
## any scene-tree access and any reliance on Dictionary iteration order are forbidden in
## this module (PRD-05 R14): the only wall-clock read here is the `id` default, and no
## scene-tree API is touched at all.
##
## Everything is static, node-free and scene-tree-free, and the catalog is injectable so
## the headless suites can run without the `Library` autoload (which does not exist under
## `--script`). With no injected catalog the shipped `res://data/exercise_library.json`
## is read once and cached by [method PlanModel.load_catalog].
##
## Movement pattern classification (PRD-05 R4 / PRD-04 R5) lives here as three public
## statics — [method classify], [method is_compound] and [method rank_for_ordering] —
## rather than in a separate `scripts/core/movement_patterns.gd`, because this PRD's
## owned-file list is fixed. `tests/suites/test_generator.gd` section 1 drift-tests
## `classify()` against all 204 ids in `tests/fixtures/pattern_table.json`, so folding it
## in cannot let the two implementations diverge silently.

# --- R8 session time model -------------------------------------------------
const REP_SEC: int = 3            # reps × 3 s                        (PRD-00 §7.1)
const TRANSITION_SEC: int = 12    # transition between sets            (PRD-00 §7.1)
const RESERVE_SEC: int = 480      # 8 min reserved for warm-up + cooldown
const MOBILITY_ITEM_SEC: int = 60
const WARMUP_ITEMS: int = 3       # 180 s actually spent
const COOLDOWN_ITEMS: int = 3     # 180 s actually spent
const MOBILITY_USED_SEC: int = 360
const MAX_BLOCKS: int = 12        # hard cap, PRD-00 §7.2
const MIN_BLOCKS: int = 3         # target; lowered only if the budget cannot hold 3
const MIN_SETS_PER_BLOCK: int = 2
const MAX_SETS_PER_BLOCK: int = 4
const AVG_SET_CYCLE_SEC: int = 150   # estimate only, for T

# --- R9 weekly volume ------------------------------------------------------
const WEEKLY_MIN_SETS: int = 10
const WEEKLY_MAX_SETS: int = 22
const DIRECT_FLOOR: int = 3
const SECONDARY_WEIGHT: float = 0.5
const TARGET_SETS_MIN: int = 8
const TARGET_SETS_MAX: int = 40

# --- R5 input ranges -------------------------------------------------------
const DAYS_MIN: int = 1
const DAYS_MAX: int = 6
const DURATION_MIN_LOW: int = 15
const DURATION_MIN_HIGH: int = 90
const DEFAULT_DAYS: int = 4
const DEFAULT_DURATION_MIN: int = 40
const DEFAULT_GOAL: String = "general_fitness"
const DEFAULT_EQUIPMENT: PackedStringArray = [
	"barbell", "machine", "cable", "dumbbell", "bodyweight",
]

# --- R10 prescription per goal --------------------------------------------
const GOAL_BANDS: Dictionary = {
	"strength": [3, 6],
	"hypertrophy": [8, 12],
	"general_fitness": [8, 15],
	"conditioning": [12, 20],
}
const GOAL_REST_COMPOUND: Dictionary = {
	"strength": 180, "hypertrophy": 90, "general_fitness": 75, "conditioning": 45,
}
const GOAL_REST_ISOLATION: Dictionary = {
	"strength": 150, "hypertrophy": 75, "general_fitness": 60, "conditioning": 30,
}
const SETS_DELTA: Dictionary = {
	"strength": 1, "hypertrophy": 0, "general_fitness": -1, "conditioning": -1,
}
## `reps` for `exercise_type == "duration"` records (PRD-00 §7.3 / appendix R35).
const DURATION_SECONDS: Dictionary = {
	"strength": 60, "hypertrophy": 45, "general_fitness": 45, "conditioning": 30,
}

# --- R6 split pools --------------------------------------------------------
const FULL_BODY_POOL: PackedStringArray = ["legs", "chest", "back", "shoulders", "core"]
const PUSH_POOL: PackedStringArray = ["chest", "shoulders", "arms", "core"]
const PULL_POOL: PackedStringArray = ["back", "arms", "core"]
const LEGS_POOL: PackedStringArray = ["legs", "core"]
const UPPER_A_POOL: PackedStringArray = ["chest", "back", "shoulders", "arms", "core"]
const UPPER_B_POOL: PackedStringArray = ["back", "chest", "shoulders", "arms", "core"]
const CARDIO_AREA: String = "cardio"

## R7 — which pool can host an otherwise uncovered selected area.
const HOST_POOL: Dictionary = {
	"chest": "Push", "shoulders": "Push", "arms": "Push",
	"back": "Pull", "legs": "Legs", "core": "any",
}
const HOST_MEMBERS: Dictionary = {
	"Push": ["chest", "shoulders", "arms"],
	"Pull": ["back"],
	"Legs": ["legs"],
	"any": [],
}

# --- R4 movement patterns (PRD-04 R5 re-implementation) --------------------
## First-match-wins scan of the lowercased id; `is_stretch` short-circuits to `mobility`.
## The ordered rule list and the keyword strings are byte-identical to
## `tools/build_library.py`'s `PATTERN_KEYWORDS`, which is what makes the 204-id drift
## test in section 1 of the generator suite meaningful.
const PATTERN_KEYWORDS: Array = [
	["vertical_pull", ["pulldown", "pull-up", "pullup", "chin-up", "chinup"]],
	["vertical_push", ["overhead-press", "shoulder-press", "arnold", "military-press",
		"push-press", "z-press", "pike-push-up", "handstand", "wall-walk",
		"dumbbell-press", "landmine-press"]],
	["horizontal_pull", ["row"]],
	["hinge", ["deadlift", "romanian", "good-morning", "swing", "hip-thrust", "glute-bridge",
		"back-extension", "hyperextension", "pull-through", "kickback", "nordic",
		"leg-curl", "hamstring-curl", "walkout", "reverse-hyper"]],
	["lunge", ["lunge", "split-squat", "step-up", "step-down", "cossack", "skater", "curtsy"]],
	["squat", ["squat", "leg-press", "hack", "sissy", "wall-sit"]],
	["horizontal_push", ["bench-press", "chest-press", "push-up", "pushup", "fly",
		"pec-deck", "pec", "svend", "dip", "floor-press"]],
	["calf", ["calf"]],
	["shoulder_iso", ["lateral-raise", "front-raise", "rear-delt", "face-pull", "reverse-fly",
		"y-raise", "t-raise", "snow-angel", "cuban", "scapular", "shrug"]],
	["arm_iso", ["curl", "pushdown", "skullcrusher", "skull-crusher", "triceps-extension",
		"tricep-extension", "wrist", "farmer", "grip", "hang", "crab-walk"]],
	["core_anti", ["plank", "dead-bug", "bird-dog", "hollow", "ab-wheel", "rollout", "bear",
		"crawl", "copenhagen", "l-sit", "knee-tuck", "dragon-flag", "inchworm"]],
	["core_rotation", ["twist", "chop", "pallof", "windmill", "russian", "side-bend"]],
	["core_flexion", ["crunch", "sit-up", "v-up", "leg-raise", "toe-touch", "heel-tap",
		"flutter", "rock", "captains-chair"]],
	["cardio", ["burpee", "jumping-jack", "high-knees", "jack", "rope", "shuffle", "fast-feet",
		"sprawl", "mountain-climber", "thrust", "climber", "jump-rope"]],
]
const COMPOUND_PATTERNS: PackedStringArray = [
	"squat", "hinge", "lunge", "horizontal_push", "vertical_push",
	"horizontal_pull", "vertical_pull", "cardio",
]
## `rank_for_ordering` — lower sorts first (PRD-05 R4).
const PATTERN_RANK: Dictionary = {
	"squat": 0, "hinge": 0, "horizontal_push": 0, "vertical_push": 0,
	"horizontal_pull": 0, "vertical_pull": 0,
	"lunge": 1,
	"core_anti": 2, "core_rotation": 2,
	"shoulder_iso": 3, "arm_iso": 3, "calf": 3,
	"core_flexion": 4,
	"cardio": 5, "mobility": 5,
	"other": 6,
}

# --- R12 notes filter ------------------------------------------------------
const NOTES_RULES: Array = [
	["shoulder_overhead",
		["shoulder", "rotator", "imping", "labrum", "ac joint", "overhead"]],
	["shoulder_rear", ["rear delt"]],
	["knee_loaded", ["knee", "acl", "meniscus", "patell"]],
	["knee_impact", ["knee", "patell"]],
	["lowback_spinal_load", ["lower back", "lumbar", "disc", "sciatic", "hernia"]],
	["hip_groin", ["hip", "groin", "adductor"]],
	["wrist_elbow", ["wrist", "carpal", "elbow", "tennis elbow", "golfer"]],
	["neck", ["neck", "cervical"]],
	["prenatal", ["pregnan", "prenatal"]],
	["no_impact", ["no jumping", "low impact", "quiet", "apartment", "neighbour"]],
	["no_deadlift", ["no deadlift", "avoid deadlift"]],
	["no_bench", ["no bench", "avoid bench"]],
	["no_barbell", ["no barbell", "dumbbells only", "dumbbell only"]],
	["machines_only", ["machines only", "no free weights"]],
]
const BOOST_RULES: Array = [
	[["glutes", "butt"], ["legs"]],
	[["abs", "six pack"], ["core"]],
	[["arms", "biceps", "triceps"], ["arms"]],
	[["posture", "upper back"], ["back", "shoulders"]],
]


# ===========================================================================
# R4 — movement patterns
# ===========================================================================

## PRD-04 R5's classifier, re-implemented: `is_stretch` first, then a first-match-wins
## substring scan of the lowercased id, else `"other"`.
static func classify(exercise_id: String, is_stretch: bool) -> String:
	if is_stretch:
		return "mobility"
	var slug := exercise_id.to_lower()
	for rule in PATTERN_KEYWORDS:
		var pattern := String(rule[0])
		for keyword in rule[1]:
			if slug.contains(String(keyword)):
				return pattern
	return "other"


## Prefers the record's own `compound` flag (the library's authoritative value).
static func is_compound(exercise_id: String, record: Dictionary) -> bool:
	if record.has("compound"):
		return bool(record.get("compound", false))
	return COMPOUND_PATTERNS.has(classify(exercise_id, record.get("is_stretch", false)))


static func rank_for_ordering(pattern: String) -> int:
	return int(PATTERN_RANK.get(pattern, 6))


## Library `equipment` string → one of the five wizard equipment keys (PRD-05 R11).
static func equipment_key(record: Dictionary) -> String:
	var raw := String(record.get("equipment", ""))
	match raw:
		"Pull-up Bar", "Box":
			return "bodyweight"
		"Bench", "Plate":
			return "barbell"
		"Cardio":
			return "machine"
	return raw.to_lower()


# ===========================================================================
# R5 — build_plan
# ===========================================================================

## Build the PRD-00 §5.3 plan document. `catalog` may be `{id: record}` or a raw library
## document; when empty the shipped library is used. Returns `{"error": …}` only for the
## documented failure modes (`no areas`, `library_not_loaded`) — out-of-range scalars are
## clamped and logged, never rejected. `input` is never mutated.
static func build_plan(input: Dictionary, seed: int, catalog: Dictionary = {}) -> Dictionary:
	var catalog_map := _resolve_catalog(catalog)
	if catalog_map.is_empty():
		_log("error=library_not_loaded")
		return {"error": "library_not_loaded"}

	var request := _normalize_input(input)
	if request.has("error"):
		_log("error=%s" % String(request["error"]))
		return request

	var goal := String(request["goal"])
	var days := int(request["days_per_week"])
	var duration := int(request["duration_min"])
	var areas: PackedStringArray = request["areas"]
	var notes := String(request["notes"])

	var filter := _notes_filter(request["equipment"], notes, catalog_map, areas, true)

	var available_sec := _available_sec(duration)
	if duration * 60 - RESERVE_SEC < 0:
		_log("budget_tight requested=%d available=%d blocks=%d"
			% [duration, available_sec, 2])
	var set_target := clampi(roundi(float(available_sec) / float(AVG_SET_CYCLE_SEC)),
		TARGET_SETS_MIN, TARGET_SETS_MAX)
	var capacity := days * set_target
	var area_count := areas.size()
	var floor_base := mini(WEEKLY_MIN_SETS, floori(float(capacity) / float(area_count)))
	var targets: Dictionary = {}
	var floors: Dictionary = {}
	var coverage: Dictionary = {}
	for area in areas:
		coverage[area] = 0
		var boost := float(filter["boosts"].get(area, 1.0))
		targets[area] = clampi(roundi(float(capacity) / float(area_count) * boost),
			WEEKLY_MIN_SETS, WEEKLY_MAX_SETS)
		floors[area] = floor_base

	var split := _select_split(days, area_count)
	var resolved := _resolve_focus(split, areas)
	var focuses: Array = resolved["focuses"]
	for focus in focuses:
		for area in focus:
			if coverage.has(String(area)):
				coverage[String(area)] = int(coverage[String(area)]) + 1

	var ctx: Dictionary = {
		"catalog": catalog_map,
		"sorted": _sorted_area_index(catalog_map),
		"removed": filter["removed"],
		"equipment": filter["equipment"],
		"stretch_ids": _stretch_ids(catalog_map, filter["removed"]),
		"goal": goal,
		"duration_min": duration,
		"available_sec": available_sec,
		"lower_est": int(ceil(0.85 * float(duration))),
		"targets": targets,
		"floors": floors,
		"coverage": coverage,
		"areas": areas,
		"direct": {},
		"secondary": {},
		"rng": null,
		"rx": {},
		"cheapest_set_sec": AVG_SET_CYCLE_SEC,
		"remaining": {},
		"ceiling": {},
	}

	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	ctx["rng"] = rng
	ctx["cheapest_set_sec"] = _cheapest_set_time(catalog_map, goal)

	var quota_list: Array = []
	for index in days:
		quota_list.append(_session_quotas(index, focuses, targets, coverage))

	var sessions: Array = []
	for index in days:
		ctx["remaining"] = _later_coverage(index, focuses)
		ctx["ceiling"] = _later_ceilings(index, focuses, quota_list)
		var focus := _to_psa(focuses[index])
		var quotas: Dictionary = quota_list[index]
		sessions.append(_build_session(index, String(resolved["titles"][index]), focus,
			quotas, ctx))

	var plan: Dictionary = {
		"id": String(request["id"]),
		"name": _plan_name(request, days, String(resolved["name"])),
		"created_at": String(request["created_at"]),
		"source": "builtin",
		"provider": "",
		"goal": goal,
		"days_per_week": days,
		"duration_min": duration,
		"areas": _plain_array(areas),
		"equipment": _plain_array(filter["equipment"]),
		"notes": notes,
		"split_name": String(resolved["name"]),
		"sessions": sessions,
	}
	_report_volume(plan, ctx)
	if OS.get_environment("MW_DEBUG_GEN") == "1":
		_log("fingerprint=%s" % JSON.stringify(plan, "", true).sha256_text())
	return plan


static func _plan_name(request: Dictionary, days: int, split_name: String) -> String:
	var requested := String(request["name"])
	if not requested.is_empty():
		return requested
	return "%d-Day %s" % [days, split_name]


# ===========================================================================
# R5 — input normalisation (clamp + log, never reject)
# ===========================================================================

static func _normalize_input(input: Dictionary) -> Dictionary:
	var request: Dictionary = {}

	var goal := String(input.get("goal", DEFAULT_GOAL))
	if goal == "general":
		# Appendix R32: `general_fitness` is the canonical stored key and `"general"`
		# is banned. Accepting the old spelling as an input alias keeps PRD-05 §R16's
		# literal golden inputs working while every emitted plan stays canonical.
		_log("clamp key=goal from=general to=general_fitness")
		goal = "general_fitness"
	elif not PlanModel.GOALS.has(goal):
		_log("clamp key=goal from=%s to=%s" % [goal, DEFAULT_GOAL])
		goal = DEFAULT_GOAL
	request["goal"] = goal

	request["days_per_week"] = _clamp_int(input, "days_per_week", DEFAULT_DAYS,
		DAYS_MIN, DAYS_MAX)
	request["duration_min"] = _clamp_int(input, "duration_min", DEFAULT_DURATION_MIN,
		DURATION_MIN_LOW, DURATION_MIN_HIGH)

	var areas := _normalize_areas(input.get("areas", []))
	if areas.is_empty():
		return {"error": "no areas"}
	request["areas"] = areas
	request["equipment"] = _normalize_equipment(input.get("equipment", DEFAULT_EQUIPMENT))
	request["notes"] = String(input.get("notes", ""))
	request["name"] = String(input.get("name", ""))

	# The only wall-clock reads in scripts/core/, confined to the two documented defaults.
	request["id"] = String(input.get("id", "plan-%d" % int(Time.get_unix_time_from_system())))
	request["created_at"] = String(input.get("created_at", Dates.now_iso8601(true)))
	return request


static func _clamp_int(input: Dictionary, key: String, fallback: int, lo: int, hi: int) -> int:
	var raw: Variant = input.get(key, fallback)
	var value := PlanModel.as_int(raw, fallback)
	if value < lo:
		_log("clamp key=%s from=%s to=%d" % [key, str(raw), lo])
		return lo
	if value > hi:
		_log("clamp key=%s from=%s to=%d" % [key, str(raw), hi])
		return hi
	return value


static func _normalize_areas(raw: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if not (raw is Array or raw is PackedStringArray):
		return out
	for entry in raw:
		var area := String(entry)
		if not Taxonomy.is_user_area(area):
			_log("clamp key=areas dropped=%s" % area)
			continue
		if not out.has(area):
			out.append(area)
	return out


static func _normalize_equipment(raw: Variant) -> PackedStringArray:
	var allowed := PackedStringArray()
	if raw is Array or raw is PackedStringArray:
		for entry in raw:
			var key := String(entry).to_lower()
			if DEFAULT_EQUIPMENT.has(key) and not allowed.has(key):
				allowed.append(key)
	if allowed.is_empty():
		_log("clamp key=equipment from=[] to=all")
		return DEFAULT_EQUIPMENT.duplicate()
	# Canonical order keeps the plan document stable whatever order the wizard sent.
	var out := PackedStringArray()
	for key in DEFAULT_EQUIPMENT:
		if allowed.has(key):
			out.append(key)
	return out


# ===========================================================================
# R12 — notes keyword filter
# ===========================================================================

## Report-only view of the fallback notes filter (no plan is built), for PRD-08 to show
## what the keyword filter understood.
static func notes_filter_report(input: Dictionary, catalog: Dictionary = {}) -> Dictionary:
	var catalog_map := _resolve_catalog(catalog)
	var areas := _normalize_areas(input.get("areas", Taxonomy.USER_AREAS))
	var equipment := _normalize_equipment(input.get("equipment", DEFAULT_EQUIPMENT))
	var notes := String(input.get("notes", ""))
	var filter := _notes_filter(equipment, notes, catalog_map, areas, false)
	return {
		"notes": notes,
		"matched_rules": filter["matched"],
		"removed": filter["removed"],
		"removed_count": (filter["removed"] as Dictionary).size(),
		"equipment": _plain_array(filter["equipment"]),
		"boosts": filter["boosts"],
		"rollbacks": filter["rollbacks"],
		"disabled": filter["disabled"],
	}


static func _notes_filter(equipment_in: PackedStringArray, notes: String,
		catalog: Dictionary, areas: PackedStringArray, verbose: bool) -> Dictionary:
	var lower := notes.to_lower()
	var matched: Array = []
	var removed: Dictionary = {}
	var rollbacks: Array = []
	var boosts: Dictionary = {}
	var equipment := equipment_in.duplicate()
	var disabled := false

	if lower.strip_edges().is_empty():
		return {"matched": matched, "removed": removed, "equipment": equipment,
			"boosts": boosts, "rollbacks": rollbacks, "disabled": disabled}

	for rule in NOTES_RULES:
		var rule_id := String(rule[0])
		if not _keywords_hit(lower, rule[1]):
			continue
		matched.append(rule_id)

	for rule in NOTES_RULES:
		var rule_id := String(rule[0])
		if not matched.has(rule_id):
			continue
		if rule_id == "no_barbell":
			equipment = _restrict_equipment(equipment, ["dumbbell", "bodyweight"])
			if verbose:
				_log("notes_rule id=%s removed=0 equipment=%s"
					% [rule_id, ",".join(_plain_array(equipment))])
			continue
		if rule_id == "machines_only":
			equipment = _restrict_equipment(equipment, ["machine", "cable", "bodyweight"])
			if verbose:
				_log("notes_rule id=%s removed=0 equipment=%s"
					% [rule_id, ",".join(_plain_array(equipment))])
			continue
		# Group this rule's victims by primary area so the never-rail can be applied
		# per area (R12: "< 3 candidates ⇒ roll back for that area").
		var victims: Dictionary = {}
		for exercise_id in catalog.keys():
			var record: Dictionary = catalog[exercise_id]
			if not _rule_removes(rule_id, record):
				continue
			var area := Taxonomy.primary_area(record)
			if not victims.has(area):
				victims[area] = []
			(victims[area] as Array).append(String(exercise_id))
		var areas_of_rule: Array = victims.keys()
		areas_of_rule.sort()
		var removed_count := 0
		for area in areas_of_rule:
			var pool := _candidate_count(String(area), catalog, equipment, removed)
			var pending: Array = victims[area]
			var survivors := pool
			for exercise_id in pending:
				if not removed.has(exercise_id):
					survivors -= 1
			if survivors < DIRECT_FLOOR:
				rollbacks.append({"area": String(area), "rule": rule_id})
				if verbose:
					_log("notes_rule_rollback area=%s rule=%s" % [area, rule_id])
				continue
			for exercise_id in pending:
				removed[exercise_id] = rule_id
				removed_count += 1
		if verbose:
			_log("notes_rule id=%s removed=%d" % [rule_id, removed_count])

	# Never-rails: a plan always beats a preference.
	var emptied := ""
	for area in areas:
		if _candidate_count(area, catalog, equipment, removed) == 0:
			emptied = area
			break
	if emptied.is_empty():
		var stretches := 0
		for exercise_id in catalog.keys():
			var record: Dictionary = catalog[exercise_id]
			if bool(record.get("is_stretch", false)) and not removed.has(exercise_id):
				stretches += 1
		if stretches < WARMUP_ITEMS + COOLDOWN_ITEMS:
			emptied = "mobility"
	if not emptied.is_empty():
		removed.clear()
		equipment = equipment_in.duplicate()
		disabled = true
		if verbose:
			_log("notes_filter_disabled reason=empty_area")

	for rule in BOOST_RULES:
		if not _keywords_hit(lower, rule[0]):
			continue
		for area in rule[1]:
			boosts[String(area)] = float(boosts.get(String(area), 1.0)) * 1.5
	return {"matched": matched, "removed": removed, "equipment": equipment,
		"boosts": boosts, "rollbacks": rollbacks, "disabled": disabled}


static func _keywords_hit(lower_notes: String, keywords: Array) -> bool:
	for keyword in keywords:
		if lower_notes.contains(String(keyword)):
			return true
	return false


static func _restrict_equipment(equipment: PackedStringArray, keep: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for key in DEFAULT_EQUIPMENT:
		if keep.has(key) and equipment.has(key):
			out.append(key)
	if out.is_empty():
		return equipment.duplicate()
	return out


## PRD-05 R12's removal table, one branch per rule id.
static func _rule_removes(rule_id: String, record: Dictionary) -> bool:
	var exercise_id := String(record.get("id", ""))
	var pattern := classify(exercise_id,
		bool(record.get("is_stretch", false)))
	var equipment := String(record.get("equipment", ""))
	match rule_id:
		"shoulder_overhead":
			return pattern == "vertical_push"
		"shoulder_rear":
			return pattern == "shoulder_iso" and (exercise_id.contains("rear-delt")
				or exercise_id.contains("reverse-fly") or exercise_id.contains("face-pull"))
		"knee_loaded":
			return (pattern == "squat" or pattern == "lunge") \
				and (equipment == "Barbell" or equipment == "Machine")
		"knee_impact":
			return pattern == "lunge" and exercise_id.contains("jump")
		"lowback_spinal_load":
			return pattern == "hinge" and equipment == "Barbell"
		"hip_groin":
			return pattern == "lunge" and equipment == "Barbell"
		"wrist_elbow":
			return exercise_id.begins_with("wrist-") \
				or (pattern == "horizontal_push" and equipment == "Barbell")
		"neck":
			return exercise_id.contains("shrug")
		"prenatal":
			return pattern == "core_flexion" or pattern == "core_rotation"
		"no_impact":
			for token in ["jump", "burpee", "high-knees", "skater-hop", "sprawl"]:
				if exercise_id.contains(token):
					return true
			return false
		"no_deadlift":
			return pattern == "hinge"
		"no_bench":
			return pattern == "horizontal_push" and equipment == "Barbell"
	return false


static func _candidate_count(area: String, catalog: Dictionary,
		equipment: PackedStringArray, removed: Dictionary) -> int:
	var total := 0
	for exercise_id in catalog.keys():
		var record: Dictionary = catalog[exercise_id]
		if bool(record.get("is_stretch", false)):
			continue
		if removed.has(exercise_id):
			continue
		if not equipment.has(equipment_key(record)):
			continue
		if (record.get("areas", []) as Array).has(area):
			total += 1
	return total


# ===========================================================================
# R6/R7 — split selection and focus resolution
# ===========================================================================

static func _select_split(days: int, area_count: int) -> Dictionary:
	var titles: Array = []
	var pools: Array = []
	var name := ""
	match days:
		2:
			name = "Full Body A / B"
			titles = ["Full Body A", "Full Body B"]
			pools = [FULL_BODY_POOL, FULL_BODY_POOL]
		3:
			# The conditional is evaluated literally on the selected-area count.
			if area_count <= 3:
				name = "Full Body ×3"
				titles = ["Full Body A", "Full Body B", "Full Body C"]
				pools = [FULL_BODY_POOL, FULL_BODY_POOL, FULL_BODY_POOL]
			else:
				name = "Push / Pull / Legs"
				titles = ["Push", "Pull", "Legs"]
				pools = [PUSH_POOL, PULL_POOL, LEGS_POOL]
		4:
			name = "Upper / Lower"
			titles = ["Upper A", "Lower A", "Upper B", "Lower B"]
			pools = [UPPER_A_POOL, LEGS_POOL, UPPER_B_POOL, LEGS_POOL]
		5:
			name = "Push / Pull / Legs + Upper / Lower"
			titles = ["Push", "Pull", "Legs", "Upper", "Lower"]
			pools = [PUSH_POOL, PULL_POOL, LEGS_POOL, UPPER_A_POOL, LEGS_POOL]
		6:
			name = "Push / Pull / Legs ×2"
			titles = ["Push A", "Pull A", "Legs A", "Push B", "Pull B", "Legs B"]
			pools = [PUSH_POOL, PULL_POOL, LEGS_POOL, PUSH_POOL, PULL_POOL, LEGS_POOL]
		_:
			name = "Full Body"
			titles = ["Full Body A"]
			pools = [FULL_BODY_POOL]
	return {"name": name, "titles": titles, "pools": pools}


static func _resolve_focus(split: Dictionary, areas: PackedStringArray) -> Dictionary:
	var pools: Array = split["pools"]
	var titles: Array = (split["titles"] as Array).duplicate()
	var name := String(split["name"])
	var focuses: Array = []
	var covered: Dictionary = {}
	for pool in pools:
		var focus: Array = []
		for area in pool:
			if areas.has(area):
				focus.append(String(area))
		focuses.append(focus)
		for area in focus:
			covered[String(area)] = true

	var relaxed := false
	var reason := ""
	for area in areas:
		if area == CARDIO_AREA or covered.has(area):
			continue
		var hosts := _host_sessions(String(area), pools)
		if hosts.is_empty():
			relaxed = true
			reason = "uncovered_area:%s" % area
			break
		for host in hosts:
			(focuses[int(host)] as Array).append(area)
		covered[area] = true
	if not relaxed:
		for index in focuses.size():
			if (focuses[index] as Array).is_empty():
				relaxed = true
				reason = "empty_focus:s%d" % (index + 1)
				break

	if relaxed:
		_log("split_relaxed reason=%s" % reason)
		var count := pools.size()
		name = "Full Body ×%d" % count
		titles = _full_body_titles(count)
		focuses = []
		for index in count:
			var full_focus: Array = []
			for area in FULL_BODY_POOL:
				if areas.has(area):
					full_focus.append(String(area))
			focuses.append(full_focus)
		# The R6 full-body pool omits `arms`; every relaxed session shares one pool, so
		# a selected area the pool cannot name is appended to all of them. Without this
		# a selected area could end up in `plan.areas` with zero coverage.
		var relaxed_covered: Dictionary = {}
		for focus in focuses:
			for area in focus:
				relaxed_covered[String(area)] = true
		for area in areas:
			if area == CARDIO_AREA or relaxed_covered.has(area):
				continue
			for focus in focuses:
				(focus as Array).append(area)

	if areas.has(CARDIO_AREA):
		for focus in focuses:
			var typed: Array = focus
			if not typed.has(CARDIO_AREA):
				typed.append(CARDIO_AREA)
	return {"name": name, "titles": titles, "focuses": focuses, "relaxed": relaxed}


static func _full_body_titles(count: int) -> Array:
	var out: Array = []
	for index in count:
		out.append("Full Body %s" % String.chr(65 + index))
	return out


## R7 step 1 — every session whose pool can host this otherwise uncovered area.
static func _host_sessions(area: String, pools: Array) -> Array:
	var group := String(HOST_POOL.get(area, ""))
	var out: Array = []
	if group.is_empty():
		return out
	var members: Array = HOST_MEMBERS.get(group, [])
	for index in pools.size():
		if group == "any":
			out.append(index)
			continue
		var pool: PackedStringArray = pools[index]
		for member in members:
			if pool.has(String(member)):
				out.append(index)
				break
	return out


## How many sessions after `index` still train each area (the `effective` reserve).
static func _later_coverage(index: int, focuses: Array) -> Dictionary:
	var out: Dictionary = {}
	for area in Taxonomy.USER_AREAS:
		out[area] = 0
	for other in range(index + 1, focuses.size()):
		for entry in (focuses[other] as Array):
			if out.has(String(entry)):
				out[String(entry)] = int(out[String(entry)]) + 1
	return out


## The hard direct-volume ceiling for one session, per area: the weekly cap minus what
## the sessions after this one are entitled to (their R9 quota, and at least
## MIN_SETS_PER_BLOCK each). This is what spreads the weekly volume evenly across the
## week instead of letting session 1 absorb the whole cap and starve session 6 — and it
## guarantees every later session can still place at least one legal block (V11).
static func _later_ceilings(index: int, focuses: Array, quota_list: Array) -> Dictionary:
	var out: Dictionary = {}
	for area in Taxonomy.USER_AREAS:
		var entitled := 0
		var later := 0
		for other in range(index + 1, focuses.size()):
			if (focuses[other] as Array).has(area):
				later += 1
				entitled += int((quota_list[other] as Dictionary).get(area, 0))
		out[area] = WEEKLY_MAX_SETS - maxi(entitled, MIN_SETS_PER_BLOCK * later)
	return out


static func _session_quotas(index: int, focuses: Array, targets: Dictionary,
		coverage: Dictionary) -> Dictionary:
	var quotas: Dictionary = {}
	var focus: Array = focuses[index]
	for entry in focus:
		var area := String(entry)
		var cover := maxi(1, int(coverage.get(area, 1)))
		var target := int(targets.get(area, WEEKLY_MIN_SETS))
		var base := target / cover
		var remainder := target % cover
		var rank := 0
		for other in focuses.size():
			if (focuses[other] as Array).has(area) and other < index:
				rank += 1
		quotas[area] = base + (1 if rank < remainder else 0)
	return quotas


# ===========================================================================
# Candidate index and ordering (R11 steps 1–2)
# ===========================================================================

## `area → Array[record]`, non-stretch records only, sorted with the **total** comparator
## of R11 step 1. Appendix R40 additionally breaks ties by area: a record whose *primary*
## area is the requested area sorts ahead of one that merely lists it as a secondary area.
static func _sorted_area_index(catalog: Dictionary) -> Dictionary:
	var index: Dictionary = {}
	var ids: Array = catalog.keys()
	ids.sort()
	for exercise_id in ids:
		var record: Dictionary = catalog[exercise_id]
		if bool(record.get("is_stretch", false)):
			continue
		var pattern := classify(String(exercise_id), false)
		var rank := rank_for_ordering(pattern)
		var compound := 0 if bool(record.get("compound", false)) else 1
		var sets := -PlanModel.as_int(record.get("default_sets"), 0)
		for area in record.get("areas", []):
			var key := String(area)
			if not index.has(key):
				index[key] = []
			(index[key] as Array).append({
				"record": record,
				"rank": rank,
				"compound": compound,
				"primary": 0 if key == Taxonomy.primary_area(record) else 1,
				"sets": sets,
				"id": String(exercise_id),
			})
	for key in index.keys():
		(index[key] as Array).sort_custom(_compare_candidates)
		var records: Array = []
		for entry in index[key]:
			records.append((entry as Dictionary)["record"])
		index[key] = records
	return index


static func _compare_candidates(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left["rank"]) != int(right["rank"]):
		return int(left["rank"]) < int(right["rank"])
	if int(left["compound"]) != int(right["compound"]):
		return int(left["compound"]) < int(right["compound"])
	if int(left["primary"]) != int(right["primary"]):
		return int(left["primary"]) < int(right["primary"])
	if int(left["sets"]) != int(right["sets"]):
		return int(left["sets"]) < int(right["sets"])
	return String(left["id"]) < String(right["id"])


static func _filter_area(area: String, ctx: Dictionary,
		equipment: PackedStringArray) -> Array:
	var out: Array = []
	var removed: Dictionary = ctx["removed"]
	for record in (ctx["sorted"] as Dictionary).get(area, []):
		var exercise_id := String((record as Dictionary).get("id", ""))
		if removed.has(exercise_id):
			continue
		if not equipment.has(equipment_key(record)):
			continue
		out.append(record)
	return out


## R11 step 1–2, plus the appendix §8 risk-table equipment ladder: an area with no
## equipment-legal candidate widens one step (logged) before its quota is dropped.
static func _queue_for(area: String, ctx: Dictionary) -> Array:
	var filtered := _filter_area(area, ctx, ctx["equipment"])
	if filtered.is_empty():
		filtered = _relax_equipment(area, ctx)
	return _rotate_queue(filtered, area, ctx)


## R11 step 2's rotation, applied to the two halves of the queue separately so the
## appendix R40 "break candidate-queue ties by area" rule survives the shuffle: the
## records whose **primary** area is the requested area stay ahead of the ones that
## merely list it as a secondary area, and the injected RNG only reorders within each
## half (and only for halves larger than 3). This is the sole consumer of `ctx.rng`.
static func _rotate_queue(records: Array, area: String, ctx: Dictionary) -> Array:
	var primary: Array = []
	var secondary: Array = []
	for record in records:
		if Taxonomy.primary_area(record) == area:
			primary.append(record)
		else:
			secondary.append(record)
	var rng: RandomNumberGenerator = ctx["rng"]
	if primary.size() > 3:
		primary = _rotate_array(primary, rng.randi_range(0, primary.size() - 1))
	if secondary.size() > 3:
		secondary = _rotate_array(secondary, rng.randi_range(0, secondary.size() - 1))
	var out: Array = []
	out.append_array(primary)
	out.append_array(secondary)
	return out


static func _relax_equipment(area: String, ctx: Dictionary) -> Array:
	var base: PackedStringArray = ctx["equipment"]
	for extra in DEFAULT_EQUIPMENT:
		if base.has(extra):
			continue
		var widened := base.duplicate()
		widened.append(extra)
		var out := _filter_area(area, ctx, widened)
		if not out.is_empty():
			_log("equipment_relaxed area=%s added=%s" % [area, extra])
			return out
	var all := _filter_area(area, ctx, DEFAULT_EQUIPMENT)
	if not all.is_empty():
		_log("equipment_relaxed area=%s added=any" % area)
	return all


static func _stretch_ids(catalog: Dictionary, removed: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for exercise_id in catalog.keys():
		var record: Dictionary = catalog[exercise_id]
		if not bool(record.get("is_stretch", false)):
			continue
		if removed.has(exercise_id):
			continue
		out.append(String(exercise_id))
	out.sort()
	return out


# ===========================================================================
# R10 — prescription
# ===========================================================================

static func _prescribe(record: Dictionary, goal: String) -> Dictionary:
	var band: Array = GOAL_BANDS.get(goal, GOAL_BANDS[DEFAULT_GOAL])
	var sets := clampi(PlanModel.as_int(record.get("default_sets"), 3)
		+ int(SETS_DELTA.get(goal, 0)), MIN_SETS_PER_BLOCK, MAX_SETS_PER_BLOCK)
	var reps := ""
	if String(record.get("exercise_type", "")) == "duration":
		reps = "%ds" % int(DURATION_SECONDS.get(goal, 45))
	else:
		var lo := maxi(PlanModel.as_int(record.get("rep_min"), int(band[0])), int(band[0]))
		var hi := mini(PlanModel.as_int(record.get("rep_max"), int(band[1])), int(band[1]))
		if lo >= hi:
			lo = int(band[0])
			hi = int(band[1])
		if lo == hi:
			reps = "%d" % lo
		else:
			reps = "%d-%d" % [lo, hi]
	var compound := bool(record.get("compound", false))
	var rest := int(GOAL_REST_COMPOUND.get(goal, 75))
	if not compound:
		rest = int(GOAL_REST_ISOLATION.get(goal, 60))
	return {"sets": sets, "reps": reps, "rest": clampi(rest, 15, 300)}


## R8 `set_time(reps, rest) = reps_used * REP_SEC + TRANSITION_SEC + rest`, with
## `reps_used` the top of the prescribed range or the seconds value of an `"Ns"` block.
static func _reps_used(reps: String) -> int:
	if reps.ends_with("s"):
		return maxi(1, reps.substr(0, reps.length() - 1).to_int())
	if reps.contains("-"):
		var parts := reps.split("-", false)
		if parts.size() == 2:
			return maxi(1, parts[1].to_int())
	return maxi(1, reps.to_int())


static func _set_time(reps: String, rest: int) -> int:
	return _reps_used(reps) * REP_SEC + TRANSITION_SEC + rest


static func _block_time(record: Dictionary, goal: String, sets: int) -> int:
	var prescription := _prescribe(record, goal)
	return sets * _set_time(String(prescription["reps"]), int(prescription["rest"]))


## Memoised `_prescribe` for the current plan (the goal is fixed for a whole build).
static func _rx(ctx: Dictionary, record: Dictionary) -> Dictionary:
	var cache: Dictionary = ctx["rx"]
	var exercise_id := String(record.get("id", ""))
	if cache.has(exercise_id):
		return cache[exercise_id]
	var prescription := _prescribe(record, String(ctx["goal"]))
	cache[exercise_id] = prescription
	return prescription


## The cheapest single set in the catalog for this goal — how many sets a session can
## possibly absorb from `available_sec`.
static func _cheapest_set_time(catalog: Dictionary, goal: String) -> int:
	var cheapest := AVG_SET_CYCLE_SEC * 2
	for exercise_id in catalog.keys():
		var record: Dictionary = catalog[exercise_id]
		if bool(record.get("is_stretch", false)):
			continue
		var prescription := _prescribe(record, goal)
		cheapest = mini(cheapest, _set_time(String(prescription["reps"]),
			int(prescription["rest"])))
	return maxi(1, cheapest)


## `0.85 * duration_min <= est_minutes <= 1.05 * duration_min` (PRD-05 R8).
static func _est_in_window(est_minutes: int, duration_min: int) -> bool:
	if duration_min <= 0:
		return false
	return float(est_minutes) >= 0.85 * float(duration_min) \
		and float(est_minutes) <= 1.05 * float(duration_min)


static func _duration_delta(est_minutes: int, duration_min: int) -> float:
	if duration_min <= 0:
		return 0.0
	return snappedf(100.0 * (float(est_minutes) - float(duration_min)) / float(duration_min), 0.1)


## Sessions outside the ±15 % duration window with their signed delta, as a pure
## function of the plan. `build_plan` logs exactly one `[gen] duration …` line per entry,
## so a miss can never be silent (R8) and a test can assert the two agree.
static func duration_misses(plan: Dictionary) -> Dictionary:
	var requested := PlanModel.as_int(plan.get("duration_min"), 0)
	var out: Dictionary = {}
	if requested <= 0:
		return out
	for session in plan.get("sessions", []):
		var entry: Dictionary = session
		var est := PlanModel.as_int(entry.get("est_minutes"), 0)
		if _est_in_window(est, requested):
			continue
		out[String(entry.get("id", ""))] = _duration_delta(est, requested)
	return out


static func _est_minutes(total_sec: int) -> int:
	return roundi(float(MOBILITY_USED_SEC + total_sec) / 60.0)


static func _available_sec(duration_min: int) -> int:
	var available := duration_min * 60 - RESERVE_SEC
	if available < 0:
		available = maxi(300, duration_min * 30)
	return available


# ===========================================================================
# R11 + R8 — session construction
# ===========================================================================

static func _build_session(index: int, title: String, focus_in: PackedStringArray,
		quotas: Dictionary, ctx: Dictionary) -> Dictionary:
	var focus := focus_in.duplicate()
	var budget: int = int(ctx["available_sec"])
	var target_sets := _session_set_budget(ctx, budget)

	# Widening is decided *before* filling so the weekly counters are mutated exactly
	# once per session. A session whose own areas cannot absorb the session budget
	# (too few remaining weekly sets, or no candidates) borrows the user's other
	# selected areas instead of emitting a six-minute session or blowing the 22-set cap.
	if _should_widen(focus, ctx, target_sets):
		var widened := _widen_focus(focus, ctx["areas"])
		_log("session_widened session=s%d reason=budget added=%d"
			% [index + 1, widened.size() - focus.size()])
		focus = widened

	# R8 pass 1 — the quota-driven greedy fill plus the cardio finisher (R11 step 5).
	var result := _fill_session(focus, quotas, ctx)
	var blocks: Array = result["blocks"]
	var cardio: Array = result["cardio"]
	var total: int = int(result["total_sec"])
	# R8 pass 2 — top-up: grow existing blocks one set at a time.
	total = _top_up(blocks, cardio, total, ctx, budget)
	# R8 pass 3 — append: 2-set blocks for areas still holding quota.
	total = _append_pass(blocks, cardio, focus, quotas, total, ctx, budget,
		result["queues"], result["used"])
	var est := _est_minutes(total)

	var lower: int = int(ctx["lower_est"])
	var requested: int = int(ctx["duration_min"])
	# R38 keeps RESERVE_SEC = 480 for block budgeting while only 360 s of mobility is
	# actually spent; the 120 s difference is documented slack inside the ±5 % window.
	# At short durations (15–20 min) whole sets no longer fit in the strict budget, so
	# the lower bound is policed against the full session length instead.
	if est < lower:
		var slack_budget := requested * 60 - MOBILITY_USED_SEC
		var before := total
		total = _top_up(blocks, cardio, total, ctx, slack_budget)
		total = _append_pass(blocks, cardio, focus, quotas, total, ctx, slack_budget,
			result["queues"], result["used"])
		if total > before:
			_log("slack_fill session=s%d added=%d" % [index + 1, total - before])
			est = _est_minutes(total)
	if not _est_in_window(est, requested):
		_log("duration session=s%d requested=%d est=%d delta=%+.1f%%" % [index + 1,
			requested, est, _duration_delta(est, requested)])
	if blocks.size() + cardio.size() < MIN_BLOCKS:
		_log("blocks session=s%d count=%d reason=time_budget"
			% [index + 1, blocks.size() + cardio.size()])

	if blocks.is_empty() and cardio.is_empty():
		# PRD-00 §7.2's "never generate a session with 0 blocks" rail is absolute: if the
		# budget or the volume ceilings left nothing placeable, one block is forced in.
		var rescue := _rescue_block(focus, ctx, result["used"])
		if not rescue.is_empty():
			total += int(rescue["time"])
			blocks.append(rescue)
			est = _est_minutes(total)
			_log("session_rescue session=s%d id=%s sets=%d"
				% [index + 1, String((rescue["record"] as Dictionary).get("id", "")),
					int(rescue["sets"])])

	var mobility := _mobility_picks(index, focus, ctx)
	var session: Dictionary = {
		"id": "s%d" % (index + 1),
		"index": index,
		"title": title,
		"focus": _plain_array(focus),
		"est_minutes": est,
		"warmup": mobility["warmup"],
		"blocks": _block_dicts(blocks, cardio, ctx),
		"cooldown": mobility["cooldown"],
	}
	return session


## The cardio finisher is always the final block slot (R7 + R11 step 5), so working
## blocks come first and the cardio blocks are concatenated after them.
static func _block_dicts(blocks: Array, cardio: Array, ctx: Dictionary) -> Array:
	var out: Array = []
	for entry in blocks + cardio:
		var item: Dictionary = entry
		var record: Dictionary = item["record"]
		var prescription := _rx(ctx, record)
		out.append({
			"exercise_id": String(record.get("id", "")),
			"sets": int(item["sets"]),
			"reps": String(prescription["reps"]),
			"rest_seconds": int(prescription["rest"]),
		})
	return out


static func _session_set_budget(ctx: Dictionary, budget: int) -> int:
	var cheapest := maxi(1, int(ctx["cheapest_set_sec"]))
	return maxi(1, floori(float(budget) / float(cheapest)))


static func _should_widen(focus: PackedStringArray, ctx: Dictionary, target_sets: int) -> bool:
	if focus.size() >= (ctx["areas"] as PackedStringArray).size():
		return false
	var need := 0
	var direct: Dictionary = ctx["direct"]
	var targets: Dictionary = ctx["targets"]
	for area in focus:
		need += maxi(0, int(targets.get(area, 0)) - int(direct.get(area, 0)))
	return need < target_sets


static func _widen_focus(focus: PackedStringArray, areas: PackedStringArray) -> PackedStringArray:
	var out := focus.duplicate()
	for area in Taxonomy.USER_AREAS:
		if areas.has(area) and not out.has(area):
			out.append(area)
	if out.has(CARDIO_AREA):
		out.remove_at(out.find(CARDIO_AREA))
		out.append(CARDIO_AREA)
	return out


static func _fill_session(focus: PackedStringArray, quotas: Dictionary,
		ctx: Dictionary) -> Dictionary:
	var queues: Dictionary = {}
	for area in focus:
		queues[area] = _queue_for(area, ctx)
	var used: Dictionary = {}
	var blocked: Dictionary = {}
	var blocks: Array = []
	var cardio: Array = []
	var total := 0
	var budget: int = int(ctx["available_sec"])
	var phase := 0
	var cardio_reserve := _cardio_reserve(focus, queues, ctx)

	# Working blocks first; `cardio` is deliberately excluded here so it can never end
	# up anywhere but last.
	while blocks.size() < MAX_BLOCKS:
		var last_muscle := _last_muscle(blocks, cardio, ctx)
		var pick := _pick(queues, quotas, ctx, blocked, used, focus, phase,
			total, budget, cardio_reserve, last_muscle)
		if pick.is_empty():
			if phase == 0:
				phase = 1
				blocked.clear()
				continue
			break
		var area := String(pick["area"])
		var queue: Array = queues[area]
		var record: Dictionary = queue[int(pick["index"])]
		var sets := int(pick["sets"])
		var time := sets * _set_time(String(pick["reps"]), int(pick["rest"]))
		queue.remove_at(int(pick["index"]))
		used[String(record.get("id", ""))] = true
		_apply_volume(ctx, record, sets)
		quotas[area] = maxi(0, int(quotas.get(area, 0)) - sets)
		total += time
		blocks.append({"area": area, "record": record, "sets": sets})

	# R11 step 5 — cardio finisher in the last block slot.
	if focus.has(CARDIO_AREA):
		var cardio_queue: Array = queues.get(CARDIO_AREA, [])
		while blocks.size() + cardio.size() < MAX_BLOCKS:
			var last := _last_muscle(blocks, cardio, ctx)
			var index := -1
			var sets := 0
			var step := 0
			for scan in cardio_queue.size():
				var candidate: Dictionary = cardio_queue[scan]
				if used.has(String(candidate.get("id", ""))):
					continue
				if not last.is_empty() \
						and String(candidate.get("primary_muscle", "")) == last:
					continue
				var candidate_rx := _rx(ctx, candidate)
				var candidate_sets := _sets_within_cap(ctx, candidate,
					int(candidate_rx["sets"]))
				var candidate_step := _set_time(String(candidate_rx["reps"]),
					int(candidate_rx["rest"]))
				while candidate_sets >= MIN_SETS_PER_BLOCK \
						and total + candidate_sets * candidate_step > budget:
					candidate_sets -= 1
				if candidate_sets < MIN_SETS_PER_BLOCK:
					continue
				index = scan
				sets = candidate_sets
				step = candidate_step
				break
			if index < 0:
				break
			var record: Dictionary = cardio_queue[index]
			cardio_queue.remove_at(index)
			used[String(record.get("id", ""))] = true
			_apply_volume(ctx, record, sets)
			quotas[CARDIO_AREA] = maxi(0, int(quotas.get(CARDIO_AREA, 0)) - sets)
			total += sets * step
			cardio.append({"area": CARDIO_AREA, "record": record, "sets": sets})
	return {"blocks": blocks, "cardio": cardio, "total_sec": total,
		"queues": queues, "used": used}


## Last-resort block for a session the filler could not populate. Ignores the session
## budget and the entitlement ceiling (the hard weekly cap still applies), prefers the
## cheapest placeable record of the first focus area, and needs no RNG.
static func _rescue_block(focus: PackedStringArray, ctx: Dictionary,
		used: Dictionary) -> Dictionary:
	var best: Dictionary = {}
	var best_time := 0
	for entry in focus:
		var area := String(entry)
		var queue: Array = _rotate_queue(_filter_area(area, ctx, ctx["equipment"]), area, ctx)
		if queue.is_empty():
			queue = _relax_equipment(area, ctx)
		for record in queue:
			if used.has(String((record as Dictionary).get("id", ""))):
				continue
			for sets in range(MIN_SETS_PER_BLOCK, 0, -1):
				if not _can_add(ctx, record, sets):
					continue
				var prescription := _rx(ctx, record)
				var time := sets * _set_time(String(prescription["reps"]),
					int(prescription["rest"]))
				if best.is_empty() or time < best_time:
					best = {"area": area, "record": record, "sets": sets, "time": time}
					best_time = time
				break
	if best.is_empty():
		return best
	_apply_volume(ctx, best["record"], int(best["sets"]))
	return best


static func _cardio_reserve(focus: PackedStringArray, queues: Dictionary,
		ctx: Dictionary) -> int:
	if not focus.has(CARDIO_AREA):
		return 0
	var queue: Array = queues.get(CARDIO_AREA, [])
	if queue.is_empty():
		return 0
	var prescription := _rx(ctx, queue[0])
	return MIN_SETS_PER_BLOCK * _set_time(String(prescription["reps"]),
		int(prescription["rest"]))


static func _last_muscle(blocks: Array, cardio: Array, ctx: Dictionary) -> String:
	var catalog: Dictionary = ctx["catalog"]
	var last_id := ""
	if not cardio.is_empty():
		last_id = String(((cardio[cardio.size() - 1] as Dictionary)["record"] as Dictionary)
			.get("id", ""))
	elif not blocks.is_empty():
		last_id = String(((blocks[blocks.size() - 1] as Dictionary)["record"] as Dictionary)
			.get("id", ""))
	if last_id.is_empty():
		return ""
	var record: Dictionary = catalog.get(last_id, {})
	return String(record.get("primary_muscle", ""))


## Choose the next (area, record, sets) triple. Phase 0 is the quota-driven greedy fill
## of R11 step 4; phase 1 falls back to the largest remaining weekly need so a session
## still fills its time budget once every per-session quota is met.
static func _pick(queues: Dictionary, quotas: Dictionary, ctx: Dictionary,
		blocked: Dictionary, used: Dictionary, focus: PackedStringArray, phase: int,
		total: int, budget: int, cardio_reserve: int, last_muscle: String) -> Dictionary:
	var best: Dictionary = {}
	var best_score: Array = []
	var targets: Dictionary = ctx["targets"]
	var direct: Dictionary = ctx["direct"]
	for order in focus.size():
		var area := String(focus[order])
		if area == CARDIO_AREA or blocked.has(area):
			continue
		var quota := int(quotas.get(area, 0))
		if phase == 0 and quota <= 0:
			continue
		var queue: Array = queues.get(area, [])
		var index := -1
		var sets := 0
		var prescription: Dictionary = {}
		# First legal record wins, but a record that cannot fit the remaining budget
		# (and a MIN_SETS_PER_BLOCK block that cannot either) is skipped rather than
		# blocking the whole area — otherwise one expensive `duration` record could
		# leave a session with no blocks at all.
		for scan in queue.size():
			var candidate: Dictionary = queue[scan]
			if used.has(String(candidate.get("id", ""))):
				continue
			if not last_muscle.is_empty() \
					and String(candidate.get("primary_muscle", "")) == last_muscle:
				continue
			var candidate_rx := _rx(ctx, candidate)
			var candidate_sets := _sets_within_cap(ctx, candidate,
				int(candidate_rx["sets"]))
			if candidate_sets < MIN_SETS_PER_BLOCK:
				continue
			var candidate_step := _set_time(String(candidate_rx["reps"]),
				int(candidate_rx["rest"]))
			if total + candidate_sets * candidate_step + cardio_reserve > budget:
				candidate_sets = MIN_SETS_PER_BLOCK
				if total + candidate_sets * candidate_step + cardio_reserve > budget:
					continue
			index = scan
			sets = candidate_sets
			prescription = candidate_rx
			break
		if index < 0:
			blocked[area] = true
			continue
		var record: Dictionary = queue[index]
		var step := _set_time(String(prescription["reps"]), int(prescription["rest"]))
		var need := maxi(0, int(targets.get(area, 0)) - int(direct.get(area, 0)))
		# `order` is the position in `focus`; a lower value is better (R11 step 4:
		# "ties → earlier in focus"), which is what `_score_better` compares last.
		var score: Array = [quota if phase == 0 else need, need, order]
		if best.is_empty() or _score_better(score, best_score):
			best = {"area": area, "index": index, "record": record, "sets": sets,
				"reps": String(prescription["reps"]), "rest": int(prescription["rest"]),
				"score": score}
			best_score = score
	return best


static func _score_better(candidate: Array, incumbent: Array) -> bool:
	if int(candidate[0]) != int(incumbent[0]):
		return int(candidate[0]) > int(incumbent[0])
	if int(candidate[1]) != int(incumbent[1]):
		return int(candidate[1]) > int(incumbent[1])
	return int(candidate[2]) < int(incumbent[2])


## The first unused queue entry that does not repeat the previous block's
## `primary_muscle` (R11 step 3 — the PRD-00 §7.2 anti-adjacency rail).
static func _legal_index(queue: Array, used: Dictionary, last_muscle: String) -> int:
	for index in queue.size():
		var record: Dictionary = queue[index]
		if used.has(String(record.get("id", ""))):
			continue
		if not last_muscle.is_empty() and String(record.get("primary_muscle", "")) == last_muscle:
			continue
		return index
	return -1


static func _top_up(blocks: Array, cardio: Array, total: int, ctx: Dictionary,
		budget: int) -> int:
	var lower: int = int(ctx["lower_est"])
	var current := total
	while _est_minutes(current) < lower:
		var progressed := false
		for entry in blocks + cardio:
			var item: Dictionary = entry
			if int(item["sets"]) >= MAX_SETS_PER_BLOCK:
				continue
			var record: Dictionary = item["record"]
			if not _can_add(ctx, record, 1):
				continue
			var prescription := _rx(ctx, record)
			var time := _set_time(String(prescription["reps"]), int(prescription["rest"]))
			if current + time > budget:
				continue
			item["sets"] = int(item["sets"]) + 1
			current += time
			_apply_volume(ctx, record, 1)
			progressed = true
			if _est_minutes(current) >= lower:
				break
		if not progressed:
			break
	return current


static func _append_pass(blocks: Array, cardio: Array, focus: PackedStringArray,
		quotas: Dictionary, total: int, ctx: Dictionary, budget: int, queues: Dictionary,
		used: Dictionary) -> int:
	var lower: int = int(ctx["lower_est"])
	var current := total
	while blocks.size() + cardio.size() < MAX_BLOCKS and _est_minutes(current) < lower:
		var placed := false
		for order in focus.size():
			var area := String(focus[order])
			if area == CARDIO_AREA or int(quotas.get(area, 0)) <= 0:
				continue
			var queue: Array = queues.get(area, [])
			var last_muscle := _last_muscle(blocks, cardio, ctx)
			var index := _legal_index(queue, used, last_muscle)
			if index < 0:
				continue
			var record: Dictionary = queue[index]
			if not _can_add(ctx, record, MIN_SETS_PER_BLOCK):
				continue
			var prescription := _rx(ctx, record)
			var time := MIN_SETS_PER_BLOCK * _set_time(String(prescription["reps"]),
				int(prescription["rest"]))
			if current + time > budget:
				continue
			queue.remove_at(index)
			used[String(record.get("id", ""))] = true
			_apply_volume(ctx, record, MIN_SETS_PER_BLOCK)
			quotas[area] = maxi(0, int(quotas.get(area, 0)) - MIN_SETS_PER_BLOCK)
			current += time
			blocks.append({"area": area, "record": record, "sets": MIN_SETS_PER_BLOCK})
			placed = true
			break
		if not placed:
			break
	return current


# ===========================================================================
# R9 — weekly volume accounting
# ===========================================================================

## Result of adding `sets` of `record`: `effective = direct + 0.5 × secondary`.
static func _effective(direct: int, secondary: int) -> float:
	return float(direct) + SECONDARY_WEIGHT * float(secondary)


static func _can_add(ctx: Dictionary, record: Dictionary, sets: int) -> bool:
	if sets <= 0:
		return false
	var direct: Dictionary = ctx["direct"]
	var secondary: Dictionary = ctx["secondary"]
	var reserve: Dictionary = ctx["remaining"]
	var primary := Taxonomy.primary_area(record)
	# Two ceilings: the *entitlement* ceiling (this session may not eat the volume the
	# later sessions were promised) and the hard weekly cap of R9. `remaining` reserves
	# 1.0 of `effective` per later session so a later session can always place a block.
	var ceiling: Dictionary = ctx["ceiling"]
	var left := int(reserve.get(primary, 0))
	var direct_ceiling := mini(WEEKLY_MAX_SETS,
		int(ceiling.get(primary, WEEKLY_MAX_SETS)))
	if int(direct.get(primary, 0)) + sets > direct_ceiling:
		return false
	if _effective(int(direct.get(primary, 0)), int(secondary.get(primary, 0))) + float(sets) \
			> float(WEEKLY_MAX_SETS - left):
		return false
	for area in Taxonomy.secondary_areas(record):
		var later := int(reserve.get(area, 0))
		var added := SECONDARY_WEIGHT * float(sets)
		if _effective(int(direct.get(area, 0)), int(secondary.get(area, 0))) + added \
				> float(WEEKLY_MAX_SETS - later):
			return false
	return true


## The largest set count ≤ `want` that keeps every area's `effective` ≤ WEEKLY_MAX_SETS.
static func _sets_within_cap(ctx: Dictionary, record: Dictionary, want: int) -> int:
	var sets := want
	while sets >= MIN_SETS_PER_BLOCK:
		if _can_add(ctx, record, sets):
			return sets
		sets -= 1
	return 0


static func _apply_volume(ctx: Dictionary, record: Dictionary, sets: int) -> void:
	var direct: Dictionary = ctx["direct"]
	var secondary: Dictionary = ctx["secondary"]
	var primary := Taxonomy.primary_area(record)
	direct[primary] = int(direct.get(primary, 0)) + sets
	for area in Taxonomy.secondary_areas(record):
		secondary[area] = int(secondary.get(area, 0)) + sets


static func _report_volume(plan: Dictionary, ctx: Dictionary) -> void:
	var floors: Dictionary = ctx["floors"]
	var table := volume_table(plan, ctx["catalog"] as Dictionary)
	var areas: PackedStringArray = ctx["areas"]
	for area in areas:
		var row: Dictionary = table.get(area, {})
		if row.is_empty():
			continue
		var floor := int(floors.get(area, 0))
		var effective: Variant = row["effective"]
		var below_floor := float(effective) < float(floor)
		var below_direct := int(row["direct"]) < DIRECT_FLOOR
		if not below_floor and not below_direct:
			continue
		var reason := "time_budget"
		if not below_floor and below_direct:
			reason = "coverage_limit"
		_log("volume_shortfall area=%s direct=%d effective=%s floor=%d reason=%s"
			% [area, int(row["direct"]), str(effective), floor, reason])


## PRD-05 R9 — a pure function of the plan document (the §5.3 schema is not extended).
## `effective = direct + 0.5 × secondary`; whole results are reported as ints.
static func volume_table(plan: Dictionary, catalog: Dictionary = {}) -> Dictionary:
	var catalog_map := catalog
	if catalog_map.is_empty():
		catalog_map = _resolve_catalog({})
	var direct: Dictionary = {}
	var secondary: Dictionary = {}
	for session in plan.get("sessions", []):
		for block in (session as Dictionary).get("blocks", []):
			var exercise_id := String((block as Dictionary).get("exercise_id", ""))
			var record: Dictionary = catalog_map.get(exercise_id, {})
			if record.is_empty():
				continue
			var sets := PlanModel.as_int((block as Dictionary).get("sets"), 0)
			var primary := Taxonomy.primary_area(record)
			direct[primary] = int(direct.get(primary, 0)) + sets
			for area in Taxonomy.secondary_areas(record):
				secondary[area] = int(secondary.get(area, 0)) + sets

	var areas: Array = plan.get("areas", [])
	var days := PlanModel.as_int(plan.get("days_per_week"), 0)
	var duration := PlanModel.as_int(plan.get("duration_min"), 0)
	if areas.is_empty() or days <= 0:
		return {}
	var available := _available_sec(duration)
	var set_target := clampi(roundi(float(available) / float(AVG_SET_CYCLE_SEC)),
		TARGET_SETS_MIN, TARGET_SETS_MAX)
	var capacity := days * set_target
	var boosts := _boost_rules(String(plan.get("notes", "")))
	var coverage: Dictionary = {}
	for area in areas:
		coverage[String(area)] = 0
	for session in plan.get("sessions", []):
		for area in (session as Dictionary).get("focus", []):
			if coverage.has(String(area)):
				coverage[String(area)] = int(coverage[String(area)]) + 1

	var order: Array = []
	for area in areas:
		order.append(String(area))
	for area in Taxonomy.USER_AREAS:
		if direct.has(area) and not order.has(area):
			order.append(area)

	var table: Dictionary = {}
	for area in order:
		var direct_sets := int(direct.get(area, 0))
		var secondary_sets := int(secondary.get(area, 0))
		var raw := _effective(direct_sets, secondary_sets)
		var effective: Variant = int(raw) if raw == floorf(raw) else raw
		var target := clampi(roundi(float(capacity) / float(areas.size())
			* float(boosts.get(area, 1.0))), WEEKLY_MIN_SETS, WEEKLY_MAX_SETS)
		table[area] = {
			"direct": direct_sets,
			"effective": effective,
			"target": target,
			"cap": WEEKLY_MAX_SETS,
			"coverage": int(coverage.get(area, 0)),
		}
	return table


## The corrected weekly floor of master plan §7.1 / appendix R37:
## `min(10, floor(days_per_week × T / area_count))`.
static func weekly_floor(plan: Dictionary) -> Dictionary:
	var areas: Array = plan.get("areas", [])
	var days := PlanModel.as_int(plan.get("days_per_week"), 0)
	if areas.is_empty() or days <= 0:
		return {}
	var available := _available_sec(PlanModel.as_int(plan.get("duration_min"), 0))
	var set_target := clampi(roundi(float(available) / float(AVG_SET_CYCLE_SEC)),
		TARGET_SETS_MIN, TARGET_SETS_MAX)
	var base := mini(WEEKLY_MIN_SETS, floori(float(days * set_target) / float(areas.size())))
	var floors: Dictionary = {}
	for area in areas:
		floors[String(area)] = base
	return floors


## Areas whose measured volume misses the corrected floor, with a reason. Shortfalls are
## never silent: `build_plan` logs one `[gen] volume_shortfall …` line per entry.
static func volume_shortfalls(plan: Dictionary, catalog: Dictionary = {}) -> Dictionary:
	var table := volume_table(plan, catalog)
	var floors := weekly_floor(plan)
	var out: Dictionary = {}
	for area in floors.keys():
		var row: Dictionary = table.get(area, {})
		if row.is_empty():
			continue
		if float(row["effective"]) < float(floors[area]):
			out[area] = "time_budget"
		elif int(row["direct"]) < DIRECT_FLOOR:
			out[area] = "coverage_limit"
	return out


static func _boost_rules(notes: String) -> Dictionary:
	var lower := notes.to_lower()
	var boosts: Dictionary = {}
	if lower.strip_edges().is_empty():
		return boosts
	for rule in BOOST_RULES:
		if not _keywords_hit(lower, rule[0]):
			continue
		for area in rule[1]:
			boosts[String(area)] = float(boosts.get(String(area), 1.0)) * 1.5
	return boosts


# ===========================================================================
# R13 — warm-up / cooldown
# ===========================================================================

static func _mobility_picks(index: int, focus: PackedStringArray,
		ctx: Dictionary) -> Dictionary:
	var pool: PackedStringArray = ctx["stretch_ids"]
	var warmup: Array = []
	var cooldown: Array = []
	if pool.size() < WARMUP_ITEMS + COOLDOWN_ITEMS:
		return {"warmup": warmup, "cooldown": cooldown}
	var ordered := _rotate_strings(pool, index % pool.size())
	# Prefer records whose areas intersect the session focus (all 13 stretches are
	# `mobility`, so this is a stable no-op today), then keep the rotated order.
	var preferred := PackedStringArray()
	var rest := PackedStringArray()
	var catalog: Dictionary = ctx["catalog"]
	for exercise_id in ordered:
		var record: Dictionary = catalog.get(exercise_id, {})
		if _areas_intersect(record, focus):
			preferred.append(exercise_id)
		else:
			rest.append(exercise_id)
	var final_order := PackedStringArray()
	final_order.append_array(preferred)
	final_order.append_array(rest)
	for offset in mini(WARMUP_ITEMS, final_order.size()):
		warmup.append({"exercise_id": final_order[offset], "duration_sec": MOBILITY_ITEM_SEC})
	for offset in mini(COOLDOWN_ITEMS, maxi(0, final_order.size() - WARMUP_ITEMS)):
		cooldown.append({"exercise_id": final_order[WARMUP_ITEMS + offset],
			"duration_sec": MOBILITY_ITEM_SEC})
	return {"warmup": warmup, "cooldown": cooldown}


static func _areas_intersect(record: Dictionary, focus: PackedStringArray) -> bool:
	for area in record.get("areas", []):
		if focus.has(String(area)):
			return true
	return false


# ===========================================================================
# Deterministic helpers
# ===========================================================================

static func _rotate_array(values: Array, offset: int) -> Array:
	var size := values.size()
	if size == 0:
		return values
	var out: Array = []
	for index in size:
		out.append(values[(index + offset) % size])
	return out


static func _rotate_strings(values: PackedStringArray, offset: int) -> PackedStringArray:
	var size := values.size()
	if size == 0:
		return values
	var out := PackedStringArray()
	for index in size:
		out.append(values[(index + offset) % size])
	return out


static func _to_psa(values: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for value in values:
		out.append(String(value))
	return out


static func _plain_array(values: PackedStringArray) -> Array:
	var out: Array = []
	for value in values:
		out.append(value)
	return out


static func _resolve_catalog(catalog: Dictionary) -> Dictionary:
	if catalog.is_empty():
		return PlanModel.load_catalog()
	if catalog.has("exercises"):
		return PlanModel.catalog_from_document(catalog)
	return PlanModel.catalog_from_document(catalog)


static func _log(line: String) -> void:
	print("[gen] %s" % line)
