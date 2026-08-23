extends RigidBody3D

@export var float_force := 3.0
@export var water_drag := 0.05
@export var water_angular_drag := 0.05

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

func _physics_process(delta: float) -> void:
	# Get the current game time in seconds
	var time := Time.get_ticks_msec() / 1000.0
	
	# Ask the Singleton for the exact water height right here
	var water_height := OceanMath.get_water_height(global_position, time)
	
	# Check how deep the object is submerged
	var depth := water_height - global_position.y
	
	if depth > 0.0:
		# If underwater, apply an upward force based on depth
		var buoyancy = Vector3.UP * gravity * float_force * depth
		apply_central_force(buoyancy)
		
		# Apply drag to simulate the thick resistance of water
		linear_velocity *= (1.0 - water_drag)
		angular_velocity *= (1.0 - water_angular_drag)
