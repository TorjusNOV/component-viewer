extends Node3D

const BOX_ID_META_KEY: StringName = &"box_id"
const BOX_COLOR_META_KEY: StringName = &"box_color_override"
const COLLISION_LAYER_META_KEY: StringName = &"original_collision_layer"
const COLLISION_MASK_META_KEY: StringName = &"original_collision_mask"
const COLLISION_DISABLED_META_KEY: StringName = &"original_collision_disabled"
const COLLISION_VISIBLE_META_KEY: StringName = &"original_collision_visible"
const MACHINE_SCENE_EXTENSIONS: Array[String] = [".scn", ".tscn"]

enum EditorSubMode {
	SELECT,
	ADD
}

enum GizmoToolMode {
	TRANSLATE,
	ROTATE,
	SCALE
}

@export var box_scene: PackedScene
@export var default_box_scale: Vector3 = Vector3.ONE * 0.25
@export var debug_enabled: bool = true
@export var switch_to_select_after_add: bool = false
@export var enable_navigation_in_display_mode: bool = true
@export var default_view_transition_sec: float = 1.0
@export var display_attention_duration_sec: float = 3.0
@export var display_single_box_only: bool = true

@onready var camera: EditorCamera = $Camera3D
@onready var gizmo: Gizmo3D = $Gizmo3D
@onready var box_container: Node3D = $BoxContainer
@onready var ipc_bridge: ProjectIpcBridge = $ProjectIPCBridge
@onready var world_root: Node3D = $World

var editor_mode: bool = false
var editor_sub_mode: EditorSubMode = EditorSubMode.SELECT
var current_gizmo_tool: GizmoToolMode = GizmoToolMode.TRANSLATE
var selected_box: BoxItem = null
var display_box_index: int = -1
var current_machine_scene_path: String = ""
var current_machine_name: String = ""
var current_tool_name: String = ""
var _gizmo_transform_pending_emit: bool = false
var _default_camera_position: Vector3 = Vector3.ZERO
var _default_camera_rotation: Vector3 = Vector3.ZERO

func _ready() -> void:
	_debug("=== MAIN READY ===")

	if camera == null:
		push_error("EditorCamera node not found at $Camera3D")
	if gizmo == null:
		push_error("Gizmo3D node not found at $Gizmo3D")
	if box_container == null:
		push_error("BoxContainer node not found at $BoxContainer")
	if box_scene == null:
		_debug("WARNING: box_scene is not assigned in the Inspector")

	_cache_default_camera_view()

	_update_camera_navigation_enabled()

	gizmo.axes = Gizmo3D.AxisMode.X | Gizmo3D.AxisMode.Y | Gizmo3D.AxisMode.Z
	gizmo.use_local_space = true
	gizmo.show_selection_box = true
	gizmo.visible = false
	gizmo.clear_selection()

	_apply_gizmo_tool_mode()
	_refresh_display_mode_boxes()
	_update_collision_runtime_state()

	if ipc_bridge != null:
		ipc_bridge.request_received.connect(_on_ipc_request_received)
		ipc_bridge.bridge_connected.connect(_on_ipc_bridge_connected)

func _cache_default_camera_view() -> void:
	if camera == null:
		return
	_default_camera_position = camera.global_position
	_default_camera_rotation = camera.global_rotation

func _reset_camera_to_default_view(transition_sec: float = 0.0) -> void:
	if camera == null:
		return
	camera.set_view(_default_camera_position, _default_camera_rotation, max(transition_sec, 0.0))

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_editor_mode"):
		set_editor_mode(!editor_mode)
		return

	if !editor_mode:
		return

	if event is InputEventKey and event.pressed and !event.echo and event.keycode == KEY_DELETE:
		if selected_box != null:
			_delete_box(selected_box, "keyboard")
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("editor_mode_select"):
		set_editor_sub_mode(EditorSubMode.SELECT)
		return

	if event.is_action_pressed("editor_mode_add"):
		set_editor_sub_mode(EditorSubMode.ADD)
		return

	if event.is_action_pressed("gizmo_translate"):
		current_gizmo_tool = GizmoToolMode.TRANSLATE
		_apply_gizmo_tool_mode()
		return

	if event.is_action_pressed("gizmo_rotate"):
		current_gizmo_tool = GizmoToolMode.ROTATE
		_apply_gizmo_tool_mode()
		return

	if event.is_action_pressed("gizmo_scale"):
		current_gizmo_tool = GizmoToolMode.SCALE
		_apply_gizmo_tool_mode()
		return

	if event.is_action_pressed("capture_box_view"):
		capture_view_for_selected_box()
		return

	if event.is_action_pressed("apply_box_view"):
		apply_view_from_selected_box()
		return

	if event is InputEventMouseMotion and gizmo.editing and selected_box != null:
		_gizmo_transform_pending_emit = true

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and !event.pressed:
		if _gizmo_transform_pending_emit and selected_box != null:
			_emit_selected_box_transform("gizmo_release")
		_gizmo_transform_pending_emit = false

	if camera.looking:
		return

	if gizmo.hovering or gizmo.editing:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		match editor_sub_mode:
			EditorSubMode.SELECT:
				_handle_select_click(event.position)
			EditorSubMode.ADD:
				_handle_add_click(event.position)

