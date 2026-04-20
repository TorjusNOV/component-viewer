# App Bridge Protocol (Manager as Neutral Router)

This document defines an app-level protocol that allows a WinCC OA EWO to talk to any Godot project through GodotManager, while keeping GodotManager and GodotEWO project-agnostic.

## Design Goals

- Keep GodotManager generic: lifecycle, hosting, routing, no project logic.
- Keep GodotEWO generic: UI-side transport and request orchestration, no project logic.
- Let each Godot project define its own app API behind a shared envelope.
- Preserve existing control protocol behavior (hello, resize, focus, project, hwnd, etc.).

## Transport

- Localhost WebSocket + UTF-8 JSON.
- Use the existing manager endpoint (`ws://127.0.0.1:6100`) for both control and app frames.

Single-socket coexistence rules:

- Control-plane messages keep current behavior and fields.
- App-plane messages use `type` values prefixed with `app_`.
- Manager validates app envelope fields and routes payload as opaque JSON.
- WinCC OA-facing API should pass only `method` + `params`; envelope metadata is injected by EWO.

## Logical Roles

- GodotEWO:
  - App client from WinCC OA side.
  - Sends app requests/events.
  - Consumes app responses/events.

- Godot Project:
  - App server for project-specific methods/events.
  - Registers app identity and schema version.

- GodotManager:
  - Stateless/low-state router for app envelopes.
  - Routes by route/session/project instance metadata.
  - Enforces limits/timeouts and lifecycle cleanup.

## Envelope (Manager-readable, Payload-opaque)

All app frames are JSON objects:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "session_id": "ewo-42",
  "project_instance_id": "mgr-proc-1734",
  "correlation_id": "8b74b6c8-8f67-4aa1-88a4-9a605f7be6fe",
  "method": "get_state",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

Required envelope fields:

- `type`: `app_hello` | `app_request` | `app_response` | `app_event` | `app_error`.
- `route`: app route string (for example `component-viewer`).
- `correlation_id`: required for request/response/error, optional for event.

Recommended fields:

- `session_id`: widget session identity.
- `project_instance_id`: current manager project runtime instance identity.
- `ts_ms`: sender timestamp.

## Payload Contract

Manager treats payload as opaque JSON.

- `app_request` payload:
  - `schema_version`: integer.
  - `params`: object.
- `app_response` payload:
  - `schema_version`: integer.
  - `result`: object/array/scalar.
- `app_error` payload:
  - `schema_version`: integer.
  - `error`: `{ "code": string, "message": string, "data": any }`.
- `app_event` payload:
  - `schema_version`: integer.
  - `event`: string.
  - `data`: any.

## Handshake

### 1) Project registers app capability

Godot Project -> Manager:

```json
{
  "type": "app_hello",
  "route": "component-viewer",
  "payload": {
    "schema_version": 1,
    "app_id": "component-viewer",
    "project_name": "Component Viewer"
  }
}
```

Manager -> Godot Project:

```json
{
  "type": "app_response",
  "route": "component-viewer",
  "correlation_id": "app-hello",
  "payload": {
    "schema_version": 1,
    "result": { "registered": true }
  }
}
```

### 2) EWO sends request

GodotEWO -> Manager -> Godot Project (`app_request`).

### 3) Project replies

Godot Project -> Manager -> GodotEWO (`app_response` or `app_error`).

## Routing Rules (Manager)

- Route by `route` and active project instance.
- Maintain a short-lived correlation map for request/response forwarding.
- Drop stale responses if requester disconnected.
- On project switch or teardown, clear route registrations for old instance.

## Reliability and Limits

- At-most-once delivery at transport level.
- Request timeout recommended: 2-5s default (EWO side configurable).
- Manager should enforce:
  - max message size (for example 256 KiB)
  - per-client rate limits
  - basic JSON validation at envelope level only

## Versioning

- Keep existing control protocol versioned independently.
- App payload uses `schema_version` per route.
- Backward compatibility rule:
  - unknown methods -> `app_error` code `method_not_found`
  - unsupported schema -> `app_error` code `unsupported_schema`

## Security (Localhost Scope)

- Bind manager endpoint to `127.0.0.1` only.
- Reject non-JSON and oversized frames.
- Optional local token in envelope for hardening if needed.

## Minimal Implementation Checklist

GodotManager:

- Add app frame routing on the existing WebSocket endpoint.
- Add envelope validator/router.
- Keep payload opaque.
- Add correlation timeout cleanup.

GodotEWO:

- Add app bridge client and request helper (`sendAppRequest`).
- Track pending `correlation_id` futures/promises.
- Emit WinCC OA callbacks/signals for app events.

