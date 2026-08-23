extends Node

# These MUST match your wave_math.gdshaderinc defaults exactly
var sea_height := 1.3
var sea_choppy := 4.0
var sea_speed := 1.5
var sea_freq := 0.08
var iter_geometry := 3

# These MUST match your water.gdshader uniforms exactly
var ocean_size := 2000.0
var tide_speed := 1.0
var tide_amount := 0.03

var mask_image: Image

func _ready() -> void:
	# Load the exact mask image used in your main scene
	var tex = load("res://Map/landmass-V3.png") as Texture2D
	if tex:
		mask_image = tex.get_image()

# Replicates the GLSL uvec2 hash12 function exactly
func hash12(p: Vector2) -> float:
	var qx: int = (int(p.x) * 1597334677) & 0xFFFFFFFF
	var qy: int = (int(p.y) * 3812015801) & 0xFFFFFFFF
	var n: int = ((qx ^ qy) * 1597334677) & 0xFFFFFFFF
	return float(n) / 4294967295.0

# Replicates the GLSL value noise
func noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	
	var a := hash12(i + Vector2(0.0, 0.0))
	var b := hash12(i + Vector2(1.0, 0.0))
	var c := hash12(i + Vector2(0.0, 1.0))
	var d := hash12(i + Vector2(1.0, 1.0))
	
	return -1.0 + 2.0 * lerpf(lerpf(a, b, u.x), lerpf(c, d, u.x), u.y)

# Replicates the GLSL sea_octave
func sea_octave(uv: Vector2, choppy: float) -> float:
	var n := noise(uv)
	uv += Vector2(n, n)
	
	var wv := Vector2.ONE - Vector2(sin(uv.x), sin(uv.y)).abs()
	var swv := Vector2(cos(uv.x), cos(uv.y)).abs()
	
	var wv_x = lerpf(wv.x, swv.x, wv.x)
	var wv_y = lerpf(wv.y, swv.y, wv.y)
	
	return pow(1.0 - pow(wv_x * wv_y, 0.65), choppy)

# Calculates the exact wave height at any 3D coordinate
func get_water_height(world_pos: Vector3, time: float) -> float:
	# 1. Base Raw Wave Math
	var freq := sea_freq
	var amp := sea_height
	var choppy := sea_choppy
	var uv := Vector2(world_pos.x, world_pos.z)
	uv.x *= 0.75
	
	var raw_wave := 0.0
	for i in range(iter_geometry):
		var t_speed := time * sea_speed
		var d := sea_octave((uv + Vector2(t_speed, t_speed)) * freq, choppy)
		d += sea_octave((uv - Vector2(t_speed, t_speed)) * freq, choppy)
		raw_wave += d * amp
		
		var new_x = uv.x * 1.6 + uv.y * 1.2
		var new_y = uv.x * -1.2 + uv.y * 1.6
		uv = Vector2(new_x, new_y)
		
		freq *= 1.9
		amp *= 0.22
		choppy = lerpf(choppy, 1.0, 0.2)
		
	# 2. Mask and Tide Logic
	var shore_weight := 1.0
	if mask_image:
		var mask_uv := (Vector2(world_pos.x, world_pos.z) / ocean_size) + Vector2(0.5, 0.5)
		mask_uv = mask_uv.clamp(Vector2.ZERO, Vector2.ONE)
		
		var px := clampi(int(mask_uv.x * (mask_image.get_width() - 1)), 0, mask_image.get_width() - 1)
		var py := clampi(int(mask_uv.y * (mask_image.get_height() - 1)), 0, mask_image.get_height() - 1)
		
		var base_weight := mask_image.get_pixel(px, py).r
		var tide := sin(time * tide_speed) * tide_amount
		shore_weight = clampf(base_weight + tide, 0.0, 1.0)
		
	# 3. Final blend mimicking your vertex shader
	return lerpf(-5.0, raw_wave, shore_weight)