func set_editor_mode(enabled_value: bool) -> void:
	editor_mode = enabled_value
	_update_camera_navigation_enabled()

	if editor_mode:
		set_editor_sub_mode(EditorSubMode.SELECT)
		gizmo.visible = selected_box != null
	else:
		_clear_selection()
		gizmo.visible = false

	_refresh_display_mode_boxes()
	_update_collision_runtime_state()

	_emit_bridge_event("editor_mode_changed", {
		"editor_mode": editor_mode
	})

func set_editor_sub_mode(mode: EditorSubMode) -> void:
	editor_sub_mode = mode
	_debug("Editor sub-mode set to %s" % _sub_mode_name(mode))
	_emit_bridge_event("editor_sub_mode_changed", {
		"editor_sub_mode": _sub_mode_name(editor_sub_mode)
	})

func _apply_gizmo_tool_mode() -> void:
	match current_gizmo_tool:
		GizmoToolMode.TRANSLATE:
			gizmo.mode = Gizmo3D.ToolMode.MOVE
		GizmoToolMode.ROTATE:
			gizmo.mode = Gizmo3D.ToolMode.ROTATE
		GizmoToolMode.SCALE:
			gizmo.mode = Gizmo3D.ToolMode.SCALE

func _handle_select_click(mouse_pos: Vector2) -> void:
	var box: BoxItem = _raycast_box_from_mouse(mouse_pos)

	if box == null:
		_clear_selection()
		return

	_select_box(box)

func _handle_add_click(mouse_pos: Vector2) -> void:
	var hit: Dictionary = _raycast_from_mouse(mouse_pos)
	if hit.is_empty():
		return

	var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
	var hit_normal: Vector3 = hit.get("normal", Vector3.UP)

	var new_box: BoxItem = _spawn_box_at_hit(hit_position, hit_normal)
	if new_box == null:
		return

	_select_box(new_box)

	if switch_to_select_after_add:
		set_editor_sub_mode(EditorSubMode.SELECT)

func _raycast_from_mouse(mouse_pos: Vector2) -> Dictionary:
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 2000.0

	var query := PhysicsRayQueryParameters3D.new()
	query.from = from
	query.to = to
	query.collision_mask = 0xFFFFFFFF

	return get_world_3d().direct_space_state.intersect_ray(query)

func _raycast_box_from_mouse(mouse_pos: Vector2) -> BoxItem:
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 2000.0

	var excluded: Array[RID] = []
	for _i in range(32):
		var query := PhysicsRayQueryParameters3D.new()
		query.from = from
		query.to = to
		query.collision_mask = 0xFFFFFFFF
		query.exclude = excluded

		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return null

		var collider: Object = hit.get("collider", null)
		var box: BoxItem = _find_box_item_from_hit(collider)
		if box != null:
			return box

		if collider is CollisionObject3D:
			excluded.append((collider as CollisionObject3D).get_rid())
		else:
			return null

	return null

func _find_box_item_from_hit(node: Object) -> BoxItem:
	if node == null:
		return null

	if node is BoxItem:
		return node as BoxItem

	if node is Node:
		var current: Node = node
		while current != null:
			if current is BoxItem:
				return current as BoxItem
			current = current.get_parent()

	return null

func _spawn_box_at_hit(hit_position: Vector3, hit_normal: Vector3) -> BoxItem:
	if box_scene == null:
		push_error("box_scene is not assigned on Main")
		return null

	var box := box_scene.instantiate() as BoxItem
	if box == null:
		push_error("box_scene does not instantiate as BoxItem")
		return null

	box_container.add_child(box)

	box.scale = default_box_scale
	box.global_rotation = Vector3.ZERO

	var n: Vector3 = hit_normal.normalized()
	var half_size: Vector3 = default_box_scale * 0.5

	var offset: float = 0.0
	if abs(n.x) > abs(n.y) and abs(n.x) > abs(n.z):
		offset = half_size.x
	elif abs(n.y) > abs(n.x) and abs(n.y) > abs(n.z):
		offset = half_size.y
	else:
		offset = half_size.z

	box.global_position = hit_position + n * offset
	return box

func _select_box(box: BoxItem) -> void:
	if box == null or !editor_mode:
		return

	selected_box = box
	gizmo.clear_selection()
	gizmo.select(box.get_selectable_node())
	gizmo.visible = true

	_emit_bridge_event("selection_changed", {
		"selected_box_index": _get_selected_box_index()
	})
	_emit_selected_box_transform("selection")

func _clear_selection() -> void:
	selected_box = null
	gizmo.clear_selection()
	gizmo.visible = false

	_emit_bridge_event("selection_changed", {
		"selected_box_index": -1
	})

func capture_view_for_selected_box() -> void:
	if selected_box == null:
		return

	selected_box.set_saved_camera_view(camera.global_position, camera.global_rotation)
	_emit_bridge_event("box_view_captured", {
		"selected_box_index": _get_selected_box_index()
	})

