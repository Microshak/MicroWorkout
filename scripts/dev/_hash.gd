extends SceneTree
func _init() -> void:
	var sp := PlanPrompt.system_prompt()
	print("system sha256=", sp.sha256_text())
	print("system md5=", sp.md5_text())
	print("system bytes=", sp.to_utf8_buffer().size())
	print("template sha256=", PlanPrompt.USER_PROMPT_TEMPLATE.sha256_text())
	print("repair sha256=", PlanPrompt.REPAIR_TEMPLATE.sha256_text())
	print("repair bytes=", PlanPrompt.REPAIR_TEMPLATE.to_utf8_buffer().size())
	quit(0)
