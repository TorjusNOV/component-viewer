extends Node3D
class_name VolumeGizmo

@onready var box_mesh: MeshInstance3D = $Box
@onready var handles_root: Node3D = $Handles

var volume = null

func bind_to_volume(v) -> void:
	volume = v
	global_transform = volume.global_transform
	volume.size_changed.connect(_sync_from_volume)
	_sync_from_volume()

func _process(_dt: float) -> void:
	if volume:
		# follow volume transform live
		global_transform = volume.global_transform

func _sync_from_volume() -> void:
	if not volume: return
	var bm := box_mesh.mesh as BoxMesh
	bm.size = volume.size
	_update_handles()

func _update_handles() -> void:
	var e: Vector3 = volume.size * 0.5
	_set_handle("HandlePX", Vector3( e.x, 0, 0))
	_set_handle("HandleNX", Vector3(-e.x, 0, 0))
	_set_handle("HandlePY", Vector3(0,  e.y, 0))
	_set_handle("HandleNY", Vector3(0, -e.y, 0))
	_set_handle("HandlePZ", Vector3(0, 0,  e.z))
	_set_handle("HandleNZ", Vector3(0, 0, -e.z))

func _set_handle(name: String, local_pos: Vector3) -> void:
	var h := handles_root.get_node(name) as Node3D
	h.position = local_pos