func apply_view_from_selected_box() -> void:
	if selected_box == null:
		return
	if !selected_box.has_saved_camera_view:
		return

	camera.set_view(selected_box.saved_camera_position, selected_box.saved_camera_rotation, default_view_transition_sec)
	_emit_bridge_event("camera_view_applied", {
		"selected_box_index": _get_selected_box_index()
	})

func load_machine(machine_name: String, reset_camera_to_default: bool = true) -> int:
	var normalized_machine_name: String = machine_name.strip_edges()
	if normalized_machine_name == "":
		return ERR_INVALID_PARAMETER

	if normalized_machine_name.contains("/") or normalized_machine_name.contains("\\") or normalized_machine_name.contains(".."):
		return ERR_INVALID_PARAMETER

	var resolved_machine_name: String = _resolve_machine_name(normalized_machine_name)
	if resolved_machine_name == "":
		return ERR_FILE_NOT_FOUND

	var normalized_scene_path: String = _machine_scene_path_from_name(resolved_machine_name)
	if normalized_scene_path == "":
		return ERR_FILE_NOT_FOUND

	var machine_scene := load(normalized_scene_path) as PackedScene
	if machine_scene == null:
		return ERR_CANT_OPEN

	_clear_all_boxes()
	_clear_selection()

	for child in world_root.get_children():
		child.queue_free()

	var machine_instance := machine_scene.instantiate()
	if machine_instance == null:
		return ERR_CANT_CREATE

	world_root.add_child(machine_instance)
	_disable_machine_directional_lights(machine_instance)
	_update_collision_runtime_state()
	if reset_camera_to_default:
		_reset_camera_to_default_view(0.0)
	current_machine_name = resolved_machine_name
	current_machine_scene_path = normalized_scene_path
	current_tool_name = ""

	_refresh_display_mode_boxes()

	_emit_bridge_event("machine_loaded", {
		"machine_name": current_machine_name,
		"machine_scene_path": current_machine_scene_path,
		"box_count": _get_box_count()
	})

	return OK

func unload_machine() -> void:
	if current_machine_name == "" and current_machine_scene_path == "":
		return

	var previous_machine_name: String = current_machine_name
	var previous_scene_path: String = current_machine_scene_path

	for child in world_root.get_children():
		child.queue_free()

	current_machine_name = ""
	current_machine_scene_path = ""
	current_tool_name = ""

	hide_all_boxes("machine_unload")

	_emit_bridge_event("machine_unloaded", {
		"previous_machine_name": previous_machine_name,
		"previous_machine_scene_path": previous_scene_path
	})

func set_tool(tool_name: String) -> int:
	var normalized_tool_name: String = tool_name.strip_edges()
	var machine_root: Node = _get_loaded_machine_root()
	if machine_root == null:
		return ERR_UNAVAILABLE

	var tools_root: Node3D = _find_tools_root(machine_root)
	if tools_root == null:
		if normalized_tool_name == "":
			current_tool_name = ""
			_emit_bridge_event("tool_changed", {
				"tool_name": current_tool_name,
				"machine_name": current_machine_name
			})
			return OK
		return ERR_DOES_NOT_EXIST

	var resolved_tool_name: String = ""
	if normalized_tool_name != "":
		resolved_tool_name = _resolve_tool_name(tools_root, normalized_tool_name)
		if resolved_tool_name == "":
			return ERR_INVALID_PARAMETER

	for child in tools_root.get_children():
		if child is Node:
			var tool_group: Node = child as Node
			var show_group: bool = (resolved_tool_name != "" and String(tool_group.name) == resolved_tool_name)
			_set_mesh_visibility_under_node(tool_group, show_group)

	current_tool_name = resolved_tool_name
	_emit_bridge_event("tool_changed", {
		"tool_name": current_tool_name,
		"machine_name": current_machine_name
	})

	return OK

func _get_loaded_machine_root() -> Node:
	if world_root == null:
		return null

	for child in world_root.get_children():
		if child is Node and !(child as Node).is_queued_for_deletion():
			return child as Node

	return null

func _find_tools_root(root: Node) -> Node3D:
	if root == null:
		return null

	if root is Node3D:
		var node_name: String = String((root as Node3D).name).to_lower()
		if node_name == "tool" or node_name == "tools":
			return root as Node3D

	for child in root.get_children():
		if child is Node:
			var found: Node3D = _find_tools_root(child as Node)
			if found != null:
				return found

	return null

func _resolve_tool_name(tools_root: Node3D, requested_tool_name: String) -> String:
	if tools_root == null:
		return ""

	var requested_lower: String = requested_tool_name.to_lower()
	for child in tools_root.get_children():
		if child is Node:
			var candidate_name: String = String((child as Node).name)
			if candidate_name.to_lower() == requested_lower:
				return candidate_name

	return ""

func _set_mesh_visibility_under_node(root: Node, visible_value: bool) -> void:
	if root is VisualInstance3D:
		(root as VisualInstance3D).visible = visible_value

	for child in root.get_children():
		if child is Node:
			_set_mesh_visibility_under_node(child as Node, visible_value)

