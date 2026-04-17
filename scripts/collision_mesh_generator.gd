@tool
extends Node3D

func _ready():
	if Engine.is_editor_hint():
		generate_collisions_for_model(self)

func generate_collisions_for_model(root: Node):
	for child in root.get_children():
		if child is MeshInstance3D:
			if child.get_node_or_null("StaticBody3D") == null:
				child.create_trimesh_collision()
		generate_collisions_for_model(child)
