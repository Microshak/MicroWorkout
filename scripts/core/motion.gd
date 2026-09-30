class_name Motion
extends RefCounted
## PRD-12 R1 — the behavioural half of the motion system.
##
## The timing table itself stays in [code]DesignTokens.MOTION[/code] (PRD-02's values are
## unchanged; PRD-12 added five keys to the same dictionary). This class answers the two
## questions a table of numbers cannot:
##
##   * is decorative motion allowed right now? ([method decorative_enabled]) — `ui.reduce_motion`
##     is PRD-03's schema key, PRD-02's `Nav.set_reduce_motion()` owns transition shortening,
##     and this guards the flourishes (stagger, pop, celebration) that are **skipped entirely**
##     rather than shortened, because a 30 ms stagger still reads as a flicker;
##   * how long does list item `i` wait? ([method stagger_seconds]) — capped so a 20-item review
##     list never delays its last row by more than `stagger_max × stagger_ms`.
##
## Nothing here animates anything: screens read these values and drive their own tweens.

## Every animated duration the PRD-12 rules mention, in seconds. Named timing entries only — a
## screen asking for `Motion.seconds("frame_ms")` gets 0.455, never a fresh literal.
static func seconds(timing: String) -> float:
	if not DesignTokens.MOTION.has(timing):
		push_error("[motion] unknown timing name '%s'" % timing)
		return 0.0
	return float(DesignTokens.MOTION[timing]) / 1000.0


## False when the owner asked for reduced motion: decorative effects are skipped, not shortened.
static func decorative_enabled() -> bool:
	return not bool(App.get_setting("ui.reduce_motion", false))


## The delay before list item [param index] starts its entry animation: `i × stagger_ms`,
## capped at `stagger_max × stagger_ms` (320 ms with PRD-12's values).
static func stagger_seconds(index: int) -> float:
	var step := int(DesignTokens.MOTION["stagger_ms"])
	var cap := int(DesignTokens.MOTION["stagger_max"])
	return float(mini(maxi(index, 0), cap) * step) / 1000.0