func _disable_machine_directional_lights(root: Node) -> void:
	if root is DirectionalLight3D:
		(root as DirectionalLight3D).visible = false

	for child in root.get_children():
		_disable_machine_directional_lights(child)

func set_display_box(index: int, move_camera: bool = true, highlight_color: Variant = null) -> int:
	if index < 0:
		display_box_index = -1
		_refresh_display_mode_boxes()
		_emit_bridge_event("display_box_changed", {
			"display_box_index": -1
		})
		return OK

	var box: BoxItem = _get_box_by_index(index)
	if box == null:
		return ERR_INVALID_PARAMETER

	display_box_index = index
	_refresh_display_mode_boxes()

	_set_box_color_override(box, highlight_color)

	if !editor_mode:
		box.play_attention_fade(display_attention_duration_sec)
		if move_camera and box.has_saved_camera_view:
			camera.set_view(box.saved_camera_position, box.saved_camera_rotation, default_view_transition_sec)

	_emit_bridge_event("display_box_changed", {
		"display_box_index": display_box_index
	})

	return OK

func _clear_all_boxes() -> void:
	for child in box_container.get_children():
		child.queue_free()
	display_box_index = -1

func hide_all_boxes(source: String = "ipc") -> int:
	var removed_count: int = _get_box_count()
	_clear_all_boxes()
	_clear_selection()
	_refresh_display_mode_boxes()

	_emit_bridge_event("boxes_hidden", {
		"removed_count": removed_count,
		"source": source
	})

	return removed_count

func _sub_mode_name(mode: int) -> String:
	match mode:
		EditorSubMode.SELECT:
			return "SELECT"
		EditorSubMode.ADD:
			return "ADD"
		_:
			return "UNKNOWN"

func _debug(message: String) -> void:
	if debug_enabled:
		print("[EDITOR] ", message)

func _on_ipc_bridge_connected() -> void:
	_emit_bridge_event("viewer_ready", _build_state_snapshot())

