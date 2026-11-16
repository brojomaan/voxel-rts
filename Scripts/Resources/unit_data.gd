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

@export_group("Weapon")
## How far it can shoot, in world units. 0 = unarmed.
@export var attack_range: float = 7.0
## Seconds between shots.
@export var reload_seconds: float = 1.5
## How fast its shells fly, in world units per second.
@export var shell_speed: float = 14.0
## Size of the crater a shell leaves, in world units (visual only).
@export var crater_radius: float = 0.25
## Where shells leave from, relative to the unit (forward is -Z).
@export var muzzle_offset: Vector3 = Vector3(0.0, 0.75, -1.25)
## Each shot lands up to this far from where it was aimed, in world units, so hits
## spread over the target instead of drilling one hole.
@export var aim_scatter: float = 0.3
## How square-on to the target it must be before firing, in degrees.
@export var aim_tolerance_degrees: float = 3.0
