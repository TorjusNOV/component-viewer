extends Camera3D
class_name EditorCamera

@export var enabled: bool = false
@export var move_speed: float = 5.0
@export var fast_multiplier: float = 4.0
@export var look_sensitivity: float = 0.003
@export var wheel_zoom_step: float = 1.0
@export var touch_look_sensitivity: float = 0.0035
@export var touch_pan_sensitivity: float = 0.01
@export var touch_zoom_sensitivity: float = 0.01
@export var max_angular_speed_deg: float = 180.0

var yaw: float = 0.0
var pitch: float = 0.0
var looking: bool = false
var _view_tween: Tween = null
var _touch_points: Dictionary = {}
var _prev_touch_center: Vector2 = Vector2.ZERO
var _prev_touch_distance: float = -1.0
var _view_start_position: Vector3 = Vector3.ZERO
var _view_target_position: Vector3 = Vector3.ZERO
var _view_start_quat: Quaternion = Quaternion.IDENTITY
var _view_target_quat: Quaternion = Quaternion.IDENTITY

func _ready() -> void:
	pitch = rotation.x
	yaw = rotation.y

func _unhandled_input(event: InputEvent) -> void:
	if !enabled:
		if looking:
			looking = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_touch_points.clear()
		_prev_touch_center = Vector2.ZERO
		_prev_touch_distance = -1.0
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_points[event.index] = event.position
		else:
			_touch_points.erase(event.index)

		if _touch_points.size() < 2:
			_prev_touch_center = Vector2.ZERO
			_prev_touch_distance = -1.0

		get_viewport().set_input_as_handled()
		return

	if event is InputEventScreenDrag:
		_touch_points[event.index] = event.position

		if _touch_points.size() == 1:
			yaw -= event.relative.x * touch_look_sensitivity
			pitch -= event.relative.y * touch_look_sensitivity
			pitch = clamp(pitch, -1.55, 1.55)
			rotation = Vector3(pitch, yaw, 0.0)
			get_viewport().set_input_as_handled()
			return

		if _touch_points.size() >= 2:
			var points: Array = _touch_points.values()
			var p1: Vector2 = points[0]
			var p2: Vector2 = points[1]

			var center: Vector2 = (p1 + p2) * 0.5
			if _prev_touch_center != Vector2.ZERO:
				var center_delta: Vector2 = center - _prev_touch_center
				global_position += -transform.basis.x * center_delta.x * touch_pan_sensitivity
				global_position += transform.basis.y * center_delta.y * touch_pan_sensitivity
			_prev_touch_center = center

			var distance: float = p1.distance_to(p2)
			if _prev_touch_distance >= 0.0:
				var pinch_delta: float = distance - _prev_touch_distance
				global_position += -global_transform.basis.z * pinch_delta * touch_zoom_sensitivity
			_prev_touch_distance = distance

			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			looking = event.pressed
			if looking:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
			return

		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			global_position += -global_transform.basis.z * wheel_zoom_step
			get_viewport().set_input_as_handled()
			return

		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			global_position += global_transform.basis.z * wheel_zoom_step
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion and looking:
		yaw -= event.relative.x * look_sensitivity
		pitch -= event.relative.y * look_sensitivity
		pitch = clamp(pitch, -1.55, 1.55)
		rotation = Vector3(pitch, yaw, 0.0)
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if !enabled:
		return

	var move_input: Vector3 = Vector3.ZERO

	if Input.is_action_pressed("camera_forward"):
		move_input.z -= 1.0
	if Input.is_action_pressed("camera_back"):
		move_input.z += 1.0
	if Input.is_action_pressed("camera_left"):
		move_input.x -= 1.0
	if Input.is_action_pressed("camera_right"):
		move_input.x += 1.0
	if Input.is_action_pressed("camera_up"):
		move_input.y += 1.0
	if Input.is_action_pressed("camera_down"):
		move_input.y -= 1.0

	if move_input == Vector3.ZERO:
		return

	move_input = move_input.normalized()

	var speed: float = move_speed
	if Input.is_action_pressed("camera_fast"):
		speed *= fast_multiplier

	var movement: Vector3 = (
		transform.basis.x * move_input.x +
		transform.basis.y * move_input.y +
		transform.basis.z * move_input.z
	) * speed * delta

	global_position += movement

func set_view(position_value: Vector3, rotation_value: Vector3, transition_sec: float = 0.0) -> void:
	if _view_tween != null and _view_tween.is_valid():
		_view_tween.kill()
		_view_tween = null

	if transition_sec <= 0.0:
		global_position = position_value
		global_rotation = rotation_value
		_sync_look_from_current_rotation()
		return

	_view_start_position = global_position
	_view_target_position = position_value
	_view_start_quat = Quaternion(global_transform.basis).normalized()
	_view_target_quat = Quaternion(Basis.from_euler(rotation_value)).normalized()

	var effective_transition_sec: float = transition_sec
	if max_angular_speed_deg > 0.0:
		var angle_rad: float = _view_start_quat.angle_to(_view_target_quat)
		var max_angular_speed_rad: float = deg_to_rad(max_angular_speed_deg)
		if max_angular_speed_rad > 0.0:
			var min_transition_sec: float = angle_rad / max_angular_speed_rad
			effective_transition_sec = max(effective_transition_sec, min_transition_sec)

	_view_tween = create_tween()
	_view_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_view_tween.tween_method(_set_view_interpolation_weight, 0.0, 1.0, effective_transition_sec)
	_view_tween.finished.connect(_on_view_tween_finished.bind(position_value, rotation_value), CONNECT_ONE_SHOT)

func _on_view_tween_finished(position_value: Vector3, rotation_value: Vector3) -> void:
	global_position = position_value
	global_rotation = rotation_value
	_sync_look_from_current_rotation()
	_view_tween = null

func _set_view_interpolation_weight(weight: float) -> void:
	var clamped_weight: float = clamp(weight, 0.0, 1.0)
	var interpolated_position: Vector3 = _view_start_position.lerp(_view_target_position, clamped_weight)
	var interpolated_quat: Quaternion = _view_start_quat.slerp(_view_target_quat, clamped_weight)

	var t: Transform3D = global_transform
	t.origin = interpolated_position
	t.basis = Basis(interpolated_quat)
	global_transform = t

func _sync_look_from_current_rotation() -> void:
	pitch = rotation.x
	yaw = rotation.y