func _on_ipc_request_received(method: String, params: Dictionary, correlation_id: String, _route: String) -> void:
	if ipc_bridge == null:
		return

	match method:
		"ping":
			ipc_bridge.send_response(correlation_id, {
				"ok": true,
				"time_ms": Time.get_ticks_msec()
			})
		"get_state":
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"set_editor_mode":
			set_editor_mode(bool(params.get("enabled", false)))
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"toggle_editor_mode":
			set_editor_mode(!editor_mode)
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"load_machine":
			var load_camera_transform: Variant = null
			if params.has("camera_transform"):
				load_camera_transform = _parse_transform_param(params.get("camera_transform", {}))
				if load_camera_transform == null:
					ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid camera_transform")
					return

			var machine_name: String = str(params.get("machine_name", params.get("name", ""))).strip_edges()
			if machine_name == "":
				unload_machine()
				ipc_bridge.send_response(correlation_id, _build_state_snapshot())
				return
			if machine_name.contains("/") or machine_name.contains("\\") or machine_name.contains(".."):
				ipc_bridge.send_error(correlation_id, "invalid_request", "machine_name must not contain path separators")
				return

			if load_camera_transform != null:
				var camera_transform_for_load: Dictionary = load_camera_transform
				camera.set_view(
					camera_transform_for_load.get("position", camera.global_position),
					camera_transform_for_load.get("rotation", camera.global_rotation),
					0.0
				)

			var load_result: int = load_machine(machine_name, load_camera_transform == null)
			if load_result != OK:
				var resolved_machine_name: String = _resolve_machine_name(machine_name)
				var scene_machine_name: String = resolved_machine_name if resolved_machine_name != "" else machine_name
				var resolved_scene_path: String = _machine_scene_path_from_name(scene_machine_name)
				var candidate_scene_paths: Array[String] = _machine_scene_candidate_paths(scene_machine_name)
				var preferred_scene_path: String = candidate_scene_paths[0] if candidate_scene_paths.size() > 0 else ""
				if load_result == ERR_FILE_NOT_FOUND:
					ipc_bridge.send_error(correlation_id, "machine_not_found", "Machine scene does not exist", {
						"machine_name": machine_name,
						"resolved_machine_name": resolved_machine_name,
						"scene_path": preferred_scene_path,
						"scene_paths": candidate_scene_paths
					})
					return

				ipc_bridge.send_error(correlation_id, "load_machine_failed", "Unable to load machine scene", {
					"machine_name": machine_name,
					"scene_path": resolved_scene_path if resolved_scene_path != "" else preferred_scene_path,
					"scene_paths": candidate_scene_paths,
					"error_code": load_result
				})
				return

			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"unload_machine":
			unload_machine()
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"set_tool":
			var requested_tool_name: String = str(params.get("tool_name", params.get("name", ""))).strip_edges()
			var set_tool_result: int = set_tool(requested_tool_name)
			if set_tool_result != OK:
				if set_tool_result == ERR_UNAVAILABLE:
					ipc_bridge.send_error(correlation_id, "machine_not_loaded", "No machine is currently loaded")
					return
				if set_tool_result == ERR_DOES_NOT_EXIST:
					ipc_bridge.send_error(correlation_id, "tools_not_available", "Current machine does not expose a tool node")
					return
				if set_tool_result == ERR_INVALID_PARAMETER:
					ipc_bridge.send_error(correlation_id, "tool_not_found", "Requested tool name was not found under tool node", {
						"tool_name": requested_tool_name
					})
					return

				ipc_bridge.send_error(correlation_id, "set_tool_failed", "Unable to apply requested tool", {
					"tool_name": requested_tool_name,
					"error_code": set_tool_result
				})
				return

			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"show_box":
			if !params.has("box_transform"):
				ipc_bridge.send_error(correlation_id, "invalid_request", "Missing box_transform")
				return

			var box_transform_value: Variant = _parse_transform_param(params.get("box_transform", {}))
			if box_transform_value == null:
				ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid box_transform")
				return
			var box_transform: Dictionary = box_transform_value

			var camera_transform: Variant = null
			if params.has("camera_transform"):
				camera_transform = _parse_transform_param(params.get("camera_transform", {}))
				if camera_transform == null:
					ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid camera_transform")
					return

			var replace_existing: bool = bool(params.get("replace_existing", display_single_box_only))
			var move_camera: bool = bool(params.get("move_camera", true))
			var box_id: String = str(params.get("boxId", params.get("box_id", ""))).strip_edges()
			var highlight_color: Variant = null
			if params.has("color"):
				highlight_color = _parse_color_param(params.get("color", null))
				if highlight_color == null:
					ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid color format for show_box", {
						"expected": "Color, '#RRGGBB', '#RRGGBBAA', '{123,23,46}', or {r,g,b} with 0..1 or 0..255 values"
					})
					return

			var show_result: int = _show_box_from_transform(box_transform, camera_transform, move_camera, highlight_color, replace_existing, box_id)
			if show_result != OK:
				ipc_bridge.send_error(correlation_id, "invalid_request", "Unable to show box", {
					"error_code": show_result
				})
				return
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"hide_box":
			var hide_box_id: String = str(params.get("boxId", params.get("box_id", ""))).strip_edges()
			if hide_box_id == "":
				ipc_bridge.send_error(correlation_id, "invalid_request", "Missing boxId")
				return

			var box_by_id: BoxItem = _get_box_by_id(hide_box_id)
			if box_by_id == null:
				ipc_bridge.send_error(correlation_id, "not_found", "No box with matching boxId is currently shown", {
					"boxId": hide_box_id
				})
				return

			_delete_box(box_by_id, "ipc_hide_box")
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"get_box_transform":
			var current_box: BoxItem = _get_current_display_box()
			if current_box == null:
				ipc_bridge.send_error(correlation_id, "not_found", "No box is currently shown")
				return
			ipc_bridge.send_response(correlation_id, {
				"box_transform": _build_transform_from_box(current_box)
			})
		"set_selected_box_transform":
			if selected_box == null:
				ipc_bridge.send_error(correlation_id, "not_found", "No box is currently selected")
				return
			if !params.has("box_transform"):
				ipc_bridge.send_error(correlation_id, "invalid_request", "Missing box_transform")
				return

			var selected_box_transform_value: Variant = _parse_transform_param(params.get("box_transform", {}))
			if selected_box_transform_value == null:
				ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid box_transform")
				return
			var selected_box_transform: Dictionary = selected_box_transform_value

			_apply_box_transform(selected_box, selected_box_transform)
			_emit_selected_box_transform("ipc")
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"get_camera_transform":
			ipc_bridge.send_response(correlation_id, {
				"camera_transform": {
					"position": _vector3_to_dict(camera.global_position),
					"rotation": _vector3_to_dict(camera.global_rotation)
				}
			})
		"set_camera_transform":
			if !params.has("camera_transform"):
				ipc_bridge.send_error(correlation_id, "invalid_request", "Missing camera_transform")
				return

			var target_camera_transform_value: Variant = _parse_transform_param(params.get("camera_transform", {}))
			if target_camera_transform_value == null:
				ipc_bridge.send_error(correlation_id, "invalid_request", "Invalid camera_transform")
				return
			var target_camera_transform: Dictionary = target_camera_transform_value

			var transition_sec: float = default_view_transition_sec
			if params.has("transition_sec"):
				transition_sec = max(float(params.get("transition_sec", default_view_transition_sec)), 0.0)

			camera.set_view(
				target_camera_transform.get("position", camera.global_position),
				target_camera_transform.get("rotation", camera.global_rotation),
				transition_sec
			)

			_emit_bridge_event("camera_transform_updated", {
				"camera_transform": {
					"position": _vector3_to_dict(target_camera_transform.get("position", camera.global_position)),
					"rotation": _vector3_to_dict(target_camera_transform.get("rotation", camera.global_rotation))
				},
				"transition_sec": transition_sec,
				"source": "ipc"
			})

			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"set_editor_sub_mode":
			var mode_name: String = str(params.get("mode", "SELECT")).to_upper()
			if mode_name == "ADD":
				set_editor_sub_mode(EditorSubMode.ADD)
			else:
				set_editor_sub_mode(EditorSubMode.SELECT)
			ipc_bridge.send_response(correlation_id, _build_state_snapshot())
		"list_machine_scenes":
			ipc_bridge.send_response(correlation_id, {
				"machine_names": _list_machine_names()
			})
		"hide_boxes":
			var removed_count: int = hide_all_boxes("ipc")
			ipc_bridge.send_response(correlation_id, {
				"removed_count": removed_count,
				"state": _build_state_snapshot()
			})
		_:
			ipc_bridge.send_error(correlation_id, "method_not_found", "Unsupported method: %s" % method)

