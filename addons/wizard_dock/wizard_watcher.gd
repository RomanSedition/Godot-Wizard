@tool
class_name WizardWatcher
extends RefCounted

## Watches live editor signals to auto-check Wizard steps. Three watchable
## kinds: scene-select (EditorSelection.selection_changed), scene-rename (a
## specific Node's own "renamed" signal), resource-create (EditorFileSystem's
## "filesystem_changed" signal). "manual" steps are never auto-watched — only
## the dock's own manual-confirm checkbox can check them.

static var _instance: WizardWatcher = null

static func get_instance() -> WizardWatcher:
	return _instance

static func set_instance(inst: WizardWatcher) -> void:
	_instance = inst

var _model: WizardModel
var _selection_connected: bool = false
var _filesystem_connected: bool = false
var _rename_hooks: Array = []  # [{node, callable, target}] for clean disconnect + display

signal watches_changed

func setup(model: WizardModel) -> void:
	_model = model

func clear_all() -> void:
	_disconnect_selection()
	for hook in _rename_hooks.duplicate():
		_disconnect_rename_hook(hook)
	_rename_hooks.clear()
	_disconnect_filesystem()
	watches_changed.emit()

## Arms every unchecked step: checks for an already-satisfied state, and
## connects the live watch for kinds that need one.
func arm_all() -> void:
	clear_all()
	var steps: Array = _model.steps
	for i in range(steps.size()):
		_arm_step(i, steps[i])

## Re-attempts arming/checking one step (the dock's per-row "Ping" button).
func ping_step(index: int) -> void:
	var steps: Array = _model.steps
	if index < 0 or index >= steps.size():
		return
	_arm_step(index, steps[index])

## Human-readable list of currently-connected watches, in the same order
## clear_watch(index) expects: selection watch, then filesystem watch, then
## one entry per armed rename hook.
func list_watches() -> Array[String]:
	var out: Array[String] = []
	if _selection_connected:
		out.append("Selection watch (scene-select steps)")
	if _filesystem_connected:
		out.append("Filesystem watch (resource-create steps)")
	for hook in _rename_hooks:
		var node = hook["node"]
		var target: String = hook.get("target", "")
		var node_name: String = String(node.name) if is_instance_valid(node) else "(freed node)"
		if target.is_empty():
			out.append("Rename watch: %s" % node_name)
		else:
			out.append("Rename watch: %s -> %s" % [node_name, target])
	return out

## Clears one watch by its index into list_watches()'s array.
func clear_watch(index: int) -> void:
	var i := index
	if _selection_connected:
		if i == 0:
			_disconnect_selection()
			watches_changed.emit()
			return
		i -= 1
	if _filesystem_connected:
		if i == 0:
			_disconnect_filesystem()
			watches_changed.emit()
			return
		i -= 1
	if i >= 0 and i < _rename_hooks.size():
		var hook = _rename_hooks[i]
		_disconnect_rename_hook(hook)
		_rename_hooks.remove_at(i)
		watches_changed.emit()

func _arm_step(index: int, step: Dictionary) -> void:
	if step.get("checked", false):
		return
	var kind: String = step.get("kind", WizardModel.KIND_MANUAL)
	if kind == WizardModel.KIND_SCENE_SELECT:
		_ensure_selection_watch()
		_check_scene_select_now(index, step)
	elif kind == WizardModel.KIND_SCENE_RENAME:
		_arm_scene_rename(index, step)
	elif kind == WizardModel.KIND_RESOURCE_CREATE:
		_ensure_filesystem_watch()
		_check_resource_create_now(index, step)
	# else "manual" — nothing to watch, only the dock checkbox applies

func _ensure_selection_watch() -> void:
	if _selection_connected:
		return
	EditorInterface.get_selection().selection_changed.connect(Callable(self, "_on_selection_changed"))
	_selection_connected = true
	watches_changed.emit()

func _ensure_filesystem_watch() -> void:
	if _filesystem_connected:
		return
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(Callable(self, "_on_filesystem_changed"))
	_filesystem_connected = true
	watches_changed.emit()

