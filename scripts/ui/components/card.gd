extends PanelContainer
## Content card — PRD-02 R7.
##
## The `Card` theme variation supplies the surface fill, radius and 24 px padding; this script
## only exposes the slot consumers fill. Nothing here restyles: a caller that wants the alt or
## sheet look sets `theme_type_variation` on its own instance.
##
## [b]`mouse_filter = PASS` is load-bearing.[/b] A `PanelContainer` defaults to `STOP`, and
## Godot's GUI stops `ScreenTouch`/`ScreenDrag` (and the emulated mouse drags Android sends)
## at the first `STOP` control — so a card covering a tab's scroll area swallowed every scroll
## gesture that began on it and the page could not be dragged at all. `PASS` lets the gesture
## bubble to the tab's `ScrollContainer` while every control inside the card keeps its own
## filter (a chip is still tappable, a swipe still scrolls).


## The vertical slot inside the card's padding. Returns `null` only if the scene was altered.
func body() -> VBoxContainer:
	return get_node_or_null(^"Body/Items") as VBoxContainer
