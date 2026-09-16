extends SceneTree

class FakeTransport extends RefCounted:
	var replies: Array = []
	var requests: Array = []
	var index: int = 0
	var cancel_calls: int = 0

	func _init(r: Array) -> void:
		replies = r

	func request(req: Dictionary) -> Dictionary:
		requests.append(req)
		var reply: Dictionary = replies[mini(index, replies.size() - 1)]
		index += 1
		return reply

	func cancel() -> void:
		cancel_calls += 1

class FakeDelay extends RefCounted:
	var waits: Array = []
	func delay(seconds: float) -> void:
		waits.append(seconds)

const OK200 := {"result": 0, "status": 200, "body": ""}

func _init() -> void:
	_run()

func _run() -> void:
	var loader: GDScript = load("res://scripts/autoload/llm.gd")
	var llm: Node = loader.new()
	var client: Node = llm.call("_ensure_client")
	var fixture := FileAccess.get_file_as_string("res://tools/fixtures/mock_plan_valid.json")
	var envelope := JSON.stringify({"choices": [{"message": {"content": fixture}, "finish_reason": "stop"}]})
	var transport := FakeTransport.new([
		{"result": 0, "status": 200, "body": envelope},
	])
	client.set("transport", transport)
	var input := {
		"goal": "hypertrophy", "days_per_week": 4, "duration_min": 40,
		"areas": ["chest", "back", "shoulders", "core"],
		"equipment": ["barbell", "machine", "cable", "dumbbell", "bodyweight"],
		"notes": "", "id": "plan-1758000000", "created_at": "2026-09-15T00:00:00Z",
	}
	var cfg := {"provider": "custom", "base_url": "http://127.0.0.1:8765/v1", "model": "deepseek-chat",
		"api_key": "sk-test-0000000000", "custom_auth_none": false, "custom_json_mode": true}
	var result: Dictionary = await llm.call("generate_plan", input, {"cfg": cfg, "seed": 7})
	print("VALID ok=", result["ok"], " source=", result["source"], " reason=", result["reason_code"],
		" attempts=", result["attempts"], " repaired=", result["repaired"],
		" sessions=", (result["plan"] as Dictionary).get("sessions", []).size(),
		" requests=", transport.requests.size())

	# 401: never retried.
	var t401 := FakeTransport.new([{"result": 0, "status": 401, "body": "{\"error\":{\"message\":\"bad key\"}}"}])
	client.set("transport", t401)
	var r401: Dictionary = await llm.call("generate_plan", input, {"cfg": cfg, "seed": 7})
	print("401 ok=", r401["ok"], " source=", r401["source"], " reason=", r401["reason_code"],
		" attempts=", r401["attempts"], " requests=", t401.requests.size(), " msg=", r401["user_message"])
	print("    plan name=", (r401["plan"] as Dictionary).get("name", ""),
		" sessions=", (r401["plan"] as Dictionary).get("sessions", []).size(),
		" gen=", (r401["plan"] as Dictionary).get("generation", {}))

	# connection refused x3 with a recording delay seam.
	var trefused := FakeTransport.new([{"result": 2, "status": 0, "body": ""}])
	var delay := FakeDelay.new()
	client.set("transport", trefused)
	client.set("delay_seam", delay)
	var rnet: Dictionary = await llm.call("generate_plan", input, {"cfg": cfg, "seed": 7})
	print("REFUSED ok=", rnet["ok"], " source=", rnet["source"], " reason=", rnet["reason_code"],
		" attempts=", rnet["attempts"], " requests=", trefused.requests.size(), " waits=", delay.waits)
	client.set("delay_seam", null)

	# malformed then valid -> repaired.
	var t2 := FakeTransport.new([
		{"result": 0, "status": 200, "body": JSON.stringify({"choices": [{"message": {"content": "{\"name\": \"X\", \"sessions\": [{\"id\": \"s1\","}, "finish_reason": "stop"}]})},
		{"result": 0, "status": 200, "body": envelope},
	])
	client.set("transport", t2)
	var rrep: Dictionary = await llm.call("generate_plan", input, {"cfg": cfg, "seed": 7})
	print("REPAIR ok=", rrep["ok"], " source=", rrep["source"], " repaired=", rrep["repaired"],
		" attempts=", rrep["attempts"], " requests=", t2.requests.size(), " msg=", rrep["user_message"])
	print("    repair prompt tail=", String(t2.requests[1]["body"]).substr(-380).substr(0, 200))

	# no key -> attempts 0, no request.
	var tnone := FakeTransport.new([{"result": 0, "status": 200, "body": envelope}])
	client.set("transport", tnone)
	var nokey_cfg := cfg.duplicate(); nokey_cfg["api_key"] = ""
	var rnk: Dictionary = await llm.call("generate_plan", input, {"cfg": nokey_cfg, "seed": 7})
	print("NOKEY ok=", rnk["ok"], " source=", rnk["source"], " reason=", rnk["reason_code"],
		" attempts=", rnk["attempts"], " requests=", tnone.requests.size(), " msg=", rnk["user_message"])

	llm.free()
	quit(0)
