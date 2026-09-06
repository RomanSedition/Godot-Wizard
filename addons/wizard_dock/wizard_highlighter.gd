@tool
class_name WizardHighlighter
extends RefCounted

## Draws a pulsing orange box over an editor UI element so the user can see
## exactly what a checklist step is pointing at, plus a broader translucent
## green box around the dock/tab panel that item lives in (so it's obvious
## which panel to even look at). Two targeting strategies, tried in order:
## - Scene Tree row: for scene-select/scene-rename steps, finds the Scene
##   dock's Tree control and boxes the row whose item text matches search_text.
## - Generic control: recursively searches the editor's base control for any
##   visible Control whose name/text/tooltip contains search_text (covers
##   dock buttons, tabs, checkboxes; also the fallback if no tree row hits).
##
## No custom step "kind" needed — this operates on whatever search_text a
## step already carries, regardless of kind.

const OVERLAY_COLOR := Color(1.0, 0.667, 0.0, 1.0)  # #ffaa00 — matches the dock's manual-checkbox orange
const CONTAINER_COLOR := Color(0.2, 0.9, 0.3, 1.0)  # green — boxes the containing dock/tab panel
const PULSE_PERIOD := 0.9
const AUTO_CLEAR_SECONDS := 5.0

static var _instance: WizardHighlighter = null

static func get_instance() -> WizardHighlighter:
	return _instance

static func set_instance(inst: WizardHighlighter) -> void:
	_instance = inst

var _tree_ref: SceneTree = null
var _overlay: Control = null

func setup(tree: SceneTree) -> void:
	_tree_ref = tree

func clear() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null

## Boxes whatever step.search_text resolves to. Returns true if a target was
## found and highlighted, false if nothing matched (nothing is drawn then).
func highlight_step(step: Dictionary) -> bool:
	clear()
	var kind: String = step.get("kind", "manual")
	var search: String = step.get("search_text", "")
	if search.is_empty():
		return false
	var lname := search.to_lower()

	var rect := Rect2()
	var owner_node: Node = null
	if kind == "scene-select" or kind == "scene-rename":
		var tree := _find_scene_tree()
		if tree != null:
			rect = _find_scene_tree_row_rect(tree, lname)
			if rect.size != Vector2.ZERO:
				owner_node = tree

	if rect.size == Vector2.ZERO:
		var control := _find_control_by_text(EditorInterface.get_base_control(), lname)
		if control != null:
			rect = control.get_global_rect()
			owner_node = control

	if rect.size == Vector2.ZERO:
		return false

	var container_rect := Rect2()
	if owner_node != null:
		var container := _find_ancestor_container(owner_node)
		if container != null:
			container_rect = container.get_global_rect()

	_show_overlay(rect, container_rect)
	return true

func _show_overlay(rect: Rect2, container_rect: Rect2) -> void:
	var has_container := container_rect.size != Vector2.ZERO
	var item_rect := Rect2(rect.position - Vector2(4, 4), rect.size + Vector2(8, 8))
	var union_rect := item_rect
	if has_container:
		union_rect = union_rect.merge(container_rect)

	var base := EditorInterface.get_base_control()
	var overlay := Control.new()
	overlay.name = "WizardHighlightOverlay"
	overlay.top_level = true
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = 4096
	base.add_child(overlay)
	overlay.global_position = union_rect.position
	overlay.size = union_rect.size

	var item_local := Rect2(item_rect.position - union_rect.position, item_rect.size)
	var container_local := Rect2(container_rect.position - union_rect.position, container_rect.size)
	overlay.draw.connect(func():
		var t := Time.get_ticks_msec() / 1000.0
		var pulse := 0.5 + 0.5 * sin(t * TAU / PULSE_PERIOD)
		if has_container:
			var container_col := CONTAINER_COLOR
			container_col.a = lerp(0.2, 0.55, pulse)
			overlay.draw_rect(container_local, container_col, false, 3.0)
		var col := OVERLAY_COLOR
		col.a = lerp(0.35, 1.0, pulse)
		overlay.draw_rect(item_local, col, false, 3.0)
	)

	var pulse_timer := Timer.new()
	pulse_timer.wait_time = 0.05
	pulse_timer.autostart = true
	pulse_timer.timeout.connect(func():
		if is_instance_valid(overlay):
			overlay.queue_redraw()
	)
	overlay.add_child(pulse_timer)

	_overlay = overlay

	if _tree_ref != null:
		var clear_timer := _tree_ref.create_timer(AUTO_CLEAR_SECONDS)
		clear_timer.timeout.connect(func():
			if _overlay == overlay:
				clear()
		)

## --- Scene Tree row lookup ---

func _find_scene_tree() -> Tree:
	var editor := _find_by_class(EditorInterface.get_base_control(), "SceneTreeEditor")
	if editor == null:
		return null
	return _find_tree_child(editor)

func _find_scene_tree_row_rect(tree: Tree, lname: String) -> Rect2:
	var root := tree.get_root()
	if root == null:
		return Rect2()
	var item := _find_tree_item(root, lname)
	if item == null:
		return Rect2()
	var local_rect: Rect2 = tree.get_item_area_rect(item)
	if local_rect.size == Vector2.ZERO:
		return Rect2()
	return Rect2(tree.global_position + local_rect.position, local_rect.size)

## Walks up from `start` looking for the nearest ancestor that represents a
## whole dock/tab panel — a TabContainer (how docked panels are grouped, e.g.
## the Scene/Import tabs) first, falling back to the nearest PanelContainer.
## Returns null if neither is found (no green box drawn then, only the item).
func _find_ancestor_container(start: Node) -> Control:
	var node := start.get_parent()
	var fallback: Control = null
	while node != null:
		if node is TabContainer:
			return node
		if fallback == null and node is PanelContainer:
			fallback = node
		node = node.get_parent()
	return fallback

func _find_by_class(node: Node, klass: String) -> Node:
	if node.get_class() == klass:
		return node
	for child in node.get_children():
		var found := _find_by_class(child, klass)
		if found != null:
			return found
	return null

func _find_tree_child(node: Node) -> Tree:
	for child in node.get_children():
		if child is Tree:
			return child
		var found := _find_tree_child(child)
		if found != null:
			return found
	return null

func _find_tree_item(item: TreeItem, lname: String) -> TreeItem:
	if String(item.get_text(0)).to_lower() == lname:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_tree_item(child, lname)
		if found != null:
			return found
		child = child.get_next()
	return null

## --- Generic editor-control lookup (dock buttons, tabs, checkboxes, …) ---

func _find_control_by_text(node: Node, lname: String) -> Control:
	if node is Control:
		var ctrl: Control = node
		if ctrl.visible and ctrl.size.x > 0.0 and ctrl.size.y > 0.0 and _control_matches(ctrl, lname):
			return ctrl
	for child in node.get_children():
		var found := _find_control_by_text(child, lname)
		if found != null:
			return found
	return null

func _control_matches(ctrl: Control, lname: String) -> bool:
	if String(ctrl.name).to_lower().contains(lname):
		return true
	var text_val = ctrl.get("text")
	if text_val != null and String(text_val).to_lower().contains(lname):
		return true
	if not ctrl.tooltip_text.is_empty() and ctrl.tooltip_text.to_lower().contains(lname):
		return true
	return false
