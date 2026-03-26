extends Node
class_name ProjectIpcBridge

signal bridge_connected
signal bridge_disconnected
signal request_received(method: String, params: Dictionary, correlation_id: String, route: String)

@export var enabled: bool = false
@export var bridge_url: String = "ws://127.0.0.1:6100"
@export var route: String = "component-viewer"
@export var app_id: String = "component-viewer"
@export var schema_version: int = 1
@export var reconnect_interval_sec: float = 2.0
@export var debug_enabled: bool = true

var _ws: WebSocketPeer = WebSocketPeer.new()
var _reconnect_cooldown: float = 0.0
var _is_connected: bool = false

func _ready() -> void:
	set_process(enabled)
	if enabled:
		_try_connect()

func _process(delta: float) -> void:
	if !enabled:
		return

	if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _is_connected:
			_is_connected = false
			bridge_disconnected.emit()
			_debug("Bridge disconnected")

		_reconnect_cooldown -= delta
		if _reconnect_cooldown <= 0.0:
			_try_connect()
		return

	_ws.poll()

	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN and !_is_connected:
		_is_connected = true
		bridge_connected.emit()
		_send_app_hello()
		_debug("Bridge connected")

	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	while _ws.get_available_packet_count() > 0:
		var packet: PackedByteArray = _ws.get_packet()
		if !_ws.was_string_packet():
			continue
		_handle_text_packet(packet.get_string_from_utf8())

func send_response(correlation_id: String, result: Variant) -> void:
	_send_json({
		"type": "app_response",
		"route": route,
		"correlation_id": correlation_id,
		"payload": {
			"schema_version": schema_version,
			"result": result
		}
	})

func send_error(correlation_id: String, code: String, message: String, data: Variant = null) -> void:
	_send_json({
		"type": "app_error",
		"route": route,
		"correlation_id": correlation_id,
		"payload": {
			"schema_version": schema_version,
			"error": {
				"code": code,
				"message": message,
				"data": data
			}
		}
	})

func send_event(event_name: String, data: Variant = null) -> void:
	_send_json({
		"type": "app_event",
		"route": route,
		"payload": {
			"schema_version": schema_version,
			"event": event_name,
			"data": data
		}
	})

func is_bridge_connected() -> bool:
	return _is_connected and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

func _try_connect() -> void:
	_reconnect_cooldown = reconnect_interval_sec
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(bridge_url)
	if err != OK:
		_debug("Failed to connect bridge: %s (err=%d)" % [bridge_url, err])

func _handle_text_packet(text: String) -> void:
	var json := JSON.new()
	if json.parse(text) != OK:
		_debug("Ignoring invalid JSON packet")
		return

	if typeof(json.data) != TYPE_DICTIONARY:
		return

	var message: Dictionary = json.data
	var message_type: String = str(message.get("type", ""))

	if message_type != "app_request":
		return

	var message_route: String = str(message.get("route", ""))
	if message_route != "" and message_route != route:
		return

	var correlation_id: String = str(message.get("correlation_id", ""))
	if correlation_id == "":
		send_error("", "invalid_request", "Missing correlation_id")
		return

	var method: String = str(message.get("method", ""))
	if method == "":
		send_error(correlation_id, "invalid_request", "Missing method")
		return

	var payload: Dictionary = message.get("payload", {})
	var params: Dictionary = payload.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	request_received.emit(method, params, correlation_id, route)

func _send_app_hello() -> void:
	_send_json({
		"type": "app_hello",
		"route": route,
		"payload": {
			"schema_version": schema_version,
			"app_id": app_id,
			"project_name": str(ProjectSettings.get_setting("application/config/name", "")),
			"project_path": ProjectSettings.globalize_path("res://")
		}
	})

func _send_json(message: Dictionary) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return

	var text: String = JSON.stringify(message)
	_ws.send_text(text)

func _debug(message: String) -> void:
	if debug_enabled:
		print("[PROJECT_IPC] ", message)