func _build_state_snapshot() -> Dictionary:
	return {
		"editor_mode": editor_mode,
		"editor_sub_mode": _sub_mode_name(editor_sub_mode),
		"gizmo_tool": _gizmo_tool_mode_name(current_gizmo_tool),
		"selected_box_index": _get_selected_box_index(),
		"display_box_index": display_box_index,
		"display_mode_active": !editor_mode,
		"box_count": _get_box_count(),
		"machine_name": current_machine_name,
		"machine_scene_path": current_machine_scene_path,
		"tool_name": current_tool_name,
		"camera": {
			"position": _vector3_to_dict(camera.global_position),
			"rotation": _vector3_to_dict(camera.global_rotation)
		}
	}

func _get_box_by_index(index: int) -> BoxItem:
	if index < 0:
		return null

	var current_index: int = 0
	for child in box_container.get_children():
		if child is BoxItem:
			if current_index == index:
				return child as BoxItem
			current_index += 1

	return null

func _get_selected_box_index() -> int:
	if selected_box == null:
		return -1

	var current_index: int = 0
	for child in box_container.get_children():
		if child is BoxItem:
			if child == selected_box:
				return current_index
			current_index += 1

	return -1

func _get_box_count() -> int:
	var count: int = 0
	for child in box_container.get_children():
		if child is BoxItem:
			count += 1
	return count

func _get_box_index_for_box(target_box: BoxItem) -> int:
	if target_box == null:
		return -1

	var current_index: int = 0
	for child in box_container.get_children():
		if child is BoxItem:
			if child == target_box:
				return current_index
			current_index += 1

	return -1

func _delete_box(box: BoxItem, source: String = "unknown") -> bool:
	if box == null:
		return false

	var deleted_index: int = _get_box_index_for_box(box)
	if deleted_index < 0:
		return false

	var deleted_box_id: String = _get_box_id(box)

	if box == selected_box:
		_clear_selection()

	box.queue_free()

	_emit_bridge_event("box_deleted", {
		"deleted_box_index": deleted_index,
		"box_id": deleted_box_id,
		"remaining_box_count": max(_get_box_count() - 1, 0),
		"source": source
	})

	return true

func _emit_selected_box_transform(source: String) -> void:
	if selected_box == null:
		return

	_emit_bridge_event("box_transform_updated", {
		"selected_box_index": _get_selected_box_index(),
		"box_transform": _build_transform_from_box(selected_box),
		"source": source
	})

func _emit_bridge_event(event_name: String, data: Variant = null) -> void:
	if ipc_bridge == null:
		return
	if !ipc_bridge.is_bridge_connected():
		return
	ipc_bridge.send_event(event_name, data)

func _update_camera_navigation_enabled() -> void:
	camera.enabled = editor_mode or enable_navigation_in_display_mode

func _update_collision_runtime_state() -> void:
	var collisions_enabled: bool = editor_mode
	_set_collision_state_for_node(world_root, collisions_enabled)
	_set_collision_state_for_node(box_container, collisions_enabled)