Godot project:

- Add app bridge node using the manager endpoint and app envelope.
- Register `route` + `schema_version` via `app_hello`.
- Implement per-project method handlers.

## Sequence (Happy Path)

1. EWO connects control plane and requests project load (existing flow).
2. Project starts and enables app bridge handling for `app_*` frames.
3. Project sends `app_hello` registration.
4. EWO sends `app_request` with `method` + `payload.params`.
5. Project handles method and returns `app_response`.
6. Project can push `app_event` for state changes.

## Component Viewer Route API (`route = "component-viewer"`)

This section defines the project-specific methods currently implemented by this workspace for WinCC OA EWO integration.

### Methods from EWO to Project

#### 0) `ping`

Health check method.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- `ok`: `true`
- `time_ms`: engine tick time in milliseconds

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "d7165c3a-4f39-4d32-89f7-d08cb4cf0f97",
  "method": "ping",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

#### 0a) `get_state`

Returns the current project state snapshot.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- Current project state snapshot (see "State Fields Useful for EWO").

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "2ac9b4d9-00c2-4455-95cb-9efc9d0a2b52",
  "method": "get_state",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

#### 1) `load_machine`

Loads a new machine scene.

`payload.params`:

- `machine_name` (string, optional) or `name` (string, alias)
- `camera_transform` (optional):
  - `position`: `{x,y,z}`
  - `rotation`: `{x,y,z}`

Behavior:

- Resolves machine scene path as `res://machine_scenes/<machine_name>/<machine_name>.scn` first, then falls back to `.tscn`.
- Machine name matching is case-insensitive against folders under `res://machine_scenes`.
- If `camera_transform` is provided, camera transform is applied immediately before loading.
- Replaces children under `World` with the loaded machine scene.
- Clears all currently shown boxes before showing content for the new machine.
- By default, load resets camera to the viewer default camera orientation; this reset is skipped when `camera_transform` is supplied.
- If `machine_name` is omitted (empty params), current machine scene is unloaded (backward-compatible behavior).

Success result (`app_response.payload.result`):

- Current project state snapshot (same shape as `get_state`).

Errors (`app_error.payload.error.code`):

- `invalid_request` when `machine_name` contains path separators.
- `invalid_request` when `camera_transform` is provided but invalid.
- `machine_not_found` when resolved scene file does not exist.
- `load_machine_failed` when scene cannot be loaded/instantiated.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "f8f7d95f-b58d-4a4f-a8b3-8dfd32c8d91a",
  "method": "load_machine",
  "payload": {
    "schema_version": 1,
    "params": {
      "machine_name": "GP400"
    }
  }
}
```

Unload example (no params):

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "a10f4307-912e-4890-89dd-8617d7aa495b",
  "method": "load_machine",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

#### 1a) `unload_machine`

Unloads the currently loaded machine scene, if any.

`payload.params`: none required.

Behavior:

- Removes current machine children under `World`.
- Clears currently shown boxes.
- If no machine is currently loaded, this is a no-op.

Success result (`app_response.payload.result`):

- Current project state snapshot (same shape as `get_state`).

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "36e4f383-a9cc-4ee7-a895-747f105bc2ef",
  "method": "unload_machine",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

#### 1b) `set_tool`

Sets which tool is visible for machines that expose a tool-selection node.

`payload.params`:

- `tool_name` (string, optional) or `name` (string, alias)

Behavior:

- Searches loaded machine scene for first `Node3D` named `Tool` or `Tools` (case-insensitive).
- Under that tool node, treats direct children as tool groups.
- If `tool_name` matches one of those children (case-insensitive), meshes under that child are shown and meshes under sibling tool groups are hidden.
- If `tool_name` is empty string, meshes under all tool groups are hidden.

Success result (`app_response.payload.result`):

- Current project state snapshot (same shape as `get_state`).

Errors (`app_error.payload.error.code`):

- `machine_not_loaded` when no machine is currently loaded.
- `tools_not_available` when loaded machine does not expose a `Tool`/`Tools` node.
- `tool_not_found` when requested `tool_name` is not found under tool node.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "9e79b9ea-57a5-4b9e-9708-713dd56d5bb1",
  "method": "set_tool",
  "payload": {
    "schema_version": 1,
    "params": {
      "tool_name": "Gripper"
    }
  }
}
```

