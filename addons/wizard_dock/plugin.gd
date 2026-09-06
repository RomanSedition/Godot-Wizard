@tool
extends EditorPlugin

## Wizard dock: a guided checklist for step-by-step editor tasks, driven by
## an AI agent via two MCP custom tools (wizard_set_steps / wizard_get_steps,
## registered with Godot AI's McpToolRegistry). Port of the earlier C#/.NET
## version, rebuilt in pure GDScript so it runs on the non-Mono Godot build.
##
## Each checklist row shows two checkboxes: an auto-verified one (disabled,
## ticked by WizardWatcher when a watched signal fires) and a manual one
## (always user-editable, orange, for steps that can't be auto-verified —
## the user ticks it themselves to say "I believe I've done this"). Below
## the checklist, an "Active Watches" section lists whatever live signal
## connections WizardWatcher currently holds, each individually clearable.

const WizardModelScript := preload("res://addons/wizard_dock/wizard_model.gd")
const WizardWatcherScript := preload("res://addons/wizard_dock/wizard_watcher.gd")
const WizardHighlighterScript := preload("res://addons/wizard_dock/wizard_highlighter.gd")

const SOURCE_PATH := "res://addons/wizard_dock/plugin.cfg"
const HANDLER_PATH := "res://addons/wizard_dock/wizard_tools_handler.gd"
const MANUAL_COLOR := Color(1.0, 0.667, 0.0, 1.0)  # #ffaa00

var _model: WizardModel
var _watcher: WizardWatcher
var _highlighter: WizardHighlighter
var _root: Control
var _steps_container: VBoxContainer
var _watches_container: VBoxContainer
var _registered: bool = false

func _enter_tree() -> void:
	_model = WizardModelScript.new()
	WizardModel.set_instance(_model)

	_watcher = WizardWatcherScript.new()
	_watcher.setup(_model)
	WizardWatcher.set_instance(_watcher)

	_highlighter = WizardHighlighterScript.new()
	_highlighter.setup(get_tree())
	WizardHighlighter.set_instance(_highlighter)

	_model.steps_changed.connect(_refresh_ui)
	_watcher.watches_changed.connect(_refresh_watches_ui)

	_build_dock()
	_refresh_ui()
	_refresh_watches_ui()
	_try_register_tools()


func _exit_tree() -> void:
	var registry := McpToolRegistry.get_instance()
	if registry != null:
		registry.unregister_source(SOURCE_PATH)

	if _watcher != null:
		_watcher.clear_all()
	WizardWatcher.set_instance(null)

	if _highlighter != null:
		_highlighter.clear()
	WizardHighlighter.set_instance(null)

	WizardModel.set_instance(null)

	if _root != null:
		remove_control_from_docks(_root)
		_root.queue_free()
		_root = null


func _try_register_tools() -> void:
	if _registered:
		return
	var registry := McpToolRegistry.get_instance()
	if registry == null:
		# Godot AI hasn't finished its own _enter_tree yet (plugin load order
		# isn't guaranteed) — retry shortly instead of failing silently.
		get_tree().create_timer(0.5).timeout.connect(_try_register_tools)
		return

	var set_spec := McpCustomToolSpec.new()
	set_spec.name = "wizard_set_steps"
	set_spec.description = ("Replace the Wizard checklist with a new step sequence. Kinds (parallel " +
		"'kinds', default 'manual'): 'scene-select' — a Node matched by current name, confirmed on " +
		"selection. 'scene-rename' — a Node, confirmed by its rename signal, or immediately if a " +
		"node named the parallel 'target_values' entry already exists. 'resource-create' — a res:// " +
		"file/folder matched by name, confirmed once it exists in the project. 'manual' — not " +
		"auto-verifiable; only the dock's orange manual-confirm checkbox applies. Already-satisfied " +
		"steps auto-tick at arm time. Setting new steps clears existing watches first.")
	set_spec.params_schema = {
		"type": "object",
		"properties": {
			"labels": {"type": "array", "items": {"type": "string"}, "description": "Ordered step labels."},
			"search_texts": {"type": "array", "items": {"type": "string"}, "description": "Parallel search texts: exact current Node name for scene-select/scene-rename, exact file/folder name for resource-create, ignored for manual. Must be the same length as labels."},
			"kinds": {"type": "array", "items": {"type": "string", "enum": WizardModel.VALID_KINDS}, "description": "Parallel step-kind array. Omit to default every step to 'manual'."},
			"target_values": {"type": "array", "items": {"type": "string"}, "description": "Parallel array, meaningful only for 'scene-rename': the name the node is being renamed TO."},
		},
		"required": ["labels", "search_texts"],
	}
	set_spec.script_path = HANDLER_PATH
	set_spec.method = &"set_steps"
	set_spec.source_path = SOURCE_PATH
	set_spec.source = "Wizard"
	set_spec.requires_writable = false
	set_spec.undoable = false

	var get_spec := McpCustomToolSpec.new()
	get_spec.name = "wizard_get_steps"
	get_spec.description = ("Return the Wizard dock's current checklist: each step's label, kind, " +
		"search_text, target_value, the auto-verified 'checked' state, and 'manual_confirmed' — the " +
		"user-toggled orange checkbox for steps that can't be auto-verified. Poll this after asking " +
		"the user to do something unverifiable to see whether they've self-reported it done, then " +
		"verify the real state yourself — manual_confirmed is a claim, not proof.")
	get_spec.params_schema = {"type": "object", "properties": {}}
	get_spec.script_path = HANDLER_PATH
	get_spec.method = &"get_steps"
	get_spec.source_path = SOURCE_PATH
	get_spec.source = "Wizard"
	get_spec.requires_writable = false
	get_spec.undoable = false

	var highlight_spec := McpCustomToolSpec.new()
	highlight_spec.name = "wizard_highlight_step"
	highlight_spec.description = ("Box the given checklist step's on-screen target with a pulsing orange " +
		"overlay so the user can see where to look. Tries a Scene Tree row (scene-select/scene-rename " +
		"steps) first, falling back to any editor UI control whose name/text/tooltip matches search_text " +
		"(dock buttons, tabs, checkboxes). Clears automatically after a few seconds. Returns 'highlighted': " +
		"false if nothing matched.")
	highlight_spec.params_schema = {
		"type": "object",
		"properties": {
			"index": {"type": "integer", "description": "0-based index into the current checklist (see wizard_get_steps)."},
		},
		"required": ["index"],
	}
	highlight_spec.script_path = HANDLER_PATH
	highlight_spec.method = &"highlight_step"
	highlight_spec.source_path = SOURCE_PATH
	highlight_spec.source = "Wizard"
	highlight_spec.requires_writable = false
	highlight_spec.undoable = false

	var specs: Array[McpCustomToolSpec] = [set_spec, get_spec, highlight_spec]
	_registered = registry.batch_register(specs)


