# Project Overview

This is a Godot 4.6 project for showing where machine components are located by placing 3D box volumes on top of machine meshes.
The project is run using libgodot in a WinCC OA Manager. The manager's libgodot instance is rendered on a WinCC OA EWO (Extended Widget Object).
The manager and EWO code can be found here: C:\Users\ottemot\Documents\Sandbox\GodotOA

## Core Intent

- Machine meshes are loaded on demand.
- Each machine loads with its corresponding component boxes.
- Component boxes are hidden by default and shown only when requested.
- The EWO is the user's interface. 
## Modes

### Display Mode

- The user views components from predefined camera angles.
- Selecting a component shows its box and moves the camera to that component's saved default view.

### Editor Mode

- The user can add and remove component boxes.
- The user can move, rotate, and scale boxes to match component locations.
- The user can save a default camera view for each box.
- Saved box camera views are used later in display mode when that component is selected.

## Goal

The project should make it easy to both author and present component locations on a machine: author them in editor mode, then review them in display mode with consistent, component-specific camera framing.

## Cross-Project IPC Architecture

- GodotManager and GodotEWO remain generic and project-agnostic.
- Project-specific API messages must be routed through GodotManager as an intermediate entity.
- Recommended split:
	- Control plane: existing manager protocol (hello, resize, focus, pause/resume, project switching, hwnd).
	- App plane: generic envelope routing between EWO and the active Godot project.

Protocol and implementation guidance is documented in:

- `APP_BRIDGE_PROTOCOL.md`

For this project, the Godot side includes an optional bridge node (`ProjectIPCBridge`) that can register to the app plane and handle project-specific methods/events when enabled.

## Protocol Maintenance Rules (Mandatory)

Future agents must keep protocol documentation detailed and synchronized with implementation changes.

When changing any bridge/API behavior, update docs in the same change:

- `APP_BRIDGE_PROTOCOL.md` for app envelope, message types, routing, schema, methods, events, and errors.
- `C:/Users/ottemot/Documents/Sandbox/GodotOA/GodotManager/IPC_PROTOCOL.md` for manager-level IPC contract changes.

Changes that always require documentation updates:

- New, removed, or renamed app message `type` values.
- Envelope field changes (`route`, `correlation_id`, `method`, `payload`, metadata fields).
- Method contract changes (parameters, defaults, result shapes, error codes).
- Event contract changes (event names, payload shape, emission timing).
- Schema/versioning behavior changes.
- Routing/lifecycle behavior changes (project switch cleanup, timeout behavior, disconnect handling).

Documentation quality requirements:

- Include at least one JSON example per new or changed message type.
- Clearly mark required vs optional fields.
- Describe manager-owned errors vs project-owned errors.
- Keep examples aligned with current implementation names and defaults.

Do not merge protocol-affecting changes without corresponding doc updates.
