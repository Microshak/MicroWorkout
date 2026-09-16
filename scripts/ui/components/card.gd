extends PanelContainer
## Content card — PRD-02 R7.
##
## The `Card` theme variation supplies the surface fill, radius and 24 px padding; this script
## only exposes the slot consumers fill. Nothing here restyles: a caller that wants the alt or
## sheet look sets `theme_type_variation` on its own instance.


## The vertical slot inside the card's padding. Returns `null` only if the scene was altered.
func body() -> VBoxContainer:
	return get_node_or_null(^"Body/Items") as VBoxContainer
