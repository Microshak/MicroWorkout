extends Node
## LLM client facade: turns wizard input into a validated plan.
##
## PRD-01: skeleton only. PRD-07 implements the provider adapters
## (OpenAI-compatible incl. DeepSeek, OpenAI, Anthropic, Gemini), validation,
## one repair retry, and the permanent fallback to the built-in generator.

## These signals are the contract PRD-07 implements; they are declared now so screens can
## connect before the client exists.
@warning_ignore("unused_signal")
signal generation_started
@warning_ignore("unused_signal")
signal generation_progress(message: String)
@warning_ignore("unused_signal")
signal generation_finished(plan: Dictionary, source: String)
@warning_ignore("unused_signal")
signal generation_failed(reason: String)


func _ready() -> void:
	print("[LLM] ready")


## True when a provider is configured well enough to attempt a request.
func is_configured() -> bool:
	return false


## Cancels an in-flight generation, if any.
func cancel() -> void:
	pass
