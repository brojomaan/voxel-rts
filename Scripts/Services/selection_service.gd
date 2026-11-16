extends Node
## Autoload as "SelectionService".
## Which unit the mouse is over and which one is selected. It only keeps the state
## and tells the units and anyone listening; InteractionService decides when it changes.
## One selected unit for now; a group comes later.

signal hovered_changed(unit: Unit)
signal selection_changed(unit: Unit)

var _hovered: Unit
var _selected: Unit


## The unit under the mouse, or null.
func get_hovered() -> Unit:
	return _hovered if is_instance_valid(_hovered) else null


## The selected unit, or null.
func get_selected() -> Unit:
	return _selected if is_instance_valid(_selected) else null


func set_hovered(unit: Unit) -> void:
	if unit == get_hovered():
		return
	if is_instance_valid(_hovered):
		_hovered.set_hovered(false)
	_hovered = unit
	if unit:
		unit.set_hovered(true)
	hovered_changed.emit(unit)


func select(unit: Unit) -> void:
	if unit == get_selected():
		return
	if is_instance_valid(_selected):
		_selected.set_selected(false)
	_selected = unit
	if unit:
		unit.set_selected(true)
	selection_changed.emit(unit)


func clear_selection() -> void:
	select(null)
