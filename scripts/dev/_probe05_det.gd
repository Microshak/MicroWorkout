extends SceneTree
const INPUT := {"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
	"areas": ["chest", "back", "shoulders", "arms", "core"],
	"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
	"notes": "", "id": "plan-1757941200", "created_at": "2026-09-15T12:00:00Z"}

func _initialize() -> void:
	var a := JSON.stringify(Generator.build_plan(INPUT, 20260915), "", true)
	var b := JSON.stringify(Generator.build_plan(INPUT, 20260915), "", true)
	var c := JSON.stringify(Generator.build_plan(INPUT, 20260916), "", true)
	print("[proof] pid=%d bytes=%d  same-seed identical: %s  different-seed differs: %s"
		% [OS.get_process_id(), a.length(), str(a == b), str(a != c)])
	print("[proof] seed 20260915 sha256=%s" % a.sha256_text())
	print("[proof] seed 20260916 sha256=%s" % c.sha256_text())
	quit(0)