func _set_collision_state_for_node(root: Node, collisions_enabled: bool) -> void:
	if root == null:
		return

	if root is CollisionObject3D:
		var collision_object: CollisionObject3D = root as CollisionObject3D
		if collisions_enabled:
			if collision_object.has_meta(COLLISION_LAYER_META_KEY):
				collision_object.collision_layer = int(collision_object.get_meta(COLLISION_LAYER_META_KEY, collision_object.collision_layer))
			if collision_object.has_meta(COLLISION_MASK_META_KEY):
				collision_object.collision_mask = int(collision_object.get_meta(COLLISION_MASK_META_KEY, collision_object.collision_mask))
		else:
			if !collision_object.has_meta(COLLISION_LAYER_META_KEY):
				collision_object.set_meta(COLLISION_LAYER_META_KEY, collision_object.collision_layer)
			if !collision_object.has_meta(COLLISION_MASK_META_KEY):
				collision_object.set_meta(COLLISION_MASK_META_KEY, collision_object.collision_mask)
			collision_object.collision_layer = 0
			collision_object.collision_mask = 0

	if root is CollisionShape3D:
		var collision_shape: CollisionShape3D = root as CollisionShape3D
		if collisions_enabled:
			if collision_shape.has_meta(COLLISION_DISABLED_META_KEY):
				collision_shape.disabled = bool(collision_shape.get_meta(COLLISION_DISABLED_META_KEY, collision_shape.disabled))
			if collision_shape.has_meta(COLLISION_VISIBLE_META_KEY):
				collision_shape.visible = bool(collision_shape.get_meta(COLLISION_VISIBLE_META_KEY, collision_shape.visible))
		else:
			if !collision_shape.has_meta(COLLISION_DISABLED_META_KEY):
				collision_shape.set_meta(COLLISION_DISABLED_META_KEY, collision_shape.disabled)
			if !collision_shape.has_meta(COLLISION_VISIBLE_META_KEY):
				collision_shape.set_meta(COLLISION_VISIBLE_META_KEY, collision_shape.visible)
			collision_shape.disabled = true
			collision_shape.visible = false

	if root is CollisionPolygon3D:
		var collision_polygon: CollisionPolygon3D = root as CollisionPolygon3D
		if collisions_enabled:
			if collision_polygon.has_meta(COLLISION_DISABLED_META_KEY):
				collision_polygon.disabled = bool(collision_polygon.get_meta(COLLISION_DISABLED_META_KEY, collision_polygon.disabled))
			if collision_polygon.has_meta(COLLISION_VISIBLE_META_KEY):
				collision_polygon.visible = bool(collision_polygon.get_meta(COLLISION_VISIBLE_META_KEY, collision_polygon.visible))
		else:
			if !collision_polygon.has_meta(COLLISION_DISABLED_META_KEY):
				collision_polygon.set_meta(COLLISION_DISABLED_META_KEY, collision_polygon.disabled)
			if !collision_polygon.has_meta(COLLISION_VISIBLE_META_KEY):
				collision_polygon.set_meta(COLLISION_VISIBLE_META_KEY, collision_polygon.visible)
			collision_polygon.disabled = true
			collision_polygon.visible = false

	for child in root.get_children():
		if child is Node:
			_set_collision_state_for_node(child as Node, collisions_enabled)

func _refresh_display_mode_boxes() -> void:
	var current_index: int = 0
	for child in box_container.get_children():
		if child is BoxItem:
			var box: BoxItem = child as BoxItem
			box.stop_attention()
			_apply_box_color_override(box)
			if editor_mode or !display_single_box_only:
				box.visible = true
			else:
				box.visible = (display_box_index >= 0 and current_index == display_box_index)
			current_index += 1

func _set_box_color_override(box: BoxItem, color_value: Variant) -> void:
	if box == null:
		return

	if color_value is Color:
		var override_color: Color = color_value as Color
		box.set_meta(BOX_COLOR_META_KEY, override_color)
		box.set_box_color(override_color)
		return

	if box.has_meta(BOX_COLOR_META_KEY):
		box.remove_meta(BOX_COLOR_META_KEY)
	box.reset_box_color()

func _apply_box_color_override(box: BoxItem) -> void:
	if box == null:
		return

	if box.has_meta(BOX_COLOR_META_KEY):
		var override_value: Variant = box.get_meta(BOX_COLOR_META_KEY, null)
		if override_value is Color:
			box.set_box_color(override_value as Color)
			return

	box.reset_box_color()

func _machine_scene_path_from_name(machine_name: String) -> String:
	for scene_path in _machine_scene_candidate_paths(machine_name):
		if ResourceLoader.exists(scene_path):
			return scene_path

	return ""

func _machine_scene_candidate_paths(machine_name: String) -> Array[String]:
	var scene_paths: Array[String] = []
	for extension in MACHINE_SCENE_EXTENSIONS:
		scene_paths.append("res://machine_scenes/%s/%s%s" % [machine_name, machine_name, extension])
	return scene_paths

func _resolve_machine_name(machine_name: String) -> String:
	var dir := DirAccess.open("res://machine_scenes")
	if dir == null:
		return ""

	var requested_lower: String = machine_name.to_lower()
	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry == "":
			break
		if !dir.current_is_dir():
			continue
		if entry == "." or entry == "..":
			continue
		if entry.to_lower() == requested_lower:
			dir.list_dir_end()
			return entry

	dir.list_dir_end()
	return ""

func _list_machine_names() -> Array:
	var result: Array = []
	var dir := DirAccess.open("res://machine_scenes")
	if dir == null:
		return result

	dir.list_dir_begin()
	while true:
		var entry: String = dir.get_next()
		if entry == "":
			break
		if entry == "." or entry == "..":
			continue
		if !dir.current_is_dir():
			continue

		var scene_path: String = _machine_scene_path_from_name(entry)
		if scene_path != "":
			result.append(entry)

	dir.list_dir_end()
	result.sort()
	return result