Hide-all example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "79a243fd-e3cc-4135-9a22-0e93dfef7882",
  "method": "set_tool",
  "payload": {
    "schema_version": 1,
    "params": {
      "tool_name": ""
    }
  }
}
```

#### 2) `show_box`

Shows a box from an explicit transform payload and applies a camera transform.

`payload.params`:

- `box_transform` (required):
  - `position`: `{x,y,z}`
  - `rotation`: `{x,y,z}`
  - `scale`: `{x,y,z}` (optional, defaults to viewer `default_box_scale`)
- `camera_transform` (optional):
  - `position`: `{x,y,z}`
  - `rotation`: `{x,y,z}`
- `move_camera` (bool, optional, default `true`)
- `replace_existing` (bool, optional, default `true` when single-box mode is enabled)
- `boxId` (string, optional): caller-defined identifier for the shown box
- `color` (optional): box color override; transparency is preserved

Accepted `color` formats:

- `"#RRGGBB"` or `"#RRGGBBAA"`
- WinCC OA RGB string `"{123,23,46}"` (channels accepted as `0..255` or `0..1`)
- dictionary `{ "r": ..., "g": ..., "b": ... }` using either `0..1` or `0..255`

Behavior:

- Adds a new box from `box_transform`.
- In current single-box display mode, existing boxes are replaced by default.
- `replace_existing=false` is supported to keep multi-box workflows compatible.
- If `color` is provided, selected box color changes to that color while keeping existing transparency.
- If `color` is not provided, selected box uses the default green color.
- Color override is persisted for that shown box and is reapplied during internal display refreshes until replaced/reset by a subsequent call.
- If `boxId` is provided, it is stored on the created box and can be used later with `hide_box`.
- The shown box runs a 3-second fade pulse for attention (in display mode).
- If `move_camera` is true and `camera_transform` is provided, camera glides to `camera_transform`.
- If `camera_transform` is omitted, camera remains at current transform.

Success result (`app_response.payload.result`):

- Current project state snapshot.

Errors (`app_error.payload.error.code`):

- `invalid_request` when `box_transform` is missing/invalid.
- `invalid_request` when `camera_transform` is provided but invalid.
- `invalid_request` when `color` format is invalid.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "5962f8be-60af-48dd-8245-b421ef3d4263",
  "method": "show_box",
  "payload": {
    "schema_version": 1,
    "params": {
      "box_transform": {
        "position": {"x": 2.0, "y": 1.0, "z": -3.5},
        "rotation": {"x": 0.0, "y": 1.5708, "z": 0.0},
        "scale": {"x": 0.25, "y": 0.25, "z": 0.25}
      },
      "camera_transform": {
        "position": {"x": 4.0, "y": 2.0, "z": -5.0},
        "rotation": {"x": -0.2, "y": 0.9, "z": 0.0}
      },
      "move_camera": true,
      "replace_existing": true,
      "boxId": "feeder_A_01",
      "color": "#FF6A00"
    }
  }
}
```

#### 2a) `get_box_transform`

Returns the transform of the currently shown box.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- `box_transform`: `{ position, rotation, scale }`

Errors (`app_error.payload.error.code`):

- `not_found` when no box is currently shown.

#### 2b) `get_camera_transform`

Returns current camera transform.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- `camera_transform`: `{ position, rotation }`

#### 2bb) `set_camera_transform`

Sets camera transform directly.

`payload.params`:

- `camera_transform` (required):
  - `position`: `{x,y,z}`
  - `rotation`: `{x,y,z}`
- `transition_sec` (optional, default viewer `default_view_transition_sec`)

Success result (`app_response.payload.result`):

- Current project state snapshot

Errors (`app_error.payload.error.code`):

- `invalid_request` when `camera_transform` is missing/invalid.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "997d6cbf-f81d-48e0-ab65-f3fb7d8ac7ad",
  "method": "set_camera_transform",
  "payload": {
    "schema_version": 1,
    "params": {
      "camera_transform": {
        "position": {"x": 4.0, "y": 2.0, "z": -5.0},
        "rotation": {"x": -0.2, "y": 0.9, "z": 0.0}
      },
      "transition_sec": 1.0
    }
  }
}
```

#### 2c) `list_machine_scenes`

Returns available machine scene names discovered under `res://machine_scenes`.

Behavior:

- Includes a machine name when either `<machine_name>.scn` or `<machine_name>.tscn` exists in that machine folder.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- `machine_names`: string array

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "ea1bb92d-3aa7-4b3d-a16d-90ebec6fece0",
  "method": "list_machine_scenes",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

Example result:

```json
{
  "machine_names": ["GP400", "MW-HT"]
}
```

#### 2d) `hide_boxes`

