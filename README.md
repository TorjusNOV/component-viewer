# Component Viewer

Component Viewer is a Godot-based 3D app for showing and editing box annotations on machine scenes. It is designed to run under GodotManager and be controlled by a WinCC OA EWO over the app IPC protocol.

## How It Fits Together

- GodotManager hosts the process and routes app messages.
- WinCC OA EWO sends app requests and receives app events.
- Component Viewer renders the machine and boxes, applies commands, and reports state/events.

For protocol details, request/response envelopes, and method contracts, see [APP_BRIDGE_PROTOCOL.md](APP_BRIDGE_PROTOCOL.md).

## Core Behavior

- Loads machine scenes from `res://machine_scenes/<name>/<name>.tscn`.
- In display workflows, boxes can be shown/hidden and updated from IPC transforms.
- In editor workflows, boxes can be selected, moved with gizmo tools, created, and deleted.
- Camera can be read and set over IPC, including smooth transitions.

## Modes

- Display mode: focused presentation and navigation.
- Editor mode: selection, add-box flow, gizmo transforms, and keyboard delete for selected boxes.

Switch modes over IPC with `set_editor_mode` or `toggle_editor_mode`.

## Typical IPC Flow

1. Load a machine with `load_machine`.
2. Show or update boxes with `show_box` and `set_selected_box_transform`.
3. Read transforms with `get_box_transform` and `get_camera_transform`.
4. Set camera directly with `set_camera_transform`.
5. Remove boxes with `hide_boxes`.

## Notes for Integrators

- The app emits events for key state changes (selection, transform updates, box removal, camera updates).
- `box_transform_updated` is emitted on selection, gizmo edit release, and IPC transform updates.
- `camera_transform_updated` is emitted when camera is changed via IPC.

Refer to [APP_BRIDGE_PROTOCOL.md](APP_BRIDGE_PROTOCOL.md) for exact payload shapes and event semantics.