func _build_dock() -> void:
	var root := VBoxContainer.new()
	root.name = "Wizard"

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)

	var header := HBoxContainer.new()
	var header_label := Label.new()
	header_label.text = "Checklist"
	header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_label)

	var redo_button := Button.new()
	redo_button.text = "Redo"
	redo_button.tooltip_text = "Redo Checklist (reset all steps and re-arm from step 1)"
	redo_button.pressed.connect(func():
		_model.reset_all_checked()
		_watcher.arm_all()
	)
	header.add_child(redo_button)
	inner.add_child(header)

	_steps_container = VBoxContainer.new()
	inner.add_child(_steps_container)

	var clear_button := Button.new()
	clear_button.text = "Clear All Tasks"
	clear_button.pressed.connect(func():
		_model.clear_steps()
		_watcher.clear_all()
	)
	inner.add_child(clear_button)

	inner.add_child(HSeparator.new())

	var watches_label := Label.new()
	watches_label.text = "Active Watches"
	inner.add_child(watches_label)

	_watches_container = VBoxContainer.new()
	inner.add_child(_watches_container)

	var clear_watches_button := Button.new()
	clear_watches_button.text = "Clear All Watches"
	clear_watches_button.pressed.connect(func(): _watcher.clear_all())
	inner.add_child(clear_watches_button)

	_root = root
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, root)


func _refresh_ui() -> void:
	if _steps_container == null:
		return
	for child in _steps_container.get_children():
		child.queue_free()

	var steps := _model.get_steps_snapshot()
	for i in range(steps.size()):
		var step: Dictionary = steps[i]
		var row := HBoxContainer.new()

		var auto_check := CheckBox.new()
		auto_check.button_pressed = step.get("checked", false)
		auto_check.disabled = true
		auto_check.tooltip_text = "Auto-verified: ticked automatically once the tracked action is detected."
		row.add_child(auto_check)

		var manual_check := CheckBox.new()
		manual_check.button_pressed = step.get("manual_confirmed", false)
		manual_check.modulate = MANUAL_COLOR
		manual_check.tooltip_text = "Manual confirmation: check this yourself once you believe you've completed this step. This can't be auto-verified, so it's just a note for the agent to go check."
		var idx := i
		manual_check.toggled.connect(func(pressed: bool): _model.set_manual_confirmed(idx, pressed))
		row.add_child(manual_check)

		var label := Label.new()
		label.text = "%d. %s" % [i + 1, step.get("label", "")]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.tooltip_text = step.get("label", "")
		row.add_child(label)

		var ping_button := Button.new()
		ping_button.text = "Ping"
		ping_button.pressed.connect(func(): _watcher.ping_step(idx))
		row.add_child(ping_button)

		var highlight_button := Button.new()
		highlight_button.text = "Highlight"
		highlight_button.tooltip_text = "Box this step's target on-screen for a few seconds (Scene Tree row, or a matching dock control)."
		highlight_button.pressed.connect(func(): _highlighter.highlight_step(step))
		row.add_child(highlight_button)

		_steps_container.add_child(row)

	if steps.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no active checklist)"
		_steps_container.add_child(empty_label)


func _refresh_watches_ui() -> void:
	if _watches_container == null:
		return
	for child in _watches_container.get_children():
		child.queue_free()

	var watches := _watcher.list_watches()
	for i in range(watches.size()):
		var row := HBoxContainer.new()

		var label := Label.new()
		label.text = watches[i]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		row.add_child(label)

		var clear_button := Button.new()
		clear_button.text = "Clear"
		var idx := i
		clear_button.pressed.connect(func(): _watcher.clear_watch(idx))
		row.add_child(clear_button)

		_watches_container.add_child(row)

	if watches.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(none)"
		_watches_container.add_child(empty_label)
