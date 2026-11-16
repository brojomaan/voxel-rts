class_name UnitData
extends Resource
## The numbers that make one kind of unit behave the way it does. One .tres per unit
## type (Units/), so they can be tuned in the Inspector.

@export var display_name: String = "Unit"

@export_group("Movement")
## World units per second (one world unit is 32 voxels at half res).
@export var move_speed: float = 2.0
## How fast it pivots, in degrees per second.
@export var turn_speed_degrees: float = 120.0
## If it's facing further off course than this, it stops and turns on the spot before
## driving on. Smaller turns are made on the move.
@export_range(0.0, 180.0) var turn_in_place_degrees: float = 12.0