func _disconnect_selection() -> void:
	var sel := EditorInterface.get_selection()
	if _selection_connected and sel.selection_changed.is_connected(Callable(self, "_on_selection_changed")):
		sel.selection_changed.disconnect(Callable(self, "_on_selection_changed"))
	_selection_connected = false

func _disconnect_filesystem() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	if _filesystem_connected and efs.filesystem_changed.is_connected(Callable(self, "_on_filesystem_changed")):
		efs.filesystem_changed.disconnect(Callable(self, "_on_filesystem_changed"))
	_filesystem_connected = false

func _disconnect_rename_hook(hook: Dictionary) -> void:
	var node = hook["node"]
	var callable = hook["callable"]
	if is_instance_valid(node) and node.renamed.is_connected(callable):
		node.renamed.disconnect(callable)

func _arm_scene_rename(index: int, step: Dictionary) -> void:
	var target: String = step.get("target_value", "")
	# Already satisfied: the rename already happened before this step armed.
	if not target.is_empty() and _find_node_by_name(target) != null:
		_model.mark_checked(index)
		return
	var node = _find_node_by_name(step.get("search_text", ""))
	if node == null:
		return
	var callable = Callable(self, "_on_node_renamed").bind(index, node, target)
	node.renamed.connect(callable)
	_rename_hooks.append({"node": node, "callable": callable, "target": target})
	watches_changed.emit()

func _on_node_renamed(index: int, node: Node, target: String) -> void:
	if target.is_empty() or node.name == target:
		_model.mark_checked(index)

func _on_selection_changed() -> void:
	var selected: Array = EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty():
		return
	var steps: Array = _model.steps
	for i in range(steps.size()):
		var step: Dictionary = steps[i]
		if step.get("checked", false) or step.get("kind", "") != WizardModel.KIND_SCENE_SELECT:
			continue
		_match_selection(i, step, selected)

func _match_selection(index: int, step: Dictionary, selected: Array) -> void:
	var search: String = String(step.get("search_text", "")).to_lower()
	for n in selected:
		if String(n.name).to_lower() == search:
			_model.mark_checked(index)
			return

func _check_scene_select_now(index: int, step: Dictionary) -> void:
	_match_selection(index, step, EditorInterface.get_selection().get_selected_nodes())

func _on_filesystem_changed() -> void:
	var steps: Array = _model.steps
	for i in range(steps.size()):
		var step: Dictionary = steps[i]
		if step.get("checked", false) or step.get("kind", "") != WizardModel.KIND_RESOURCE_CREATE:
			continue
		if _resource_exists(step.get("search_text", "")):
			_model.mark_checked(i)

func _check_resource_create_now(index: int, step: Dictionary) -> void:
	if _resource_exists(step.get("search_text", "")):
		_model.mark_checked(index)

## --- helpers ---

func _find_node_by_name(name: String) -> Node:
	if name.is_empty():
		return null
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	return _find_node_by_name_recursive(root, name.to_lower())

func _find_node_by_name_recursive(node: Node, lname: String) -> Node:
	if String(node.name).to_lower() == lname:
		return node
	for child in node.get_children():
		var found = _find_node_by_name_recursive(child, lname)
		if found != null:
			return found
	return null

func _resource_exists(name: String) -> bool:
	if name.is_empty():
		return false
	return _search_dir("res://", name.to_lower())

func _search_dir(path: String, lname: String) -> bool:
	var da := DirAccess.open(path)
	if da == null:
		return false
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if entry == ".godot" or entry == ".git":
			entry = da.get_next()
			continue
		var full := path.path_join(entry)
		var is_dir := da.current_is_dir()
		var base := entry if is_dir else entry.get_basename()
		if base.to_lower() == lname:
			da.list_dir_end()
			return true
		if is_dir:
			if _search_dir(full, lname):
				da.list_dir_end()
				return true
		entry = da.get_next()
	da.list_dir_end()
	return false