func _parse_color_param(value: Variant) -> Variant:
	if value == null:
		return null

	if value is Color:
		return value

	if typeof(value) == TYPE_STRING:
		var color_text: String = str(value).strip_edges()
		var parsed := Color.from_string(color_text, Color(-1.0, -1.0, -1.0, -1.0))
		if parsed.a < 0.0:
			if color_text.begins_with("{") and color_text.ends_with("}"):
				var inner: String = color_text.substr(1, color_text.length() - 2).strip_edges()
				var parts: PackedStringArray = inner.split(",", false)
				if parts.size() != 3:
					return null

				var r_text: String = str(parts[0]).strip_edges()
				var g_text: String = str(parts[1]).strip_edges()
				var b_text: String = str(parts[2]).strip_edges()
				if !r_text.is_valid_float() or !g_text.is_valid_float() or !b_text.is_valid_float():
					return null

				var r: float = float(r_text)
				var g: float = float(g_text)
				var b: float = float(b_text)
				if r > 1.0 or g > 1.0 or b > 1.0:
					r /= 255.0
					g /= 255.0
					b /= 255.0

				return Color(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0)

			return null
		return parsed

	if typeof(value) == TYPE_DICTIONARY:
		var d: Dictionary = value
		if !d.has("r") or !d.has("g") or !d.has("b"):
			return null

		var r: float = float(d.get("r", 0.0))
		var g: float = float(d.get("g", 0.0))
		var b: float = float(d.get("b", 0.0))
		if r > 1.0 or g > 1.0 or b > 1.0:
			r /= 255.0
			g /= 255.0
			b /= 255.0

		return Color(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0)

	return null

func _parse_transform_param(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null

	var d: Dictionary = value
	if !d.has("position") or !d.has("rotation"):
		return null

	var position_variant: Variant = d.get("position", null)
	var rotation_variant: Variant = d.get("rotation", null)
	if typeof(position_variant) != TYPE_DICTIONARY or typeof(rotation_variant) != TYPE_DICTIONARY:
		return null

	var result: Dictionary = {
		"position": _dict_to_vector3(position_variant)
	}

	result["rotation"] = _dict_to_vector3(rotation_variant)

	if d.has("scale") and typeof(d.get("scale", null)) == TYPE_DICTIONARY:
		result["scale"] = _dict_to_vector3(d.get("scale", {}))
	else:
		result["scale"] = default_box_scale

	return result

func _show_box_from_transform(box_transform: Dictionary, camera_transform: Variant, move_camera: bool, highlight_color: Variant, replace_existing: bool, box_id: String = "") -> int:
	if box_scene == null:
		return ERR_CANT_CREATE

	if replace_existing:
		_clear_all_boxes()
		_clear_selection()

	var box := box_scene.instantiate() as BoxItem
	if box == null:
		return ERR_CANT_CREATE

	box_container.add_child(box)
	_apply_box_transform(box, box_transform)
	if box_id != "":
		box.set_meta(BOX_ID_META_KEY, box_id)
	_set_box_color_override(box, highlight_color)
	_update_collision_runtime_state()

	display_box_index = _get_box_count() - 1
	_refresh_display_mode_boxes()

	if !editor_mode:
		box.play_attention_fade(display_attention_duration_sec)

	if move_camera and camera_transform != null:
		camera.set_view(
			camera_transform.get("position", camera.global_position),
			camera_transform.get("rotation", camera.global_rotation),
			default_view_transition_sec
		)

	_emit_bridge_event("display_box_changed", {
		"display_box_index": display_box_index
	})

	return OK

func _get_box_by_id(box_id: String) -> BoxItem:
	if box_id == "":
		return null

	for child in box_container.get_children():
		if child is BoxItem:
			var box := child as BoxItem
			if _get_box_id(box) == box_id:
				return box

	return null

func _get_box_id(box: BoxItem) -> String:
	if box == null:
		return ""
	if !box.has_meta(BOX_ID_META_KEY):
		return ""
	return str(box.get_meta(BOX_ID_META_KEY, ""))

func _get_current_display_box() -> BoxItem:
	if display_box_index >= 0:
		var by_index: BoxItem = _get_box_by_index(display_box_index)
		if by_index != null:
			return by_index

	for child in box_container.get_children():
		if child is BoxItem:
			return child as BoxItem

	return null

func _build_transform_from_box(box: BoxItem) -> Dictionary:
	return {
		"position": _vector3_to_dict(box.global_position),
		"rotation": _vector3_to_dict(box.global_rotation),
		"scale": _vector3_to_dict(box.scale)
	}

func _apply_box_transform(box: BoxItem, box_transform: Dictionary) -> void:
	if box == null:
		return

	box.global_position = box_transform.get("position", Vector3.ZERO)
	box.global_rotation = box_transform.get("rotation", Vector3.ZERO)
	box.scale = box_transform.get("scale", default_box_scale)

func _dict_to_vector3(data: Dictionary) -> Vector3:
	return Vector3(
		float(data.get("x", 0.0)),
		float(data.get("y", 0.0)),
		float(data.get("z", 0.0))
	)

func _vector3_to_dict(value: Vector3) -> Dictionary:
	return {
		"x": value.x,
		"y": value.y,
		"z": value.z
	}

func _gizmo_tool_mode_name(mode: int) -> String:
	match mode:
		GizmoToolMode.TRANSLATE:
			return "TRANSLATE"
		GizmoToolMode.ROTATE:
			return "ROTATE"
		GizmoToolMode.SCALE:
			return "SCALE"
		_:
			return "UNKNOWN"