Removes all currently shown boxes.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- `removed_count`: integer
- `state`: current project state snapshot

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "17f058f5-9fc7-4ae4-8d06-c29d383d2272",
  "method": "hide_boxes",
  "payload": {
    "schema_version": 1,
    "params": {}
  }
}
```

#### 2da) `hide_box`

Removes a currently shown box by id.

`payload.params`:

- `boxId` (required, string)

Success result (`app_response.payload.result`):

- Current project state snapshot

Errors (`app_error.payload.error.code`):

- `invalid_request` when `boxId` is missing.
- `not_found` when no shown box matches `boxId`.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "099132d2-f8f1-44b1-8d13-78b78675af91",
  "method": "hide_box",
  "payload": {
    "schema_version": 1,
    "params": {
      "boxId": "13"
    }
  }
}
```

#### 2e) `set_selected_box_transform`

Updates the transform of the currently selected box.

`payload.params`:

- `box_transform` (required):
  - `position`: `{x,y,z}`
  - `rotation`: `{x,y,z}`
  - `scale`: `{x,y,z}` (optional, defaults to viewer `default_box_scale`)

Success result (`app_response.payload.result`):

- Current project state snapshot

Errors (`app_error.payload.error.code`):

- `not_found` when no box is currently selected.
- `invalid_request` when `box_transform` is missing/invalid.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "7ef8f7a5-2168-4baf-bf2e-155d42527b27",
  "method": "set_selected_box_transform",
  "payload": {
    "schema_version": 1,
    "params": {
      "box_transform": {
        "position": {"x": 1.5, "y": 0.4, "z": -2.2},
        "rotation": {"x": 0.0, "y": 0.7, "z": 0.0},
        "scale": {"x": 0.25, "y": 0.25, "z": 0.25}
      }
    }
  }
}
```

#### 3) `set_editor_mode`

Sets editor mode explicitly.

`payload.params`:

- `enabled` (bool, required)

Behavior:

- `true`: editor workflows active (selection/gizmo logic).
- `false`: display mode active; user can still navigate camera.

Success result (`app_response.payload.result`):

- Current project state snapshot.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "6d8d9c30-812c-4dd3-a4cd-7a3076e8d02f",
  "method": "set_editor_mode",
  "payload": {
    "schema_version": 1,
    "params": {
      "enabled": false
    }
  }
}
```

#### 3a) `set_editor_sub_mode`

Sets editor sub mode.

`payload.params`:

- `mode` (string, required): `SELECT` or `ADD`

Success result (`app_response.payload.result`):

- Current project state snapshot.

Example:

```json
{
  "type": "app_request",
  "route": "component-viewer",
  "correlation_id": "f9f18b20-4e5c-4ca4-9d1f-f95cc52db0da",
  "method": "set_editor_sub_mode",
  "payload": {
    "schema_version": 1,
    "params": {
      "mode": "ADD"
    }
  }
}
```

#### 4) `toggle_editor_mode`

Toggles editor mode.

`payload.params`: none required.

Success result (`app_response.payload.result`):

- Current project state snapshot.

### State Fields Useful for EWO

Current state snapshot includes:

- `editor_mode` (bool)
- `editor_sub_mode` (string)
- `gizmo_tool` (string)
- `selected_box_index` (int, `-1` when none)
- `display_box_index` (int, `-1` when none)
- `display_mode_active` (bool)
- `box_count` (int)
- `machine_name` (string)
- `machine_scene_path` (string)
- `tool_name` (string, empty when no tool selected)
- `camera.position` / `camera.rotation` (vector dictionaries)

### Project Events Emitted

The project emits `app_event` frames with the following behavior:

- `viewer_ready`: Sent when the IPC bridge connects and the project is ready to serve app requests.
- `machine_loaded`: Sent after `load_machine` succeeds.
- `machine_unloaded`: Sent when `unload_machine` succeeds, or when `load_machine` is called without `machine_name` and an active machine is unloaded.
- `tool_changed`: Sent after `set_tool` succeeds.
- `display_box_changed`: Sent after display target box changes (for example via `show_box`).
- `box_deleted`: Sent when a box is deleted (Delete key or IPC deletion path).
- `boxes_hidden`: Sent when all boxes are removed via `hide_boxes` (or internal hide-all flow).
- `box_transform_updated`: Sent when a selected box transform changes. Triggered on box selection, gizmo edit release (left mouse button up), and `set_selected_box_transform`.
- `camera_transform_updated`: Sent when camera transform is changed via `set_camera_transform`.
- `editor_mode_changed`: Sent whenever `set_editor_mode` or `toggle_editor_mode` changes editor mode.
- `selection_changed`: Sent when selection is set or cleared.
- `box_view_captured`: Sent after capturing current camera view into the selected box.
- `camera_view_applied`: Sent after applying a selected box's saved camera view.