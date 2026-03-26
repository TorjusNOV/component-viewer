extends Node3D
class_name BoxItem

@onready var _box_mesh: MeshInstance3D = $Body/Box

var saved_camera_position: Vector3 = Vector3.ZERO
var saved_camera_rotation: Vector3 = Vector3.ZERO
var has_saved_camera_view: bool = false
var _base_alpha: float = 1.0
var _base_color: Color = Color(0.30588236, 0.70980394, 0.0, 0.6745098)
var _attention_tween: Tween = null

func _ready() -> void:
	_prepare_material_instance()
	_set_visual_alpha(_base_alpha)

func get_selectable_node() -> Node3D:
	return self

func set_saved_camera_view(camera_position: Vector3, camera_rotation: Vector3) -> void:
	saved_camera_position = camera_position
	saved_camera_rotation = camera_rotation
	has_saved_camera_view = true

func clear_saved_camera_view() -> void:
	saved_camera_position = Vector3.ZERO
	saved_camera_rotation = Vector3.ZERO
	has_saved_camera_view = false

func stop_attention() -> void:
	if _attention_tween != null and _attention_tween.is_valid():
		_attention_tween.kill()
		_attention_tween = null
	_set_visual_alpha(_base_alpha)

func play_attention_fade(duration_sec: float = 3.0, low_alpha: float = 0.15, high_alpha: float = -1.0, cycle_sec: float = 0.5) -> void:
	stop_attention()
	if duration_sec <= 0.0:
		return

	visible = true

	var target_high_alpha: float = _base_alpha
	if high_alpha >= 0.0:
		target_high_alpha = clamp(high_alpha, 0.0, 1.0)

	var target_low_alpha: float = clamp(low_alpha, 0.0, target_high_alpha)
	_set_visual_alpha(target_high_alpha)

	_attention_tween = create_tween()
	_attention_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var half_cycle: float = max(cycle_sec * 0.5, 0.05)
	var elapsed: float = 0.0
	while elapsed < duration_sec:
		_attention_tween.tween_method(_set_visual_alpha, target_high_alpha, target_low_alpha, half_cycle)
		elapsed += half_cycle
		if elapsed >= duration_sec:
			break
		_attention_tween.tween_method(_set_visual_alpha, target_low_alpha, target_high_alpha, half_cycle)
		elapsed += half_cycle

	_attention_tween.tween_callback(_restore_base_alpha)

func set_visual_alpha(alpha: float) -> void:
	_set_visual_alpha(alpha)

func set_box_color(color_value: Color) -> void:
	_set_visual_rgb(color_value)

func reset_box_color() -> void:
	_set_visual_rgb(_base_color)

func get_save_data() -> Dictionary:
	return {
		"position": {
			"x": global_position.x,
			"y": global_position.y,
			"z": global_position.z
		},
		"rotation": {
			"x": global_rotation.x,
			"y": global_rotation.y,
			"z": global_rotation.z
		},
		"scale": {
			"x": scale.x,
			"y": scale.y,
			"z": scale.z
		},
		"has_saved_camera_view": has_saved_camera_view,
		"camera_position": {
			"x": saved_camera_position.x,
			"y": saved_camera_position.y,
			"z": saved_camera_position.z
		},
		"camera_rotation": {
			"x": saved_camera_rotation.x,
			"y": saved_camera_rotation.y,
			"z": saved_camera_rotation.z
		}
	}

func load_from_data(data: Dictionary) -> void:
	global_position = _dict_to_vector3(data.get("position", {}))
	global_rotation = _dict_to_vector3(data.get("rotation", {}))
	scale = _dict_to_vector3(data.get("scale", {"x": 1.0, "y": 1.0, "z": 1.0}))

	has_saved_camera_view = data.get("has_saved_camera_view", false)
	saved_camera_position = _dict_to_vector3(data.get("camera_position", {}))
	saved_camera_rotation = _dict_to_vector3(data.get("camera_rotation", {}))

func _dict_to_vector3(data: Dictionary) -> Vector3:
	return Vector3(
		float(data.get("x", 0.0)),
		float(data.get("y", 0.0)),
		float(data.get("z", 0.0))
	)

func _prepare_material_instance() -> void:
	if _box_mesh == null:
		return

	var mat := _box_mesh.get_active_material(0)
	if mat is StandardMaterial3D:
		var material_instance := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
		_box_mesh.set_surface_override_material(0, material_instance)
		_base_color = material_instance.albedo_color
		_base_alpha = material_instance.albedo_color.a

func _set_visual_alpha(alpha: float) -> void:
	if _box_mesh == null:
		return

	var material := _box_mesh.get_active_material(0)
	if material is StandardMaterial3D:
		var sm := material as StandardMaterial3D
		var c: Color = sm.albedo_color
		c.a = clamp(alpha, 0.0, 1.0)
		sm.albedo_color = c

func _set_visual_rgb(color_value: Color) -> void:
	if _box_mesh == null:
		return

	var material := _box_mesh.get_active_material(0)
	if material is StandardMaterial3D:
		var sm := material as StandardMaterial3D
		var current: Color = sm.albedo_color
		current.r = clamp(color_value.r, 0.0, 1.0)
		current.g = clamp(color_value.g, 0.0, 1.0)
		current.b = clamp(color_value.b, 0.0, 1.0)
		sm.albedo_color = current

func _restore_base_alpha() -> void:
	_set_visual_alpha(_base_alpha)
	_attention_tween = null
